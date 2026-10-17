import Foundation

enum CustomDataCategory: String, Codable, CaseIterable, Identifiable {
    case water, sewer, stormwater, electricity, gas, telecommunications, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .water: "Water"
        case .sewer: "Sewer"
        case .stormwater: "Stormwater"
        case .electricity: "Electricity"
        case .gas: "Gas"
        case .telecommunications: "Telecommunications"
        case .other: "Other data"
        }
    }
}

enum CustomDataFormat: String, Codable, CaseIterable {
    case geoJSON, arcGIS
    var title: String { self == .geoJSON ? "GeoJSON" : "ArcGIS feature layer" }
}

struct CustomDataLayer: Codable, Identifiable {
    var id = UUID()
    var name: String
    var folderID: UUID?
    var category: CustomDataCategory = .other
    var format: CustomDataFormat = .geoJSON
    var url: URL?
    var features: [EarthFeature] = []
    var enabled = true
    /// A publisher-provided dataset modification date, never the download date.
    var providerUpdatedAt: Date?
    var checkedAt: Date?
    var fileModifiedAt: Date?
    var partial: Bool?
    var legend: [LayerLegendEntry]?
    var stylingNotice: String?
}

struct CustomDataResult {
    var features: [EarthFeature]
    var providerUpdatedAt: Date?
    var partial: Bool
    var legend: [LayerLegendEntry] = []
    var stylingNotice: String?
}
