import XCTest
@testable import EarthPro

final class GoogleSessionTests: XCTestCase {
    private final class Reader: @unchecked Sendable {
        let lock = NSLock()
        var interactions: [Bool] = []
        var fails = false
        let gate: DispatchSemaphore?
        init(gate: DispatchSemaphore? = nil) { self.gate = gate }
        func read(_ interaction: Bool) throws -> String? {
            lock.lock(); interactions.append(interaction); let fail = fails; lock.unlock()
            gate?.wait()
            if fail { throw NSError(domain: "TestKeychain", code: -25308) }
            return "test-only-saved-google-key"
        }
    }
    @MainActor private func waitForRead(_ store: EarthStore) async {
        for _ in 0..<200 {
            if !store.googleKeyLoading { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Saved-key read did not finish")
    }
    @MainActor func testSavedKeyAndGoogleSelectionRestoreWithoutInteractionOnEveryLaunch() async {
        let name = "EarthGoogleSessionTests-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name) }
        prefs.set(MapProvider.google.rawValue, forKey: "earthMapProvider")
        let reader = Reader()
        for _ in 0..<2 {
            let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), googleKeyReader: { try reader.read($0) }, googlePreferences: prefs)
            store.restoreGoogleSession(); await waitForRead(store)
            XCTAssertNotNil(store.googleKey); XCTAssertEqual(store.provider, .google)
            XCTAssertEqual(store.mode, .map); XCTAssertFalse(store.googleSettings)
            store.restoreGoogleSession(); XCTAssertFalse(store.googleKeyLoading)
        }
        XCTAssertEqual(reader.interactions, [false, false])
        XCTAssertNil(prefs.string(forKey: "googleKey"))
    }
    @MainActor func testExplicitGoogleSelectionLoadsExistingKeyWithoutReentry() async {
        let reader = Reader()
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), googleKeyReader: { try reader.read($0) })
        store.chooseProvider(.google); await waitForRead(store)
        XCTAssertNotNil(store.googleKey); XCTAssertEqual(store.provider, .google)
        XCTAssertFalse(store.googleSettings); XCTAssertEqual(reader.interactions, [true])
    }
    @MainActor func testBlockedKeychainIsAnAccessErrorAndCanBeRetried() async {
        let reader = Reader(); reader.fails = true
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), googleKeyReader: { try reader.read($0) })
        store.loadGoogleKey(allowInteraction: false); await waitForRead(store)
        XCTAssertNotNil(store.googleKeyAccessError); XCTAssertNil(store.googleKey)
        reader.fails = false
        store.loadGoogleKey(); await waitForRead(store)
        XCTAssertNotNil(store.googleKey); XCTAssertNil(store.googleKeyAccessError)
        XCTAssertEqual(store.provider, .apple); XCTAssertEqual(reader.interactions, [false, true])
    }
    @MainActor func testChoosingFreeMapsCancelsPendingGoogleSelection() async {
        let gate = DispatchSemaphore(value: 0)
        let delayedReader = Reader(gate: gate)
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), googleKeyReader: { try delayedReader.read($0) })
        store.chooseProvider(.google); store.chooseProvider(.apple)
        gate.signal(); await waitForRead(store)
        XCTAssertNotNil(store.googleKey); XCTAssertEqual(store.provider, .apple)
    }
}
