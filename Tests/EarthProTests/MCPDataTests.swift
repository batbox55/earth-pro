import XCTest
@testable import EarthPro

@MainActor final class MCPDataTests: XCTestCase {
    private func call(_ server: EarthMCPServer, _ name: String, _ args: [String:Any]) async throws -> [String:Any] {
        let response = await server.rpc(["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":name,"arguments":args]])!
        let result = try XCTUnwrap(response["result"] as? [String:Any])
        let blocks = try XCTUnwrap(result["content"] as? [[String:Any]])
        let text = try XCTUnwrap(blocks.first?["text"] as? String)
        if result["isError"] as? Bool == true { throw KMLError.invalid(text) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])
    }
    private func withStore(_ body: (EarthStore,EarthMCPServer) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EarthStore(libraryURL:dir.appendingPathComponent("library.json")); store.mcpEnabled = true
        let server = EarthMCPServer(store:store)
        defer { server.stop(); store.mcpEnabled = false; store.customDataSaveTask?.cancel() }
        try await body(store,server)
    }
    func testToolsDiscoverableAndNotesPersistWithoutLosingStyle() async throws {
        let names = EarthMCPServer.tools.compactMap { $0["name"] as? String }
        for name in ["public_data","custom_data","source_dates","location_notes","folders","data_discovery"] {
            XCTAssertTrue(names.contains(name)); XCTAssertTrue(EarthMCPInstructions.prompt(appPath:"/Applications/Earth Pro.app",configuration:nil).contains(name))
        }
        try await withStore { s, server in
            var pin = EarthFeature(name:"Site",kind:.point,points:[.init(latitude:40,longitude:-74)],color:"#123456")
            pin.pinIcon = .flag; s.searchPin = pin
            _ = try await call(server,"location_notes",["action":"set","id":pin.id.uuidString,"notes":"Meter by gate","save":true])
            let restored = EarthStore(libraryURL:s.libraryURL)
            XCTAssertEqual(restored.features.first?.notes,"Meter by gate")
            XCTAssertEqual(restored.features.first?.points,pin.points)
            XCTAssertEqual(restored.features.first?.pinIcon,.flag)
            XCTAssertEqual(restored.features.first?.color,pin.color)
            let notes = try await call(server,"location_notes",["action":"get","id":pin.id.uuidString])
            XCTAssertEqual(notes["notes"] as? String,"Meter by gate")
        }
    }
    func testShapefileFolderImportAndLegendPersistThroughMCP() async throws {
        try await withStore { store, server in
            let folder = store.libraryURL.deletingLastPathComponent().appendingPathComponent("Zoning")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let (shp,dbf) = ShapefileTests.fixture()
            try shp.write(to:folder.appendingPathComponent("zoning.shp"))
            try dbf.write(to:folder.appendingPathComponent("zoning.dbf"))
            try Data(ShapefileTests.wgs.utf8).write(to:folder.appendingPathComponent("zoning.prj"))
            let accepted = try await call(server,"custom_data",["action":"import_file","path":folder.path])
            XCTAssertEqual(accepted["accepted"] as? Bool,true)
            for _ in 0..<200 where store.customDataImporting { try await Task.sleep(for:.milliseconds(10)) }
            XCTAssertNil(store.customDataImportError)
            let layer = try XCTUnwrap(store.customDataLayers.first)
            XCTAssertEqual(layer.features.count,2); XCTAssertEqual(layer.features.first?.holes?.count,1)
            let state = try await call(server,"custom_data",["action":"list"])
            let layers = try XCTUnwrap(state["layers"] as? [[String:Any]])
            XCTAssertEqual((layers.first?["legend"] as? [[String:Any]])?.first?["label"] as? String,"Residential")
            await store.customDataSaveTask?.value
            try FileManager.default.removeItem(at:folder)
            let restored = EarthStore(libraryURL:store.libraryURL)
            XCTAssertEqual(restored.customDataLayers.first?.features,layer.features)
            XCTAssertEqual(restored.customDataLayers.first?.legend,layer.legend)
        }
    }
    func testLocalImportFolderUtilityCategoryAndDates() async throws {
        try await withStore { s, server in
            try FileManager.default.createDirectory(at:s.libraryURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            let file = s.libraryURL.deletingLastPathComponent().appendingPathComponent("water.geojson")
            try Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Meter","description":"Inspect water meter"},"geometry":{"type":"Point","coordinates":[-74,40]}}]}"#.utf8).write(to:file)
            let start = try await call(server,"custom_data",["action":"import_file","path":file.path,"category":"water"])
            XCTAssertEqual(start["accepted"] as? Bool,true)
            for _ in 0..<100 where s.customDataImporting { try await Task.sleep(for:.milliseconds(10)) }
            XCTAssertFalse(s.customDataImporting); XCTAssertNil(s.customDataImportError)
            let layer = try XCTUnwrap(s.customDataLayers.first); XCTAssertEqual(layer.category,.water)
            let geometry = try await call(server,"custom_data",["action":"features","id":layer.id.uuidString,"limit":1])
            let geometries = try XCTUnwrap(geometry["features"] as? [[String:Any]])
            let first = try XCTUnwrap(geometries.first)
            XCTAssertEqual(first["name"] as? String,"Meter")
            XCTAssertTrue((first["notes"] as? String)?.contains("Inspect water meter") == true)
            let coordinates = try XCTUnwrap(first["points"] as? [[String:Any]])
            XCTAssertEqual(coordinates.first?["longitude"] as? Double,-74)
            XCTAssertEqual(coordinates.first?["latitude"] as? Double,40)
            let geometryID = try XCTUnwrap(first["id"] as? String)
            let single = try await call(server,"custom_data",["action":"features","id":layer.id.uuidString,"feature_id":geometryID])
            XCTAssertEqual(single["total"] as? Int,1)
            for invalid in [["offset":true],["offset":-1],["offset":0.5],["offset":1e100],["limit":"2"],["limit":0],["limit":101],["feature_id":UUID().uuidString]] as [[String:Any]] {
                do {
                    _ = try await call(server,"custom_data",invalid.merging(["action":"features","id":layer.id.uuidString]) { _,new in new })
                    XCTFail("Accepted invalid feature paging")
                } catch { }
            }
            let folder = try await call(server,"folders",["action":"create","name":"Inspection"])
            let folderID = try XCTUnwrap(folder["id"] as? String)
            _ = try await call(server,"folders",["action":"move_layer","id":layer.id.uuidString,"folder_id":folderID])
            _ = try await call(server,"custom_data",["action":"rename","id":layer.id.uuidString,"name":"Water assets"])
            _ = try await call(server,"custom_data",["action":"visible","id":layer.id.uuidString,"enabled":false])
            try await Task.sleep(for:.milliseconds(250))
            let restored = EarthStore(libraryURL:s.libraryURL)
            XCTAssertEqual(restored.customDataLayers.first?.name,"Water assets")
            XCTAssertEqual(restored.customDataLayers.first?.folderID?.uuidString,folderID)
            XCTAssertEqual(restored.customDataLayers.first?.enabled,false)
            let rows = try await call(server,"source_dates",["action":"list"])["sources"] as? [[String:Any]]
            let dates = try XCTUnwrap(rows?.first { $0["id"] as? String == layer.id.uuidString })
            XCTAssertTrue(dates["provider_updated_at"] is NSNull); XCTAssertNotNil(dates["file_modified_at"] as? String)
            _ = try await call(server,"folders",["action":"remove","id":folderID])
            XCTAssertEqual(s.customDataLayers.count,1); XCTAssertNil(s.customDataLayers.first?.folderID)
        }
    }
    func testInvalidActionsIDsBooleansAndConnectionsDoNotMutate() async throws {
        try await withStore { s,server in
            let cases: [(String,[String:Any])] = [
                ("public_data",["action":"enable","kind":"flood","enabled":1]),
                ("public_data",["action":"opacity","kind":"flood","opacity":true]),
                ("public_data",["action":"enable","kind":"unknown","enabled":true]),
                ("custom_data",["action":"visible","id":UUID().uuidString,"enabled":true]),
                ("custom_data",["action":"connect","name":"Bad","format":"arcGIS","url":"https://example.com/FeatureServer/0?token=secret"]),
                ("custom_data",["action":"import_file","path":"/tmp/commands.sh"]),
                ("source_dates",["action":"invent"]),
                ("location_notes",["action":"set","id":UUID().uuidString,"notes":"lost"])
            ]
            for (name,args) in cases {
                do { _ = try await call(server,name,args); XCTFail("Accepted invalid \(name)") } catch { }
            }
            XCTAssertTrue(s.customDataLayers.isEmpty); XCTAssertTrue(s.publicDataEnabled.isEmpty); XCTAssertTrue(s.features.isEmpty)
            let state = try await call(server,"get_state",[:])
            XCTAssertNotNil(state["customData"]); XCTAssertNotNil(state["dataDiscovery"]); XCTAssertNotNil(state["sourceDates"])
        }
    }
}
