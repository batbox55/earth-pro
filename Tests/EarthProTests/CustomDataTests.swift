import XCTest
@testable import EarthPro

final class CustomDataTests: XCTestCase {
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func feature(_ type: String, _ coordinates: Any) -> [String: Any] {
        ["type": "Feature", "properties": ["name": "Utility line", "operator": "City"], "geometry": ["type": type, "coordinates": coordinates]]
    }
    func testGeoJSONPartsPreserveFilledPolygonsAndHoles() throws {
        let outer = [[-118.0,33.0],[-117.0,33.0],[-117.0,34.0],[-118.0,33.0]]
        let hole = [[-117.9,33.1],[-117.8,33.1],[-117.8,33.2],[-117.9,33.1]]
        let records = [
            feature("Point", [-118.0,33.0]), feature("MultiPoint", [[-118.0,33.0],[-117.0,34.0]]),
            feature("LineString", [[-118.0,33.0],[-117.0,34.0]]), feature("MultiLineString", [outer, hole]),
            feature("Polygon", [outer, hole]), feature("MultiPolygon", [[outer, hole], [outer]])
        ]
        let result = try CustomDataService.decodeGeoJSON(data: data(["type": "FeatureCollection", "features": records]))
        XCTAssertEqual(result.features.count, 9)
        XCTAssertEqual(result.features.filter { $0.kind == .point }.count, 3)
        XCTAssertEqual(result.features.filter { $0.kind == .polygon }.count, 3)
        XCTAssertEqual(result.features.filter { $0.kind == .polygon }.first?.holes?.count, 1)
        XCTAssertFalse(result.legend.isEmpty)
        XCTAssertTrue(result.features.allSatisfy(\.isValid))
        XCTAssertTrue(result.features[0].notes.contains("operator: City"))
        XCTAssertNil(result.providerUpdatedAt)
        XCTAssertFalse(result.partial)
    }
    func testBudgetsSkipWholeMultipartFeatureWithoutTruncation() throws {
        let points = (0..<301).map { _ in [-118.0, 33.0] }
        let result = try CustomDataService.decodeGeoJSON(data: data(["type": "FeatureCollection", "features": [feature("MultiPoint", points), feature("Point", [-118.0,33.0])]]))
        XCTAssertEqual(result.features.count, 1)
        XCTAssertTrue(result.partial)
        let long = (0..<16_001).map { _ in [-118.0,33.0] }
        let longResult = try CustomDataService.decodeGeoJSON(data: data(feature("LineString", long)))
        XCTAssertTrue(longResult.features.isEmpty)
        XCTAssertTrue(longResult.partial)
    }
    func testRejectsInvalidCoordinatesRingsAndCRS() throws {
        XCTAssertThrowsError(try CustomDataService.decodeGeoJSON(data: data(feature("Point", [-118.0,91.0]))))
        XCTAssertThrowsError(try CustomDataService.decodeGeoJSON(data: data(feature("Polygon", [[[-118.0,33.0],[-117.0,33.0],[-117.0,34.0],[-118.0,34.0]]]))))
        var value = feature("Point", [-118.0,33.0])
        value["crs"] = ["properties": ["name": "EPSG:3857"]]
        XCTAssertThrowsError(try CustomDataService.decodeGeoJSON(data: data(value)))
        XCTAssertThrowsError(try CustomDataService.decodeGeoJSON(data: Data(repeating: 0, count: CustomDataService.byteLimit + 1)))
    }
    func testArcGISQueryIsViewportBoundedAndURLsExcludeCredentials() throws {
        let url = URL(string: "https://example.com/arcgis/rest/services/Utilities/FeatureServer/2")!
        let bounds = PublicDataBounds(west: -118, south: 33, east: -117, north: 34)
        let query = try CustomDataService.queryURL(url, bounds: bounds)
        XCTAssertTrue(query.path.hasSuffix("/2/query"))
        let parameters = Dictionary(uniqueKeysWithValues: URLComponents(url: query, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value) })
        XCTAssertEqual(parameters["geometry"]!, "-118.0,33.0,-117.0,34.0")
        XCTAssertEqual(parameters["resultRecordCount"]!, "300")
        XCTAssertEqual(parameters["outSR"]!, "4326")
        XCTAssertThrowsError(try CustomDataService.validateURL(URL(string: "http://example.com/data.json")!, format: .geoJSON))
        XCTAssertThrowsError(try CustomDataService.validateURL(URL(string: "https://user:pass@example.com/data.json")!, format: .geoJSON))
        XCTAssertThrowsError(try CustomDataService.validateURL(URL(string: "https://example.com/data.json?token=secret")!, format: .geoJSON))
        XCTAssertNoThrow(try CustomDataService.validateURL(URL(string: "http://localhost:9000/data.json")!, format: .geoJSON))
        XCTAssertThrowsError(try CustomDataService.validateURL(URL(string: "https://example.com/FeatureServer")!, format: .arcGIS))
    }
    func testUpdateDateIsProviderDateAndNeverDownloadTime() throws {
        XCTAssertEqual(CustomDataService.providerUpdateDate(data: try data(["editingInfo": ["lastEditDate": 1_700_000_000_000]])), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(CustomDataService.providerUpdateDate(data: try data(["editingInfo": ["dataLastEditDate": 1_600_000_000_000, "lastEditDate": 1_700_000_000_000]])), Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertNil(CustomDataService.providerUpdateDate(data: try data(["checkedAt": 1_700_000_000_000, "modified": 1_700_000_000_000])))
        let layer = CustomDataLayer(name: "Water", category: .water, url: URL(string: "https://example.com/data.json"), checkedAt: Date(), fileModifiedAt: Date(timeIntervalSince1970: 10))
        let decoded = try JSONDecoder().decode(CustomDataLayer.self, from: JSONEncoder().encode(layer))
        XCTAssertNil(decoded.providerUpdatedAt)
        XCTAssertNotNil(decoded.checkedAt)
        XCTAssertEqual(decoded.fileModifiedAt, layer.fileModifiedAt)
    }
}
