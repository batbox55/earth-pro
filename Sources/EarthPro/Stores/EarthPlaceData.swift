import Foundation
import CoreLocation

@MainActor extension EarthStore {
    func scheduleDataDiscovery(force: Bool = false) {
        guard showPublicData, force || discoveryFollowsMap else { return }
        if discoveryFollowsMap && distance > 250_000 {
            let message = "Zoom closer to a town or choose an area above to find local sources."
            if discoveryStatus == message, !discoveryLoading, discoveredData.isEmpty { return }
            discoveryTask?.cancel(); discoveryTask = nil; discoveryGeneration = UUID()
            discoveryLoading = false; placeDataRegion = nil; discoveredData = []
            placeDataArea = "Current map view"; discoveryStatus = message
            discoveryLastCenter = nil; discoveryLastLookup = .distantPast
            return
        }
        let point = discoveryFollowsMap ? center : (discoveryManualCenter ?? center)
        let moved = discoveryLastCenter.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) > 5_000
        } ?? true
        guard force || moved || Date().timeIntervalSince(discoveryLastLookup) > 30 else { return }
        discoveryTask?.cancel(); discoveryGeneration = UUID()
        let generation = discoveryGeneration, scale = distance, topic = discoveryQuery
        discoveryLoading = true; placeDataRegion = nil; discoveredData = []
        placeDataArea = discoveryFollowsMap ? "Current map view · Finding area…" : "Chosen area · Finding sources…"
        discoveryTask = Task(priority: .utility) {
            do {
                try await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled, generation == discoveryGeneration else { return }
                discoveryLoading = true; discoveryStatus = "Finding public sources for this area…"
                discoveryLastLookup = Date(); discoveryLastCenter = point
                // County lookup failure must not hide worldwide service discovery.
                let region = try? await PlaceDataDiscoveryService.shared.region(at: point)
                guard !Task.isCancelled, generation == discoveryGeneration else { return }
                placeDataRegion = region
                placeDataArea = region?.displayName.isEmpty == false ? region!.displayName : point.label
                let result = try await PlaceDataDiscoveryService.shared.discover(center: point, distance: scale, region: region, query: topic)
                guard !Task.isCancelled, generation == discoveryGeneration else { return }
                discoveredData = result.services
                discoveryStatus = result.services.isEmpty
                    ? "No public service candidates found for this area\(topic.isEmpty ? "" : " and topic"). Try another topic, clear the topic, or browse county portals below."
                    : "\(result.services.count) \(result.localized ? "area-named" : "overlapping extent") service candidates · Verify publisher coverage and terms; catalog extents may be broad."
                discoveryLoading = false
            } catch {
                guard !Task.isCancelled, generation == discoveryGeneration else { return }
                discoveredData = []; discoveryLoading = false; discoveryStatus = error.localizedDescription
            }
        }
    }
    func resumeMapDataDiscovery() {
        discoveryFollowsMap = true; discoveryManualCenter = nil
        scheduleDataDiscovery(force: true)
    }
    func setDataDiscoveryArea(_ name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        discoveryTask?.cancel(); discoveryGeneration = UUID()
        let generation = discoveryGeneration
        // Freeze camera-driven discovery before awaiting geocoding.
        discoveryFollowsMap = false; discoveryManualCenter = center
        placeDataRegion = nil; discoveredData = []; placeDataArea = name
        discoveryLoading = true; discoveryStatus = "Finding area…"
        do {
            guard let point = try await PlaceDataDiscoveryService.shared.point(named: name) else { throw DiscoveryError.notFound }
            guard generation == discoveryGeneration else { return }
            discoveryFollowsMap = false; discoveryManualCenter = point; placeDataArea = name
            discoveryLoading = false; scheduleDataDiscovery(force: true)
        } catch {
            guard generation == discoveryGeneration else { return }
            discoveryLoading = false; discoveryStatus = error.localizedDescription
        }
    }
}
