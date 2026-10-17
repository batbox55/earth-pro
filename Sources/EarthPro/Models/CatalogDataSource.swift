import Foundation

/// A workbook entry is a candidate, not proof of current access, coverage or reuse rights.
struct CatalogDataSource: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let publisher: String
    let topic: String
    let geography: String
    let url: URL
    let sourceURL: URL
    let kind: String
    let category: CustomDataCategory
    let access: String
    let terms: String
    let verification: String
    let sheet: String
    let row: Int
    let workbook: String
    let workbookSHA256: String
    let indexedOn: String
    let workbookModified: String?

    var connectionFormat: CustomDataFormat? {
        guard access.lowercased().hasPrefix("no"), !access.lowercased().hasPrefix("not ") else { return nil }
        let format: CustomDataFormat
        switch kind {
        case "layer": format = .arcGIS
        case "geoJSON": format = .geoJSON
        default: return nil
        }
        return (try? CustomDataService.validateURL(url, format: format)) != nil ? format : nil
    }
    var service: DiscoveredDataService? {
        guard kind == "service", access.lowercased().hasPrefix("no"), !access.lowercased().hasPrefix("not "),
              url.scheme == "https", url.query == nil, url.user == nil, url.password == nil,
              ["featureserver", "mapserver"].contains(url.lastPathComponent.lowercased()) else { return nil }
        return .init(id: id, name: name, publisher: publisher, url: url, modifiedAt: nil, sourceURL: sourceURL)
    }
}

struct CatalogSearchPage: Sendable {
    let records: [CatalogDataSource]
    let total: Int
    let catalogCount: Int
}

/// Loaded once, only when explicitly opened or queried by MCP. No remote requests or geometry.
actor CatalogDataIndex {
    static let shared = CatalogDataIndex()
    private var entries: [(record: CatalogDataSource, text: String)]?
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func matches(_ source: CatalogDataSource, query: String, region: PlaceDataRegion?) -> Bool {
        let text = normalized("\(source.name) \(source.publisher) \(source.topic) \(source.geography) \(source.sheet)")
        let terms = normalized(query).split(whereSeparator: \.isWhitespace)
        if !terms.isEmpty { return terms.allSatisfy { text.contains($0) } }
        guard let region else { return false }
        let county = normalized(PlaceDataRegion.normalizeCounty(region.county))
        let state = normalized(PlaceDataRegion.fullStateName(region.state))
        // Names are catalog hints only, never a geographic coverage guarantee.
        return (county.count >= 3 && text.contains(county)) || (state.count >= 3 && text.contains(state)) ||
            (!source.geography.isEmpty && source.geography.split(separator: " · ").contains { PlaceDataRegion.normalizeState(String($0)) == PlaceDataRegion.normalizeState(region.state) && !region.state.isEmpty })
    }
    func search(query: String, region: PlaceDataRegion? = nil, offset: Int = 0, limit: Int = 30) throws -> CatalogSearchPage {
        if entries == nil {
            guard let url = Bundle.module.url(forResource: "geospatial-layer-catalog", withExtension: "json") else { throw KMLError.invalid("The bundled source catalog is unavailable.") }
            let data = try Data(contentsOf: url)
            let records = try JSONDecoder().decode([CatalogDataSource].self, from: data)
            entries = records.map { ($0, Self.normalized("\($0.name) \($0.publisher) \($0.topic) \($0.geography) \($0.sheet)")) }
        }
        let terms = Self.normalized(query).split(whereSeparator: \.isWhitespace)
        var total = 0, page: [CatalogDataSource] = []
        let start = max(0, offset), count = max(1, min(100, limit))
        for entry in entries ?? [] {
            try Task.checkCancellation()
            let match = terms.isEmpty ? Self.matches(entry.record, query: "", region: region) : terms.allSatisfy { entry.text.contains($0) }
            guard match else { continue }
            if total >= start && page.count < count { page.append(entry.record) }
            total += 1
        }
        return .init(records: page, total: total, catalogCount: entries?.count ?? 0)
    }
    func source(id: String) throws -> CatalogDataSource? {
        if entries == nil { _ = try search(query: "", limit: 1) }
        return entries?.first { $0.record.id == id }?.record
    }
}
