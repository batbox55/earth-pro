import Foundation

@MainActor extension EarthMCPServer {
    static var dataTools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["name":name,"description":description,"inputSchema":["type":"object","properties":properties,"required":required,"additionalProperties":false]]
        }
        let string: [String: Any] = ["type":"string"], boolean: [String: Any] = ["type":"boolean"]
        func action(_ names: [String]) -> [String: Any] { ["type":"string","enum":names] }
        return [
            Self.libraryTool,
            tool("data_discovery", "Find public service candidates for the current map or a named area. Discovery uses a settled-view debounce; poll list. Inspect numbered layers in a discovered service, then connect its layer URL using custom_data. Catalog dates are not dataset update dates. Use catalog to search the bundled workbook index without networking (query, offset, limit); catalog_layers reads numbered layers for a catalog service_id. Connect compatible returned URLs using custom_data; source links require publisher setup/format support.", ["action":action(["list","refresh","follow_map","area","service_layers","catalog","catalog_layers"]),"area":string,"query":["type":"string","maxLength":200],"service_id":string,"offset":["type":"integer","minimum":0],"limit":["type":"integer","minimum":1,"maximum":100]], ["action"]),
            tool("public_data", "List public layers and current-view status/features. Enable, hide, set opacity, refresh, or inspect a currently loaded feature by feature_id. Refresh/details are asynchronous: poll list/get_state. Coverage is source-specific; enabling never establishes coverage.", ["action":action(["list","enable","visible","opacity","refresh","details"]),"kind":action(PublicDataKind.allCases.map(\.rawValue)),"enabled":boolean,"opacity":["type":"number","minimum":0,"maximum":1],"feature_id":string], ["action"]),
            tool("custom_data", "List utility/custom layers, import a local shapefile ZIP/SHP, KML/KMZ/GeoJSON file, connect a public GeoJSON/numbered ArcGIS layer or bounded OpenDataSoft records URL, change visibility/category/name, refresh, frame or remove. Downloads/imports return accepted, not completion; poll list for running/status/error and new IDs. Files are geometry only, never executed. Connections preserve bounded manual current-view refresh. Use features to inspect bounded pages of loaded/imported utility geometry, including notes and coordinates. Use folders to organize layers.", ["action":action(["list","connect","import_file","features","visible","refresh","zoom","remove","rename","category"]),"id":string,"name":string,"category":action(CustomDataCategory.allCases.map(\.rawValue)),"format":action(CustomDataFormat.allCases.map(\.rawValue)),"url":string,"path":string,"enabled":boolean,"feature_id":string,"offset":["type":"integer","minimum":0],"limit":["type":"integer","minimum":1,"maximum":100]], ["action"]),
            tool("location_notes", "Read or replace notes on a saved place or temporary search pin, preserving its coordinates/style. Set save=true to save a temporary pin. Saved notes persist.", ["action":action(["get","set"]),"id":string,"notes":["type":"string","maxLength":100000],"save":boolean], ["action","id"]),
            tool("folders", "List/create/rename/remove folders or move a saved place/custom layer to a folder. Omit folder_id (or null) to unfile. Removing a folder preserves its contents.", ["action":action(["list","create","rename","remove","move_place","move_layer"]),"id":string,"name":string,"folder_id":["type":["string","null"]]], ["action"]),
            tool("source_dates", "List publisher update, catalog edit, checked and local file modified dates separately. Null means not supplied. Map/imagery sources often do not publish a global update date. Refresh starts asynchronous metadata checks; poll list afterward.", ["action":action(["list","refresh"])], ["action"])
        ]
    }

    static func dataDate(_ date: Date?) -> Any { date.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull() as Any }
    static func freshnessState(_ value: SourceFreshness?) -> [String: Any] {
        let isCatalog = value?.provenance.lowercased().contains("catalog") == true
        return ["provider_updated_at":dataDate(isCatalog ? nil : value?.providerUpdatedAt),"catalog_edited_at":dataDate(isCatalog ? value?.providerUpdatedAt : nil),"checked_at":dataDate(value?.checkedAt),"provenance":value?.provenance ?? "Not supplied","status":value?.status ?? "Metadata not checked"]
    }
    func publicDataState(_ s: EarthStore) -> [[String: Any]] {
        PublicDataSource.starters.map { source in
            ["kind":source.kind.rawValue,"name":source.title,"publisher":source.publisher,"coverage":source.coverage,"terms":source.terms,"url":source.serviceURL.absoluteString,"enabled":s.publicDataEnabled.contains(source.kind),"visible":!s.publicDataHidden.contains(source.kind),"opacity":s.publicDataOpacity[source.kind] ?? 0.7,"loading":s.publicDataLoading.contains(source.kind),"status":s.publicDataStatus[source.kind] ?? "Not loaded","partial":s.publicDataSnapshots[source.kind]?.partial ?? false,"styling_notice":s.publicDataSnapshots[source.kind]?.stylingNotice as Any? ?? NSNull(),"legend":(s.publicDataSnapshots[source.kind]?.legend ?? []).map { ["label":$0.label,"fill":$0.style.fill,"stroke":$0.style.stroke,"fill_opacity":$0.style.fillOpacity] as [String: Any] },"features":(s.publicDataSnapshots[source.kind]?.features ?? []).map { ["id":$0.id,"attributes":$0.attributes] as [String: Any] },"dates":Self.freshnessState(s.sourceFreshness[source.id])] as [String: Any]
        }
    }
    func customDataState(_ s: EarthStore) -> [String: Any] {
        ["layers":s.customDataLayers.map { layer in
            ["id":layer.id.uuidString,"name":layer.name,"folder_id":layer.folderID?.uuidString as Any? ?? NSNull(),"category":layer.category.rawValue,"format":layer.format.rawValue,"url":layer.url?.absoluteString as Any? ?? NSNull(),"enabled":layer.enabled,"loading":s.customDataLoading.contains(layer.id),"status":s.customDataStatus[layer.id] ?? "Not loaded","partial":layer.partial ?? false,"geometry_count":layer.url == nil ? layer.features.count : s.customDataSnapshots[layer.id]?.count ?? 0,"dates":Self.freshnessState(s.sourceFreshness[layer.id.uuidString] ?? SourceFreshness(providerUpdatedAt:layer.providerUpdatedAt,checkedAt:layer.checkedAt,status:"No verified publisher timestamp unless supplied")),"styling_notice":layer.stylingNotice as Any? ?? NSNull(),"legend":(layer.legend ?? []).map { ["label":$0.label,"fill":$0.style.fill,"stroke":$0.style.stroke,"fill_opacity":$0.style.fillOpacity] as [String: Any] },"file_modified_at":Self.dataDate(layer.fileModifiedAt)] as [String: Any]
        },"import_running":s.customDataImporting,"import_error":s.customDataImportError as Any? ?? NSNull(),"last_imported_id":s.customDataLastImportedID?.uuidString as Any? ?? NSNull(),"categories":CustomDataCategory.allCases.map { ["id":$0.rawValue,"name":$0.title] }]
    }
    func dataFeatureState(_ s: EarthStore) throws -> [String: Any] {
        ["publicData":publicDataState(s),"customData":customDataState(s),"folders":s.folders.map { ["id":$0.id.uuidString,"name":$0.name] },"selectedFolderID":s.selectedFolderID?.uuidString as Any? ?? NSNull(),"sourceDates":sourceDatesState(s),"dataDiscovery":discoveryState(s)]
    }
    func sourceDatesState(_ s: EarthStore) -> [[String: Any]] {
        var result = PublicDataSource.starters.map { source in Self.freshnessState(s.sourceFreshness[source.id]).merging(["id":source.id,"name":source.title]) { _, new in new } }
        result += s.customDataLayers.map { layer in
            Self.freshnessState(s.sourceFreshness[layer.id.uuidString] ?? SourceFreshness(providerUpdatedAt:layer.providerUpdatedAt,checkedAt:layer.checkedAt,status:"Not supplied unless source publishes a dataset timestamp")).merging(["id":layer.id.uuidString,"name":layer.name,"styling_notice":layer.stylingNotice as Any? ?? NSNull(),"legend":(layer.legend ?? []).map { ["label":$0.label,"fill":$0.style.fill,"stroke":$0.style.stroke,"fill_opacity":$0.style.fillOpacity] as [String: Any] },"file_modified_at":Self.dataDate(layer.fileModifiedAt)]) { _, new in new }
        }
        result += s.discoveredData.map { ["id":$0.id,"name":$0.name,"provider_updated_at":NSNull(),"catalog_edited_at":Self.dataDate($0.modifiedAt),"status":"ArcGIS catalog modification; not a dataset update date"] as [String:Any] }
        for name in ["Apple Maps","Google Maps & photorealistic 3D","OpenStreetMap","Esri World Imagery","NASA GIBS","Esri Wayback","USGS earthquakes","Wikimedia photos","Wikipedia places","Open-Meteo elevation","NASA cloud cover","Natural Earth & bundled terrain"] {
            result.append(["name":name,"provider_updated_at":NSNull(),"status":"A verified global dataset update date is not supplied. Capture, event and release dates are separate facts."])
        }
        return result
    }

    func discoveryState(_ s: EarthStore) -> [String: Any] {
        ["follows_map":s.discoveryFollowsMap,"area":s.placeDataArea,"query":s.discoveryQuery,"loading":s.discoveryLoading,"status":s.discoveryStatus,"services":s.discoveredData.map { ["id":$0.id,"name":$0.name,"publisher":$0.publisher,"url":$0.url.absoluteString,"catalog_edited_at":Self.dataDate($0.modifiedAt)] as [String: Any] }]
    }
    func executeDataFeature(_ name: String, _ a: [String: Any], _ s: EarthStore) async throws -> [String: Any]? {
        if name == "data_libraries" { return try await executeLibrary(a,s) }
        guard ["public_data","custom_data","location_notes","folders","source_dates","data_discovery"].contains(name) else { return nil }
        func invalid(_ message: String) -> Error { KMLError.invalid(message) }
        func text(_ key: String) throws -> String { guard let value = a[key] as? String else { throw invalid("Expected string: \(key)") }; return value }
        func id(_ key: String = "id") throws -> UUID { guard let value = UUID(uuidString: try text(key)) else { throw invalid("Invalid UUID: \(key)") }; return value }
        func flag(_ key: String) throws -> Bool { guard let value = a[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw invalid("Expected boolean: \(key)") }; return value.boolValue }
        func category() throws -> CustomDataCategory { guard a["category"] == nil || a["category"] is String, let value = CustomDataCategory(rawValue: a["category"] as? String ?? "other") else { throw invalid("Unknown category") }; return value }
        let action = try text("action")
        switch name {
        case "data_discovery":
            if action == "catalog" {
                let query = a["query"] as? String ?? ""
                guard a["query"] == nil || a["query"] is String, query.count <= 200 else { throw invalid("Catalog query must be a string of up to 200 characters") }
                func integer(_ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
                    guard let raw = a[key] else { return fallback }
                    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                          number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else { throw invalid("Invalid catalog \(key)") }
                    return number.intValue
                }
                let offset = try integer("offset", fallback: 0, range: 0...100_000)
                let limit = try integer("limit", fallback: 30, range: 1...100)
                let page = try await CatalogDataIndex.shared.search(query: query, region: s.placeDataRegion, offset: offset, limit: limit)
                return ["total": page.total, "catalog_count": page.catalogCount, "offset": offset, "sources": page.records.map { source -> [String: Any] in
                    ["id": source.id, "name": source.name, "publisher": source.publisher, "geography": source.geography, "topic": source.topic,
                     "url": source.url.absoluteString, "source_url": source.sourceURL.absoluteString, "format": source.connectionFormat?.rawValue as Any? ?? NSNull(),
                     "kind": source.kind, "category": source.category.rawValue, "access": source.access, "terms_excerpt": source.terms,
                     "workbook_check": source.verification, "workbook": source.workbook, "sheet": source.sheet, "row": source.row,
                     "workbook_sha256": source.workbookSHA256, "indexed_on": source.indexedOn, "provider_updated_at": NSNull(),
                     "workbook_modified": source.workbookModified as Any? ?? NSNull()]
                }]
            }
            if action == "catalog_layers" {
                let serviceID = try text("service_id")
                guard let source = try await CatalogDataIndex.shared.source(id: serviceID), let service = source.service else { throw invalid("Unknown or unsupported catalog service ID") }
                let layers = try await PlaceDataDiscoveryService.shared.layers(in: service)
                return ["service_id": serviceID, "source_url": source.sourceURL.absoluteString, "layers": layers.map { ["id": $0.id, "name": $0.name, "url": $0.url.absoluteString] as [String: Any] }]
            }
            guard ["list", "refresh", "follow_map", "area", "service_layers"].contains(action) else { throw invalid("Unknown discovery action") }
            if a["query"] != nil, !["refresh", "follow_map", "area"].contains(action) { throw invalid("Use refresh, follow_map or area when setting a discovery query") }
            if let raw = a["query"] {
                guard let query = raw as? String, query.count <= 200 else { throw invalid("Discovery query must be a string of up to 200 characters") }
                s.discoveryQuery = query
            }
            switch action {
            case "list":break
            case "refresh":s.showPublicData = true; s.scheduleDataDiscovery(force:true)
            case "follow_map":s.showPublicData = true; s.resumeMapDataDiscovery()
            case "area":
                let area = try text("area").trimmingCharacters(in:.whitespacesAndNewlines)
                guard !area.isEmpty,area.count <= 300 else { throw invalid("Area must have 1–300 characters") }
                s.showPublicData = true; await s.setDataDiscoveryArea(area)
            case "service_layers":
                let serviceID = try text("service_id")
                guard let service = s.discoveredData.first(where: { $0.id == serviceID }) else { throw invalid("Unknown discovered service ID") }
                let layers = try await PlaceDataDiscoveryService.shared.layers(in:service)
                return ["service_id":serviceID,"layers":layers.map { ["id":$0.id,"name":$0.name,"url":$0.url.absoluteString] as [String:Any] }]
            default:throw invalid("Unknown discovery action")
            }
            return discoveryState(s)
        case "source_dates":
            guard ["list","refresh"].contains(action) else { throw invalid("Unknown source dates action") }
            if action == "refresh" { s.refreshSourceDates(force: true) }
            return ["accepted":action == "refresh","sources":sourceDatesState(s)]
        case "location_notes":
            let target = try id()
            guard var feature = s.features.first(where: { $0.id == target }) ?? (s.searchPin?.id == target ? s.searchPin : nil) else { throw invalid("Unknown saved place or search pin ID") }
            let saved = s.features.contains { $0.id == target }
            if action == "set" {
                let notes = try text("notes"); guard notes.count <= 100_000 else { throw invalid("Notes limit is 100000 characters") }
                let save = a["save"] == nil ? false : try flag("save")
                if saved || save { guard s.writable else { throw invalid("Places file cannot be saved") } }
                feature.notes = notes
                if saved || save { s.save(feature) } else { s.searchPin = feature }
            } else if action != "get" { throw invalid("Unknown notes action") }
            return ["id":target.uuidString,"notes":feature.notes,"saved":s.features.contains { $0.id == target }]
        case "folders":
            switch action {
            case "list":break
            case "create":return ["id":try s.createFolder(name:text("name")).uuidString]
            case "rename":try s.renameFolder(id:id(),name:text("name"))
            case "remove":try s.removeFolder(id:id())
            case "move_place","move_layer":
                let folder: UUID? = a["folder_id"] == nil || a["folder_id"] is NSNull ? nil : try id("folder_id")
                if action == "move_place" { try s.movePlace(id:id(),folderID:folder) } else { try s.moveCustomLayer(id:id(),folderID:folder) }
            default:throw invalid("Unknown folders action")
            }
            return ["folders":s.folders.map { ["id":$0.id.uuidString,"name":$0.name] }]
        case "public_data":
            if action == "list" { return ["layers":publicDataState(s),"selected_attributes":s.publicDataAttributes,"detail_loading":s.publicDataDetailLoading] }
            if action == "refresh" { s.refreshPublicData(force:true); return ["accepted":true,"layers":publicDataState(s)] }
            guard let kind = PublicDataKind(rawValue:try text("kind")) else { throw invalid("Unknown public layer kind") }
            switch action {
            case "enable":s.setPublicData(kind,enabled:try flag("enabled"))
            case "visible":s.setPublicDataVisible(kind,visible:try flag("enabled"))
            case "opacity":
                guard let number = a["opacity"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,(0...1).contains(number.doubleValue) else { throw invalid("Opacity must be a number from 0 to 1") }
                s.setPublicDataOpacity(kind,opacity:number.doubleValue)
            case "details":
                let featureID = try text("feature_id")
                guard let feature = s.publicDataSnapshots[kind]?.features.first(where: { $0.id == featureID }) else { throw invalid("Unknown loaded feature ID") }
                s.showPublicDataDetails(feature); return ["accepted":true,"feature_id":featureID]
            default:throw invalid("Unknown public data action")
            }
            return ["layers":publicDataState(s)]
        case "custom_data":
            switch action {
            case "list":return customDataState(s)
            case "connect":
                guard let format = CustomDataFormat(rawValue:try text("format")),let url = URL(string:try text("url")) else { throw invalid("Invalid format or URL") }
                let before = Set(s.customDataLayers.map(\.id))
                try s.addCustomConnection(name:text("name"),category:category(),format:format,url:url)
                return ["accepted":true,"id":s.customDataLayers.first { !before.contains($0.id) }?.id.uuidString as Any? ?? NSNull(),"state":customDataState(s)]
            case "import_file":
                guard !s.customDataImporting else { throw invalid("An import is already running") }
                let path = try text("path"), category = try category()
                let url = URL(fileURLWithPath:path)
                let fileValues = try? url.resourceValues(forKeys:[.isRegularFileKey,.isDirectoryKey])
                guard path.hasPrefix("/"), fileValues?.isDirectory == true || (["kml","kmz","geojson","json","shp","zip"].contains(url.pathExtension.lowercased()) && fileValues?.isRegularFile == true) else { throw invalid("Expected an existing absolute KML, KMZ, GeoJSON, SHP, shapefile ZIP or dataset folder path") }
                guard s.customDataWritable,s.customDataLayers.count < 8 else { throw invalid("Custom layer file unavailable or eight-layer limit reached") }
                let before = s.customDataLayers.map { $0.id.uuidString }; s.importCustomDataFile(url,category:category)
                return ["accepted":s.customDataImporting,"before_ids":before,"state":customDataState(s)]
            default:
                let target = try id()
                guard let index = s.customDataLayers.firstIndex(where: { $0.id == target }) else { throw invalid("Unknown custom layer ID") }
                if action == "features" {
                    func pageInteger(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
                        guard let raw = a[key] else { return fallback }
                        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                              let integer = Int(exactly:n.doubleValue), range.contains(integer) else { throw invalid("Invalid integer: \(key)") }
                        return integer
                    }
                    let offset = try pageInteger("offset",default:0,range:0...Int.max)
                    let limit = try pageInteger("limit",default:25,range:1...100)
                    let layer = s.customDataLayers[index]
                    let available = layer.url == nil ? layer.features : s.customDataSnapshots[target] ?? []
                    let items: [EarthFeature]
                    if a["feature_id"] != nil {
                        let featureID = try id("feature_id")
                        guard let feature = available.first(where: { $0.id == featureID }) else { throw invalid("Unknown loaded custom feature ID") }
                        items = [feature]
                    } else { items = available }
                    let start = min(offset,items.count), end = start + min(limit,items.count - start)
                    let encoded = try JSONSerialization.jsonObject(with:JSONEncoder().encode(Array(items[start..<end])))
                    return ["id":target.uuidString,"total":items.count,"features":encoded,"next_offset":end < items.count ? end as Any : NSNull(),"loading":s.customDataLoading.contains(target),"status":s.customDataStatus[target] ?? "Not loaded"]
                }
                guard s.customDataWritable else { throw invalid("Custom layer file cannot be saved") }
                switch action {
                case "visible":s.setCustomDataEnabled(target,enabled:try flag("enabled"))
                case "refresh":s.refreshCustomData(target)
                case "zoom":s.zoomToCustomData(s.customDataLayers[index])
                case "remove":s.removeCustomData(target)
                case "rename":
                    let value = try text("name").trimmingCharacters(in:.whitespacesAndNewlines)
                    guard !value.isEmpty,value.count <= 200 else { throw invalid("Layer name must have 1–200 characters") }
                    s.customDataLayers[index].name = value; s.saveCustomData()
                case "category":s.customDataLayers[index].category = try category(); s.saveCustomData()
                default:throw invalid("Unknown custom data action")
                }
                return ["accepted":action == "refresh","state":customDataState(s)]
            }
        default:return nil
        }
    }
}
