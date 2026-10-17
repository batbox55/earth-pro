import XCTest
@testable import EarthPro

final class NotesMCPPreferencesTests: XCTestCase {
    func testMCPDefaultsOnAndPersistsExplicitChoice() throws {
        let suite = "EarthProTests.MCP.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(LocalMCPPreference.isEnabled(in: defaults))
        LocalMCPPreference.save(false, in: defaults)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertFalse(LocalMCPPreference.isEnabled(in: reloaded))
        LocalMCPPreference.save(true, in: reloaded)
        XCTAssertTrue(LocalMCPPreference.isEnabled(in: defaults))
    }

    @MainActor func testSearchLocationNotesPersistAndCanBeUpdatedWithoutDuplicatingPin() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("library.json")
        let store = EarthStore(libraryURL: url)
        store.selectSearchHit(SearchHit(title: "Inspection site", subtitle: "", point: .init(latitude: 33.8, longitude: -117.9)))
        var place = try XCTUnwrap(store.selectedFeature)
        place.notes = "Water meter beside the north gate.\nRecheck after inspection."
        store.save(place)
        let reloaded = EarthStore(libraryURL: url)
        XCTAssertEqual(reloaded.features.first?.notes, place.notes)
        XCTAssertEqual(reloaded.features.count, 1)
        place.notes = "Inspection complete."
        reloaded.save(place)
        let updated = EarthStore(libraryURL: url)
        XCTAssertEqual(updated.features.count, 1)
        XCTAssertEqual(updated.features.first?.notes, "Inspection complete.")
        XCTAssertEqual(updated.features.first?.center, place.center)
    }
}
