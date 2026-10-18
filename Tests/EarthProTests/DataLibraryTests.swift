import XCTest
@testable import EarthPro

final class DataLibraryTests: XCTestCase {
    func testV5RegistrySeparatesLibrariesAndExecutableCapabilities() throws {
        let all = try DataLibrary.load()
        XCTAssertEqual(all.count,31)
        XCTAssertEqual(Set(all.map(\.id)).count,31)
        XCTAssertEqual(Set(all.map(\.group)),Set(DataLibraryGroup.allCases))
        XCTAssertFalse(all.contains { $0.name == "CesiumJS" })
        XCTAssertTrue(all.allSatisfy { $0.row >= 2 && $0.workbookSHA256.count == 64 })
        XCTAssertTrue(all.contains { $0.adapter == .stac && $0.canSearch })
        XCTAssertTrue(all.contains { $0.adapter == .reference && !$0.canSearch })
    }
    func testSTACScenesRetainCaptureAndCloudMetadataWithoutPretendingToRenderRaster() throws {
        let body = Data(#"{"features":[{"id":"scene1","collection":"sentinel-2-l2a","bbox":[0,0,1,1],"geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,0]]]},"properties":{"datetime":"2025-01-27T18:45:02Z","updated":"2025-02-01T00:00:00Z","eo:cloud_cover":12},"assets":{"visual":{"href":"https://example.org/scene.tif","type":"image/tiff"}}}]}"#.utf8)
        let rows = try DataLibraryService.decode(body,adapter:.stac,libraryID:"earth-search")
        let scene = try XCTUnwrap(rows.first)
        XCTAssertEqual(scene.captureDate,"2025-01-27T18:45:02Z")
        XCTAssertEqual(scene.updatedAt,"2025-02-01T00:00:00Z")
        XCTAssertEqual(scene.cloudCover,12)
        XCTAssertNotNil(scene.footprint)
        XCTAssertEqual(scene.displayKind,"scene_footprint")
        XCTAssertNil(scene.connectionURL)
    }
    func testQueriesAreBoundedAndRejectMalformedDateRanges() throws {
        let bounds = PublicDataBounds(west:-118,south:33,east:-117,north:34)
        let lib = try XCTUnwrap(DataLibrary.load().first { $0.adapter == .stac })
        let url = try DataLibraryService.searchURL(lib,query:"",bounds:bounds,collection:"sentinel-2-l2a",startDate:"2025-01-01",endDate:"2025-02-01",offset:0)
        let params = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
        XCTAssertEqual(params.first { $0.name == "limit" }?.value,"20")
        XCTAssertTrue(params.contains { $0.name == "bbox" })
        XCTAssertThrowsError(try DataLibraryService.searchURL(lib,query:"",bounds:bounds,collection:nil,startDate:"bad",endDate:nil,offset:0))
        XCTAssertThrowsError(try DataLibraryService.searchURL(lib,query:"",bounds:bounds,collection:nil,startDate:"2026-01-01",endDate:"2025-01-01",offset:0))
    }
    func testGeoCatalogResultsOnlyOfferBoundedConnectionsWithAdvertisedGeometry() throws {
        let bounds = PublicDataBounds(west:-118,south:33,east:-117,north:34)
        let socrata = Data(#"{"results":[{"resource":{"id":"abcd-1234","name":"Parcels","columns_field_name":["shape"],"columns_datatype":["Polygon"]},"metadata":{"domain":"data.example.org"},"link":"https://data.example.org/d/abcd-1234"},{"resource":{"id":"efgh-5678","name":"Budget"},"metadata":{"domain":"data.example.org"}}]}"#.utf8)
        let rows = try DataLibraryService.decode(socrata,adapter:.socrata,libraryID:"socrata",bounds:bounds)
        XCTAssertEqual(rows.count,2)
        let url = try XCTUnwrap(rows[0].connectionURL)
        let params = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems
        XCTAssertEqual(params?.first { $0.name == "$limit" }?.value,"300")
        XCTAssertEqual(params?.first { $0.name == "$where" }?.value,"within_box(shape,34.0,-118.0,33.0,-117.0)")
        XCTAssertTrue(rows[0].canAdd); XCTAssertFalse(rows[1].canAdd)
        XCTAssertTrue(rows[0].notice.contains("same area"))
        let ods = Data(#"{"results":[{"dataset_id":"zoning","has_records":true,"fields":[{"name":"geom","type":"geo_shape"}],"metas":{"default":{"title":"Zoning","modified":"2025-01-01"}}}]}"#.utf8)
        let layer = try XCTUnwrap(try DataLibraryService.decode(ods,adapter:.openDataSoft,libraryID:"ods",bounds:bounds).first)
        XCTAssertTrue(layer.canAdd)
        XCTAssertEqual(layer.connectionURL?.lastPathComponent,"records")
        XCTAssertEqual(layer.connectionFormat,.openDataSoft)
        XCTAssertEqual(layer.updatedAt,"2025-01-01")
        XCTAssertNil(layer.captureDate)
    }
    func testOpenDataSoftRecordsTranslatePointsAndFilledPolygons() throws {
        let records = Data(#"{"total_count":4,"results":[{"name":"City","coordinates":{"lon":-117.84,"lat":33.64}},{"ZONE":"R","geo_point":{"lon":0.5,"lat":0.5},"geo_shape":{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,0]]]}}},{"name":"No location"}]}"#.utf8)
        let result = try CustomDataService.decodeOpenDataSoft(records)
        XCTAssertEqual(result.features.count,2)
        XCTAssertTrue(result.partial)
        XCTAssertEqual(result.features[0].kind,.point)
        XCTAssertEqual(result.features[0].points[0].latitude,33.64)
        XCTAssertEqual(result.features[1].kind,.polygon)
        XCTAssertTrue(result.features.allSatisfy(\.isValid))
        XCTAssertFalse(result.legend.isEmpty)
        XCTAssertThrowsError(try CustomDataService.decodeOpenDataSoft(Data(#"{"results":[]}"#.utf8)))
    }
    @MainActor func testSceneFootprintCanBeAddedOnceAndRestoredAsGeometryNotImagery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = EarthStore(libraryURL:folder.appendingPathComponent("library.json"))
        var scene = DataLibraryResult(libraryID:"earth-search",sourceID:"scene1",name:"Sentinel capture",sourceURL:URL(string:"https://example.org/scene"))
        scene.footprint = EarthFeature(name:"scene",kind:.polygon,points:[.init(latitude:0,longitude:0),.init(latitude:1,longitude:0),.init(latitude:1,longitude:1),.init(latitude:0,longitude:0)])
        scene.captureDate = "2025-01-27T18:45:02Z"
        let id = try store.addLibraryResult(scene)
        XCTAssertEqual(try store.addLibraryResult(scene),id)
        XCTAssertEqual(store.customDataLayers.count,1)
        XCTAssertTrue(store.customDataLayers[0].features[0].notes.contains("not imagery pixels"))
        XCTAssertTrue(store.customDataLayers[0].features[0].notes.contains(scene.captureDate!))
        XCTAssertNil(store.customDataLayers[0].url)
        XCTAssertNil(store.customDataLayers[0].providerUpdatedAt)
        await store.customDataSaveTask?.value
        let restored = EarthStore(libraryURL:store.libraryURL)
        XCTAssertEqual(restored.customDataLayers.first?.id,id)
        XCTAssertEqual(restored.customDataLayers.first?.features,store.customDataLayers.first?.features)
    }
    func testLiveLibraryAdapters() async throws {
        guard ProcessInfo.processInfo.environment["EARTH_LIBRARY_LIVE"] == "1" else { throw XCTSkip("Opt-in live source search") }
        let libraries = try DataLibrary.load()
        let bounds = PublicDataBounds(west:-117.9,south:33.6,east:-117.8,north:33.7)
        for adapter in [DataLibraryAdapter.arcGIS,.stac,.openAerialMap,.socrata,.openDataSoft] {
            let library = try XCTUnwrap(libraries.first { $0.adapter == adapter && (adapter != .stac || $0.name.contains("Element 84")) })
            do {
                let isScene = adapter == .stac || adapter == .openAerialMap
                let searchBounds = adapter == .openAerialMap ? PublicDataBounds(west:-80.43,south:-0.99,east:-80.41,north:-0.97) : bounds
                let rows = try await DataLibraryService.shared.search(library,query:isScene ? "" : adapter == .openDataSoft ? "geonames-all-cities-with-a-population-1000" : "parcels",bounds:searchBounds,collection:adapter == .stac ? "sentinel-2-l2a" : nil,startDate:adapter == .stac ? "2025-01-01" : nil,endDate:adapter == .stac ? "2025-02-01" : nil)
                print("LIBRARY_LIVE \(library.id): \(rows.count) results")
                XCTAssertLessThanOrEqual(rows.count,20)
                if let result = rows.first { let cached = try await DataLibraryService.shared.result(result.id); XCTAssertEqual(cached.id,result.id) }
                if isScene { XCTAssertFalse(rows.isEmpty); XCTAssertNotNil(rows.first?.captureDate); XCTAssertNotNil(rows.first?.footprint) }
                if [.socrata,.openDataSoft].contains(adapter), let row = rows.first(where: { $0.canAdd }), let url = row.connectionURL, let format = row.connectionFormat {
                    let ready = try await DataLibraryService.shared.readyResult(row.id)
                    XCTAssertEqual(ready.id,row.id)
                    let vectors = try await CustomDataService.shared.load(url:url,format:format,bounds:searchBounds)
                    XCTAssertTrue(vectors.features.allSatisfy(\.isValid))
                    if adapter == .openDataSoft { XCTAssertFalse(vectors.features.isEmpty) }
                    print("LIBRARY_VECTOR_LOAD \(library.id): \(vectors.features.count) geometries in requested area")
                }
                if adapter == .arcGIS, let service = rows.first(where: { $0.displayKind == "service" }) {
                    let layers = try await DataLibraryService.shared.layers(service.id)
                    XCTAssertFalse(layers.isEmpty)
                    XCTAssertTrue(layers.allSatisfy { $0.canAdd })
                }
            } catch { XCTFail("\(library.id): \(error.localizedDescription)") }
        }
    }
    @MainActor func testMCPListsLibrariesWithoutEnablingLayersAndRejectsReferenceSearch() async throws {
        let store = EarthStore(libraryURL:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json"))
        store.mcpEnabled = true
        defer { store.mcpEnabled = false }
        let server = EarthMCPServer(store:store)
        let response = await server.rpc(["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"data_libraries","arguments":["action":"list","group":"imagery"]]])
        let result = try XCTUnwrap(response?["result"] as? [String:Any])
        XCTAssertNil(result["isError"])
        let content = try XCTUnwrap((result["content"] as? [[String:Any]])?.first?["text"] as? String)
        let data = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(content.utf8)) as? [String:Any])
        XCTAssertFalse((data["libraries"] as? [[String:Any]] ?? []).isEmpty)
        XCTAssertTrue(store.customDataLayers.isEmpty)
        XCTAssertTrue(store.publicDataEnabled.isEmpty)
        let bad = await server.rpc(["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":"data_libraries","arguments":["action":"search","library_id":"not-a-library"]]])
        XCTAssertEqual((bad?["result"] as? [String:Any])?["isError"] as? Bool,true)
    }
    @MainActor func testLiveMCPSearchAddAndInspectSceneFootprint() async throws {
        guard ProcessInfo.processInfo.environment["EARTH_LIBRARY_LIVE"] == "1" else { throw XCTSkip("Opt-in live MCP flow") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = EarthStore(libraryURL:folder.appendingPathComponent("library.json")); store.mcpEnabled = true
        let server = EarthMCPServer(store:store)
        defer { store.mcpEnabled = false; store.customDataSaveTask?.cancel() }
        func call(_ tool: String, _ args: [String:Any]) async throws -> [String:Any] {
            let response = await server.rpc(["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":tool,"arguments":args]])
            let result = try XCTUnwrap(response?["result"] as? [String:Any])
            let content = try XCTUnwrap((result["content"] as? [[String:Any]])?.first?["text"] as? String)
            XCTAssertNotEqual(result["isError"] as? Bool,true,content)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(content.utf8)) as? [String:Any])
        }
        let provider = try XCTUnwrap(DataLibrary.load().first { $0.name.contains("Element 84") })
        let search = try await call("data_libraries",["action":"search","library_id":provider.id,"collection":"sentinel-2-l2a","start_date":"2025-01-01","end_date":"2025-02-01","bounds":["west":-117.9,"south":33.6,"east":-117.8,"north":33.7]])
        let row = try XCTUnwrap((search["results"] as? [[String:Any]])?.first)
        let resultID = try XCTUnwrap(row["result_id"] as? String)
        XCTAssertEqual(row["display_kind"] as? String,"scene_footprint")
        let added = try await call("data_libraries",["action":"add_result","result_id":resultID])
        XCTAssertNotNil(added["layer_id"] as? String)
        let state = try await call("custom_data",["action":"list"])
        let layer = try XCTUnwrap((state["layers"] as? [[String:Any]])?.first)
        XCTAssertEqual(layer["geometry_count"] as? Int,1)
        XCTAssertTrue((layer["status"] as? String ?? "").contains("Not imagery pixels"))
        XCTAssertEqual(store.customDataLayers[0].features[0].kind,.polygon)
    }
}
