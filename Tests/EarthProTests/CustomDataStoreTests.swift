import XCTest
@testable import EarthPro

final class CustomDataStoreTests: XCTestCase {
    @MainActor func testLocalLayerVisibilityNotesAndPersistenceRemainSeparateFromMyPlaces() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("library.json")
        let store = EarthStore(libraryURL: url)
        let feature = EarthFeature(name: "Test water valve", notes: "Verify access", kind: .point, points: [.init(latitude: 33.67, longitude: -117.86)])
        let layer = CustomDataLayer(name: "Local water", category: .water, features: [feature], fileModifiedAt: Date(timeIntervalSince1970: 100), partial: true)
        store.customDataLayers = [layer]
        XCTAssertEqual(store.renderedFeatures, [feature])
        XCTAssertTrue(store.features.isEmpty)
        store.selection = feature.id
        XCTAssertEqual(store.selectedFeature?.notes, "Verify access")
        store.setCustomDataEnabled(layer.id, enabled: false)
        XCTAssertTrue(store.renderedFeatures.isEmpty)
        await store.customDataSaveTask?.value
        let restored = EarthStore(libraryURL: url)
        XCTAssertEqual(restored.customDataLayers.count, 1)
        XCTAssertFalse(restored.customDataLayers[0].enabled)
        XCTAssertTrue(restored.customDataStatus[layer.id]?.contains("Partial import") == true)
        XCTAssertEqual(restored.customDataLayers[0].features[0].notes, "Verify access")
        XCTAssertNil(restored.customDataLayers[0].providerUpdatedAt)
        restored.setCustomDataEnabled(layer.id, enabled: true)
        XCTAssertEqual(restored.renderedFeatures, [feature])
        restored.streetView = true
        XCTAssertTrue(restored.renderedFeatures.isEmpty)
        restored.removeCustomData(layer.id)
        await restored.customDataSaveTask?.value
        XCTAssertTrue(EarthStore(libraryURL: url).customDataLayers.isEmpty)
    }
    @MainActor func testLiveConnectionsPersistReferencesAndPauseAboveZoomLimit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("library.json")
        let store = EarthStore(libraryURL: url)
        try store.addCustomConnection(name: "Stormwater", category: .stormwater, format: .arcGIS, url: URL(string: "https://example.com/FeatureServer/0")!)
        let layer = try XCTUnwrap(store.customDataLayers.first)
        XCTAssertTrue(store.customDataStatus[layer.id]?.contains("Zoom closer") == true)
        XCTAssertTrue(store.customDataLoading.isEmpty)
        store.customDataSnapshots[layer.id] = [EarthFeature(name: "Runtime only", kind: .point, points: [.init(latitude: 0, longitude: 0)])]
        store.saveCustomData()
        await store.customDataSaveTask?.value
        let restored = EarthStore(libraryURL: url)
        XCTAssertEqual(restored.customDataLayers.first?.url, layer.url)
        XCTAssertTrue(restored.customDataLayers.first?.features.isEmpty == true)
        XCTAssertTrue(restored.customDataSnapshots.isEmpty)
        XCTAssertTrue(restored.customDataStatus[layer.id]?.contains("Refresh this view") == true)
    }
    @MainActor func testGeoJSONFileImportRetainsNotesAndSurvivesOriginalFileRemoval() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("Water valves.geojson")
        let fixture = #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"North valve","note":"Inspect gate"},"geometry":{"type":"Point","coordinates":[-117.8682,33.6757]}}]}"#
        try Data(fixture.utf8).write(to: source)
        let library = folder.appendingPathComponent("library.json")
        let store = EarthStore(libraryURL: library)
        store.importCustomDataFile(source, category: .water)
        for _ in 0..<200 where store.customDataImporting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.customDataImporting)
        XCTAssertNil(store.error)
        let layer = try XCTUnwrap(store.customDataLayers.first)
        XCTAssertEqual(layer.category, .water)
        XCTAssertEqual(layer.features.first?.name, "North valve")
        XCTAssertTrue(layer.features.first?.notes.contains("Inspect gate") == true)
        XCTAssertNotNil(layer.fileModifiedAt)
        XCTAssertNil(layer.providerUpdatedAt)
        await store.customDataSaveTask?.value
        try FileManager.default.removeItem(at: source)
        let restored = EarthStore(libraryURL: library)
        XCTAssertEqual(restored.customDataLayers.first?.features, layer.features)
        XCTAssertTrue(restored.features.isEmpty)
        restored.importCustomDataFile(source)
        for _ in 0..<200 where restored.customDataImporting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(restored.error)
        XCTAssertEqual(restored.customDataLayers.count, 1)
    }

}
