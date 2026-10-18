import Foundation

/// Explicit metadata searches only. Navigation never starts library requests.
actor DataLibraryService {
    static let shared = DataLibraryService()
    private let session: URLSession
    private var results: [String:(DataLibraryResult, Date)] = [:]
    private var requests = 0
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration:config)
    }
    static func publicURL(_ raw: Any?) -> URL? {
        guard let text = raw as? String, let url = URL(string:text), url.scheme == "https",
              (try? CustomDataService.validateURL(url,format:.geoJSON)) != nil else { return nil }
        return url
    }
    static func searchURL(_ library: DataLibrary, query: String, bounds: PublicDataBounds, collection: String?, startDate: String?, endDate: String?, offset: Int) throws -> URL {
        guard library.canSearch, let endpoint = library.endpoint, bounds.isValid, query.count <= 200,
              (0...1000).contains(offset) else { throw KMLError.invalid("This library requires manual setup, or the search is invalid. Inspect its capability and source link.") }
        func validDay(_ value: String?) throws -> String? {
            guard let value else { return nil }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT:0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard value.count == 10, let date = formatter.date(from:value), formatter.string(from:date) == value else { throw KMLError.invalid("Use dates in YYYY-MM-DD format.") }
            return value
        }
        let start = try validDay(startDate), end = try validDay(endDate)
        if let start, let end, start > end { throw KMLError.invalid("The start date must precede the end date.") }
        guard collection == nil || (collection!.count <= 100 && collection!.allSatisfy { $0.isLetter || $0.isNumber || "_-".contains($0) }) else { throw KMLError.invalid("Choose a collection ID returned by collections.") }
        let bbox = "\(bounds.west),\(bounds.south),\(bounds.east),\(bounds.north)"
        var url = URLComponents(url:endpoint,resolvingAgainstBaseURL:false)!
        var params: [String:String] = [:]
        switch library.adapter {
        case .arcGIS:
            let atlas = library.name.contains("Living Atlas") ? " group:47dd57c9a59d458c86d3d6b978560088" : ""
            params = ["f":"json","q":"access:public AND (type:\"Feature Service\" OR type:\"Map Service\") " + PlaceDataDiscoveryService.safeTerm(query) + atlas,"bbox":bbox,"num":"20","start":String(offset+1)]
        case .stac:
            guard query.isEmpty else { throw KMLError.invalid("STAC searches use collection and dates. Call collections, then pass its collection ID; omit query.") }
            guard offset == 0 else { throw KMLError.invalid("Narrow the scene search by date or collection; scene searches return up to 20 results.") }
            url = URLComponents(url:endpoint.appendingPathComponent("search"),resolvingAgainstBaseURL:false)!
            params = ["bbox":bbox,"limit":"20"]
            if let collection, !collection.isEmpty { params["collections"] = collection }
            if start != nil || end != nil { params["datetime"] = (start.map { $0+"T00:00:00Z" } ?? "..") + "/" + (end.map { $0+"T23:59:59Z" } ?? "..") }
        case .openAerialMap:
            params = ["bbox":bbox,"limit":"20","page":String(offset/20+1)]
            if !query.isEmpty { params["title"] = query }
            if let start { params["acquisition_from"] = start }
            if let end { params["acquisition_to"] = end }
        case .socrata:
            params = ["q":query,"limit":"20","offset":String(offset),"only":"datasets"]
        case .openDataSoft:
            params = ["limit":"20","offset":String(offset),"refine":"features:geo"]
            if !query.isEmpty { params["where"] = "search(\"" + query.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"") + "\")" }
        case .reference: throw KMLError.invalid("Reference sources cannot be searched in the app.")
        }
        url.queryItems = params.sorted { $0.key < $1.key }.map { .init(name:$0.key,value:$0.value) }
        return url.url!
    }
    func search(_ library: DataLibrary, query: String, bounds: PublicDataBounds, collection: String? = nil, startDate: String? = nil, endDate: String? = nil, offset: Int = 0) async throws -> [DataLibraryResult] {
        try await searchPage(library,query:query,bounds:bounds,collection:collection,startDate:startDate,endDate:endDate,offset:offset).results
    }
    func searchPage(_ library: DataLibrary, query: String, bounds: PublicDataBounds, collection: String? = nil, startDate: String? = nil, endDate: String? = nil, offset: Int = 0) async throws -> DataLibrarySearchPage {
        let url = try Self.searchURL(library,query:query,bounds:bounds,collection:collection,startDate:startDate,endDate:endDate,offset:offset)
        let data = try await request(url)
        let rows = try Self.decode(data,adapter:library.adapter,libraryID:library.id,bounds:bounds)
        let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
        let total = object["total_count"] as? Int ?? object["total"] as? Int ?? object["resultSetSize"] as? Int ?? (object["meta"] as? [String:Any])?["found"] as? Int
        let rawCount = (object["results"] as? [Any])?.count ?? 0
        let more = library.adapter != .stac && offset < 1000 && (total.map { offset + 20 < $0 } ?? (rawCount >= 20))
        remember(rows)
        return .init(results:rows,hasMore:more)
    }
    func collections(_ library: DataLibrary) async throws -> [[String:String]] {
        guard library.adapter == .stac, let endpoint = library.endpoint else { throw KMLError.invalid("Collections are available for searchable STAC libraries only.") }
        let data = try await request(endpoint.appendingPathComponent("collections"))
        let object = try JSONSerialization.jsonObject(with:data) as? [String:Any]
        guard object?["error"] == nil, let items = object?["collections"] as? [[String:Any]] else { throw CustomDataError.unsupported }
        return items.prefix(100).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return ["id":id,"title":item["title"] as? String ?? id,"description":String((item["description"] as? String ?? "").prefix(1000)),"license":item["license"] as? String ?? "Not supplied"]
        }
    }
    func result(_ id: String) throws -> DataLibraryResult {
        guard let (item,date) = results[id], Date().timeIntervalSince(date) < 900 else { throw KMLError.invalid("Search result expired or unknown. Search again before choosing a result.") }
        return item
    }
    func readyResult(_ id: String) async throws -> DataLibraryResult {
        let item = try result(id)
        // Federated metadata can remain available when the actual data route is unavailable.
        // Probe one record in the selected area before persisting the connection.
        if let library = try DataLibrary.load().first(where: { $0.id == item.libraryID }), library.adapter == .openDataSoft, item.connectionURL != nil {
            var components = URLComponents(url:item.connectionURL!,resolvingAgainstBaseURL:false)!
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "limit" } + [.init(name:"limit",value:"1")]
            do {
                let object = try JSONSerialization.jsonObject(with:await request(components.url!)) as? [String:Any]
                guard object?["results"] is [[String:Any]], object?["total_count"] is Int else { throw CustomDataError.unavailable }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw KMLError.invalid("This catalog candidate is not currently accessible from its publisher. No layer was added. Choose another result or inspect the source; catalog metadata can outlive a dataset.")
            }
        }
        return item
    }
    func layers(_ id: String) async throws -> [DataLibraryResult] {
        let item = try result(id)
        guard item.displayKind == "service", let url = item.connectionURL else { throw KMLError.invalid("This result is not an ArcGIS service. Inspect can_add and notice.") }
        let source = DiscoveredDataService(id:item.sourceID,name:item.name,publisher:"Publisher source",url:url,modifiedAt:nil,sourceURL:item.sourceURL)
        let layers = try await PlaceDataDiscoveryService.shared.layers(in:source)
        let rows = layers.prefix(100).map { layer in DataLibraryResult(libraryID:item.libraryID,sourceID:item.sourceID+"/"+String(layer.id),name:layer.name,sourceURL:item.sourceURL,connectionURL:layer.url,connectionFormat:.arcGIS) }
        remember(rows); return rows
    }
    private func remember(_ rows: [DataLibraryResult]) {
        results = results.filter { Date().timeIntervalSince($0.value.1) < 900 }
        if results.count + rows.count > 500 { results.removeAll() }
        for row in rows { results[row.id] = (row,Date()) }
    }
    private func request(_ url: URL) async throws -> Data {
        while requests >= 2 { try await Task.sleep(for:.milliseconds(30)) }
        try Task.checkCancellation(); requests += 1; defer { requests -= 1 }
        var request = URLRequest(url:url); request.networkServiceType = .background
        let (bytes,response) = try await session.bytes(for:request); defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= 2_097_152 else { throw KMLError.invalid("Library unavailable, access restricted or response too large. Try a narrower search or open its source.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_097_152 else { throw CustomDataError.tooLarge }
            if data.count % 16384 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        return data
    }
    static func decode(_ data: Data, adapter: DataLibraryAdapter, libraryID: String, bounds: PublicDataBounds? = nil) throws -> [DataLibraryResult] {
        guard data.count <= 2_097_152, let object = try JSONSerialization.jsonObject(with:data) as? [String:Any], object["error"] == nil else { throw CustomDataError.unsupported }
        guard let records = object[adapter == .stac ? "features" : "results"] as? [[String:Any]] else { throw CustomDataError.unsupported }
        return records.prefix(20).compactMap { row in
            switch adapter {
            case .arcGIS:
                guard row["access"] as? String == "public", let id = row["id"] as? String, let url = publicURL(row["url"]) else { return nil }
                var result = DataLibraryResult(libraryID:libraryID,sourceID:id,name:row["title"] as? String ?? id,sourceURL:URL(string:"https://www.arcgis.com/home/item.html?id="+id))
                if (try? CustomDataService.validateURL(url,format:.arcGIS)) != nil { result.connectionURL = url; result.connectionFormat = .arcGIS }
                else if ["featureserver","mapserver"].contains(url.lastPathComponent.lowercased()) { result.connectionURL = url }
                if let modified = row["modified"] as? Double { result.updatedAt = Date(timeIntervalSince1970:modified/1000).ISO8601Format(); result.notice = "Catalog item modification date; not a verified dataset update. Choose a numbered layer before adding a service." }
                return result
            case .stac, .openAerialMap:
                let props = row["properties"] as? [String:Any] ?? [:]
                let id = row["id"] as? String ?? row["_id"] as? String ?? UUID().uuidString
                var result = DataLibraryResult(libraryID:libraryID,sourceID:id,name:row["title"] as? String ?? id,sourceURL:publicURL(row["meta_uri"]))
                result.captureDate = (adapter == .stac ? props["datetime"] ?? props["start_datetime"] : row["acquisition_start"]) as? String
                result.captureEndDate = (adapter == .stac ? props["end_datetime"] : row["acquisition_end"]) as? String
                result.updatedAt = props["updated"] as? String
                result.cloudCover = (props["eo:cloud_cover"] as? Double).flatMap { (0...100).contains($0) ? $0 : nil }
                result.collection = row["collection"] as? String
                if adapter == .stac {
                    for (name,raw) in (row["assets"] as? [String:[String:Any]] ?? [:]).sorted(by: { $0.key < $1.key }).prefix(30) {
                        if let url = publicURL(raw["href"]) { result.assets.append(.init(name:name,url:url,mediaType:raw["type"] as? String)) }
                    }
                    let links = row["links"] as? [[String:Any]] ?? []
                    result = withSource(result,url:links.first { $0["rel"] as? String == "self" }.flatMap { publicURL($0["href"]) })
                } else {
                    for name in ["thumbnail","tms","wmts"] { if let url = publicURL(props[name]) { result.assets.append(.init(name:name,url:url,mediaType:nil)) } }
                    if let url = publicURL(row["uuid"]) { result.assets.append(.init(name:"image",url:url,mediaType:"image/tiff")) }
                }
                if let geometry = row[adapter == .stac ? "geometry" : "geojson"] as? [String:Any] {
                    let feature: [String:Any] = ["type":"Feature","properties":["name":result.name,"capture_date":result.captureDate ?? "Not supplied","source_id":id],"geometry":geometry]
                    result.footprint = try? CustomDataService.decodeGeoJSON(data:JSONSerialization.data(withJSONObject:feature)).features.first
                }
                result.notice = "Scene footprint only, not imagery pixels. Capture dates are source metadata; assets may require authentication, payment or a raster renderer."
                return result
            case .socrata:
                guard let resource = row["resource"] as? [String:Any], let id = resource["id"] as? String,
                      id.range(of:"^[a-z0-9]{4}-[a-z0-9]{4}$",options:.regularExpression) != nil,
                      let metadata = row["metadata"] as? [String:Any], let domain = metadata["domain"] as? String,
                      domain.range(of:"^[a-zA-Z0-9.-]+$",options:.regularExpression) != nil else { return nil }
                var result = DataLibraryResult(libraryID:libraryID,sourceID:domain+"/"+id,name:resource["name"] as? String ?? id,sourceURL:publicURL(row["link"]))
                result.updatedAt = resource["updatedAt"] as? String
                let fields = resource["columns_field_name"] as? [String] ?? [], types = resource["columns_datatype"] as? [String] ?? []
                if let index = types.firstIndex(where: { ["point","location","multipoint","line","multiline","polygon","multipolygon"].contains($0.lowercased()) }), fields.indices.contains(index), fields[index].range(of:"^[a-zA-Z_][a-zA-Z0-9_]*$",options:.regularExpression) != nil, let bounds {
                    var components = URLComponents(string:"https://\(domain)/resource/\(id).geojson")!
                    components.queryItems = [.init(name:"$limit",value:"300"),.init(name:"$where",value:"within_box(\(fields[index]),\(bounds.north),\(bounds.west),\(bounds.south),\(bounds.east))")]
                    result.connectionURL = components.url; result.connectionFormat = .geoJSON
                    result.notice = "Bounded to the area of this search; refresh rechecks that same area. Search again to change the area. Coverage and publisher terms require verification."
                } else { result.notice = "No supported geographic column was advertised. Open the publisher or choose another dataset." }
                return result
            case .openDataSoft:
                guard let id = row["dataset_id"] as? String else { return nil }
                let metas = (row["metas"] as? [String:[String:Any]])?["default"] ?? [:]
                let encoded = id.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed.subtracting(CharacterSet(charactersIn:"/?#"))) ?? ""
                var result = DataLibraryResult(libraryID:libraryID,sourceID:id,name:metas["title"] as? String ?? id,sourceURL:URL(string:"https://data.opendatasoft.com/explore/dataset/"+encoded))
                result.updatedAt = metas["modified"] as? String
                let fields = row["fields"] as? [[String:Any]] ?? []
                if row["has_records"] as? Bool == true, let field = fields.first(where: { ["geo_point_2d","geo_shape"].contains($0["type"] as? String ?? "") })?["name"] as? String, field.range(of:"^[a-zA-Z_][a-zA-Z0-9_]*$",options:.regularExpression) != nil, let bounds {
                    // The records API is bounded and interactive; bulk exports can stall even for small areas.
                    var components = URLComponents(string:"https://data.opendatasoft.com/api/explore/v2.1/catalog/datasets/\(encoded)/records")!
                    components.queryItems = [.init(name:"limit",value:"100"),.init(name:"where",value:"in_bbox(\(field),\(bounds.south),\(bounds.west),\(bounds.north),\(bounds.east))")]
                    result.connectionURL = components.url; result.connectionFormat = .openDataSoft
                    result.notice = "Bounded to the area of this search; refresh rechecks that same area. Search again to change the area. Verify source update meaning and publisher terms."
                } else { result.notice = "Reference metadata only: no accessible geographic records were advertised." }
                return result
            case .reference: return nil
            }
        }
    }
    private static func withSource(_ item: DataLibraryResult, url: URL?) -> DataLibraryResult {
        DataLibraryResult(id:item.id,libraryID:item.libraryID,sourceID:item.sourceID,name:item.name,sourceURL:url ?? item.sourceURL,connectionURL:item.connectionURL,connectionFormat:item.connectionFormat,footprint:item.footprint,captureDate:item.captureDate,captureEndDate:item.captureEndDate,updatedAt:item.updatedAt,cloudCover:item.cloudCover,collection:item.collection,assets:item.assets,geometryField:item.geometryField,notice:item.notice)
    }
}
