import XCTest
@testable import EarthPro

final class FolderTests: XCTestCase {
    @MainActor func testFoldersPersistAndOrganizePlacesAndLayersWithoutDeletingChildren() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let store = EarthStore(libraryURL: url)
        let folder = try store.createFolder(name: "  Fieldwork  ")
        XCTAssertEqual(store.folders.first?.name, "Fieldwork")
        let place = EarthFeature(name: "Seattle", kind: .point, points: [.init(latitude: 47.6, longitude: -122.3)])
        store.save(place)
        let layer = CustomDataLayer(name: "Water lines")
        store.customDataLayers = [layer]
        try store.movePlace(id: place.id, folderID: folder)
        try store.moveCustomLayer(id: layer.id, folderID: folder)
        try await Task.sleep(for: .milliseconds(250))
        let restored = EarthStore(libraryURL: url)
        XCTAssertEqual(restored.features.first?.folderID, folder)
        XCTAssertEqual(restored.customDataLayers.first?.folderID, folder)
        XCTAssertEqual(restored.folders.first?.name, "Fieldwork")
        try restored.renameFolder(id: folder, name: "Utilities")
        XCTAssertEqual(restored.folders.first?.name, "Utilities")
        restored.selectedFolderID = folder
        try restored.removeFolder(id: folder)
        XCTAssertNil(restored.selectedFolderID)
        XCTAssertEqual(restored.features.count, 1)
        XCTAssertEqual(restored.customDataLayers.count, 1)
        XCTAssertNil(restored.features.first?.folderID)
        XCTAssertNil(restored.customDataLayers.first?.folderID)
        XCTAssertTrue(restored.folders.isEmpty)
    }

    @MainActor func testFolderValidationAndCorruptRegistryPreservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let store = EarthStore(libraryURL: url)
        XCTAssertThrowsError(try store.createFolder(name: "  "))
        XCTAssertThrowsError(try store.createFolder(name: String(repeating: "x", count: 101)))
        XCTAssertThrowsError(try store.movePlace(id: UUID(), folderID: UUID()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("preserve me".utf8)
        try corrupt.write(to: store.foldersURL)
        let restored = EarthStore(libraryURL: url)
        XCTAssertFalse(restored.foldersWritable)
        XCTAssertThrowsError(try restored.createFolder(name: "Work"))
        XCTAssertTrue(restored.folders.isEmpty)
        XCTAssertEqual(try Data(contentsOf: restored.foldersURL), corrupt)
    }

    func testExistingFilesDecodeWithoutFolderIDs() throws {
        let place = EarthFeature(name: "Old place", kind: .point, points: [.init(latitude: 0, longitude: 0)])
        let layer = CustomDataLayer(name: "Old layer")
        XCTAssertNil(try JSONDecoder().decode(EarthFeature.self, from: JSONEncoder().encode(place)).folderID)
        XCTAssertNil(try JSONDecoder().decode(CustomDataLayer.self, from: JSONEncoder().encode(layer)).folderID)
    }
}
