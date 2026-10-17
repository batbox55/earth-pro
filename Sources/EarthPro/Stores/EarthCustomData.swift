import AppKit
import UniformTypeIdentifiers

/// Explicit refresh keeps third-party vector downloads out of the navigation path.
@MainActor extension EarthStore {
    var customDataURL: URL { libraryURL.deletingPathExtension().appendingPathExtension("custom-data.json") }
    var customDataFeatures: [EarthFeature] {
        guard publicDataSupported else { return [] }
        return customDataLayers.filter(\.enabled).flatMap { $0.url == nil ? $0.features : customDataSnapshots[$0.id] ?? [] }
    }
    func restoreCustomData() {
        guard FileManager.default.fileExists(atPath: customDataURL.path) else { return }
        do {
            let data = try Data(contentsOf: customDataURL)
            guard data.count <= 40 * 1_024 * 1_024 else { throw CustomDataError.tooLarge }
            let saved = try JSONDecoder().decode([CustomDataLayer].self, from: data)
            guard saved.count <= 8, Set(saved.map(\.id)).count == saved.count,
                  saved.allSatisfy({ layer in layer.features.count <= 300 && layer.features.allSatisfy(\.isValid) && layer.features.reduce(0, { $0 + $1.points.count }) <= 16_000 }) else { throw CustomDataError.invalidGeometry }
            for layer in saved { if let url = layer.url { try CustomDataService.validateURL(url, format: layer.format) } }
            customDataLayers = saved
            for layer in saved { customDataStatus[layer.id] = layer.url == nil ? "\(layer.features.count) imported geometries" + (layer.partial == true ? " · Partial import; some geometry omitted" : "") : "Saved connection · Refresh this view to load" }
        } catch {
            customDataWritable = false
            self.error = "Custom layers could not be restored. The original file is preserved. \(error.localizedDescription)"
        }
    }
    func saveCustomData() {
        guard customDataWritable else { return }
        customDataSaveTask?.cancel()
        // Live data is a bounded, temporary snapshot, never a silent offline copy.
        let saved = customDataLayers.map { layer -> CustomDataLayer in
            var layer = layer; if layer.url != nil { layer.features = [] }; return layer
        }
        let url = customDataURL
        customDataSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do { try await CustomDataDisk.shared.write(saved, to: url) }
            catch { self.error = "Could not save custom layers: \(error.localizedDescription)" }
        }
    }
    func setCustomDataEnabled(_ id: UUID, enabled: Bool) {
        guard let index = customDataLayers.firstIndex(where: { $0.id == id }) else { return }
        customDataLayers[index].enabled = enabled
        if !enabled { customDataGenerations[id] = UUID(); customDataTasks[id]?.cancel(); customDataLoading.remove(id) }
        saveCustomData()
    }
    func removeCustomData(_ id: UUID) {
        customDataGenerations.removeValue(forKey: id)
        customDataTasks[id]?.cancel(); customDataTasks.removeValue(forKey: id)
        customDataLoading.remove(id); customDataSnapshots.removeValue(forKey: id)
        customDataStatus.removeValue(forKey: id); customDataLayers.removeAll { $0.id == id }
        saveCustomData()
    }
    func addCustomConnection(name: String, category: CustomDataCategory, format: CustomDataFormat, url: URL) throws {
        guard customDataWritable else { throw KMLError.invalid("The custom layer file could not be read. It has been preserved; no changes can be saved.") }
        guard customDataLayers.count < 8 else { throw KMLError.invalid("Eight custom layers are supported at once. Remove a layer before adding another.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KMLError.invalid("Enter a layer name.") }
        try CustomDataService.validateURL(url, format: format)
        let layer = CustomDataLayer(name: String(name.prefix(200)), folderID: selectedFolderID, category: category, format: format, url: url)
        customDataLayers.append(layer); saveCustomData(); refreshCustomData(layer.id)
    }
    func refreshCustomData(_ id: UUID) {
        guard let layer = customDataLayers.first(where: { $0.id == id }), let url = layer.url, layer.enabled else { return }
        guard distance <= 50_000, let bounds = PublicDataBounds.around(center: center, distance: distance * 0.6) else {
            customDataStatus[id] = "Zoom closer than 50 km and refresh this view"; return
        }
        guard !customDataLoading.contains(id) else { return }
        let generation = UUID(); customDataGenerations[id] = generation
        customDataLoading.insert(id); customDataStatus[id] = "Loading this view…"
        customDataTasks[id] = Task(priority: .utility) {
            defer { if customDataGenerations[id] == generation { customDataLoading.remove(id); customDataTasks.removeValue(forKey: id) } }
            do {
                let result = try await CustomDataService.shared.load(url: url, format: layer.format, bounds: bounds)
                guard !Task.isCancelled, customDataGenerations[id] == generation, let index = customDataLayers.firstIndex(where: { $0.id == id && $0.enabled }) else { return }
                let colors: [CustomDataCategory: String] = [.water: "#53B8F6", .sewer: "#E59555", .stormwater: "#55D4C5", .electricity: "#F5C542", .gas: "#FF6B5E", .telecommunications: "#C49BFF"]
                customDataSnapshots[id] = result.features.map { feature in
                    var feature = feature; if let color = colors[layer.category] { feature.color = color }; return feature
                }
                customDataLayers[index].partial = result.partial
                customDataLayers[index].providerUpdatedAt = result.providerUpdatedAt
                customDataLayers[index].checkedAt = Date()
                customDataStatus[id] = "\(result.features.count) geometries · \(result.partial ? "Partial results; zoom closer and refresh" : result.features.isEmpty ? "No data returned for this view" : "Refresh to load another view")"
                saveCustomData()
            } catch is CancellationError { }
            catch { if !Task.isCancelled, customDataGenerations[id] == generation { customDataStatus[id] = "Refresh failed · \(error.localizedDescription)" } }
        }
    }
    func zoomToCustomData(_ layer: CustomDataLayer) {
        let items = layer.url == nil ? layer.features : customDataSnapshots[layer.id] ?? []
        guard let framing = GeoMath.framing(items.flatMap(\.points)) else { return }
        fly(to: framing.center, distance: framing.distance, detail: mode == .map)
    }
    func importCustomData(category: CustomDataCategory = .other) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = ["kml", "kmz", "geojson", "json"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Import a custom vector layer (KML, KMZ or GeoJSON)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importCustomDataFile(url, category: category)
    }
    func importCustomDataFile(_ url: URL, category: CustomDataCategory = .other) {
        guard !customDataImporting else { return }
        guard customDataWritable, customDataLayers.count < 8 else { error = "Remove a custom layer before importing another, or resolve the preserved layer file error."; return }
        customDataImporting = true; customDataImportError = nil; customDataLastImportedID = nil
        let destinationFolder = selectedFolderID
        Task {
            defer { customDataImporting = false }
            do {
                let result = try await Task.detached(priority: .utility) { () throws -> (CustomDataResult, Date?) in
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let result: CustomDataResult
                    if ["kml", "kmz"].contains(url.pathExtension.lowercased()) {
                        let imported = try KMLService.read(url)
                        var count = 0, items: [EarthFeature] = []
                        for feature in imported.features where items.count < 300 {
                            if count + feature.points.count <= 16_000 { items.append(feature); count += feature.points.count }
                        }
                        result = .init(features: items, providerUpdatedAt: nil, partial: imported.skipped > 0 || items.count < imported.features.count)
                    } else {
                        guard (values.fileSize ?? 0) <= CustomDataService.byteLimit else { throw CustomDataError.tooLarge }
                        result = try CustomDataService.decodeGeoJSON(data: Data(contentsOf: url))
                    }
                    return (result, values.contentModificationDate)
                }.value
                guard !result.0.features.isEmpty else { throw KMLError.invalid("No supported geometry fits within the layer limits.") }
                let layer = CustomDataLayer(name: url.deletingPathExtension().lastPathComponent, folderID: folders.contains(where: { $0.id == destinationFolder }) ? destinationFolder : nil, category: category, features: result.0.features, checkedAt: Date(), fileModifiedAt: result.1, partial: result.0.partial)
                customDataLayers.append(layer)
                customDataLastImportedID = layer.id
                customDataStatus[layer.id] = "\(layer.features.count) imported geometries" + (result.0.partial ? " · Partial import; some geometry omitted" : "")
                saveCustomData(); zoomToCustomData(layer)
            } catch { customDataImportError = error.localizedDescription; self.error = "Import failed · \(error.localizedDescription)" }
        }
    }
}

private actor CustomDataDisk {
    static let shared = CustomDataDisk()
    func write(_ layers: [CustomDataLayer], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(layers).write(to: url, options: .atomic)
    }
}
