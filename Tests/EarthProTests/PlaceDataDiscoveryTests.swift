import XCTest
@testable import EarthPro

final class PlaceDataDiscoveryTests: XCTestCase {
    func testCountyMatchingRequiresStateAndCountryAndNormalizesFullStateName() {
        let portal = PublicDataPortal(id: "sample", name: "County data", county: "Orange County", state: "CA", fips: "06059", url: URL(string: "https://example.com")!, siteType: "Portal", access: "No", workbookRow: nil, discovered: nil)
        XCTAssertTrue(PlaceDataRegion(county: "Orange", state: "California", countryCode: "US").matches(portal))
        XCTAssertFalse(PlaceDataRegion(county: "Orange County", state: "FL", countryCode: "US").matches(portal))
        XCTAssertFalse(PlaceDataRegion(county: "Orange County", state: "CA", countryCode: "CA").matches(portal))
        XCTAssertFalse(PlaceDataRegion(county: "", state: "CA", countryCode: "US").matches(portal))
    }
    func testDiscoveryQueryIsBoundedMetadataOnlyAndWorksOutsideCalifornia() {
        let url = PlaceDataDiscoveryService.searchURL(center: .init(latitude: 40.7, longitude: -74), distance: 500_000)
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(items["num"], "20")
        XCTAssertEqual(items["q"], "type:\"Feature Service\" AND access:public")
        XCTAssertNil(items["returnGeometry"])
        let bbox = items["bbox"]!.split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(bbox.count, 4)
        XCTAssertTrue(bbox[0] < -74 && bbox[2] > -74)
        XCTAssertLessThan(bbox[2] - bbox[0], 3)
    }
    func testLocalizedQuerySanitizesSearchSyntaxAndUsesStateName() {
        let region = PlaceDataRegion(county: "Orange County\" OR owner:evil", state: "CA", countryCode: "US")
        let url = PlaceDataDiscoveryService.searchURL(center: .init(latitude: 33.7, longitude: -117.8), distance: 1000, region: region)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
        XCTAssertTrue(query.contains("california"))
        XCTAssertFalse(query.contains("owner:"))
        XCTAssertEqual(PlaceDataDiscoveryService.safeTerm("A\" OR x:y"), "A OR x y")
    }
    func testTopicSearchConstrainsLocalizedAndFallbackMetadataRequests() {
        let center = GeoPoint(latitude: 40.7, longitude: -74)
        let region = PlaceDataRegion(county: "New York County", state: "NY", countryCode: "US")
        for area in [region, nil] {
            let url = PlaceDataDiscoveryService.searchURL(center: center, distance: 5000, region: area, query: "water\" OR owner:evil")
            let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertNotNil(items["bbox"])
            XCTAssertEqual(items["num"], "20")
            XCTAssertTrue(items["q"]!.contains("AND \"water\" AND \"OR\" AND \"owner\" AND \"evil\""))
            XCTAssertFalse(items["q"]!.contains("owner:"))
            if area != nil { XCTAssertTrue(items["q"]!.contains("new york")) }
        }
    }
    func testCatalogDateAndCredentialFreePublicServiceDecode() throws {
        let json = #"{"results":[{"id":"0123456789abcdef0123456789abcdef","title":"Water networks","owner":"publicworks","access":"public","url":"https://example.com/rest/services/Water/FeatureServer","modified":1700000000000},{"id":"0123456789abcdef0123456789abcdef","title":"Private","access":"private","url":"https://example.com/FeatureServer"},{"id":"0123456789abcdef0123456789abcdef","title":"Token","access":"public","url":"https://example.com/FeatureServer?token=secret"}]}"#
        let decoded = try PlaceDataDiscoveryService.decodeServices(Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].modifiedAt, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(decoded[0].publisher, "publicworks")
    }
    @MainActor func testCameraSchedulesDoNotInterruptManuallyChosenArea() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.showPublicData = true
        store.discoveryFollowsMap = false
        store.discoveryStatus = "Finding area…"
        store.discoveryManualCenter = .init(latitude: 40.7, longitude: -74)
        let generation = store.discoveryGeneration
        store.latitude = 34; store.longitude = -118
        store.scheduleDataDiscovery()
        XCTAssertEqual(store.discoveryGeneration, generation)
        XCTAssertEqual(store.discoveryStatus, "Finding area…")
        XCTAssertNil(store.discoveryTask)
    }
    func testMalformedOrDeniedCatalogDoesNotBecomeEmptySuccess() {
        XCTAssertThrowsError(try PlaceDataDiscoveryService.decodeServices(Data(#"{"error":{"code":499}}"#.utf8)))
    }
    @MainActor func testGlobalViewRequestsLocalAreaInsteadOfUnrelatedWorldwideCandidates() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.showPublicData = true
        store.scheduleDataDiscovery(force: true)
        XCTAssertTrue(store.discoveryStatus.contains("Zoom closer"))
        XCTAssertFalse(store.discoveryLoading)
        XCTAssertTrue(store.discoveredData.isEmpty)
        XCTAssertNil(store.discoveryTask)
    }

}
