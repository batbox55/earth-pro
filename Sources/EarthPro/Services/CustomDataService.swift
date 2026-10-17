import Foundation

enum CustomDataError: LocalizedError {
    case invalidURL, unsupported, invalidGeometry, tooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Use a public HTTPS URL without credentials or API tokens, or HTTP on localhost. ArcGIS URLs must identify a numbered feature or map layer."
        case .unsupported: "The source must contain a GeoJSON Feature or FeatureCollection in WGS84 coordinates."
        case .invalidGeometry: "The source contains invalid coordinates or an unclosed polygon ring."
        case .tooLarge: "The source exceeds the 4 MB limit. Use a smaller file or a viewport-filtered ArcGIS layer."
        case .unavailable: "The custom source is unavailable or returned an error."
        }
    }
}

/// Geometry work and bounded networking remain separate from map interaction.
actor CustomDataService {
    static let shared = CustomDataService()
    static let byteLimit = 4 * 1_024 * 1_024
    static let featureLimit = 300
    static let vertexLimit = 16_000
    private let session: URLSession
    private var requests = 0

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    static func validateURL(_ url: URL, format: CustomDataFormat) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.scheme?.lowercased() == "https" || (components.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { throw CustomDataError.invalidURL }
        let sensitive = ["key", "apikey", "api_key", "token", "access_token", "authorization", "password", "secret"]
        guard !(components.queryItems ?? []).contains(where: { sensitive.contains($0.name.lowercased()) }) else { throw CustomDataError.invalidURL }
        if format == .arcGIS {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2, let layer = Int(parts.last ?? ""), layer >= 0,
                  ["FeatureServer", "MapServer"].contains(parts[parts.count - 2]) else { throw CustomDataError.invalidURL }
        }
    }

    static func queryURL(_ url: URL, bounds: PublicDataBounds) throws -> URL {
        try validateURL(url, format: .arcGIS)
        guard bounds.isValid else { throw CustomDataError.invalidGeometry }
        var components = URLComponents(url: url.appendingPathComponent("query"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            "f": "geojson", "where": "1=1", "geometry": "\(bounds.west),\(bounds.south),\(bounds.east),\(bounds.north)",
            "geometryType": "esriGeometryEnvelope", "inSR": "4326", "outSR": "4326", "spatialRel": "esriSpatialRelIntersects",
            "outFields": "*", "returnGeometry": "true", "returnZ": "false", "returnM": "false", "resultRecordCount": String(featureLimit),
            "maxAllowableOffset": "0.000005"
        ].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    func load(url: URL, format: CustomDataFormat, bounds: PublicDataBounds) async throws -> CustomDataResult {
        try Self.validateURL(url, format: format)
        let query = format == .arcGIS ? try Self.queryURL(url, bounds: bounds) : url
        let data = try await request(query)
        var result = try Self.decodeGeoJSON(data: data)
        if format == .arcGIS {
            var metadataURL = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            metadataURL.queryItems = [URLQueryItem(name: "f", value: "json")]
            if let metadata = try? await request(metadataURL.url!) {
                result.providerUpdatedAt = Self.providerUpdateDate(data: metadata)
            }
            try Task.checkCancellation()
        }
        return result
    }

    private func request(_ url: URL) async throws -> Data {
        while requests >= 2 { try await Task.sleep(nanoseconds: 30_000_000) }
        try Task.checkCancellation()
        requests += 1
        defer { requests -= 1 }
        var request = URLRequest(url: url)
        request.networkServiceType = .background
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CustomDataError.unavailable }
        guard response.expectedContentLength <= Int64(Self.byteLimit) else { throw CustomDataError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.byteLimit else { throw CustomDataError.tooLarge }
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        return data
    }

    static func providerUpdateDate(data: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return SourceFreshnessService.editDate(object)
    }

    static func decodeGeoJSON(data: Data) throws -> CustomDataResult {
        guard data.count <= byteLimit else { throw CustomDataError.tooLarge }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CustomDataError.unsupported }
        if object["error"] != nil { throw CustomDataError.unavailable }
        try validateCRS(object)
        let records: [[String: Any]]
        switch object["type"] as? String {
        case "FeatureCollection":
            guard let features = object["features"] as? [[String: Any]] else { throw CustomDataError.unsupported }
            records = features
        case "Feature": records = [object]
        default: throw CustomDataError.unsupported
        }
        var result: [EarthFeature] = [], vertices = 0
        var partial = object["exceededTransferLimit"] as? Bool == true
        if let properties = object["properties"] as? [String: Any], properties["exceededTransferLimit"] as? Bool == true { partial = true }
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            try validateCRS(record)
            guard record["type"] as? String == "Feature", let geometry = record["geometry"] as? [String: Any] else { partial = true; continue }
            try validateCRS(geometry)
            let properties = record["properties"] as? [String: Any] ?? [:]
            let name = ["name", "NAME", "title", "Title", "Name"].compactMap { properties[$0] as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Feature \(index + 1)"
            let notes = properties.keys.sorted().prefix(60).compactMap { key -> String? in
                guard let value = properties[key], !(value is NSNull) else { return nil }
                let text: String
                if let scalar = value as? String { text = scalar }
                else if let number = value as? NSNumber { text = number.stringValue }
                else { return nil }
                return "\(String(key.prefix(100))): \(String(text.prefix(500)))"
            }.joined(separator: "\n")
            let parts = try decodeGeometry(geometry)
            let size = parts.reduce(0) { $0 + $1.1.count }
            guard result.count + parts.count <= featureLimit, vertices + size <= vertexLimit else { partial = true; continue }
            vertices += size
            for (part, value) in parts.enumerated() {
                let title = parts.count == 1 ? name : "\(name) · \(part + 1)"
                result.append(EarthFeature(name: String(title.prefix(200)), notes: String(notes.prefix(8_000)), kind: value.0, points: value.1))
            }
        }
        return .init(features: result, providerUpdatedAt: nil, partial: partial)
    }

    private static func validateCRS(_ object: [String: Any]) throws {
        guard let raw = object["crs"], !(raw is NSNull) else { return }
        guard let crs = raw as? [String: Any], let properties = crs["properties"] as? [String: Any], let name = properties["name"] as? String,
              ["urn:ogc:def:crs:OGC:1.3:CRS84", "urn:ogc:def:crs:EPSG::4326", "EPSG:4326", "http://www.opengis.net/def/crs/EPSG/0/4326"].contains(name) else { throw CustomDataError.invalidGeometry }
    }

    private static func decodeGeometry(_ object: [String: Any]) throws -> [(FeatureKind, [GeoPoint])] {
        func point(_ coordinate: [Double]) throws -> GeoPoint {
            guard coordinate.count >= 2 else { throw CustomDataError.invalidGeometry }
            let point = GeoPoint(latitude: coordinate[1], longitude: coordinate[0], altitude: coordinate.count > 2 ? coordinate[2] : 0)
            guard point.isValid else { throw CustomDataError.invalidGeometry }
            return point
        }
        func line(_ coordinates: [[Double]], ring: Bool = false) throws -> [GeoPoint] {
            let points = try coordinates.map(point)
            guard points.count >= (ring ? 4 : 2), !ring || points.first == points.last else { throw CustomDataError.invalidGeometry }
            return points
        }
        guard let type = object["type"] as? String else { throw CustomDataError.unsupported }
        switch type {
        case "Point":
            guard let coordinates = object["coordinates"] as? [Double] else { throw CustomDataError.invalidGeometry }
            return [(.point, [try point(coordinates)])]
        case "MultiPoint":
            guard let coordinates = object["coordinates"] as? [[Double]], !coordinates.isEmpty else { throw CustomDataError.invalidGeometry }
            return try coordinates.map { (.point, [try point($0)]) }
        case "LineString":
            guard let coordinates = object["coordinates"] as? [[Double]] else { throw CustomDataError.invalidGeometry }
            return [(.path, try line(coordinates))]
        case "MultiLineString", "Polygon":
            guard let coordinates = object["coordinates"] as? [[[Double]]], !coordinates.isEmpty else { throw CustomDataError.invalidGeometry }
            return try coordinates.map { (.path, try line($0, ring: type == "Polygon")) }
        case "MultiPolygon":
            guard let coordinates = object["coordinates"] as? [[[[Double]]]], !coordinates.isEmpty, coordinates.allSatisfy({ !$0.isEmpty }) else { throw CustomDataError.invalidGeometry }
            return try coordinates.flatMap { polygon in try polygon.map { (.path, try line($0, ring: true)) } }
        default: throw CustomDataError.unsupported
        }
    }
}
