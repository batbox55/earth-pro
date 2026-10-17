import XCTest
@testable import EarthPro

final class PublicDataTests: XCTestCase {
    let bounds = PublicDataBounds(west: -118, south: 33, east: -117, north: 34)
    func testQueriesAreSpatialBoundedAndDoNotRequestBulkAttributes() {
        for kind in PublicDataKind.allCases {
            let url = PublicDataService.queryURL(kind: kind, bounds: bounds, distance: 750)
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(q["geometryType"], "esriGeometryEnvelope")
            XCTAssertEqual(q["inSR"], "4326"); XCTAssertEqual(q["outSR"], "4326")
            XCTAssertEqual(q["resultRecordCount"], "500"); XCTAssertNotEqual(q["outFields"], "*")
        }
    }
    func testDecoderPreservesHolesAndMultipartAndFlagsPartialResults() throws {
        let data = Data(#"{"type":"FeatureCollection","exceededTransferLimit":true,"features":[{"type":"Feature","id":7,"properties":{"OBJECTID":7},"geometry":{"type":"MultiPolygon","coordinates":[[[[-118,33],[-117,33],[-117,34],[-118,33]],[[-117.9,33.1],[-117.8,33.1],[-117.8,33.2],[-117.9,33.1]]],[[[-117.7,33.3],[-117.6,33.3],[-117.6,33.4],[-117.7,33.3]]]]}}]}"#.utf8)
        let snapshot = try PublicDataService.decode(data, kind: .parcels, bounds: bounds)
        XCTAssertEqual(snapshot.features.count, 1); XCTAssertEqual(snapshot.features[0].rings.count, 3)
        XCTAssertEqual(snapshot.vertexCount, 12); XCTAssertTrue(snapshot.partial)
        XCTAssertThrowsError(try PublicDataService.decode(Data(#"{"type":"FeatureCollection","crs":{"properties":{"name":"EPSG:2230"}},"features":[]}"#.utf8), kind: .parcels, bounds: bounds))
    }
    @MainActor func testZoomGateDoesNotFetchAndHidingCancelsPendingWork() async throws {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var calls = 0
        store.publicDataFetch = { kind, bounds, _ in
            calls += 1
            try await Task.sleep(for: .seconds(1))
            return .init(kind: kind, bounds: bounds, features: [], partial: false)
        }
        store.latitude = 33.8; store.longitude = -117.8; store.distance = 1_000_000
        store.setPublicData(.parcels, enabled: true)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(calls, 0); XCTAssertTrue(store.publicDataFeatures.isEmpty)
        store.distance = 750; store.refreshPublicData()
        store.setPublicDataVisible(.parcels, visible: false)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(calls, 0); XCTAssertTrue(store.publicDataLoading.isEmpty)
    }
    @MainActor func testCancelledOldViewCannotPublishAndCameraPanDoesNotRebuildCachedGeometry() async throws {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.latitude = 33.8; store.longitude = -117.8; store.distance = 750
        store.publicDataFetch = { kind, bounds, _ in
            // Deliberately ignore cancellation as a misbehaving transport might.
            try? await Task.sleep(for: .milliseconds(300))
            return .init(kind: kind, bounds: bounds, features: [], partial: false)
        }
        store.setPublicData(.parcels, enabled: true)
        try await Task.sleep(for: .milliseconds(650))
        store.longitude = -117.7; store.refreshPublicData()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(store.publicDataSnapshots[.parcels])
        store.setPublicData(.parcels, enabled: false)
        let broad = PublicDataBounds(west: -118.1, south: 33.5, east: -117.5, north: 33.9)
        store.publicDataEnabled = [.parcels]
        store.publicDataSnapshots[.parcels] = .init(kind: .parcels, bounds: broad, features: [], partial: false)
        store.refreshPublicData(); let revision = store.publicDataRevision
        store.longitude += 0.00001; store.refreshPublicData()
        XCTAssertEqual(store.publicDataRevision, revision)
        store.setPublicDataVisible(.parcels, visible: false)
    }
    @MainActor func testPreferencesPersistWithoutStartingRequestsAndCatalogIsBundled() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let store = EarthStore(libraryURL: url)
        store.setPublicData(.flood, enabled: true)
        store.setPublicDataVisible(.flood, visible: false)
        store.setPublicDataOpacity(.flood, opacity: 0.4)
        try await Task.sleep(for: .milliseconds(400))
        let restored = EarthStore(libraryURL: url)
        XCTAssertEqual(restored.publicDataEnabled, [.flood]); XCTAssertEqual(restored.publicDataHidden, [.flood])
        XCTAssertEqual(restored.publicDataOpacity[.flood], 0.4)
        XCTAssertNil(restored.publicDataTask); XCTAssertTrue(restored.publicDataSnapshots.isEmpty)
        await restored.loadPublicDataCatalog()
        XCTAssertEqual(restored.publicDataCounties.count, 1622)
        XCTAssertEqual(Set(restored.publicDataCounties.map(\.id)).count, 1622)
        XCTAssertTrue(restored.publicDataCounties.contains { $0.fips == "06059" })
        XCTAssertTrue(restored.publicDataCounties.contains { $0.fips == "16013" && $0.county == "Blaine County" })
    }
    func testOversizedFeatureNeverLosesItsRingsSilently() throws {
        let ring = Array(repeating: [-117.8, 33.8], count: PublicDataService.vertexLimit + 1)
        let object: [String: Any] = ["type":"FeatureCollection", "features":[["type":"Feature", "id":1, "properties":["OBJECTID":1], "geometry":["type":"Polygon", "coordinates":[ring]]]]]
        let result = try PublicDataService.decode(JSONSerialization.data(withJSONObject: object), kind: .flood, bounds: bounds)
        XCTAssertTrue(result.partial); XCTAssertTrue(result.features.isEmpty)
    }

}
