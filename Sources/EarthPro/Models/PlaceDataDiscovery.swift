import Foundation

struct PlaceDataRegion: Codable, Equatable, Sendable {
    var county: String
    var state: String
    var countryCode: String
    var displayName: String { [county, state, countryCode == "US" ? "" : countryCode].filter { !$0.isEmpty }.joined(separator: ", ") }
    var isOrangeCounty: Bool { countryCode == "US" && Self.normalizeCounty(county) == "orange" && Self.normalizeState(state) == "ca" }
    func matches(_ portal: PublicDataPortal) -> Bool {
        countryCode == "US" && !county.isEmpty && Self.normalizeCounty(county) == Self.normalizeCounty(portal.county) && Self.normalizeState(state) == Self.normalizeState(portal.state)
    }
    static func normalizeCounty(_ name: String) -> String {
        var value = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" county", " parish", " borough", " municipality", " census area"] where value.hasSuffix(suffix) { value = String(value.dropLast(suffix.count)) }
        return value
    }
    static func fullStateName(_ name: String) -> String {
        let code = normalizeState(name)
        return stateNames.first(where: { normalizeState($0) == code }) ?? name
    }
    private static let stateNames = ["alabama", "alaska", "arizona", "arkansas", "california", "colorado", "connecticut", "delaware", "district of columbia", "florida", "georgia", "hawaii", "idaho", "illinois", "indiana", "iowa", "kansas", "kentucky", "louisiana", "maine", "maryland", "massachusetts", "michigan", "minnesota", "mississippi", "missouri", "montana", "nebraska", "nevada", "new hampshire", "new jersey", "new mexico", "new york", "north carolina", "north dakota", "ohio", "oklahoma", "oregon", "pennsylvania", "rhode island", "south carolina", "south dakota", "tennessee", "texas", "utah", "vermont", "virginia", "washington", "west virginia", "wisconsin", "wyoming"]
    static func normalizeState(_ name: String) -> String {
        let value = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let names = stateNames
        let codes = "al ak az ar ca co ct de dc fl ga hi id il in ia ks ky la me md ma mi mn ms mo mt ne nv nh nj nm ny nc nd oh ok or pa ri sc sd tn tx ut vt va wa wv wi wy".split(separator: " ").map(String.init)
        return names.firstIndex(of: value).map { codes[$0] } ?? value
    }
}

struct DiscoveredDataService: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let publisher: String
    let url: URL
    /// ArcGIS catalog item modification, not a guarantee of geometry freshness.
    let modifiedAt: Date?
    var sourceURL: URL? = nil
    var itemURL: URL { sourceURL ?? URL(string: "https://www.arcgis.com/home/item.html?id=" + id)! }
}
struct DiscoveredDataLayer: Identifiable, Sendable {
    let id: Int
    let name: String
    let url: URL
}
