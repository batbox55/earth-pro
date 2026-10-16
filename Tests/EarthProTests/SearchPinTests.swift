import XCTest
import AppKit
@testable import EarthPro

final class SearchPinTests: XCTestCase {
    @MainActor func testCoordinateSearchPlacesOneTemporaryPinAndClearsIt() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.searchText = "37.7749, -122.4194"; store.search()
        XCTAssertEqual(store.searchPin?.center, GeoPoint(latitude: 37.7749, longitude: -122.4194))
        XCTAssertEqual(store.renderedFeatures.count, 1); XCTAssertTrue(store.features.isEmpty)
        store.showPlaces = false
        XCTAssertEqual(store.renderedFeatures.count, 1)
        store.searchText = "48.8584, 2.2945"; store.search()
        XCTAssertEqual(store.renderedFeatures.count, 1)
        XCTAssertEqual(store.searchPin?.center.latitude, 48.8584)
        store.searchText = ""; store.search()
        XCTAssertNil(store.searchPin); XCTAssertTrue(store.searchHits.isEmpty)
    }
    @MainActor func testResultSelectionAndStyledPinSurviveSaveAndReloadWithoutDuplicates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = EarthStore(libraryURL: url)
        let hit = SearchHit(title: "Found address", subtitle: "Nearest resolved location", point: .init(latitude: 40, longitude: -70))
        store.selectSearchHit(hit)
        XCTAssertEqual(store.latitude, 40); XCTAssertEqual(store.longitude, -70)
        XCTAssertEqual(store.selection, store.searchPin?.id)
        store.saveSearchHit(hit)
        var pin = try XCTUnwrap(store.editingFeature)
        pin.color = "#123ABC"; pin.pinShape = .diamond; pin.pinIcon = .camera
        store.save(pin)
        XCTAssertNil(store.searchPin); XCTAssertEqual(store.renderedFeatures.count, 1)
        store.selectSearchHit(hit)
        XCTAssertEqual(store.renderedFeatures.count, 1)
        XCTAssertEqual(store.searchPin?.resolvedPinIcon, .camera)
        let reloaded = EarthStore(libraryURL: url)
        XCTAssertEqual(reloaded.features, [pin])
        XCTAssertEqual(reloaded.features.first?.resolvedPinShape, .diamond)
        XCTAssertEqual(reloaded.features.first?.resolvedPinIcon, .camera)
    }
    @MainActor func testSelectingSearchResultZoomsToAddressWithDistinctPin() throws {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let point = GeoPoint(latitude: 48.8584, longitude: 2.2945)
        store.distance = 16_000_000; store.mode = .globe
        // Broad geocoder regions must not keep an individual selected address zoomed out.
        let hit = SearchHit(title: "Address", subtitle: "Paris", point: point, distance: 4_000_000)
        store.selectSearchHit(hit)
        XCTAssertEqual(store.mode, .map)
        XCTAssertEqual(store.distance, 750)
        XCTAssertEqual(store.latitude, point.latitude, accuracy: 0.0000001)
        XCTAssertEqual(store.longitude, point.longitude, accuracy: 0.0000001)
        let pin = try XCTUnwrap(store.searchPin)
        XCTAssertEqual(pin.center, point)
        XCTAssertEqual(pin.color, "#E234A8")
        XCTAssertNotEqual(pin.color, EarthFeature(name: "Saved", kind: .point, points: [point]).color)
        XCTAssertEqual(store.renderedFeatures.filter { $0.id == pin.id }.count, 1)
        store.selectSearchHit(SearchHit(title: "Closer", subtitle: "", point: point, distance: 200))
        XCTAssertEqual(store.distance, 200)
    }
    func testOldLibraryDefaultsAndKMLStyleRoundTrip() throws {
        let point = EarthFeature(name: "Legacy", kind: .point, points: [.init(latitude: 5, longitude: 6)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(point)) as? [String: Any])
        object.removeValue(forKey: "pinShape"); object.removeValue(forKey: "pinIcon")
        let legacy = try JSONDecoder().decode(EarthFeature.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.resolvedPinShape, .pin); XCTAssertEqual(legacy.resolvedPinIcon, .location)
        var styled = point; styled.pinShape = .square; styled.pinIcon = .star; styled.color = "#123ABC"
        let imported = try XCTUnwrap(KMLService.decode(KMLService.encode([styled])).features.first)
        XCTAssertEqual(imported.pinShape, .square); XCTAssertEqual(imported.pinIcon, .star)
        XCTAssertEqual(imported.color.uppercased(), styled.color)
    }
    @MainActor func testPinArtworkIsTransparentAndDistinctForEachStyle() throws {
        var point = EarthFeature(name: "Pin", kind: .point, points: [.init(latitude: 0, longitude: 0)])
        var art = Set<String>()
        for shape in PinShape.allCases {
            point.pinShape = shape
            let image = EarthPinAppearance.image(point)
            XCTAssertEqual(image.size, NSSize(width: 40, height: 48))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0)
            art.insert(EarthPinAppearance.dataURL(point))
        }
        XCTAssertEqual(art.count, PinShape.allCases.count)
        let previous = EarthPinAppearance.dataURL(point)
        point.pinIcon = .home
        XCTAssertNotEqual(EarthPinAppearance.dataURL(point), previous)
        point.color = "#FF0000"
        XCTAssertNotEqual(EarthPinAppearance.dataURL(point), previous)
    }
}
