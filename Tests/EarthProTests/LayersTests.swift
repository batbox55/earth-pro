import XCTest
import MapKit
@testable import EarthPro

final class LayersTests: XCTestCase {
    func testBundledBordersAndCitiesHaveValidGeometry() {
        XCTAssertEqual(EarthBaseData.countries.count, 177)
        XCTAssertGreaterThan(EarthBaseData.cities.count, 200)
        XCTAssertGreaterThan(EarthBaseData.regions.count, 500)
        XCTAssertTrue(EarthBaseData.regions.allSatisfy { $0.allSatisfy(\.isValid) })
        XCTAssertTrue(EarthBaseData.countries.allSatisfy { !$0.name.isEmpty && $0.label.isValid && !$0.outlines.isEmpty && $0.outlines.allSatisfy { $0.count > 1 && $0.allSatisfy(\.isValid) } })
        XCTAssertTrue(EarthBaseData.cities.allSatisfy { $0.point.isValid })
        XCTAssertTrue(EarthBaseData.countries.contains { $0.name == "Canada" })
    }
    func testLayerPreferencesRoundTripAndPrimaryVisibility() throws {
        var layers = EarthLayers(); layers.labels = false; layers.clouds = true
        XCTAssertTrue(layers.enabled["borders"] == true); XCTAssertFalse(layers.enabled["labels"] == true)
        layers.primary = false
        XCTAssertTrue(layers.enabled.values.allSatisfy { !$0 })
        let restored = try JSONDecoder().decode(EarthLayers.self, from: JSONEncoder().encode(layers))
        XCTAssertEqual(restored, layers)
        layers.primary = true
        XCTAssertTrue(layers.clouds); XCTAssertFalse(layers.labels)
    }
    func testEarthquakeCoordinatesSortingAndSourceValidation() throws {
        let rows: [[String: Any]] = [
            ["id":"low", "properties":["title":"Small event", "mag":2.7, "url":"https://earthquake.usgs.gov/test", "time":0], "geometry":["coordinates":[-120, 35, 4]]],
            ["id":"high", "properties":["title":"Larger event", "mag":5.1, "url":"javascript:bad"], "geometry":["coordinates":[30, 20, 8]]],
            ["id":"invalid", "properties":["title":"Bad coordinates", "mag":6], "geometry":["coordinates":[30, 120]]]
        ]
        let items = try EarthLayerService.decodeEarthquakes(JSONSerialization.data(withJSONObject: ["features":rows]))
        XCTAssertEqual(items.map(\.id), ["usgs-high", "usgs-low"])
        XCTAssertEqual(items[1].point, .init(latitude: 35, longitude: -120))
        XCTAssertNil(items[0].url); XCTAssertEqual(items[1].url?.host, "earthquake.usgs.gov")
        XCTAssertTrue(items[1].detail.contains("4.0 km"))
    }
    func testPhotoAttributionAndURLValidation() throws {
        let info: [String: Any] = ["descriptionurl":"https://commons.wikimedia.org/wiki/File:Example.jpg", "thumburl":"https://upload.wikimedia.org/example.jpg", "extmetadata":["Artist":["value":"<a href='bad'>Example Artist</a>"], "LicenseShortName":["value":"CC BY-SA 4.0"]]]
        let page: [String: Any] = ["pageid":12, "title":"File:Example.jpg", "coordinates":[["lat":37.7,"lon":-122.4]], "imageinfo":[info]]
        let data = try JSONSerialization.data(withJSONObject: ["query":["pages":["12":page]]])
        let item = try XCTUnwrap(EarthLayerService.decodePhotos(data).first)
        XCTAssertEqual(item.title, "Example.jpg"); XCTAssertEqual(item.credit, "Example Artist · CC BY-SA 4.0")
        XCTAssertEqual(item.imageURL?.host, "upload.wikimedia.org")
        var unsafe = page; unsafe["imageinfo"] = [["descriptionurl":"https://untrusted.example/file", "thumburl":"file:///private/file"]]
        let rejected = try JSONSerialization.data(withJSONObject: ["query":["pages":["12":unsafe]]])
        XCTAssertTrue(try EarthLayerService.decodePhotos(rejected).isEmpty)
    }
    func testNewLayersPreserveOlderPreferences() throws {
        let old = Data(#"{"primary":true,"borders":false,"photos":true,"clouds":true}"#.utf8)
        let restored = try JSONDecoder().decode(EarthLayers.self, from: old)
        XCTAssertFalse(restored.borders); XCTAssertTrue(restored.photos); XCTAssertTrue(restored.clouds)
        XCTAssertTrue(restored.roads); XCTAssertFalse(restored.water); XCTAssertFalse(restored.wikipedia)
        var layers = restored; layers.water = true; layers.wikipedia = true
        XCTAssertTrue(layers.enabled["water"] == true); XCTAssertTrue(layers.enabled["wikipedia"] == true)
        layers.primary = false
        XCTAssertTrue(layers.enabled.values.allSatisfy { !$0 })
    }
    func testRoadAndWaterGeometry() {
        XCTAssertGreaterThan(EarthBaseData.roads.count, 100)
        XCTAssertGreaterThan(EarthBaseData.water.count, 400)
        for lines in [EarthBaseData.roads, EarthBaseData.water] {
            XCTAssertTrue(lines.allSatisfy { $0.count > 1 && $0.allSatisfy(\.isValid) })
        }
    }
    func testWikipediaExcerptsAndSourceValidation() throws {
        let page: [String: Any] = ["pageid":42, "title":"Example landmark", "extract":"A public landmark.",
            "coordinates":[["lat":37.7,"lon":-122.4]], "fullurl":"https://en.wikipedia.org/wiki/Example"]
        var unsafe = page; unsafe["fullurl"] = "https://untrusted.example/article"
        var invalid = page; invalid["coordinates"] = [["lat":120,"lon":0]]
        let data = try JSONSerialization.data(withJSONObject: ["query":["pages":["42":page,"43":unsafe,"44":invalid]]])
        let items = try EarthLayerService.decodeWikipedia(data)
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?.kind, .wikipedia)
        XCTAssertEqual(items.first?.detail, "A public landmark."); XCTAssertEqual(items.first?.url?.host, "en.wikipedia.org")
        XCTAssertTrue(items.first?.credit.contains("CC BY-SA") == true)
        XCTAssertThrowsError(try EarthLayerService.decodeWikipedia(Data(#"{"error":{"code":"badvalue"}}"#.utf8)))
    }
    func testPrimaryCheckboxSelectsAndClearsEveryChild() {
        var layers = EarthLayers()
        XCTAssertTrue(layers.selectionValues.contains(true)); XCTAssertTrue(layers.selectionValues.contains(false))
        layers.selectAll(true)
        XCTAssertTrue(layers.primary); XCTAssertTrue(layers.selectionValues.allSatisfy { $0 })
        layers.water = false
        XCTAssertTrue(layers.selectionValues.contains(true)); XCTAssertTrue(layers.selectionValues.contains(false))
        layers.selectAll(false)
        XCTAssertFalse(layers.primary); XCTAssertTrue(layers.selectionValues.allSatisfy { !$0 })
        XCTAssertTrue(EarthLayers.selectionKeys.allSatisfy { !layers[keyPath: $0] })
    }
    func testBundledParkAndAirportLayers() {
        XCTAssertEqual(EarthBaseData.parks.count, 387)
        XCTAssertEqual(EarthBaseData.airports.count, 893)
        XCTAssertGreaterThan(EarthBaseData.parkBoundaries.count, 100)
        XCTAssertTrue(EarthBaseData.parkBoundaries.allSatisfy { $0.count > 1 && $0.allSatisfy(\.isValid) })
        for items in [EarthBaseData.parks, EarthBaseData.airports] {
            XCTAssertEqual(Set(items.map(\.id)).count, items.count)
            XCTAssertTrue(items.allSatisfy { $0.point.isValid && !$0.title.isEmpty && $0.url?.scheme == "https" })
        }
        XCTAssertTrue(EarthBaseData.parks.contains { $0.title.contains("Yosemite") })
        XCTAssertTrue(EarthBaseData.airports.contains { $0.title.contains("SFO") })
    }
    func testTerrainSamplingAndSeam() {
        XCTAssertEqual(EarthTerrain.heights.count, 1024 * 1024)
        XCTAssertGreaterThan(EarthTerrain.elevation(.init(latitude: 30, longitude: 85)), 3000)
        XCTAssertEqual(EarthTerrain.elevation(.init(latitude: 0, longitude: -140)), 0)
        XCTAssertEqual(EarthTerrain.elevation(.init(latitude: 90, longitude: 0)), 0)
        XCTAssertEqual(EarthTerrain.elevation(.init(latitude: 45, longitude: 180)), EarthTerrain.elevation(.init(latitude: 45, longitude: -180)), accuracy: 0.001)
        XCTAssertEqual(EarthTerrain.elevation(.init(latitude: 91, longitude: 0)), 0)
    }
    @MainActor func testBuildingsLayerUsesSupportedRendererAndPublicMarkersFollowMaster() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.provider = .openStreetMap; store.setBuildingsLayer(true)
        XCTAssertEqual(store.provider, .openStreetMap); XCTAssertFalse(store.layers.buildings)
        store.provider = .apple; store.setBuildingsLayer(true)
        XCTAssertEqual(store.provider, .apple); XCTAssertEqual(store.mode, .map); XCTAssertEqual(store.mapStyle, .streets)
        XCTAssertTrue(store.layers.buildings); XCTAssertEqual(store.pitch, 55)
        store.setBuildingsLayer(false); XCTAssertFalse(store.layers.buildings)
        store.layers.parks = true; store.layers.transit = true
        XCTAssertEqual(store.visibleLayerItems.count, 1280)
        store.layers.primary = false; XCTAssertTrue(store.visibleLayerItems.isEmpty)
    }
    @MainActor func testGoogleBuildingsRespectProviderAndMasterLayer() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        // Selecting the provider directly avoids Keychain and billed network access in this test.
        store.provider = .google; store.setBuildingsLayer(true)
        XCTAssertEqual(store.provider, .google); XCTAssertEqual(store.mode, .map)
        XCTAssertEqual(store.mapStyle, .hybrid); XCTAssertTrue(store.google3DRequested)
        XCTAssertEqual(store.pitch, 55); XCTAssertTrue(store.terrain)
        store.google3DActive = true
        XCTAssertTrue(store.imageryInformation.contains("photorealistic 3D"))
        store.layers.primary = false; XCTAssertFalse(store.google3DRequested)
        store.layers.primary = true; store.setBuildingsLayer(false)
        XCTAssertFalse(store.google3DRequested); XCTAssertFalse(store.google3DActive)
        store.chooseProvider(.apple); store.setBuildingsLayer(true)
        XCTAssertEqual(store.provider, .apple); XCTAssertEqual(store.mapStyle, .streets)
        store.chooseProvider(.openStreetMap)
        XCTAssertEqual(store.provider, .openStreetMap); XCTAssertFalse(store.google3DRequested)
        XCTAssertEqual(store.pitch, 0)
    }
    func testCloudProjectionAndObservationDate() {
        let url = EarthLayerService.cloudURL(bbox: "-180,-90,180,90", mercator: false, width: 1024, height: 512, date: "2026-10-15")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["SRS"], "EPSG:4326"); XCTAssertEqual(query["TIME"], "2026-10-15")
        XCTAssertEqual(query["LAYERS"], "MODIS_Terra_Cloud_Fraction_Day")
        let tile = EarthCloudTiles().url(forTilePath: .init(x: 0, y: 0, z: 0, contentScaleFactor: 1))
        XCTAssertEqual(URLComponents(url: tile, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "SRS" }?.value, "EPSG:3857")
    }
}
