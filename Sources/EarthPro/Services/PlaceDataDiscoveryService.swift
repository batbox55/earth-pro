import Foundation
import CoreLocation

/// Metadata-only discovery, kept separate from the bounded vector loader.
actor PlaceDataDiscoveryService {
    static let shared = PlaceDataDiscoveryService()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    private var cachedRegion: (point: GeoPoint, value: PlaceDataRegion, checked: Date)?
    func region(at point: GeoPoint) async throws -> PlaceDataRegion? {
        if let cache = cachedRegion, Date().timeIntervalSince(cache.checked) < 60,
           CLLocation(latitude: cache.point.latitude, longitude: cache.point.longitude).distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) < 1_000 {
            return cache.value
        }
        let geocoder = CLGeocoder()
        return try await withTaskCancellationHandler {
            let marks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: point.latitude, longitude: point.longitude))
            guard let mark = marks.first else { return nil }
            let region = PlaceDataRegion(county: mark.subAdministrativeArea ?? mark.locality ?? "", state: mark.administrativeArea ?? "", countryCode: mark.isoCountryCode ?? "")
            cachedRegion = (point, region, Date())
            return region
        } onCancel: { geocoder.cancelGeocode() }
    }
    func point(named name: String) async throws -> GeoPoint? {
        let geocoder = CLGeocoder()
        return try await withTaskCancellationHandler {
            guard let location = try await geocoder.geocodeAddressString(name).first?.location else { return nil }
            return GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        } onCancel: { geocoder.cancelGeocode() }
    }
    static func searchURL(center: GeoPoint, distance: Double, region: PlaceDataRegion? = nil, query topic: String = "") -> URL {
        let radius = min(100_000, max(10_000, distance * 0.5))
        let latitudeSpan = radius / 111_320
        let longitudeSpan = min(180, latitudeSpan / max(0.05, cos(center.latitude * .pi / 180)))
        var components = URLComponents(string: "https://www.arcgis.com/sharing/rest/search")!
        var query = "type:\"Feature Service\" AND access:public"
        if let region {
            let county = Self.safeTerm(PlaceDataRegion.normalizeCounty(region.county))
            let state = Self.safeTerm(region.state)
            let fullState = Self.safeTerm(PlaceDataRegion.fullStateName(region.state))
            if county.count >= 2 {
                query += " AND (\"\(county)\""
                if !state.isEmpty { query += " AND (\"\(state)\" OR \"\(fullState)\")" }
                query += ")"
            }
        }
        for term in Self.safeTerm(topic).split(separator: " ").prefix(8) {
            query += " AND \"\(term)\""
        }
        components.queryItems = [
            .init(name: "f", value: "json"), .init(name: "q", value: query),
            .init(name: "bbox", value: "\(max(-180, center.longitude - longitudeSpan)),\(max(-90, center.latitude - latitudeSpan)),\(min(180, center.longitude + longitudeSpan)),\(min(90, center.latitude + latitudeSpan))"),
            .init(name: "num", value: "20"), .init(name: "sortField", value: "modified"), .init(name: "sortOrder", value: "desc")
        ]
        return components.url!
    }
    static func safeTerm(_ value: String) -> String {
        String(value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) ? String($0) : " " }.joined().prefix(100)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    func discover(center: GeoPoint, distance: Double, region: PlaceDataRegion? = nil, query: String = "") async throws -> (services: [DiscoveredDataService], localized: Bool) {
        if let region, Self.safeTerm(region.county).count >= 2 {
            let local = try Self.decodeServices(await json(at: Self.searchURL(center: center, distance: distance, region: region, query: query)))
            if !local.isEmpty { return (local, true) }
            try Task.checkCancellation()
        }
        return (try Self.decodeServices(await json(at: Self.searchURL(center: center, distance: distance, query: query))), false)
    }
    static func decodeServices(_ data: Data) throws -> [DiscoveredDataService] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard object?["error"] == nil, let rows = object?["results"] as? [[String: Any]] else { throw DiscoveryError.unavailable }
        return rows.prefix(20).compactMap { row in
            guard row["access"] as? String == "public", let id = row["id"] as? String,
                  id.count == 32, id.allSatisfy(\.isHexDigit), let name = row["title"] as? String,
                  let raw = row["url"] as? String, let url = URL(string: raw), url.scheme == "https",
                  url.user == nil, url.password == nil, url.query == nil,
                  url.path.lowercased().hasSuffix("/featureserver") else { return nil }
            let date = (row["modified"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            return .init(id: id, name: String(name.prefix(200)), publisher: row["owner"] as? String ?? "Publisher not supplied", url: url, modifiedAt: date)
        }
    }
    func layers(in service: DiscoveredDataService) async throws -> [DiscoveredDataLayer] {
        var components = URLComponents(url: service.url, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "f", value: "json")]
        let object = try JSONSerialization.jsonObject(with: await json(at: components.url!)) as? [String: Any]
        guard object?["error"] == nil, let layers = object?["layers"] as? [[String: Any]] else { throw DiscoveryError.unavailable }
        return layers.prefix(100).compactMap { row in
            guard let id = row["id"] as? Int, id >= 0, let name = row["name"] as? String else { return nil }
            if let type = row["type"] as? String, type != "Feature Layer" { return nil }
            return .init(id: id, name: String(name.prefix(200)), url: service.url.appendingPathComponent(String(id)))
        }
    }
    private func json(at url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.networkServiceType = .background
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), response.expectedContentLength <= 1_048_576 else { throw DiscoveryError.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw DiscoveryError.unavailable }
            data.append(byte)
        }
        return data
    }
}

enum DiscoveryError: LocalizedError {
    case unavailable, notFound
    var errorDescription: String? { self == .notFound ? "No matching area found. Try a county, state or country." : "Source discovery unavailable. Your saved sources and the county directory are still available." }
}
