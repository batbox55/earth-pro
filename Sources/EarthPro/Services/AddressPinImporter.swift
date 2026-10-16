import Foundation
import MapKit
import Combine

struct AddressImportRow: Identifiable {
    let id = UUID()
    let address: String
    var match: SearchHit?
    var failure: String?
    var finished = false
}

@MainActor final class AddressPinImporter: ObservableObject {
    @Published private(set) var rows: [AddressImportRow] = []
    @Published private(set) var running = false
    @Published private(set) var plottedCount = 0
    @Published private(set) var jobID: UUID?
    @Published private(set) var plottedIDs: [UUID] = []
    private var task: Task<Void, Never>?
    static let limit = 250
    static func addresses(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            let address = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = address.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            return !key.isEmpty && seen.insert(key).inserted ? address : nil
        }
    }
    var completedCount: Int { rows.filter(\.finished).count }
    var failures: [AddressImportRow] { rows.filter { $0.failure != nil } }
    func plot(_ addresses: [String], color: String,
              resolve: @escaping @MainActor (String) async throws -> SearchHit,
              commit: @escaping @MainActor ([EarthFeature]) -> Void) {
        guard !running, !addresses.isEmpty, addresses.count <= Self.limit else { return }
        rows = addresses.map { AddressImportRow(address: $0) }; plottedCount = 0; plottedIDs = []; jobID = UUID(); running = true
        task = Task { [weak self] in
            guard let self else { return }
            var pins: [EarthFeature] = []
            for index in rows.indices {
                if Task.isCancelled { break }
                do {
                    let hit = try await resolve(rows[index].address)
                    try Task.checkCancellation()
                    guard hit.point.isValid else { throw KMLError.invalid("The provider returned invalid coordinates.") }
                    rows[index].match = hit; rows[index].finished = true
                    pins.append(EarthFeature(name: hit.title, notes: "Address: \(rows[index].address)\n\(hit.subtitle)", kind: .point, points: [hit.point], color: color))
                } catch is CancellationError { break }
                catch {
                    if Task.isCancelled { break }
                    rows[index].failure = error.localizedDescription; rows[index].finished = true
                }
                // Serial, paced lookups avoid a burst of geocoding requests.
                if index < rows.count - 1 {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { break }
                }
            }
            if !pins.isEmpty { commit(pins) }
            plottedIDs = pins.map(\.id); plottedCount = pins.count; running = false; task = nil
        }
    }
    func stop() { task?.cancel() }
    /// The smallest longitude arc avoids fitting dateline-adjacent addresses around the wrong side of Earth.
    static func viewport(_ points: [GeoPoint]) -> (center: GeoPoint, distance: Double)? {
        guard !points.isEmpty, points.allSatisfy(\.isValid) else { return nil }
        let longitudes = points.map { ($0.longitude + 360).truncatingRemainder(dividingBy: 360) }.sorted()
        var largestGap = -1.0, arcStart = longitudes[0]
        for index in longitudes.indices {
            let next = index + 1 < longitudes.count ? longitudes[index + 1] : longitudes[0] + 360
            if next - longitudes[index] > largestGap { largestGap = next - longitudes[index]; arcStart = next }
        }
        let latitude = ((points.map(\.latitude).min() ?? 0) + (points.map(\.latitude).max() ?? 0)) / 2
        let center = GeoPoint(latitude: latitude, longitude: GeoMath.normalizedLongitude(arcStart + (360 - largestGap) / 2))
        let radius = points.map { GeoMath.distance(center, $0) }.max() ?? 0
        return (center, max(750, min(40_000_000, radius * 6)))
    }
}

extension EarthStore {
    func resolveAddressForPins(_ address: String) async throws -> SearchHit {
        try Task.checkCancellation()
        if let point = GeoPoint.parse(address) { return SearchHit(title: address, subtitle: point.label, point: point) }
        if provider == .google {
            guard pendingAddressLookup == nil else { throw KMLError.invalid("Another address lookup is already running.") }
            guard googleKey != nil, googleReady, googleError == nil else { throw KMLError.invalid("Google Maps is not ready. Check the connection or use Apple Maps.") }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let id = UUID()
                    pendingAddressLookup = (id, continuation)
                    googleQuery = (id, address)
                    addressLookupTimeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(25)) } catch { return }
                        self?.finishAddressLookup(id: id, result: .failure(KMLError.invalid("Address lookup timed out. Try this address again.")))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelAddressLookup() }
            }
        }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = address; request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request)
        let response = try await withTaskCancellationHandler { try await search.start() } onCancel: { search.cancel() }
        try Task.checkCancellation()
        guard let item = response.mapItems.first else { throw KMLError.invalid("No location found. Add the city, state, or postal code.") }
        let coordinate = item.placemark.coordinate
        let description = [item.placemark.title, "Apple Maps"].compactMap { $0 }.joined(separator: " · ")
        return SearchHit(title: item.name ?? address, subtitle: description, point: GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
    @discardableResult func receiveAddressLookup(id: UUID, hits: [SearchHit], status: String) -> Bool {
        guard pendingAddressLookup?.id == id else { return false }
        let result: Result<SearchHit, Error>
        if let hit = hits.first { result = .success(hit) }
        else { result = .failure(KMLError.invalid(status == "ZERO_RESULTS" ? "No location found. Add the city, state, or postal code." : "Google lookup failed (\(status)). Check Geocoding API, billing, and quotas.")) }
        finishAddressLookup(id: id, result: result); return true
    }
    func finishAddressLookup(id: UUID, result: Result<SearchHit, Error>) {
        guard let pending = pendingAddressLookup, pending.id == id else { return }
        pendingAddressLookup = nil; addressLookupTimeout?.cancel(); addressLookupTimeout = nil
        if googleQuery?.id == id { googleQuery = nil }
        pending.continuation.resume(with: result)
    }
    func cancelAddressLookup() {
        if let pending = pendingAddressLookup { finishAddressLookup(id: pending.id, result: .failure(CancellationError())) }
    }
}
