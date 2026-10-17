import Foundation
import CoreFoundation

actor SourceFreshnessService {
    static let shared = SourceFreshnessService()
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// Metadata only, requested on demand. Never downloads the underlying feature collection.
    func metadata(url: URL) async throws -> SourceFreshness {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { throw URLError(.unsupportedURL) }
        let checked = Date()
        let path = url.path.lowercased()
        guard path.contains("/featureserver") || path.contains("/mapserver") else {
            return .init(checkedAt: checked, status: "This endpoint does not supply a verified dataset update date.")
        }
        let layer = try await json(at: Self.metadataURL(url))
        if let date = Self.editDate(layer) { return .init(providerUpdatedAt: date, checkedAt: checked, status: "Publisher layer edit timestamp.") }
        var service = layer
        if Self.itemID(service) == nil, Int(url.lastPathComponent) != nil {
            service = try await json(at: Self.metadataURL(url.deletingLastPathComponent()))
            if let date = Self.editDate(service) { return .init(providerUpdatedAt: date, checkedAt: checked, status: "Publisher service edit timestamp.") }
        }
        if let item = Self.itemID(service), let itemURL = URL(string: "https://www.arcgis.com/sharing/rest/content/items/\(item)?f=pjson") {
            let record = try await json(at: itemURL)
            if let date = Self.milliseconds(record["modified"]) {
                return .init(providerUpdatedAt: date, checkedAt: checked, status: "Catalog changes can include metadata or styling; this is not a verified dataset edit or imagery capture date.", provenance: "Catalog item modified")
            }
        }
        return .init(checkedAt: checked, status: "Publisher metadata does not supply an update timestamp.")
    }

    private func json(at url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.networkServiceType = .background
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), response.expectedContentLength <= 1_048_576 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil else { throw URLError(.cannotParseResponse) }
        return json
    }
    static func metadataURL(_ url: URL) -> URL {
        var u = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        u.queryItems = (u.queryItems ?? []).filter { $0.name.lowercased() != "f" } + [URLQueryItem(name: "f", value: "pjson")]
        return u.url!
    }
    static func editDate(_ json: [String: Any]) -> Date? {
        guard let info = json["editingInfo"] as? [String: Any] else { return nil }
        return milliseconds(info["dataLastEditDate"]) ?? milliseconds(info["lastEditDate"])
    }
    static func itemID(_ json: [String: Any]) -> String? {
        guard let id = json["serviceItemId"] as? String, id.count == 32, id.allSatisfy(\.isHexDigit) else { return nil }
        return id
    }
    static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue / 1000
        guard seconds.isFinite, seconds > 0, seconds <= Date().addingTimeInterval(86400).timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
