import XCTest
@testable import EarthPro

final class SourceFreshnessTests: XCTestCase {
    func testLayerEditDateUsesMillisecondsAndDoesNotSubstituteCaptureDate() {
        let date = SourceFreshnessService.editDate(["editingInfo": ["lastEditDate": 1_700_000_000_000]])
        XCTAssertEqual(date?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(SourceFreshnessService.editDate(["editingInfo": ["lastEditDate": 1_700_000_000_000, "dataLastEditDate": 1_600_000_000_000]])?.timeIntervalSince1970, 1_600_000_000)
        XCTAssertNil(SourceFreshnessService.editDate(["captureDate": 1_700_000_000_000, "modified": 1_700_000_000_000]))
        XCTAssertNil(SourceFreshnessService.milliseconds(0))
        XCTAssertNil(SourceFreshnessService.milliseconds(true))
    }
    func testUnknownProviderDateNeverUsesCheckDate() {
        let fresh = SourceFreshness(checkedAt: Date(), status: "Checked")
        XCTAssertEqual(fresh.updateLabel, "Source updated: Not supplied")
        XCTAssertNotNil(fresh.checkedLabel)
    }
    func testCatalogModifiedIsExplicitlyLabeled() {
        let fresh = SourceFreshness(providerUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), status: "", provenance: "Catalog item modified")
        XCTAssertTrue(fresh.updateLabel.hasPrefix("Catalog item modified:"))
        XCTAssertFalse(fresh.updateLabel.hasPrefix("Source updated:"))
        XCTAssertNil(SourceFreshnessService.itemID(["serviceItemId": "../invalid"]))
        XCTAssertNotNil(SourceFreshnessService.itemID(["serviceItemId": String(repeating: "a", count: 32)]))
    }
    func testMetadataURLPreservesCredentialsQueryAndReplacesFormat() {
        let url = SourceFreshnessService.metadataURL(URL(string: "https://example.org/FeatureServer/0?token=abc&f=json")!)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.filter { $0.name == "f" }.map(\.value), ["pjson"])
        XCTAssertEqual(items.first { $0.name == "token" }?.value, "abc")
    }
}
