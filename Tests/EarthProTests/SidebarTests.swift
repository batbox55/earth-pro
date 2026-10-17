import XCTest
@testable import EarthPro

final class SidebarTests: XCTestCase {
    @MainActor func testSwitchingSidebarSectionsPreservesMapAndLibraryChoices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EarthStore(libraryURL: directory.appendingPathComponent("library.json"))
        let folder = try store.createFolder(name: "Survey")
        store.selectedFolderID = folder
        var layers = store.layers
        layers.roads = false
        store.layers = layers
        let center = store.center
        let distance = store.distance
        for section in SidebarSection.allCases {
            store.setSidebarSection(section)
            XCTAssertEqual(store.sidebarSection, section)
            XCTAssertEqual(store.showPublicData, section == .data)
            XCTAssertEqual(store.selectedFolderID, folder)
            XCTAssertFalse(store.layers.roads)
            XCTAssertEqual(store.center.latitude, center.latitude)
            XCTAssertEqual(store.center.longitude, center.longitude)
            XCTAssertEqual(store.distance, distance)
        }
    }

    @MainActor func testFindDataReopensDiscoveryAfterSidebarWasHidden() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let store = EarthStore(libraryURL: url)
        store.openPublicDataBrowser()
        XCTAssertEqual(store.sidebarSection, .data)
        XCTAssertTrue(store.showPublicData)
        store.showPublicData = false
        store.openPublicDataBrowser()
        XCTAssertEqual(store.sidebarSection, .data)
        XCTAssertTrue(store.showPublicData)
        store.setSidebarSection(.layers)
        XCTAssertFalse(store.showPublicData)
    }
}
