import Foundation

enum DataLibraryGroup: String, Codable, CaseIterable, Identifiable {
    case localData, imagery, historicalMaps, reference
    var id: String { rawValue }
    var title: String {
        switch self {
        case .localData: "Local data & utilities"
        case .imagery: "Imagery & earth observation"
        case .historicalMaps: "Historical maps"
        case .reference: "Reference sources"
        }
    }
}
enum DataLibraryAdapter: String, Codable { case arcGIS, stac, openAerialMap, socrata, openDataSoft, reference }
struct DataLibrary: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let group: DataLibraryGroup
    let publisher: String
    let scope: String
    let sourceURL: URL
    let endpoint: URL?
    let adapter: DataLibraryAdapter
    let access: String
    let formats: String
    let terms: String
    let verification: String
    let limitation: String
    let workbook: String
    let workbookSHA256: String
    let sheet: String
    let row: Int
    let indexedOn: String
    var canSearch: Bool { adapter != .reference && endpoint != nil }
    var capability: String {
        switch adapter {
        case .stac, .openAerialMap: "Search scenes · add footprints"
        case .arcGIS: "Search datasets · choose layers"
        case .socrata, .openDataSoft: "Search datasets · add bounded vectors"
        case .reference: "Reference link · manual setup"
        }
    }
    static func load() throws -> [Self] {
        guard let url = Bundle.module.url(forResource:"data-libraries",withExtension:"json") else { throw KMLError.invalid("Data libraries are unavailable.") }
        return try JSONDecoder().decode([Self].self,from:Data(contentsOf:url))
    }
}
struct DataLibraryAsset: Codable, Sendable {
    let name: String
    let url: URL
    let mediaType: String?
}
struct DataLibraryResult: Identifiable, Sendable {
    var id = UUID().uuidString
    let libraryID: String
    let sourceID: String
    let name: String
    let sourceURL: URL?
    var connectionURL: URL?
    var connectionFormat: CustomDataFormat?
    var footprint: EarthFeature?
    var captureDate: String?
    var captureEndDate: String?
    var updatedAt: String?
    var cloudCover: Double?
    var collection: String?
    var assets: [DataLibraryAsset] = []
    var geometryField: String?
    var notice = "Coverage and reuse terms require publisher verification."
    var displayKind: String { footprint != nil ? "scene_footprint" : connectionFormat != nil ? "vector_layer" : connectionURL != nil ? "service" : "reference" }
    var canAdd: Bool { footprint != nil || connectionFormat != nil }
}
struct DataLibrarySearchPage: Sendable {
    let results: [DataLibraryResult]
    let hasMore: Bool
}
