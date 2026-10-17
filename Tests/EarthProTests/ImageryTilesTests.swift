import XCTest
@testable import EarthPro

final class ImageryTilesTests: XCTestCase {
    func testVisibleTilesRefineAndStayBoundedAcrossDatelineAndPoles() {
        for point in [GeoPoint(latitude: 0, longitude: 179.99), .init(latitude: 84.9, longitude: -179.99), .init(latitude: -84.9, longitude: 0)] {
            for distance in [150.0, 50_000, 2_000_000, 20_000_000] {
                let tiles = ImageryTile.visible(center: point, distance: distance, pitch: 60, width: 2000, height: 1200, maxZoom: 19)
                XCTAssertFalse(tiles.isEmpty); XCTAssertLessThan(tiles.count, 220)
                for t in tiles { XCTAssertTrue((0..<(1 << t.z)).contains(t.x)); XCTAssertTrue((0..<(1 << t.z)).contains(t.y)) }
                for t in tiles { if let parent = t.parent { XCTAssertTrue(tiles.contains(parent)) } }
            }
        }
        let p = GeoPoint(latitude: 40, longitude: -74)
        let far = ImageryTile.visible(center: p, distance: 10_000_000, pitch: 0, width: 2000, height: 1200, maxZoom: 19)
        let near = ImageryTile.visible(center: p, distance: 500, pitch: 0, width: 2000, height: 1200, maxZoom: 19)
        XCTAssertGreaterThan(near.map(\.z).max()!, far.map(\.z).max()!)
    }
    func testSourceURLsAndWaybackMetadataNeverConfuseReleaseWithCapture() throws {
        let data = Data(#"{"1":{"itemTitle":"World Imagery (Wayback 2026-09-24)","itemURL":"https://wayback.maptiles.arcgis.com/tile/1/{level}/{row}/{col}","metadataLayerUrl":"https://metadata.maptiles.arcgis.com/arcgis/rest/services/example/MapServer"},"bad":{"itemTitle":"2026-09-25","itemURL":"http://evil.test/{level}/{row}/{col}","metadataLayerUrl":"https://evil.test/"}}"#.utf8)
        let releases = try WaybackRelease.decode(data); XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(ImagerySource.wayback(releases[0]).url(.init(z: 3, x: 4, y: 2)).absoluteString, "https://wayback.maptiles.arcgis.com/tile/1/3/2/4")
        let capture = try ImageryCatalog.capture(Data(#"{"results":[{"attributes":{"SRC_DATE2":"3/14/2024","SRC_DESC":"City orthos"}}]}"#.utf8))
        XCTAssertEqual(capture?.date, "2024-03-14"); XCTAssertNotEqual(capture?.date, releases[0].date)
        XCTAssertNil(try ImageryCatalog.capture(Data(#"{"results":[{"attributes":{"SRC_DATE2":"Null"}}]}"#.utf8)))
        let source = ImagerySource.nasa(.landsat, date: EarthObservation.earliest)
        XCTAssertTrue(source.template.contains("HLS_L30")); XCTAssertEqual(source.maxZoom, 12)
    }
    func testCatalogDatesAreUniqueAndOrdered() throws {
        let data = Data(#"{"feed":{"entry":[{"time_start":"2026-10-02T12:00:00Z"},{"time_start":"2026-10-01T12:00:00Z"},{"time_start":"2026-10-02T15:00:00Z"}]}}"#.utf8)
        XCTAssertEqual(try ImageryCatalog.decodeDates(data), ["2026-10-01", "2026-10-02"])
    }
    @MainActor func testZoomKeepsTiledGlobeAndFlyToFramesGeometryAndStopsTour() throws {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.mode = .globe; store.distance = 3_000_000; store.zoom(0.01)
        XCTAssertEqual(store.mode, .globe); XCTAssertEqual(store.distance, 30_000)
        store.touring = true; store.tool = .polygon; store.cursorPoint = .init(latitude: 0, longitude: 0)
        let feature = EarthFeature(name: "Dateline", kind: .path, points: [.init(latitude: 10, longitude: 179), .init(latitude: 12, longitude: -179)])
        let request = store.cameraRequest; store.fly(to: feature)
        XCTAssertFalse(store.touring); XCTAssertEqual(store.tool, .navigate); XCTAssertNil(store.cursorPoint)
        XCTAssertEqual(store.latitude, 11, accuracy: 0.001); XCTAssertEqual(abs(store.longitude), 180, accuracy: 0.001)
        XCTAssertNotEqual(store.cameraRequest, request); XCTAssertEqual(store.selection, feature.id); XCTAssertEqual(store.mode, .map)
        XCTAssertGreaterThan(store.distance, GeoMath.distance(store.center, feature.points[0]))
    }
    @MainActor func testTourFlightPreservesPlaybackAndHistoryUsesFlatMap() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let place = EarthFeature(name: "Stop", kind: .point, points: [.init(latitude: 40, longitude: -74)])
        store.touring = true
        store.fly(to: place, interruptTour: false)
        XCTAssertTrue(store.touring); XCTAssertEqual(store.distance, 750)
        store.historicalImagery = true
        XCTAssertEqual(store.pitch, 0)
        store.fly(to: place)
        XCTAssertFalse(store.touring); XCTAssertEqual(store.pitch, 0)
    }
    @MainActor func testWaybackCaptureLabelUsesMetadataAndClearsOnReleaseChange() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.historicalImagery = true; store.historyProduct = .wayback; store.captureDate = "2024-03-14"
        XCTAssertEqual(store.imageryDateLabel, "Captured: 2024-03-14")
        store.waybackReleaseID = "different"
        XCTAssertNil(store.captureDate); XCTAssertEqual(store.imageryDateLabel, "Captured: Not supplied")
    }
}
