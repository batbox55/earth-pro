import XCTest
@testable import EarthPro

@MainActor final class MCPPlacesTests: XCTestCase {
    private func rawCall(_ server: EarthMCPServer, _ name: String, _ arguments: [String: Any] = [:]) async -> [String: Any] {
        let response = await server.rpc(["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":name,"arguments":arguments]])!
        return response["result"] as? [String: Any] ?? response
    }
    private func call(_ server: EarthMCPServer, _ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let response = await rawCall(server, name, arguments)
        let content = try XCTUnwrap(response["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        if response["isError"] as? Bool == true { throw KMLError.invalid(text) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func withStore(_ operation: (EarthStore, EarthMCPServer) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = EarthStore(libraryURL: folder.appendingPathComponent("library.json")); store.mcpEnabled = true
        let server = EarthMCPServer(store: store)
        defer { server.stop(); store.mcpEnabled = false }
        try await operation(store, server)
    }
    func testNewToolsAreDiscoverableAndDocumented() async throws {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let server = EarthMCPServer(store: store)
        let response = await server.rpc(["jsonrpc":"2.0","id":1,"method":"tools/list"])!
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names).count, names.count)
        let prompt = EarthMCPInstructions.prompt(appPath: "/Applications/Earth Pro.app", configuration: nil)
        for name in ["select_search_result","update_geometry","remove_geometry","undo_redo","address_import"] {
            XCTAssertTrue(names.contains(name)); XCTAssertTrue(prompt.contains(name))
        }
        let add = try XCTUnwrap(tools.first { $0["name"] as? String == "add_geometry" })
        let schema = try XCTUnwrap(add["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        for key in ["notes","color","visible","pin_shape","pin_icon"] { XCTAssertNotNil(properties[key]) }
    }
    func testMCPAddsEditsAndRemovesStyledPins() async throws {
        try await withStore { store, server in
            let added = try await call(server, "add_geometry", ["name":"Styled","kind":"point","points":[["latitude":40,"longitude":-70]],"color":"#abcdef","pin_shape":"diamond","pin_icon":"camera","notes":"Description"])
            let id = try XCTUnwrap(added["id"] as? String)
            XCTAssertEqual(store.features.first?.color, "#ABCDEF")
            XCTAssertEqual(store.features.first?.resolvedPinShape, .diamond); XCTAssertEqual(store.features.first?.resolvedPinIcon, .camera)
            _ = try await call(server, "update_geometry", ["id":id,"name":"Edited","color":"#123456","visible":false,"pin_icon":"home","points":[["latitude":41,"longitude":-71]]])
            XCTAssertEqual(store.features.first?.name, "Edited"); XCTAssertEqual(store.features.first?.center.latitude, 41)
            XCTAssertEqual(store.features.first?.isVisible, false); XCTAssertEqual(store.features.first?.pinIcon, .home)
            let reloaded = EarthStore(libraryURL: store.libraryURL)
            XCTAssertEqual(reloaded.features, store.features)
            let before = store.features
            for invalid in [["color":"red"],["pin_shape":"triangle"],["pin_icon":"missing"],["visible":1]] as [[String: Any]] {
                let response = await rawCall(server, "update_geometry", invalid.merging(["id":id]) { _, value in value })
                XCTAssertEqual(response["isError"] as? Bool, true); XCTAssertEqual(store.features, before)
            }
            _ = try await call(server, "remove_geometry", ["id":id]); XCTAssertTrue(store.features.isEmpty)
            _ = try await call(server, "undo_redo", ["action":"undo"]); XCTAssertEqual(store.features, before)
        }
    }
    func testMCPSearchSelectionAndTemporaryPinStylingAndSave() async throws {
        try await withStore { store, server in
            _ = try await call(server, "search", ["query":"48.8584, 2.2945"])
            let state = try await call(server, "get_state")
            let results = try XCTUnwrap(state["searchResults"] as? [[String: Any]])
            let id = try XCTUnwrap(results.first?["id"] as? String)
            let selected = try await call(server, "select_search_result", ["result_id":id])
            XCTAssertEqual(selected["pin_id"] as? String, id); XCTAssertEqual(store.distance, 750)
            _ = try await call(server, "update_geometry", ["id":id,"color":"#123456","pin_shape":"square","pin_icon":"star"])
            XCTAssertTrue(store.features.isEmpty); XCTAssertEqual(store.searchPin?.resolvedPinIcon, .star)
            let styled = try await call(server, "get_state")
            XCTAssertEqual((styled["searchPin"] as? [String: Any])?["pinShape"] as? String, "square")
            _ = try await call(server, "update_geometry", ["id":id,"save":true])
            XCTAssertNil(store.searchPin); XCTAssertEqual(store.features.first?.pinIcon, .star)
            let stale = await rawCall(server, "select_search_result", ["result_id":UUID().uuidString])
            XCTAssertEqual(stale["isError"] as? Bool, true)
            let badSuggestion = await rawCall(server, "select_search_result", ["suggestion_index":0,"query":"stale"])
            XCTAssertEqual(badSuggestion["isError"] as? Bool, true)
            _ = try await call(server, "set_layer", ["layer":"saved_places","enabled":false]); XCTAssertFalse(store.showPlaces)
            _ = try await call(server, "search", ["query":"x","suggestions_only":true])
            XCTAssertEqual(store.searchText,"x"); XCTAssertFalse(store.searching); XCTAssertTrue(store.searchHits.isEmpty)
            // Repeating a suggestion-only query must not leave a previous coordinate result selected.
            store.searchHits = [SearchHit(title:"Old",subtitle:"",point:.init(latitude:0,longitude:0))]
            _ = try await call(server, "search", ["query":"x","suggestions_only":true]); XCTAssertTrue(store.searchHits.isEmpty)
        }
    }
    func testMCPAddressBatchStartsPollsAndUndoesAsOneChange() async throws {
        try await withStore { store, server in
            let started = try await call(server, "address_import", ["action":"start","text":"40, -70\n41, -71\n40, -70", "color":"#123ABC"])
            let id = try XCTUnwrap(started["job_id"] as? String)
            XCTAssertEqual(started["running"] as? Bool,true); XCTAssertEqual(started["total"] as? Int,2)
            let overlap = await rawCall(server, "address_import", ["action":"start","addresses":["0, 0"]])
            XCTAssertEqual(overlap["isError"] as? Bool,true)
            let stale = await rawCall(server, "address_import", ["action":"stop","job_id":UUID().uuidString])
            XCTAssertEqual(stale["isError"] as? Bool,true); XCTAssertTrue(server.addressImporter.running)
            try await waitForBatch(server)
            let finished = try await call(server,"address_import",["action":"status","job_id":id])
            XCTAssertEqual(finished["processed"] as? Int,2); XCTAssertEqual(finished["plotted_count"] as? Int,2)
            XCTAssertEqual((finished["plotted_ids"] as? [String])?.count,2); XCTAssertEqual(finished["unresolved"] as? Int,0)
            XCTAssertEqual((finished["rows"] as? [[String: Any]])?.count,2)
            XCTAssertTrue(store.features.allSatisfy { $0.color == "#123ABC" }); XCTAssertEqual(store.features.count,2)
            let state = try await call(server,"get_state")
            XCTAssertEqual((state["addressImport"] as? [String: Any])?["job_id"] as? String,id)
            XCTAssertFalse(String(decoding:try JSONSerialization.data(withJSONObject:state),as:UTF8.self).contains("googleKey"))
            _ = try await call(server,"undo_redo",["action":"undo"]); XCTAssertTrue(store.features.isEmpty)
            _ = try await call(server,"undo_redo",["action":"redo"]); XCTAssertEqual(store.features.count,2)
        }
    }
    func testMCPBatchStopAndServerShutdownCancelFurtherWork() async throws {
        try await withStore { store, server in
            _ = try await call(server,"address_import",["action":"start","addresses":["10, 10","11, 11","12, 12"]])
            for _ in 0..<100 {
                if server.addressImporter.completedCount == 1 { break }
                try await Task.sleep(for:.milliseconds(5))
            }
            _ = try await call(server,"address_import",["action":"stop"])
            try await waitForBatch(server)
            XCTAssertEqual(store.features.count,1); XCTAssertEqual(server.addressImporter.completedCount,1)
            let stopped = try await call(server,"address_import",["action":"status"])
            XCTAssertEqual(stopped["stopped"] as? Bool,true)
            _ = try await call(server,"address_import",["action":"start","addresses":["20, 20","21, 21","22, 22"]])
            store.mcpEnabled = false; server.stop()
            try await waitForBatch(server)
            XCTAssertEqual(store.features.count,1)
            let disabled = await rawCall(server,"address_import",["action":"start","addresses":["0, 0"]])
            XCTAssertNotNil(disabled["error"])
        }
    }
    func testAuthenticatedHTTPDiscoversAndRunsAddressImport() async throws {
        try await withStore { store, _ in
            let server = EarthMCPServer(store:store,port:0); try server.start()
            defer { server.stop() }
            for _ in 0..<100 {
                if server.port != 0 { break }
                try await Task.sleep(for:.milliseconds(10))
            }
            XCTAssertNotEqual(server.port,0)
            @MainActor func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
                let endpoint = server.endpoint
                var request = URLRequest(url:try XCTUnwrap(URL(string:endpoint)))
                request.httpMethod = "POST"; request.timeoutInterval = 3
                request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                request.setValue("Bearer " + server.token,forHTTPHeaderField:"Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"method":method,"params":params])
                let (data,response) = try await URLSession.shared.data(for:request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String: Any])
                return try XCTUnwrap(json["result"] as? [String: Any])
            }
            let discovery = try await request("tools/list",[:])
            XCTAssertTrue((discovery["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "address_import" } == true)
            let started = try await request("tools/call",["name":"address_import","arguments":["action":"start","addresses":["10, 20","11, 21"]]])
            XCTAssertNil(started["isError"])
            try await waitForBatch(server)
            let status = try await request("tools/call",["name":"address_import","arguments":["action":"status"]])
            let content = try XCTUnwrap(status["content"] as? [[String: Any]])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(try XCTUnwrap(content.first?["text"] as? String).utf8)) as? [String: Any])
            XCTAssertEqual(json["running"] as? Bool,false); XCTAssertEqual(json["plotted_count"] as? Int,2)
            XCTAssertEqual(store.features.count,2)
        }
    }
    private func waitForBatch(_ server: EarthMCPServer) async throws {
        for _ in 0..<300 {
            if !server.addressImporter.running { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("MCP address import did not finish")
    }
}
