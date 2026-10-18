import Foundation

@MainActor extension EarthMCPServer {
    static var libraryTool: [String:Any] {
        ["name":"data_libraries","description":"Discover the v5 data libraries by user task. list is offline metadata only. search queries a supported library for this map view or explicit bounds, returning expiring result IDs without enabling layers. STAC: call collections, then search with collection/start_date/end_date and omit query. ArcGIS service results need layers before add_result. add_result adds a supported vector connection or explicitly labeled scene FOOTPRINT, not raster imagery. Reference-only providers return source links and setup limitations; they cannot be added as layers. Socrata/OpenDataSoft vector URLs remain bounded to the searched area. Poll custom_data list after adding a connection. Publisher terms/access and coverage vary.","inputSchema":["type":"object","additionalProperties":false,"required":["action"],"properties":[
            "action":["type":"string","enum":["list","search","collections","layers","add_result"]],
            "group":["type":"string","enum":DataLibraryGroup.allCases.map(\.rawValue)],
            "library_id":["type":"string"],"result_id":["type":"string"],"query":["type":"string","maxLength":200],
            "collection":["type":"string","maxLength":100],"start_date":["type":"string"],"end_date":["type":"string"],
            "offset":["type":"integer","minimum":0,"maximum":1000],
            "bounds":["type":"object","additionalProperties":false,"required":["west","south","east","north"],"properties":Dictionary(uniqueKeysWithValues:["west","south","east","north"].map { ($0,["type":"number"]) })]
        ]]]
    }
    func executeLibrary(_ a: [String:Any], _ store: EarthStore) async throws -> [String:Any] {
        func invalid(_ text: String) -> Error { KMLError.invalid(text) }
        func string(_ key: String) throws -> String? {
            guard let value = a[key] else { return nil }
            guard let value = value as? String else { throw invalid("Expected string: \(key)") }
            return value
        }
        let action = try string("action") ?? ""
        let libraries = try DataLibrary.load()
        let query = try string("query") ?? ""
        guard query.count <= 200 else { throw invalid("Query is limited to 200 characters.") }
        let group = try string("group")
        guard group == nil || DataLibraryGroup(rawValue:group!) != nil else { throw invalid("Unknown data library group.") }
        if action == "list" {
            let terms = CatalogDataIndex.normalized(query).split(whereSeparator:\.isWhitespace)
            let rows = libraries.filter { library in
                (group == nil || library.group.rawValue == group) && terms.allSatisfy { CatalogDataIndex.normalized("\(library.name) \(library.publisher) \(library.scope) \(library.group.title) \(library.formats)").contains($0) }
            }
            return ["groups":DataLibraryGroup.allCases.map { ["id":$0.rawValue,"title":$0.title] },"libraries":rows.map(Self.libraryState),"total":rows.count,"network_requested":false]
        }
        if ["layers","add_result"].contains(action) {
            guard let resultID = try string("result_id") else { throw invalid("Use a result_id returned by search or layers.") }
            if action == "layers" { return ["results":try await DataLibraryService.shared.layers(resultID).map(Self.libraryResultState),"checked_at":Date().ISO8601Format()] }
            let result = try await DataLibraryService.shared.readyResult(resultID)
            guard store.mcpEnabled else { throw invalid("Local MCP is off.") }
            let id = try store.addLibraryResult(result)
            return ["accepted":true,"layer_id":id.uuidString,"display_kind":result.displayKind,"notice":result.notice,"next_step":"Poll custom_data action list; accepted does not prove connection loading completed."]
        }
        guard let libraryID = try string("library_id"), let library = libraries.first(where: { $0.id == libraryID }) else { throw invalid("Unknown library_id. Call data_libraries action list.") }
        if action == "collections" { return ["library_id":libraryID,"collections":try await DataLibraryService.shared.collections(library),"checked_at":Date().ISO8601Format()] }
        guard action == "search" else { throw invalid("Unknown data library action.") }
        let bounds: PublicDataBounds
        if let raw = a["bounds"] {
            guard let values = raw as? [String:Any], Set(values.keys) == Set(["west","south","east","north"]) else { throw invalid("Supply west, south, east and north bounds.") }
            func number(_ key: String) throws -> Double {
                guard let n = values[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw invalid("Invalid bound: \(key)") }
                return n.doubleValue
            }
            bounds = try .init(west:number("west"),south:number("south"),east:number("east"),north:number("north"))
        } else {
            guard store.distance <= 500_000, let view = PublicDataBounds.around(center:store.discoveryManualCenter ?? store.center,distance:store.distance*0.6) else { throw invalid("Zoom closer or supply explicit geographic bounds for this search.") }
            bounds = view
        }
        guard bounds.isValid else { throw invalid("Invalid geographic bounds. Split antimeridian searches into two areas.") }
        var offset = 0
        if let raw = a["offset"] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), (0...1000).contains(n.doubleValue), n.doubleValue.rounded() == n.doubleValue else { throw invalid("Offset must be an integer from 0 to 1000.") }
            offset = n.intValue
        }
        let page = try await DataLibraryService.shared.searchPage(library,query:query,bounds:bounds,collection:string("collection"),startDate:string("start_date"),endDate:string("end_date"),offset:offset)
        return ["library":Self.libraryState(library),"results":page.results.map(Self.libraryResultState),"checked_at":Date().ISO8601Format(),"bounds":["west":bounds.west,"south":bounds.south,"east":bounds.east,"north":bounds.north],"offset":offset,"limit":20,"result_expiry_seconds":900,"more_results_may_exist":page.hasMore,"spatial_filter":(library.adapter == .socrata || library.adapter == .openDataSoft) ? "Catalog discovery is text-based; supported vector loading is bounded to this area. Search using a place name to narrow catalog matches." : "Publisher bounding-box search; verify returned coverage."]
    }
    static func libraryState(_ library: DataLibrary) -> [String:Any] {
        ["id":library.id,"name":library.name,"group":library.group.rawValue,"group_title":library.group.title,"publisher":library.publisher,"scope":library.scope,"source_url":library.sourceURL.absoluteString,"endpoint":library.endpoint?.absoluteString as Any? ?? NSNull(),"adapter":library.adapter.rawValue,"can_search":library.canSearch,"capability":library.capability,"access":library.access,"formats":library.formats,"terms_excerpt":library.terms,"workbook_check":library.verification,"limitation":library.limitation,"provider_updated_at":NSNull(),"workbook":library.workbook,"sheet":library.sheet,"row":library.row,"workbook_sha256":library.workbookSHA256,"indexed_on":library.indexedOn]
    }
    static func libraryResultState(_ result: DataLibraryResult) -> [String:Any] {
        ["result_id":result.id,"library_id":result.libraryID,"source_id":result.sourceID,"name":result.name,"source_url":result.sourceURL?.absoluteString as Any? ?? NSNull(),"display_kind":result.displayKind,"can_add":result.canAdd,"can_choose_layers":result.displayKind == "service","connection_url":result.connectionURL?.absoluteString as Any? ?? NSNull(),"format":result.connectionFormat?.rawValue as Any? ?? NSNull(),"capture_date":result.captureDate as Any? ?? NSNull(),"capture_end_date":result.captureEndDate as Any? ?? NSNull(),"metadata_updated_at":result.updatedAt as Any? ?? NSNull(),"cloud_cover_percent":result.cloudCover as Any? ?? NSNull(),"collection":result.collection as Any? ?? NSNull(),"assets":result.assets.map { ["name":$0.name,"url":$0.url.absoluteString,"media_type":$0.mediaType as Any? ?? NSNull()] },"notice":result.notice]
    }
}

@MainActor extension EarthStore {
    @discardableResult func addLibraryResult(_ result: DataLibraryResult) throws -> UUID {
        if let url = result.connectionURL, let format = result.connectionFormat {
            if let saved = customDataLayers.first(where: { $0.url == url }) { return saved.id }
            try addCustomConnection(name:result.name,category:.other,format:format,url:url)
            return customDataLayers.last!.id
        }
        guard var feature = result.footprint else { throw KMLError.invalid("This result needs a numbered service layer or manual publisher setup. It cannot be added directly.") }
        let provenance = result.libraryID+":"+result.sourceID
        if let saved = customDataLayers.first(where: { $0.features.first?.sourceID == provenance }) { return saved.id }
        guard customDataWritable, customDataLayers.count < 8 else { throw KMLError.invalid("Remove a custom layer or resolve its preserved file error before adding another.") }
        feature.sourceID = provenance
        feature.name = "Scene footprint · "+result.name
        feature.notes = "Scene footprint only, not imagery pixels.\nCapture: \(result.captureDate ?? "Not supplied")\nCapture end: \(result.captureEndDate ?? "Not supplied")\nSource: \(result.sourceURL?.absoluteString ?? result.libraryID)\n\(result.notice)"
        var styled = CustomDataResult(features:[feature],providerUpdatedAt:nil,partial:false)
        VectorStyling.generated(&styled)
        let layer = CustomDataLayer(name:feature.name,folderID:selectedFolderID,features:styled.features,checkedAt:Date(),legend:styled.legend,stylingNotice:"Scene footprint only · acquisition date in feature notes")
        customDataLayers.append(layer); customDataStatus[layer.id] = "1 scene footprint · Not imagery pixels"; saveCustomData()
        return layer.id
    }
}
