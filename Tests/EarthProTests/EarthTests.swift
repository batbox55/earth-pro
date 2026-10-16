import XCTest
import simd
@testable import EarthPro

final class EarthTests: XCTestCase {
    func testMotionEasingAndCoastAreIndependentOfFrameRate() {
        for response in [0.065, 0.23] {
            let targetDecay = 1 - EarthNavigation.motionFraction(elapsed: 1, response: response)
            for frames in [30, 60, 120] {
                var remaining = 1.0, travel = 0.0
                for _ in 0..<frames {
                    let fraction = EarthNavigation.motionFraction(elapsed: 1 / Double(frames), response: response)
                    travel += remaining * response * fraction
                    remaining *= 1 - fraction
                }
                XCTAssertEqual(remaining, targetDecay, accuracy: 0.0000001)
                XCTAssertEqual(travel, response * (1 - targetDecay), accuracy: 0.0000001)
            }
        }
        XCTAssertEqual(EarthNavigation.motionFraction(elapsed: 0, response: 0.23), 0)
        XCTAssertEqual(EarthNavigation.motionFraction(elapsed: .nan, response: 0.23), 0)
    }
    func testCoordinatesAndDateline() {
        XCTAssertEqual(GeoPoint.parse("37.7749, -122.4194"), .init(latitude: 37.7749, longitude: -122.4194))
        XCTAssertNil(GeoPoint.parse("91, 0")); XCTAssertNil(GeoPoint.parse("London 1 2")); XCTAssertNil(GeoPoint.parse("nan, 0"))
        XCTAssertEqual(GeoMath.normalizedLongitude(181), -179)
        let length = GeoMath.distance(.init(latitude: 0, longitude: 179), .init(latitude: 0, longitude: -179))
        XCTAssertEqual(length, 222_390, accuracy: 50)
    }
    func testGeodesicDistanceAndArea() {
        let london = GeoPoint(latitude: 51.5074, longitude: -0.1278), ny = GeoPoint(latitude: 40.7128, longitude: -74.006)
        XCTAssertEqual(GeoMath.distance(london, ny) / 1000, 5570, accuracy: 10)
        let square: [GeoPoint] = [.init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 1), .init(latitude: 1, longitude: 1), .init(latitude: 1, longitude: 0)]
        XCTAssertEqual(GeoMath.area(square) / 1_000_000, 12363.7, accuracy: 2)
        XCTAssertEqual(GeoMath.area(square), GeoMath.area(square.reversed()), accuracy: 1)
    }
    func testKMLRoundTrip() throws {
        let features = [
            EarthFeature(name: "A & B <park>", notes: "Water > land\nA \"quote\"", kind: .point, points: [.init(latitude: 12.5, longitude: -23.5, altitude: 100)], color: "#53B8F6", isVisible: false),
            EarthFeature(name: "Walk", kind: .path, points: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 2)]),
            EarthFeature(name: "Area", kind: .polygon, points: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 0), .init(latitude: 1, longitude: 1)])
        ]
        let parsed = try KMLService.decode(KMLService.encode(features))
        XCTAssertEqual(parsed.features.count, 3)
        for (before, after) in zip(features, parsed.features) {
            XCTAssertEqual(before.name, after.name); XCTAssertEqual(before.notes, after.notes)
            XCTAssertEqual(before.kind, after.kind); XCTAssertEqual(before.points, after.points)
            XCTAssertEqual(before.color.uppercased(), after.color.uppercased()); XCTAssertEqual(before.isVisible, after.isVisible)
        }
    }
    func testMalformedAndUnsupportedKML() throws {
        XCTAssertThrowsError(try KMLService.decode(Data("<kml><broken>".utf8)))
        XCTAssertThrowsError(try KMLService.decode(Data("<other/>".utf8)))
        let mixed = "<kml><Document><Placemark><name>Bad</name><Point><coordinates>1,95</coordinates></Point></Placemark><Placemark><name>Good</name><description><![CDATA[<b>Notes</b>]]></description><Point><coordinates>1,2</coordinates></Point></Placemark></Document></kml>"
        let result = try KMLService.decode(Data(mixed.utf8)); XCTAssertEqual(result.skipped, 1); XCTAssertEqual(result.features[0].notes, "<b>Notes</b>")
    }
    func testKMZImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feature = EarthFeature(name: "Archived place", kind: .point, points: [.init(latitude: 12, longitude: 34)])
        try KMLService.encode([feature]).write(to: directory.appendingPathComponent("doc.kml"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory; process.arguments = ["-q", "places.kmz", "doc.kml"]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let result = try KMLService.read(directory.appendingPathComponent("places.kmz"))
        XCTAssertEqual(result.features.first?.name, feature.name)
        XCTAssertEqual(result.features.first?.points, feature.points)
    }
    @MainActor func testPersistenceEditUndoAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("places.json")
        let store = EarthStore(libraryURL: url)
        let feature = EarthFeature(name: "Test", kind: .point, points: [.init(latitude: 1, longitude: 2)])
        store.save(feature); XCTAssertEqual(EarthStore(libraryURL: url).features, [feature])
        store.delete(feature); XCTAssertTrue(store.features.isEmpty)
        store.undo(); XCTAssertEqual(store.features, [feature])
        store.redo(); XCTAssertTrue(store.features.isEmpty)
    }
    @MainActor func testCorruptLibraryIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("places.json"), original = Data("broken".utf8)
        try original.write(to: url)
        let store = EarthStore(libraryURL: url); XCTAssertNotNil(store.error)
        store.save(.init(name: "New", kind: .point, points: [.init(latitude: 1, longitude: 2)]))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    @MainActor func testDrawingRequiresEnoughPointsAndSavesShape() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EarthStore(libraryURL: directory.appendingPathComponent("places.json"))
        store.begin(.polygon); store.pick(.init(latitude: 0, longitude: 0)); store.pick(.init(latitude: 0, longitude: 1))
        XCTAssertFalse(store.canFinish); store.finishDrawing(); XCTAssertNil(store.editingFeature)
        store.pick(.init(latitude: 1, longitude: 1)); XCTAssertTrue(store.canFinish); store.finishDrawing()
        let feature = try XCTUnwrap(store.editingFeature); store.save(feature)
        XCTAssertEqual(store.features[0].kind, .polygon); XCTAssertEqual(store.tool, .navigate); XCTAssertTrue(store.vertices.isEmpty)
    }
    func testGoogleKeyInputValidation() {
        XCTAssertNil(GoogleMapsKeychain.normalized(""))
        XCTAssertNil(GoogleMapsKeychain.normalized("https://example.com/?key=secret"))
        XCTAssertNil(GoogleMapsKeychain.normalized(String(repeating: "a", count: 201)))
        let sample = "AIza" + String(repeating: "x", count: 35)
        XCTAssertEqual(GoogleMapsKeychain.normalized("  " + sample + "\n"), sample)
    }
    @MainActor func testGoogleWithoutKeyKeepsAppleAvailable() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.chooseProvider(.google)
        XCTAssertEqual(store.mode, .globe)
        XCTAssertEqual(store.provider, .apple)
        XCTAssertTrue(store.googleKeyLoading)
        XCTAssertTrue(store.googleSettings)
        XCTAssertNil(store.googleKey)
        XCTAssertNil(store.googleQuery)
        store.chooseProvider(.apple)
        XCTAssertEqual(store.provider, .apple)
        XCTAssertFalse(store.streetView)
    }
    func testGoogleLocalViewerServesOnlyBundledPage() async throws {
        let server = GoogleMapServer(port: 0)
        defer { server.stop() }
        let url = try await withCheckedThrowingContinuation { continuation in
            server.start { continuation.resume(with: $0) }
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Referrer-Policy"), "strict-origin-when-cross-origin")
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(html.contains("window.earthUpdate"))
        XCTAssertTrue(html.contains("window.earthKey"))
        XCTAssertFalse(html.contains("AIza"))
        let (_, missing) = try await URLSession.shared.data(from: URL(string: "/library.json", relativeTo: url)!.absoluteURL)
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
        var wrongHost = URLRequest(url: url)
        wrongHost.setValue("untrusted.example:18793", forHTTPHeaderField: "Host")
        let (_, rejected) = try await URLSession.shared.data(for: wrongHost)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 404)
    }
    func testSurfaceGrabRotatesCameraAcrossDatelineAndBack() {
        let grabbed = GeoPoint(latitude: 25, longitude: 179), underCursor = GeoPoint(latitude: 30, longitude: -170)
        let rotation = simd_quatd(from: EarthNavigation.vector(underCursor), to: EarthNavigation.vector(grabbed))
        XCTAssertLessThan(simd_distance(rotation.act(EarthNavigation.vector(underCursor)), EarthNavigation.vector(grabbed)), 0.000001)
        let center = GeoPoint(latitude: 60, longitude: 175)
        let (moved, heading) = EarthNavigation.rotatedCamera(center: center, heading: 42, rotation: rotation)
        let (restored, restoredHeading) = EarthNavigation.rotatedCamera(center: moved, heading: heading, rotation: rotation.inverse)
        XCTAssertLessThan(GeoMath.distance(center, restored), 0.01)
        XCTAssertEqual(restoredHeading, 42, accuracy: 0.000001)
    }
    @MainActor func testFreeStreetProviderAndGoogleSetupDoNotInterruptExploring() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let defaults = UserDefaults.standard.string(forKey: "freeMapProvider")
        defer { UserDefaults.standard.set(defaults, forKey: "freeMapProvider") }
        store.chooseProvider(.openStreetMap); store.setMode(.map)
        store.navigationZoom(0.5)
        let distance = store.distance
        store.chooseProvider(.google)
        XCTAssertEqual(store.provider, .openStreetMap)
        XCTAssertEqual(store.mode, .map)
        XCTAssertEqual(store.distance, distance)
        XCTAssertTrue(store.googleSettings)
        XCTAssertTrue(store.googleKeyLoading)
        let tiles = OpenStreetMapTiles()
        XCTAssertTrue(tiles.canReplaceMapContent)
        XCTAssertEqual(tiles.url(forTilePath: .init(x: 1, y: 2, z: 3, contentScaleFactor: 2)).absoluteString, "https://tile.openstreetmap.org/3/1/2.png")
    }
    func testEarthProMouseMappingAndFineZoom() {
        XCTAssertEqual(EarthNavigation.dragMode(button: 0, modifiers: []), .pan)
        XCTAssertEqual(EarthNavigation.dragMode(button: 0, modifiers: .shift), .orbit)
        XCTAssertEqual(EarthNavigation.dragMode(button: 2, modifiers: []), .orbit)
        XCTAssertEqual(EarthNavigation.dragMode(button: 0, modifiers: .command), .look)
        XCTAssertEqual(EarthNavigation.dragMode(button: 0, modifiers: .control), .zoom)
        XCTAssertEqual(EarthNavigation.dragMode(button: 1, modifiers: []), .zoom)
        let normal = EarthNavigation.zoomFactor(delta: 3, precise: false, fine: false)
        let fine = EarthNavigation.zoomFactor(delta: 3, precise: false, fine: true)
        XCTAssertLessThan(normal, 1); XCTAssertGreaterThan(fine, normal); XCTAssertLessThan(fine, 1)
        XCTAssertGreaterThan(EarthNavigation.zoomFactor(delta: -3, precise: true, fine: false), 1)
    }
    @MainActor func testNavigationZoomAnchoringAndContinuousViewTransition() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.latitude = 0; store.longitude = 179; store.distance = 2_600_000
        store.navigationZoom(0.9, anchor: .init(latitude: 10, longitude: -179))
        XCTAssertEqual(store.mode, .map)
        XCTAssertEqual(store.distance, 2_340_000, accuracy: 0.1)
        XCTAssertEqual(store.latitude, 1, accuracy: 0.001)
        XCTAssertEqual(store.longitude, 179.2, accuracy: 0.001)
        store.navigationZoom(.nan); XCTAssertTrue(store.distance.isFinite)
        store.navigationZoom(0.00001); XCTAssertEqual(store.distance, 150)
    }
    @MainActor func testPanFollowsCameraHeadingAndFineModifier() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.latitude = 0; store.longitude = 0; store.distance = 100_000
        store.navigateDrag(.pan, dx: 100, dy: 0, height: 800)
        XCTAssertLessThan(store.longitude, 0); XCTAssertEqual(store.latitude, 0, accuracy: 0.001)
        let normal = abs(store.longitude)
        store.longitude = 0
        store.navigateDrag(.pan, dx: 100, dy: 0, height: 800, fine: true)
        XCTAssertEqual(abs(store.longitude), normal * 0.2, accuracy: 0.001)
        store.latitude = 0; store.longitude = 0; store.heading = 90
        store.navigateDrag(.pan, dx: 100, dy: 0, height: 800)
        XCTAssertGreaterThan(store.latitude, 0); XCTAssertEqual(store.longitude, 0, accuracy: 0.001)
    }
    @MainActor func testOrbitAndFirstPersonLookHaveDifferentPivots() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.mode = .map; store.latitude = 10; store.longitude = 20; store.distance = 10_000; store.pitch = 45
        let center = store.center
        store.navigationOrbit(dx: 30, dy: 10)
        XCTAssertEqual(store.center, center)
        XCTAssertEqual(store.heading, 30); XCTAssertEqual(store.pitch, 55)
        let eye = EarthNavigation.offset(store.center, bearing: store.heading + 180, meters: store.distance * sin(store.pitch * .pi / 180))
        let altitude = store.distance * cos(store.pitch * .pi / 180)
        store.navigationOrbit(dx: 20, dy: 5, look: true)
        let nextEye = EarthNavigation.offset(store.center, bearing: store.heading + 180, meters: store.distance * sin(store.pitch * .pi / 180))
        XCTAssertLessThan(GeoMath.distance(eye, nextEye), 10)
        XCTAssertEqual(store.distance * cos(store.pitch * .pi / 180), altitude, accuracy: 0.01)
        XCTAssertNotEqual(store.center, center)
        store.navigationOrbit(dx: 720, dy: 900); XCTAssertTrue((0..<360).contains(store.heading)); XCTAssertEqual(store.pitch, 80)
        store.terrain = false; store.navigationOrbit(dx: 0, dy: 20); XCTAssertEqual(store.pitch, 0)
    }
}
