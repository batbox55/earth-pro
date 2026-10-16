import XCTest
@testable import EarthPro

final class AddressPinImporterTests: XCTestCase {
    @MainActor func testPastedLinesPreserveAddressCommasAndSkipDuplicates() {
        XCTAssertEqual(AddressPinImporter.addresses("  1 Main St, Austin, TX \r\n\n1 MAIN ST, Austin, TX\n2 Oak St, Dallas, TX\r\n37.5, -122.4\n"),
                       ["1 Main St, Austin, TX", "2 Oak St, Dallas, TX", "37.5, -122.4"])
        XCTAssertTrue(AddressPinImporter.addresses(" \n\t\r\n").isEmpty)
    }
    @MainActor func testBatchKeepsSuccessfulMatchesAndReportsFailures() async {
        let importer = AddressPinImporter()
        var requests: [String] = [], committed: [EarthFeature] = []
        importer.plot(["First", "Missing", "Last"], color: "#53B8F6", resolve: { address in
            requests.append(address)
            if address == "Missing" { throw KMLError.invalid("No location found") }
            return SearchHit(title: "Resolved \(address)", subtitle: "Provider", point: .init(latitude: 40, longitude: -70))
        }, commit: { committed = $0 })
        await waitUntilStopped(importer)
        XCTAssertEqual(requests, ["First", "Missing", "Last"])
        XCTAssertEqual(importer.plottedCount, 2); XCTAssertEqual(importer.completedCount, 3)
        XCTAssertEqual(importer.failures.map(\.address), ["Missing"])
        XCTAssertEqual(committed.map(\.name), ["Resolved First", "Resolved Last"])
        XCTAssertTrue(committed.allSatisfy { $0.color == "#53B8F6" && $0.kind == .point && $0.isValid })
        XCTAssertTrue(committed[0].notes.contains("First"))
    }
    @MainActor func testStoppingKeepsEarlierMatchesAndDoesNotPlotLateResponse() async {
        let importer = AddressPinImporter()
        var requests: [String] = [], committed: [EarthFeature] = []
        importer.plot(["First", "Second", "Third"], color: "#E234A8", resolve: { address in
            requests.append(address)
            if address == "Second" { importer.stop() }
            return SearchHit(title: address, subtitle: "", point: .init(latitude: 5, longitude: 6))
        }, commit: { committed = $0 })
        await waitUntilStopped(importer)
        XCTAssertEqual(requests, ["First", "Second"])
        XCTAssertEqual(committed.map(\.name), ["First"])
        XCTAssertEqual(importer.plottedCount, 1); XCTAssertEqual(importer.completedCount, 1)
        XCTAssertFalse(importer.rows[1].finished)
    }
    @MainActor func testInvalidLookupDoesNotCreatePinAndOversizeBatchIsRejected() async {
        let importer = AddressPinImporter()
        var didCommit = false
        importer.plot(["Invalid"], color: "#E234A8", resolve: { _ in
            SearchHit(title: "Invalid", subtitle: "", point: .init(latitude: 91, longitude: 0))
        }, commit: { _ in didCommit = true })
        await waitUntilStopped(importer)
        XCTAssertFalse(didCommit); XCTAssertEqual(importer.failures.count, 1)
        let excessive = AddressPinImporter()
        excessive.plot(Array(repeating: "Address", count: AddressPinImporter.limit + 1), color: "#E234A8", resolve: { _ in
            XCTFail("Oversize input must not start lookups"); throw CancellationError()
        }, commit: { _ in XCTFail("Must not commit oversize batch") })
        XCTAssertFalse(excessive.running); XCTAssertTrue(excessive.rows.isEmpty)
    }
    @MainActor func testBatchSaveFitsAcrossDatelineAndUndoesTogether() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = EarthStore(libraryURL: url)
        let existing = EarthFeature(name: "Existing", kind: .point, points: [.init(latitude: 0, longitude: 0)])
        store.save(existing); store.showPlaces = false
        let pins = [179.0, -179.0].map { EarthFeature(name: "Dateline \($0)", kind: .point, points: [.init(latitude: 0, longitude: $0)]) }
        store.addAddressPins(pins)
        XCTAssertEqual(store.features.count, 3); XCTAssertTrue(store.showPlaces)
        XCTAssertEqual(abs(store.longitude), 180, accuracy: 0.001)
        XCTAssertLessThan(store.distance, 1_000_000); XCTAssertEqual(store.pitch, 0)
        XCTAssertEqual(EarthStore(libraryURL: url).features.count, 3)
        store.undo(); XCTAssertEqual(store.features, [existing])
        store.redo(); XCTAssertEqual(store.features.count, 3)
    }
    @MainActor func testCoordinateListLookupAndGoogleResponseRouting() async throws {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let hit = try await store.resolveAddressForPins("37.5, -122.4")
        XCTAssertEqual(hit.point, GeoPoint(latitude: 37.5, longitude: -122.4))
        let id = UUID()
        let resolved: SearchHit = try await withCheckedThrowingContinuation { continuation in
            store.pendingAddressLookup = (id, continuation); store.googleQuery = (id, "Address")
            XCTAssertFalse(store.receiveAddressLookup(id: UUID(), hits: [hit], status: "OK"))
            XCTAssertTrue(store.receiveAddressLookup(id: id, hits: [hit], status: "OK"))
            XCTAssertFalse(store.receiveAddressLookup(id: id, hits: [hit], status: "OK"))
        }
        XCTAssertEqual(resolved.point, hit.point); XCTAssertNil(store.googleQuery); XCTAssertNil(store.pendingAddressLookup)
    }
    @MainActor private func waitUntilStopped(_ importer: AddressPinImporter) async {
        for _ in 0..<300 {
            if !importer.running { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Address import did not finish")
        importer.stop()
    }
}
