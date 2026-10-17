import Foundation

@MainActor extension EarthStore {
    /// Opening the source inspector or explicitly refreshing starts metadata work; navigation never does.
    func refreshSourceDates(force: Bool = false) {
        sourceFreshnessTask?.cancel()
        let publicSources = PublicDataSource.starters.map { ($0.id, $0.serviceURL) }
        let customSources = customDataLayers.compactMap { layer -> (String, URL)? in
            guard layer.format == .arcGIS, let url = layer.url else { return nil }
            return (layer.id.uuidString, url)
        }
        let pending = (publicSources + customSources).filter { entry in
            force || sourceFreshness[entry.0]?.checkedAt.map { Date().timeIntervalSince($0) > 600 } != false
        }
        sourceFreshnessTask = Task {
            for (id, url) in pending {
                guard !Task.isCancelled else { return }
                do {
                    let result = try await SourceFreshnessService.shared.metadata(url: url)
                    guard !Task.isCancelled else { return }
                    sourceFreshness[id] = result
                } catch {
                    guard !Task.isCancelled else { return }
                    var result = sourceFreshness[id] ?? .init(status: "")
                    result.checkedAt = Date()
                    result.status = "Metadata check unavailable. Any displayed provider date is from the previous successful check."
                    sourceFreshness[id] = result
                }
            }
        }
    }
}
