import XCTest
@testable import EarthPro

/// Opt-in integration run against the audited live manifest; normal tests stay offline.
final class LiveConnectionTests: XCTestCase {
    struct Case: Decodable {
        let id: String
        let url: URL
        let bounds: PublicDataBounds
    }
    func testLiveBuiltInPublicLayers() async throws {
        guard let path = ProcessInfo.processInfo.environment["EARTH_LIVE_MANIFEST"] else { throw XCTSkip("Set EARTH_LIVE_MANIFEST for live provider checks") }
        let cases = try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        for (kind, prefix) in [(PublicDataKind.parcels,"08-"),(.zoning,"05-zoning-unincorporated-orange-county-ca-silverado"),(.flood,"11-")] {
            let item = try XCTUnwrap(cases.first { $0.id.hasPrefix(prefix) })
            let snapshot = try await PublicDataService.shared.fetch(kind:kind,bounds:item.bounds,distance:1000)
            XCTAssertFalse(snapshot.vectors.isEmpty,kind.rawValue)
            XCTAssertFalse(snapshot.legend.isEmpty,kind.rawValue)
            XCTAssertTrue(snapshot.vectors.contains { $0.vectorStyle?.hasVisibleGeometry == true },kind.rawValue)
        }
    }
    func testLiveSourceGeometryStylesAndLegends() async throws {
        guard let path = ProcessInfo.processInfo.environment["EARTH_LIVE_MANIFEST"] else { throw XCTSkip("Set EARTH_LIVE_MANIFEST for live provider checks") }
        let cases = try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        var reports: [[String:Any]] = []
        for item in cases {
            do {
                let result = try await CustomDataService.shared.load(url:item.url,format:.arcGIS,bounds:item.bounds)
                XCTAssertFalse(result.features.isEmpty,item.id+" returned no geometry")
                XCTAssertTrue(result.features.allSatisfy(\.isValid),item.id+" invalid geometry")
                XCTAssertFalse(result.legend.isEmpty,item.id+" missing legend")
                let visible = result.features.filter { feature in
                    guard let style = feature.vectorStyle else { return false }
                    return feature.kind == .polygon ? style.fillOpacity > 0 || (style.width > 0 && style.strokeOpacity > 0) : feature.kind == .path ? style.width > 0 && style.strokeOpacity > 0 : true
                }
                XCTAssertFalse(visible.isEmpty,item.id+" all geometry invisible")
                for feature in visible {
                    XCTAssertTrue(result.legend.contains { $0.style == feature.vectorStyle },item.id+" feature style absent from legend")
                }
                let data = try JSONEncoder().encode(result.features)
                let destination = URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent(item.id+"-features.json")
                try data.write(to:destination)
                reports.append(["id":item.id,"features":result.features.count,"visible":visible.count,"kinds":Array(Set(result.features.map { $0.kind.rawValue })).sorted(),"legend":result.legend.map { ["label":$0.label,"fill":$0.style.fill,"stroke":$0.style.stroke] },"notice":result.stylingNotice ?? "","partial":result.partial,"provider_updated":result.providerUpdatedAt?.ISO8601Format() ?? "Not supplied"])
            } catch { XCTFail(item.id+": "+error.localizedDescription); reports.append(["id":item.id,"error":error.localizedDescription]) }
        }
        let report = URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("app-live-results.json")
        try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:report)
    }
}
