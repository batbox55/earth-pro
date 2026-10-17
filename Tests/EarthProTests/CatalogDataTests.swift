import XCTest
@testable import EarthPro

final class CatalogDataTests: XCTestCase {
    func testBundledCatalogSearchPagesAndProvenanceWithoutConnecting() async throws {
        let result = try await CatalogDataIndex.shared.search(query: "zoning", limit: 12)
        XCTAssertGreaterThan(result.catalogCount, 21_000)
        XCTAssertGreaterThan(result.total, 3_000)
        XCTAssertEqual(result.records.count, 12)
        let next = try await CatalogDataIndex.shared.search(query: "zoning", offset: 12, limit: 12)
        XCTAssertEqual(result.total, next.total)
        XCTAssertTrue(Set(result.records.map(\.id)).isDisjoint(with: next.records.map(\.id)))
        XCTAssertTrue(result.records.allSatisfy { $0.workbook == "Open_Geospatial_Catalog_v4.xlsx" && $0.row >= 2 && $0.workbookSHA256.count == 64 })
        let noMatch = try await CatalogDataIndex.shared.search(query: "xyz_no_catalog_match_934874")
        XCTAssertEqual(noMatch.total, 0)
    }
    func testEveryConnectionIsConcretePublicAndCredentialFree() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "geospatial-layer-catalog", withExtension: "json"))
        let records = try JSONDecoder().decode([CatalogDataSource].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(records.map(\.id)).count, records.count)
        XCTAssertTrue(records.contains { $0.sheet == "Utilities" && $0.connectionFormat == .arcGIS })
        XCTAssertTrue(records.contains { $0.sheet == "Zoning & General Plan" && $0.topic.contains("General") && $0.connectionFormat == .arcGIS })
        for source in records {
            XCTAssertEqual(source.url.scheme, "https")
            XCTAssertNil(source.url.user); XCTAssertNil(source.url.password)
            if let format = source.connectionFormat { XCTAssertNoThrow(try CustomDataService.validateURL(source.url, format: format)) }
            if let service = source.service { XCTAssertTrue(service.itemURL == source.sourceURL); XCTAssertNil(service.modifiedAt) }
            if source.kind == "source" { XCTAssertNil(source.connectionFormat); XCTAssertNil(source.service) }
        }
    }
    @MainActor func testMCPCatalogIsBoundedAndDoesNotEnableDataOrChangeDiscovery() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let store = EarthStore(libraryURL: file)
        store.mcpEnabled = true
        defer { store.mcpEnabled = false }
        let server = EarthMCPServer(store: store)
        let response = await server.rpc(["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"data_discovery","arguments":["action":"catalog","query":"broadband","limit":3]]])
        let content = try XCTUnwrap((response?["result"] as? [String:Any])?["content"] as? [[String:Any]])
        let value = try XCTUnwrap(content.first?["text"] as? String)
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
        XCTAssertEqual((result["sources"] as? [[String:Any]])?.count, 3)
        XCTAssertGreaterThan(result["total"] as? Int ?? 0, 100)
        XCTAssertTrue(store.customDataLayers.isEmpty)
        XCTAssertTrue(store.publicDataEnabled.isEmpty)
        XCTAssertTrue(store.discoveryQuery.isEmpty)
        XCTAssertNil(store.discoveryTask)
    }
}
