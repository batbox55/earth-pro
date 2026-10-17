import Foundation

enum PublicDataKind: String, Codable, CaseIterable, Identifiable {
    case parcels, zoning, flood
    var id: String { rawValue }
}

struct PublicDataSource: Identifiable {
    var id: String { kind.rawValue }
    let kind: PublicDataKind
    let title: String
    let publisher: String
    let serviceURL: URL
    let sourceURL: URL
    let coverage: String
    let terms: String
    let maxDistance: Double
    let color: String

    static let starters: [Self] = [
        .init(kind: .parcels, title: "Parcel outlines", publisher: "Orange County Public Works", serviceURL: URL(string: "https://ocgis.com/arcpub/rest/services/LegalLotsAttributeOpenData/FeatureServer/0")!, sourceURL: URL(string: "https://data-ocpw.opendata.arcgis.com/")!, coverage: "Orange County, California", terms: "County reference data; not a survey or proof of ownership. Review publisher terms at the source.", maxDistance: 8_000, color: "#F5BD59"),
        .init(kind: .zoning, title: "Unincorporated zoning", publisher: "Orange County Public Works", serviceURL: URL(string: "https://services.arcgis.com/UXmFoWC7yDHcDN5Q/arcgis/rest/services/OCZoning_P/FeatureServer/0")!, sourceURL: URL(string: "https://data-ocpw.opendata.arcgis.com/")!, coverage: "Unincorporated Orange County, California; incorporated cities are excluded", terms: "Planning reference only; verify current zoning with the responsible jurisdiction. Review publisher terms at the source.", maxDistance: 30_000, color: "#B99AFF"),
        .init(kind: .flood, title: "Flood hazard zones", publisher: "FEMA · National Flood Hazard Layer", serviceURL: URL(string: "https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer/28")!, sourceURL: URL(string: "https://www.fema.gov/flood-maps/national-flood-hazard-layer")!, coverage: "United States where FEMA digital flood mapping is available", terms: "FEMA NFHL reference data. Empty or partial results do not establish absence of flood risk; consult the effective FIRM and FEMA guidance.", maxDistance: 50_000, color: "#61C7F4")
    ]
    static func source(_ kind: PublicDataKind) -> Self { starters.first { $0.kind == kind }! }
}

struct PublicDataBounds: Codable, Equatable {
    let west: Double
    let south: Double
    let east: Double
    let north: Double
    var isValid: Bool {
        [west, south, east, north].allSatisfy(\.isFinite) && west >= -180 && east <= 180 && south >= -90 && north <= 90 && west < east && south < north
    }
    func contains(_ other: Self) -> Bool {
        isValid && other.isValid && other.west >= west && other.east <= east && other.south >= south && other.north <= north
    }
    func contains(_ point: GeoPoint) -> Bool {
        point.isValid && point.longitude >= west && point.longitude <= east && point.latitude >= south && point.latitude <= north
    }
    /// A padded local footprint; antimeridian-crossing views pause instead of querying the wrong hemisphere.
    static func around(center: GeoPoint, distance: Double) -> Self? {
        guard center.isValid, distance.isFinite, distance > 0, abs(center.latitude) < 85 else { return nil }
        let latitudeSpan = max(0.0005, distance * 1.4 / 111_320)
        let longitudeSpan = latitudeSpan / max(0.087, cos(center.latitude * .pi / 180))
        let west = center.longitude - longitudeSpan, east = center.longitude + longitudeSpan
        guard west >= -180, east <= 180 else { return nil }
        return .init(west: west, south: max(-85, center.latitude - latitudeSpan), east: east, north: min(85, center.latitude + latitudeSpan))
    }
}

struct PublicDataFeature: Identifiable, Equatable {
    let id: String
    let kind: PublicDataKind
    let rings: [[GeoPoint]]
    let attributes: [String: String]
}

struct PublicDataSnapshot: Equatable {
    let kind: PublicDataKind
    let bounds: PublicDataBounds
    let features: [PublicDataFeature]
    let partial: Bool
    var vectors: [EarthFeature] = []
    var legend: [LayerLegendEntry] = []
    var stylingNotice: String?
    var vertexCount: Int { features.reduce(0) { $0 + $1.rings.reduce(0) { $0 + $1.count } } }
}
