import SwiftUI

struct PublicDataPortal: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let county: String
    let state: String
    let fips: String
    let url: URL
    let siteType: String
    let access: String
    let workbookRow: Int?
    let discovered: String?
}

struct PublicDataSettings: Codable {
    var enabled: [PublicDataKind]
    var hidden: [PublicDataKind]
    var opacity: [String: Double]
}

@MainActor extension EarthStore {
    var publicDataSupported: Bool { !streetView && !google3DRequested }
    var publicDataFeatures: [PublicDataFeature] {
        guard publicDataSupported else { return [] }
        return PublicDataKind.allCases.flatMap { kind -> [PublicDataFeature] in
            guard publicDataEnabled.contains(kind), !publicDataHidden.contains(kind), (publicDataOpacity[kind] ?? 0.7) > 0,
                  distance <= PublicDataSource.source(kind).maxDistance,
                  let snapshot = publicDataSnapshots[kind], snapshot.bounds.contains(center) else { return [] }
            return snapshot.features
        }
    }
    var publicDataVectors: [(PublicDataKind, EarthFeature)] {
        guard publicDataSupported else { return [] }
        return PublicDataKind.allCases.flatMap { kind -> [(PublicDataKind, EarthFeature)] in
            guard publicDataEnabled.contains(kind), !publicDataHidden.contains(kind),
                  distance <= PublicDataSource.source(kind).maxDistance,
                  let snapshot = publicDataSnapshots[kind], snapshot.bounds.contains(center) else { return [] }
            let opacity = publicDataOpacity[kind] ?? 0.7
            guard opacity > 0 else { return [] }
            return snapshot.vectors.map { feature in
                var feature = feature
                if var style = feature.vectorStyle { style.fillOpacity *= opacity; style.strokeOpacity *= opacity; feature.vectorStyle = style }
                return (kind,feature)
            }
        }
    }
    var publicDataSettingsURL: URL { libraryURL.deletingPathExtension().appendingPathExtension("public-data.json") }
    func restorePublicDataSettings() {
        guard let data = try? Data(contentsOf: publicDataSettingsURL), let settings = try? JSONDecoder().decode(PublicDataSettings.self, from: data) else { return }
        publicDataEnabled = Set(settings.enabled); publicDataHidden = Set(settings.hidden)
        publicDataOpacity = Dictionary(uniqueKeysWithValues: settings.opacity.compactMap { key, value in
            guard let kind = PublicDataKind(rawValue: key), value.isFinite else { return nil }
            return (kind, min(1, max(0, value)))
        })
        for kind in publicDataEnabled { publicDataStatus[kind] = "Paused · Move closer or Retry to load this view" }
    }
    func savePublicDataSettings() {
        publicDataSaveTask?.cancel()
        let settings = PublicDataSettings(enabled: Array(publicDataEnabled), hidden: Array(publicDataHidden), opacity: Dictionary(uniqueKeysWithValues: publicDataOpacity.map { ($0.key.rawValue, $0.value) }))
        let url = publicDataSettingsURL
        publicDataSaveTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(settings) else { return }
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }
    func openPublicDataBrowser() { setSidebarSection(.data) }
    func usePublicDataMap() {
        streetView = false
        if provider == .google { var flags = layers; flags.buildings = false; layers = flags }
        mode = .map; pitch = 0; cameraRequest = UUID()
        refreshPublicData()
    }
    func setPublicData(_ kind: PublicDataKind, enabled: Bool) {
        if enabled { publicDataEnabled.insert(kind); publicDataHidden.remove(kind) }
        else {
            publicDataEnabled.remove(kind); publicDataHidden.remove(kind)
            publicDataSnapshots.removeValue(forKey: kind)
            if publicDataSelection?.kind == kind { publicDataSelection = nil; publicDataDetailTask?.cancel() }
        }
        publicDataRevision = UUID(); savePublicDataSettings(); refreshPublicData()
    }
    func setPublicDataVisible(_ kind: PublicDataKind, visible: Bool) {
        if visible { publicDataHidden.remove(kind) } else { publicDataHidden.insert(kind); publicDataSnapshots.removeValue(forKey: kind) }
        publicDataRevision = UUID(); savePublicDataSettings(); refreshPublicData()
    }
    func setPublicDataOpacity(_ kind: PublicDataKind, opacity: Double) {
        guard opacity.isFinite else { return }
        publicDataOpacity[kind] = min(1, max(0, opacity)); publicDataRevision = UUID(); savePublicDataSettings()
    }
    func zoomToPublicData(_ kind: PublicDataKind) {
        if kind != .flood && !publicDataInOrangeCounty {
            fly(to: .init(latitude: kind == .zoning ? 33.7814 : 33.8762, longitude: kind == .zoning ? -117.7733 : -117.8981), distance: kind == .zoning ? 3_000 : 750, detail: mode == .map)
        } else { distance = min(distance, kind == .parcels ? 750 : 3_000); cameraRequest = UUID() }
        refreshPublicData()
    }
    var publicDataInOrangeCounty: Bool { (33.35...33.96).contains(latitude) && (-118.2 ... -117.4).contains(longitude) }
    func updatePublicDataVisibility() {
        let key = PublicDataKind.allCases.filter { kind in
            publicDataSupported && publicDataEnabled.contains(kind) && !publicDataHidden.contains(kind) && (publicDataOpacity[kind] ?? 0.7) > 0 && distance <= PublicDataSource.source(kind).maxDistance && publicDataSnapshots[kind]?.bounds.contains(center) == true
        }.map(\.rawValue).joined(separator: "|")
        if key != publicDataVisibilityKey { publicDataVisibilityKey = key; publicDataRevision = UUID() }
    }
    func refreshPublicData(force: Bool = false) {
        publicDataTask?.cancel(); publicDataTask = nil
        publicDataGeneration = UUID(); let generation = publicDataGeneration
        publicDataLoading = []
        // Camera-only changes retain existing geometry. Rebuild only when its visibility changes.
        defer { updatePublicDataVisibility() }
        guard !publicDataEnabled.isEmpty else { return }
        let aspect = max(1, publicDataViewSize.width / max(1, publicDataViewSize.height))
        let center = center, distance = distance
        guard let bounds = PublicDataBounds.around(center: center, distance: distance * 0.25 * aspect * (1 + pitch / 80)) else {
            for kind in publicDataEnabled { publicDataStatus[kind] = "Move away from the date line/pole or zoom closer" }
            publicDataSnapshots = [:]; return
        }
        var requested: [PublicDataKind] = []
        for kind in publicDataEnabled {
            if publicDataHidden.contains(kind) { publicDataStatus[kind] = "Hidden"; continue }
            if !publicDataSupported { publicDataStatus[kind] = "Switch to Map to show this layer"; continue }
            if kind != .flood && !publicDataInOrangeCounty {
                publicDataStatus[kind] = "Outside starter area · Orange County, California"; publicDataSnapshots.removeValue(forKey: kind); continue
            }
            if distance > PublicDataSource.source(kind).maxDistance {
                publicDataStatus[kind] = "Zoom closer to show \(kind == .parcels ? "parcels" : "this layer")"; publicDataSnapshots.removeValue(forKey: kind); continue
            }
            if !force, let cached = publicDataSnapshots[kind], distance >= (publicDataFetchScale[kind] ?? distance) * 0.8, cached.bounds.contains(bounds) { continue }
            if let old = publicDataSnapshots[kind], !old.bounds.contains(center) { publicDataSnapshots.removeValue(forKey: kind) }
            publicDataStatus[kind] = "Waiting for the view to settle…"
            requested.append(kind)
        }
        guard !requested.isEmpty else { return }
        let injected = publicDataFetch
        publicDataTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self, !Task.isCancelled, self.publicDataGeneration == generation else { return }
            for kind in requested {
                guard !Task.isCancelled else { return }
                self.publicDataLoading.insert(kind); self.publicDataStatus[kind] = "Loading visible area…"
                do {
                    // Pad the request to retain an inexpensive in-memory result across small pans.
                    let requestBounds = PublicDataBounds.around(center: center, distance: distance * 0.25 * aspect * (1 + self.pitch / 80) * 1.25) ?? bounds
                    let result: PublicDataSnapshot
                    if let injected { result = try await injected(kind, requestBounds, distance) }
                    else { result = try await PublicDataService.shared.fetch(kind: kind, bounds: requestBounds, distance: distance) }
                    guard !Task.isCancelled, self.publicDataGeneration == generation, self.publicDataEnabled.contains(kind), !self.publicDataHidden.contains(kind) else { return }
                    self.publicDataSnapshots[kind] = result
                    self.publicDataFetchScale[kind] = distance
                    self.publicDataStatus[kind] = result.partial ? "Partial results — zoom closer (\(result.features.count) features)" : result.features.isEmpty ? "No features returned in this view · Check source coverage" : "\(result.features.count) features · Visible area"
                    self.publicDataRevision = UUID()
                } catch {
                    guard !Task.isCancelled, self.publicDataGeneration == generation else { return }
                    if case PublicDataError.responseTooLarge = error { self.publicDataStatus[kind] = "Too much data in this view · Zoom closer and Retry" }
                    else { self.publicDataStatus[kind] = "Source unavailable · Retry or open source" }
                }
                self.publicDataLoading.remove(kind)
            }
        }
    }
    func showPublicDataDetails(_ feature: PublicDataFeature) {
        publicDataDetailTask?.cancel(); publicDataSelection = feature
        publicDataAttributes = feature.attributes; publicDataDetailLoading = true
        publicDataDetailTask = Task(priority: .utility) { [weak self] in
            do {
                let details = try await PublicDataService.shared.details(kind: feature.kind, id: feature.id)
                guard !Task.isCancelled, let self, self.publicDataSelection?.id == feature.id, self.publicDataSelection?.kind == feature.kind else { return }
                self.publicDataAttributes = details; self.publicDataDetailLoading = false
            } catch {
                guard !Task.isCancelled, let self, self.publicDataSelection?.id == feature.id, self.publicDataSelection?.kind == feature.kind else { return }
                self.publicDataAttributes["Source status"] = "Details unavailable · Retry or open source"
                self.publicDataDetailLoading = false
            }
        }
    }
    func loadPublicDataCatalog() async {
        guard publicDataCounties.isEmpty else { return }
        let rows = await Task.detached(priority: .utility) {
            guard let url = Bundle.module.url(forResource: "public-data-catalog", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [PublicDataPortal]() }
            return (try? JSONDecoder().decode([PublicDataPortal].self, from: data)) ?? []
        }.value
        publicDataCounties = rows
    }
}
