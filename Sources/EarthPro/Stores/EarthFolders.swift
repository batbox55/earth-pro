import Foundation

@MainActor extension EarthStore {
    var foldersURL: URL { libraryURL.deletingPathExtension().appendingPathExtension("folders.json") }

    func restoreFolders() {
        guard FileManager.default.fileExists(atPath: foldersURL.path) else { return }
        do {
            let data = try Data(contentsOf: foldersURL)
            guard data.count <= 1_024 * 1_024 else { throw KMLError.invalid("Folder file is too large.") }
            let saved = try JSONDecoder().decode([EarthFolder].self, from: data)
            guard saved.count <= 500, Set(saved.map(\.id)).count == saved.count,
                  saved.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 100 }) else {
                throw KMLError.invalid("Invalid folder registry.")
            }
            folders = saved
        } catch {
            foldersWritable = false
            self.error = "Folders could not be restored. The original file is preserved. \(error.localizedDescription)"
        }
    }

    func persistFolders() throws {
        guard foldersWritable else { throw KMLError.invalid("The folder file could not be read and has been preserved.") }
        try FileManager.default.createDirectory(at: foldersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(folders).write(to: foldersURL, options: .atomic)
    }

    @discardableResult func createFolder(name: String) throws -> UUID {
        guard folders.count < 500 else { throw KMLError.invalid("The folder limit is 500.") }
        let name = try validatedFolderName(name)
        let folder = EarthFolder(name: name)
        folders.append(folder)
        do { try persistFolders() } catch { folders.removeAll { $0.id == folder.id }; throw error }
        return folder.id
    }

    func renameFolder(id: UUID, name: String) throws {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { throw KMLError.invalid("Folder not found.") }
        let name = try validatedFolderName(name)
        let previous = folders[index].name
        folders[index].name = name
        do { try persistFolders() } catch { folders[index].name = previous; throw error }
    }

    /// Removing a collection never deletes its places or layer connections.
    func removeFolder(id: UUID) throws {
        guard folders.contains(where: { $0.id == id }) else { throw KMLError.invalid("Folder not found.") }
        guard writable, customDataWritable else { throw KMLError.invalid("A saved data file is unavailable. Its contents have been preserved.") }
        let previous = folders
        folders.removeAll { $0.id == id }
        do { try persistFolders() } catch { folders = previous; throw error }
        for index in features.indices where features[index].folderID == id { features[index].folderID = nil }
        for index in customDataLayers.indices where customDataLayers[index].folderID == id { customDataLayers[index].folderID = nil }
        if selectedFolderID == id { selectedFolderID = nil }
        persist(); saveCustomData()
    }

    func movePlace(id: UUID, folderID: UUID?) throws {
        try validateFolderID(folderID)
        guard writable else { throw KMLError.invalid("Your places file is unavailable and has been preserved.") }
        guard let index = features.firstIndex(where: { $0.id == id }) else { throw KMLError.invalid("Saved place not found.") }
        var feature = features[index]; feature.folderID = folderID
        save(feature)
    }

    func moveCustomLayer(id: UUID, folderID: UUID?) throws {
        try validateFolderID(folderID)
        guard customDataWritable else { throw KMLError.invalid("The custom layer file is unavailable and has been preserved.") }
        guard let index = customDataLayers.firstIndex(where: { $0.id == id }) else { throw KMLError.invalid("Custom layer not found.") }
        customDataLayers[index].folderID = folderID
        saveCustomData()
    }

    func folderName(_ id: UUID?) -> String {
        folders.first(where: { $0.id == id })?.name ?? "Unfiled"
    }

    private func validateFolderID(_ id: UUID?) throws {
        if let id, !folders.contains(where: { $0.id == id }) { throw KMLError.invalid("Folder not found.") }
    }

    private func validatedFolderName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw KMLError.invalid("Enter a folder name of 1–100 characters.") }
        return name
    }
}
