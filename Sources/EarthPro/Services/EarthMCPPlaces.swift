import Foundation

@MainActor extension EarthMCPServer {
    static var pointsSchema: [String: Any] {
        ["type":"array", "maxItems":10000, "items":["type":"object", "properties":["latitude":["type":"number"],"longitude":["type":"number"]], "required":["latitude","longitude"], "additionalProperties":false]]
    }
    static var geometryProperties: [String: Any] {
        ["name":["type":"string"], "notes":["type":"string"], "color":["type":"string","pattern":"^#[0-9a-fA-F]{6}$"],
         "visible":["type":"boolean"], "pin_shape":["type":"string","enum":PinShape.allCases.map(\.rawValue)],
         "pin_icon":["type":"string","enum":PinIcon.allCases.map(\.rawValue)]]
    }
    static var recentFeatureTools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["name":name,"description":description,"inputSchema":["type":"object","properties":properties,"required":required,"additionalProperties":false]]
        }
        return [
            tool("select_search_result", "Zoom to and highlight a search result by result_id. Alternatively resolve a suggestion_index with the exact query returned by get_state; poll get_state for completion. Supply exactly one selection method.", ["result_id":["type":"string"],"suggestion_index":["type":"integer","minimum":0],"query":["type":"string"]], []),
            tool("update_geometry", "Edit a saved place or the temporary search pin by ID. Saved edits persist; a search pin remains temporary unless save=true. Point styles support color, shape and icon.", geometryProperties.merging(["id":["type":"string"],"points":pointsSchema,"save":["type":"boolean"]]) { _, new in new }, ["id"]),
            tool("remove_geometry", "Remove a place by ID, or dismiss a temporary search pin. Saved-place removal can be undone.", ["id":["type":"string"]], ["id"]),
            tool("undo_redo", "Undo or redo a saved-place change, including an entire plotted address batch.", ["action":["type":"string","enum":["undo","redo"]]], ["action"]),
            tool("address_import", "Start, inspect or stop the latest MCP address-list job. Start accepts either text (one address per line) or addresses, plus optional #RRGGBB color. Deduplicates up to 250 addresses. Poll status until running=false, then inspect per-address matches/errors and plotted_ids. Stop keeps completed matches. Requires the selected provider to be ready.", ["action":["type":"string","enum":["start","status","stop"]],"text":["type":"string","maxLength":125000],"addresses":["type":"array","maxItems":250,"items":["type":"string","maxLength":500]],"color":geometryProperties["color"]!,"job_id":["type":"string"]], ["action"])
        ]
    }
    static func geometryPoints(_ value: Any?) throws -> [GeoPoint] {
        guard let rows = value as? [[String: Any]], rows.count <= 10000 else { throw KMLError.invalid("Expected points array (maximum 10000)") }
        return try rows.map { row in
            guard let lat = row["latitude"] as? NSNumber, let lon = row["longitude"] as? NSNumber,
                  CFGetTypeID(lat) != CFBooleanGetTypeID(), CFGetTypeID(lon) != CFBooleanGetTypeID() else { throw KMLError.invalid("Expected numeric latitude/longitude") }
            let point = GeoPoint(latitude: lat.doubleValue, longitude: lon.doubleValue)
            guard point.isValid else { throw KMLError.invalid("Invalid coordinates") }; return point
        }
    }
    static func applyGeometryOptions(_ args: [String: Any], to feature: inout EarthFeature) throws {
        if let value = args["name"] { guard let name = value as? String else { throw KMLError.invalid("name must be a string") }; feature.name = name }
        if let value = args["notes"] { guard let notes = value as? String else { throw KMLError.invalid("notes must be a string") }; feature.notes = notes }
        if let value = args["color"] {
            guard let color = value as? String, color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { throw KMLError.invalid("color must be #RRGGBB") }
            feature.color = color.uppercased()
        }
        if let value = args["visible"] { guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw KMLError.invalid("visible must be a boolean") }; feature.isVisible = flag.boolValue }
        if args["pin_shape"] != nil || args["pin_icon"] != nil {
            guard feature.kind == .point else { throw KMLError.invalid("Pin shapes and icons apply only to point geometry") }
        }
        if let value = args["pin_shape"] { guard let raw = value as? String, let shape = PinShape(rawValue: raw) else { throw KMLError.invalid("Unknown pin_shape") }; feature.pinShape = shape }
        if let value = args["pin_icon"] { guard let raw = value as? String, let icon = PinIcon(rawValue: raw) else { throw KMLError.invalid("Unknown pin_icon") }; feature.pinIcon = icon }
    }
    func addressImportState() -> [String: Any] {
        let importer = addressImporter
        return ["job_id":importer.jobID?.uuidString as Any? ?? NSNull(), "running":importer.running,
                "total":importer.rows.count,"processed":importer.completedCount,"plotted_count":importer.plottedCount,
                "plotted_ids":importer.plottedIDs.map(\.uuidString),"unresolved":importer.failures.count,
                "stopped":importer.jobID != nil && !importer.running && importer.completedCount < importer.rows.count,
                "rows":importer.rows.map { row -> [String: Any] in
                    var result: [String: Any] = ["address":row.address,"finished":row.finished]
                    if let hit = row.match { result["match"] = Self.searchHitState(hit) }
                    if let error = row.failure { result["error"] = error }; return result
                }]
    }
    static func searchHitState(_ hit: SearchHit) -> [String: Any] {
        ["id":hit.id.uuidString,"title":hit.title,"subtitle":hit.subtitle,"latitude":hit.point.latitude,"longitude":hit.point.longitude,"distance":hit.distance]
    }
    func recentFeatureState(_ store: EarthStore) throws -> [String: Any] {
        let searchPin: Any = try store.searchPin.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
        return ["searchText":store.searchText,"searching":store.searching,"searchPin":searchPin,
                "selection":store.selection?.uuidString as Any? ?? NSNull(),"showPlaces":store.showPlaces,"canUndo":store.canUndo,"canRedo":store.canRedo,
                "searchResults":store.searchHits.map(Self.searchHitState),
                "searchSuggestions":store.searchSuggestions.enumerated().map { index, completion in
                    ["index":index,"query":store.searchText,"title":completion.title,"subtitle":completion.subtitle] as [String: Any]
                },"addressImport":addressImportState(),"pinStyles":["shapes":PinShape.allCases.map(\.rawValue),"icons":PinIcon.allCases.map(\.rawValue),"colorFormat":"#RRGGBB"]]
    }
    func executeRecentFeature(_ name: String, _ args: [String: Any], _ store: EarthStore) throws -> [String: Any] {
        switch name {
        case "select_search_result":
            guard !addressImporter.running else { throw KMLError.invalid("Stop the address import before selecting a search result") }
            guard (args["result_id"] != nil) != (args["suggestion_index"] != nil) else { throw KMLError.invalid("Supply either result_id or suggestion_index with query") }
            if let raw = args["result_id"] as? String {
                guard let id = UUID(uuidString: raw), let hit = store.searchHits.first(where: { $0.id == id }) else { throw KMLError.invalid("Unknown search result ID. Read get_state for current results.") }
                store.selectSearchHit(hit); return ["pin_id":id.uuidString,"searching":false]
            }
            guard let query = args["query"] as? String, query == store.searchText,
                  let index = args["suggestion_index"] as? NSNumber, CFGetTypeID(index) != CFBooleanGetTypeID(), index.doubleValue == Double(index.intValue),
                  store.searchSuggestions.indices.contains(index.intValue) else { throw KMLError.invalid("Stale or invalid suggestion. Read get_state and supply its index and exact query.") }
            store.selectSearchSuggestion(store.searchSuggestions[index.intValue]); return ["searching":store.searching,"query":store.searchText]
        case "update_geometry", "remove_geometry":
            guard let raw = args["id"] as? String, let id = UUID(uuidString: raw),
                  var feature = store.features.first(where: { $0.id == id }) ?? (store.searchPin?.id == id ? store.searchPin : nil) else { throw KMLError.invalid("Unknown place or search pin ID") }
            let saved = store.features.contains { $0.id == id }
            if name == "remove_geometry" {
                if saved { store.delete(feature) }
                if store.searchPin?.id == id { store.searchPin = nil }
                if store.selection == id { store.selection = nil }
                return ["removed":id.uuidString,"canUndo":store.canUndo]
            }
            try Self.applyGeometryOptions(args, to: &feature)
            if args["points"] != nil { feature.points = try Self.geometryPoints(args["points"]) }
            guard feature.isValid else { throw KMLError.invalid("Invalid geometry") }
            if let value = args["save"] { guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw KMLError.invalid("save must be a boolean") } }
            if saved || args["save"] as? Bool == true { store.save(feature) }
            else { store.searchPin = feature }
            return ["id":id.uuidString,"saved":saved || args["save"] as? Bool == true]
        case "undo_redo":
            if args["action"] as? String == "undo", store.canUndo { store.undo() }
            else if args["action"] as? String == "redo", store.canRedo { store.redo() }
            else { throw KMLError.invalid("Expected available undo or redo action") }
            return ["canUndo":store.canUndo,"canRedo":store.canRedo]
        case "address_import":
            guard let action = args["action"] as? String else { throw KMLError.invalid("Expected address import action") }
            if let raw = args["job_id"] {
                guard let text = raw as? String, let id = UUID(uuidString:text), id == addressImporter.jobID else { throw KMLError.invalid("Unknown or expired address import job_id") }
            }
            if action == "start" {
                guard !addressImporter.running else { throw KMLError.invalid("An MCP address import is already running") }
                guard (args["text"] != nil) != (args["addresses"] != nil) else { throw KMLError.invalid("Supply either text or addresses") }
                let text: String
                if let value = args["text"] as? String, value.count <= 125000 { text = value }
                else if let values = args["addresses"] as? [String], values.count <= AddressPinImporter.limit, values.allSatisfy({ $0.count <= 500 }) { text = values.joined(separator:"\n") }
                else { throw KMLError.invalid("Invalid address list") }
                let addresses = AddressPinImporter.addresses(text)
                guard !addresses.isEmpty, addresses.count <= AddressPinImporter.limit else { throw KMLError.invalid("Expected 1–250 unique addresses") }
                var style = EarthFeature(name:"Batch",kind:.point,points:[] ,color:"#E234A8")
                try Self.applyGeometryOptions(["color":args["color"] ?? "#E234A8"], to:&style)
                if store.provider == .google {
                    guard store.googleKey != nil, store.googleReady, store.googleError == nil else { throw KMLError.invalid("Connect Google Maps and wait for the map to be ready before starting an address import") }
                    store.setMode(.map)
                }
                guard store.pendingAddressLookup == nil else { throw KMLError.invalid("Another address lookup is running") }
                store.searchText = ""; store.search()
                addressImporter.plot(addresses, color:style.color, resolve: { [weak store] address in
                    guard let store else { throw CancellationError() }; return try await store.resolveAddressForPins(address)
                }, commit: { [weak store] pins in store?.addAddressPins(pins) })
            } else if action == "stop" { addressImporter.stop() }
            else if action != "status" { throw KMLError.invalid("Unknown address import action") }
            return addressImportState()
        default: throw KMLError.invalid("Unknown tool")
        }
    }
}
