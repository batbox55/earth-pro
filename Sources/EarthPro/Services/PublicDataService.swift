import Foundation

enum PublicDataError: LocalizedError {
    case invalidResponse, invalidGeometry, responseTooLarge, tooFar, service(String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The source returned an unsupported response."
        case .invalidGeometry: return "The source returned invalid or unsupported polygon coordinates."
        case .responseTooLarge: return "The source response exceeded the size limit. Zoom closer and retry."
        case .tooFar: return "Zoom closer to load this layer."
        case .service(let message): return "Source unavailable: \(message)"
        }
    }
}

/// Separate, low-priority networking; no persistent geometry cache or startup requests.
actor PublicDataService {
    static let shared = PublicDataService()
    private let session: URLSession
    private var activeRequests = 0
    private var rendererCache: [PublicDataKind: (Date, Data)] = [:]
    static let byteLimit = 4 * 1_024 * 1_024
    static let featureLimit = 500
    static let vertexLimit = 16_000

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func fetch(kind: PublicDataKind, bounds: PublicDataBounds, distance: Double) async throws -> PublicDataSnapshot {
        guard distance.isFinite, distance > 0, distance <= PublicDataSource.source(kind).maxDistance else { throw PublicDataError.tooFar }
        guard bounds.isValid else { throw PublicDataError.invalidGeometry }
        let metadata: Data?
        if let cached = rendererCache[kind], Date().timeIntervalSince(cached.0) < 900 { metadata = cached.1 }
        else {
            var components = URLComponents(url:PublicDataSource.source(kind).serviceURL,resolvingAgainstBaseURL:false)!
            components.queryItems = [URLQueryItem(name:"f",value:"json")]
            metadata = try? await request(components.url!)
            if let metadata { rendererCache[kind] = (Date(),metadata) }
        }
        try Task.checkCancellation()
        let renderer = metadata.flatMap(VectorStyling.arcGIS)
        let data = try await request(Self.queryURL(kind:kind,bounds:bounds,distance:distance,additionalFields:renderer?.fields ?? []))
        try Task.checkCancellation()
        var snapshot = try Self.decode(data,kind:kind,bounds:bounds)
        var result = CustomDataResult(features:snapshot.vectors,providerUpdatedAt:nil,partial:snapshot.partial)
        renderer?.apply(&result)
        snapshot.vectors = result.features; snapshot.legend = result.legend.isEmpty ? snapshot.legend : result.legend
        snapshot.stylingNotice = result.stylingNotice ?? snapshot.stylingNotice
        return snapshot
    }

    func details(kind: PublicDataKind, id: String) async throws -> [String: String] {
        guard Int64(id) != nil else { throw PublicDataError.invalidResponse }
        let url = Self.url(kind: kind, parameters: ["f": "json", "objectIds": id, "outFields": "*", "returnGeometry": "false"])
        let data = try await request(url)
        try Task.checkCancellation()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PublicDataError.invalidResponse }
        try Self.checkError(object)
        guard let features = object["features"] as? [[String: Any]], let attributes = features.first?["attributes"] as? [String: Any] else { throw PublicDataError.invalidResponse }
        return Self.strings(attributes)
    }

    private func request(_ url: URL) async throws -> Data {
        do { return try await requestOnce(url) }
        catch {
            guard CustomDataService.shouldRetry(error) else { throw error }
            // Retry once using the same normal TLS validation; never accept invalid certificates.
            try await Task.sleep(for:.milliseconds(150))
            return try await requestOnce(url)
        }
    }
    private func requestOnce(_ url: URL) async throws -> Data {
        // Actor reentrancy permits cancellation while waiting, and caps fetch + detail requests together.
        while activeRequests >= 2 { try await Task.sleep(nanoseconds: 30_000_000) }
        try Task.checkCancellation()
        activeRequests += 1
        defer { activeRequests -= 1 }
        var request = URLRequest(url: url)
        request.networkServiceType = .background
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw PublicDataError.invalidResponse }
        guard response.expectedContentLength <= Int64(Self.byteLimit) else { throw PublicDataError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(min(Self.byteLimit, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if data.count >= Self.byteLimit { throw PublicDataError.responseTooLarge }
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        return data
    }

    static func queryURL(kind: PublicDataKind, bounds: PublicDataBounds, distance: Double, additionalFields: [String] = []) -> URL {
        let base: String
        switch kind {
        case .parcels: base = "OBJECTID,LegalLotID,Name,LotType"
        case .zoning: base = "FID,ZONECLASS,DESCRIPTIO,CATEGORY"
        case .flood: base = "OBJECTID,FLD_ZONE,ZONE_SUBTY,SFHA_TF"
        }
        let extra = additionalFields.prefix(3).filter { $0.range(of:"^[A-Za-z_][A-Za-z0-9_]{0,127}$",options:.regularExpression) != nil }
        let fields = (base.split(separator:",").map(String.init)+extra).joined(separator:",")
        return url(kind: kind, parameters: [
            "f": "geojson", "where": "1=1", "geometry": "\(bounds.west),\(bounds.south),\(bounds.east),\(bounds.north)",
            "geometryType": "esriGeometryEnvelope", "inSR": "4326", "outSR": "4326", "spatialRel": "esriSpatialRelIntersects",
            "outFields": fields, "returnGeometry": "true", "returnZ": "false", "returnM": "false",
            "resultRecordCount": String(featureLimit), "orderByFields": kind == .zoning ? "FID ASC" : "OBJECTID ASC",
            "maxAllowableOffset": String(max(0.000001, min(0.00005, distance / 111_320 / 2_000)))
        ])
    }

    private static func url(kind: PublicDataKind, parameters: [String: String]) -> URL {
        var components = URLComponents(url: PublicDataSource.source(kind).serviceURL.appendingPathComponent("query"), resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    static func decode(_ data: Data, kind: PublicDataKind, bounds: PublicDataBounds) throws -> PublicDataSnapshot {
        guard data.count <= byteLimit else { throw PublicDataError.responseTooLarge }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PublicDataError.invalidResponse }
        try checkError(object)
        guard object["type"] as? String == "FeatureCollection", let records = object["features"] as? [[String: Any]] else { throw PublicDataError.invalidResponse }
        if let crs = object["crs"] as? [String: Any] {
            guard let properties = crs["properties"] as? [String: Any], let name = properties["name"] as? String,
                  name.uppercased().contains("CRS84") || name.hasSuffix(":4326") || name.hasSuffix("/4326") else { throw PublicDataError.invalidGeometry }
        }
        var partial = object["exceededTransferLimit"] as? Bool == true || records.count > featureLimit
        if let properties = object["properties"] as? [String: Any], properties["exceededTransferLimit"] as? Bool == true { partial = true }
        var result: [PublicDataFeature] = [], count = 0
        var vectors: [EarthFeature] = []
        var seen = Set<String>()
        for record in records.prefix(featureLimit) {
            try Task.checkCancellation()
            guard let geometry = record["geometry"] as? [String: Any], let type = geometry["type"] as? String,
                  let properties = record["properties"] as? [String: Any] else { throw PublicDataError.invalidGeometry }
            let polygons: [[[[Double]]]]
            if type == "Polygon", let coordinates = geometry["coordinates"] as? [[[Double]]] { polygons = [coordinates] }
            else if type == "MultiPolygon", let coordinates = geometry["coordinates"] as? [[[[Double]]]] { polygons = coordinates }
            else { throw PublicDataError.invalidGeometry }
            guard !polygons.isEmpty, polygons.allSatisfy({ !$0.isEmpty }) else { throw PublicDataError.invalidGeometry }
            var rings: [[GeoPoint]] = []
            for polygon in polygons {
                for ring in polygon {
                    guard ring.count >= 4 else { throw PublicDataError.invalidGeometry }
                    let points = try ring.map { coordinate -> GeoPoint in
                        guard coordinate.count >= 2 else { throw PublicDataError.invalidGeometry }
                        let point = GeoPoint(latitude: coordinate[1], longitude: coordinate[0])
                        guard point.isValid else { throw PublicDataError.invalidGeometry }
                        return point
                    }
                    guard points.first == points.last else { throw PublicDataError.invalidGeometry }
                    rings.append(points)
                }
            }
            let attributes = strings(properties)
            let id = attributes[kind == .zoning ? "FID" : "OBJECTID"] ?? scalar(record["id"])
            guard let id, Int64(id) != nil else { throw PublicDataError.invalidResponse }
            guard seen.insert(id).inserted else { partial = true; continue }
            let size = rings.reduce(0) { $0 + $1.count }
            guard count + size <= vertexLimit, vectors.count + polygons.count <= featureLimit else { partial = true; continue }
            count += size
            result.append(.init(id: id, kind: kind, rings: rings, attributes: attributes))
            var ringIndex = 0
            for polygon in polygons {
                let grouped = Array(rings[ringIndex..<ringIndex+polygon.count]); ringIndex += polygon.count
                var vector = EarthFeature(name: "\(kind.rawValue) \(id)",kind:.polygon,points:grouped[0])
                vector.holes = Array(grouped.dropFirst()); vector.attributes = attributes; vector.sourceID = id
                vectors.append(vector)
            }
        }
        var styled = CustomDataResult(features:vectors,providerUpdatedAt:nil,partial:partial)
        VectorStyling.generated(&styled)
        return .init(kind: kind, bounds: bounds, features: result, partial: partial, vectors:styled.features,legend:styled.legend,stylingNotice:styled.stylingNotice)
    }

    private static func checkError(_ object: [String: Any]) throws {
        if let error = object["error"] as? [String: Any] { throw PublicDataError.service(String((error["message"] as? String ?? "Please retry later.").prefix(240))) }
    }
    private static func scalar(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    private static func strings(_ properties: [String: Any]) -> [String: String] {
        properties.reduce(into: [:]) { result, pair in
            if let value = scalar(pair.value) { result[pair.key] = String(value.prefix(2_000)) } else if pair.value is NSNull { result[pair.key] = "<Null>" }
        }
    }
}
