import XCTest
import MapKit
@testable import EarthPro

final class ObservationTests: XCTestCase {
    @MainActor func testSearchHistoryDeduplicatesBoundsAndClears() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.rememberSearch("  Paris  "); store.rememberSearch("Tokyo"); store.rememberSearch("paris")
        XCTAssertEqual(store.recentSearches, ["paris", "Tokyo"])
        store.rememberSearch("  "); XCTAssertEqual(store.recentSearches.count, 2)
        for index in 0..<25 { store.rememberSearch("Place \(index)") }
        XCTAssertEqual(store.recentSearches.count, 20); XCTAssertEqual(store.recentSearches.first, "Place 24")
        store.clearSearchHistory(); XCTAssertTrue(store.recentSearches.isEmpty)
        store.repeatSearch("0, -140"); XCTAssertEqual(store.recentSearches, ["0, -140"])
    }
    @MainActor func testPadPanUsesElapsedTime() {
        func travel(frames: Int) -> GeoPoint {
            let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            store.latitude = 0; store.longitude = 0; store.distance = 100_000
            for _ in 0..<frames { store.navigationPad(look: false, x: 0, y: -1, seconds: 1 / Double(frames)) }
            return store.center
        }
        let a = travel(frames: 30), b = travel(frames: 120)
        XCTAssertEqual(GeoMath.distance(.init(latitude: 0, longitude: 0), a), 18_000, accuracy: 0.1)
        XCTAssertLessThan(GeoMath.distance(a, b), 0.1)
    }
    @MainActor func testImmediateOfflineElevationAndOceanDepth() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.latitude = 0; store.longitude = -140; store.updateElevation()
        XCTAssertLessThan(store.elevationMeters ?? 0, -1000)
        XCTAssertTrue(store.elevationStatus.contains("coarse")); XCTAssertTrue(store.elevationSource.contains("Mapzen"))
        XCTAssertEqual(EarthTerrain.elevation(store.center), 0)
        XCTAssertNil(EarthTerrain.sampledElevation(.init(latitude: 90, longitude: 0)))
    }
    @MainActor func testHistoryPlaybackWaitsForImagesAndStopsAtEnd() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.mode = .map; store.imageryDate = EarthObservation.earliest; store.historyStepDays = 30
        store.toggleHistoryPlayback(); XCTAssertTrue(store.historyPlaying); XCTAssertTrue(store.historicalImagery)
        store.archiveLoading = true; store.advanceHistoryPlayback(); XCTAssertEqual(store.imageryDate, EarthObservation.earliest)
        store.archiveLoading = false; store.advanceHistoryPlayback()
        XCTAssertEqual(store.imageryDate, EarthObservation.earliest.addingTimeInterval(30 * 86400))
        store.imageryDate = EarthObservation.latest; store.advanceHistoryPlayback(); XCTAssertFalse(store.historyPlaying)
        store.toggleHistoryPlayback(); store.historicalImagery = false; XCTAssertFalse(store.historyPlaying)
    }
    func testDateArchiveProjectionAndTile() {
        let date = EarthObservation.calendar.date(from: DateComponents(year: 2015, month: 7, day: 21))!
        let url = EarthObservation.archiveURL(date: date, bbox: "-180,-90,180,90", mercator: false, width: 2048, height: 1024)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["LAYERS"], "MODIS_Terra_CorrectedReflectance_TrueColor")
        XCTAssertEqual(query["TIME"], "2015-07-21"); XCTAssertEqual(query["SRS"], "EPSG:4326")
        XCTAssertEqual(query["WIDTH"], "2048")
        let tile = EarthArchiveTiles(date: date).url(forTilePath: .init(x: 0, y: 0, z: 0, contentScaleFactor: 1))
        XCTAssertTrue(tile.absoluteString.contains("EPSG:3857") || tile.absoluteString.contains("EPSG%3A3857"))
        XCTAssertEqual(EarthObservation.day(EarthObservation.earliest), "2000-02-24")
    }
    func testDMSRoundingAndHemisphere() {
        let point = GeoPoint(latitude: -12.99999999, longitude: 179.5)
        XCTAssertEqual(EarthObservation.coordinates(point, dms: true), "13°00′00.00″ S  179°30′00.00″ E")
        XCTAssertEqual(EarthObservation.coordinates(point, dms: false), point.label)
    }
    func testEyeAltitudeRespectsTiltAndCurvature() {
        XCTAssertEqual(EarthObservation.eyeAltitude(distance: 10_000, pitch: 0), 10_000, accuracy: 0.001)
        let tilted = EarthObservation.eyeAltitude(distance: 10_000, pitch: 60)
        XCTAssertGreaterThan(tilted, 5_000); XCTAssertLessThan(tilted, 5_010)
        XCTAssertEqual(EarthObservation.eyeAltitude(distance: 16_000_000, pitch: 0), 16_000_000, accuracy: 0.001)
    }
    func testSolsticeSunPositionAndDailyRotation() {
        let noon = EarthObservation.calendar.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12))!
        let sun = EarthObservation.sunPoint(at: noon), later = EarthObservation.sunPoint(at: noon.addingTimeInterval(6 * 3600))
        XCTAssertEqual(sun.latitude, 23.44, accuracy: 0.1); XCTAssertEqual(sun.longitude, 0, accuracy: 2)
        XCTAssertEqual(GeoMath.normalizedLongitude(later.longitude - sun.longitude), -90, accuracy: 1)
    }
    func testArchiveRejectsEmptyCoverage() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<4 { for x in 0..<4 { bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: x, y: y) } }
        XCTAssertFalse(EarthObservation.hasCoverage(try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))))
        bitmap.setColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), atX: 1, y: 1)
        XCTAssertTrue(EarthObservation.hasCoverage(try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))))
    }
    func testElevationValidation() throws {
        XCTAssertEqual(try EarthObservation.decodeElevation(Data(#"{"elevation":[1234.5]}"#.utf8)), 1234.5)
        XCTAssertThrowsError(try EarthObservation.decodeElevation(Data(#"{"elevation":[null]}"#.utf8)))
        XCTAssertThrowsError(try EarthObservation.decodeElevation(Data(#"{"elevation":[999999]}"#.utf8)))
    }
    @MainActor func testMetadataAndDateBounds() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertTrue(store.imageryInformation.contains("Esri tiled"))
        store.mode = .map; store.provider = .apple
        XCTAssertTrue(store.imageryInformation.contains("not supplied"))
        store.historicalImagery = true; store.imageryDate = EarthObservation.earliest; store.stepImagery(days: -1)
        XCTAssertEqual(store.imageryDate, EarthObservation.earliest)
        store.imageryDate = EarthObservation.latest; store.stepImagery(days: 1)
        XCTAssertEqual(store.imageryDate, EarthObservation.latest)
    }
    @MainActor func testImageryDateDescribesDisplayedSource() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(store.imageryDateLabel, "Imagery date: Not supplied")
        store.mode = .map; store.provider = .apple; store.mapStyle = .hybrid
        XCTAssertEqual(store.imageryDateLabel, "Imagery date: Not supplied")
        store.provider = .openStreetMap
        XCTAssertEqual(store.imageryDateLabel, "Imagery date: N/A")
        store.provider = .google; store.mapStyle = .streets; store.google3DActive = true
        XCTAssertEqual(store.imageryDateLabel, "Imagery date: Not supplied")
        store.historicalImagery = true; store.imageryDate = EarthObservation.earliest
        XCTAssertEqual(store.imageryDateLabel, "Imagery day: 2000-02-24 UTC")
        store.mode = .globe
        store.archiveLoading = true
        XCTAssertEqual(store.imageryDateLabel, "Imagery day: 2000-02-24 UTC")
        store.archiveLoading = false
        XCTAssertEqual(store.imageryDateLabel, "Imagery day: 2000-02-24 UTC")
        store.archiveImage = NSImage(size: NSSize(width: 1, height: 1))
        store.archiveLoadedDate = "2000-02-25"
        XCTAssertEqual(store.imageryDateLabel, "Imagery day: 2000-02-24 UTC")
    }
    @MainActor func testStreetViewDatesClearAndRejectStaleMetadata() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.mode = .map; store.provider = .google; store.streetView = true
        let request = store.streetRequest.uuidString
        store.updateStreetImagery(date: nil, loading: true, request: request)
        XCTAssertEqual(store.imageryDateLabel, "Street View date: Loading…")
        store.updateStreetImagery(date: "2024-09", loading: false, request: request)
        XCTAssertEqual(store.imageryDateLabel, "Street View date: 2024-09")
        XCTAssertEqual(store.imageryInformation, "Imagery: Google Street View")
        store.updateStreetImagery(date: "2023", loading: false, request: request)
        XCTAssertEqual(store.imageryDateLabel, "Street View date: 2023")
        for date in [nil, "", "2024-13", "© 2024 Google", "2024-09-17"] as [String?] {
            store.updateStreetImagery(date: date, loading: false, request: request)
            XCTAssertEqual(store.imageryDateLabel, "Street View date: Not supplied")
        }
        store.updateStreetImagery(date: "2024-09", loading: false, request: request)
        store.updateStreetImagery(date: nil, loading: true, request: request)
        XCTAssertNil(store.streetImageryDate)
        store.streetRequest = UUID()
        store.updateStreetImagery(date: "2024-09", loading: false, request: request)
        XCTAssertNil(store.streetImageryDate)
        let current = store.streetRequest.uuidString
        store.updateStreetImagery(date: "2025-02", loading: false, request: current)
        store.streetView = false
        store.updateStreetImagery(date: "2025-02", loading: false, request: current)
        XCTAssertNil(store.streetImageryDate)
        XCTAssertEqual(store.imageryDateLabel, "Imagery date: Not supplied")
        store.provider = .apple
        store.streetView = true
        store.updateStreetImagery(date: "2025-02", loading: false, request: current)
        XCTAssertNil(store.streetImageryDate)
    }
}
