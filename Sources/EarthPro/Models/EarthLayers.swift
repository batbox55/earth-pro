import Foundation

struct EarthLayers: Codable, Equatable {
    var primary = true
    var borders = true
    var labels = true
    var places = true
    var photos = false
    var roads = true
    var buildings = false
    var clouds = false
    var earthquakes = false
    var parks = false
    var transit = false
    var traffic = false
    var water = false
    var wikipedia = false
    init() {}
    enum CodingKeys: String, CodingKey { case primary, borders, labels, places, photos, roads, buildings, clouds, earthquakes, parks, transit, traffic, water, wikipedia }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        primary = try values.decodeIfPresent(Bool.self, forKey: .primary) ?? true
        borders = try values.decodeIfPresent(Bool.self, forKey: .borders) ?? true
        labels = try values.decodeIfPresent(Bool.self, forKey: .labels) ?? true
        places = try values.decodeIfPresent(Bool.self, forKey: .places) ?? true
        photos = try values.decodeIfPresent(Bool.self, forKey: .photos) ?? false
        roads = try values.decodeIfPresent(Bool.self, forKey: .roads) ?? true
        buildings = try values.decodeIfPresent(Bool.self, forKey: .buildings) ?? false
        clouds = try values.decodeIfPresent(Bool.self, forKey: .clouds) ?? false
        earthquakes = try values.decodeIfPresent(Bool.self, forKey: .earthquakes) ?? false
        parks = try values.decodeIfPresent(Bool.self, forKey: .parks) ?? false
        transit = try values.decodeIfPresent(Bool.self, forKey: .transit) ?? false
        traffic = try values.decodeIfPresent(Bool.self, forKey: .traffic) ?? false
        water = try values.decodeIfPresent(Bool.self, forKey: .water) ?? false
        wikipedia = try values.decodeIfPresent(Bool.self, forKey: .wikipedia) ?? false
    }
    static let selectionKeys: [WritableKeyPath<EarthLayers, Bool>] = [\.borders, \.labels, \.places, \.photos, \.roads, \.buildings, \.clouds, \.earthquakes, \.parks, \.transit, \.traffic, \.water, \.wikipedia]
    var selectionValues: [Bool] { Self.selectionKeys.map { primary && self[keyPath: $0] } }
    mutating func selectAll(_ value: Bool) {
        primary = value
        for key in Self.selectionKeys { self[keyPath: key] = value }
    }
    var enabled: [String: Bool] {
        ["borders": primary && borders, "labels": primary && labels, "places": primary && places,
         "photos": primary && photos, "roads": primary && roads, "buildings": primary && buildings,
         "clouds": primary && clouds, "earthquakes": primary && earthquakes, "parks": primary && parks,
         "transit": primary && transit, "traffic": primary && traffic, "water": primary && water, "wikipedia": primary && wikipedia]
    }
}
struct EarthCountry {
    let name: String
    let label: GeoPoint
    let rank: Int
    let outlines: [[GeoPoint]]
}
struct EarthCity {
    let name: String
    let point: GeoPoint
    let rank: Int
}
enum EarthBaseData {
    private static func features(_ name: String) -> [[String: Any]] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "geojson"), let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root["features"] as? [[String: Any]] ?? []
    }
    static let countries: [EarthCountry] = features("countries").compactMap { row in
        guard let p = row["properties"] as? [String: Any], let name = p["NAME"] as? String,
              let x = p["LABEL_X"] as? Double, let y = p["LABEL_Y"] as? Double,
              let g = row["geometry"] as? [String: Any] else { return nil }
        let polygons: [[[[Double]]]]
        if let multi = g["coordinates"] as? [[[[Double]]]] { polygons = multi }
        else if let polygon = g["coordinates"] as? [[[Double]]] { polygons = [polygon] }
        else { return nil }
        let outlines = polygons.compactMap(\.first).map { ring in
            ring.compactMap { c -> GeoPoint? in guard c.count >= 2 else { return nil }; let point = GeoPoint(latitude: c[1], longitude: c[0]); return point.isValid ? point : nil }
        }.filter { $0.count > 1 }
        return EarthCountry(name: name, label: .init(latitude: y, longitude: x), rank: p["LABELRANK"] as? Int ?? 6, outlines: outlines)
    }
    static let regions: [[GeoPoint]] = features("regions").flatMap { row -> [[GeoPoint]] in
        guard let g = row["geometry"] as? [String: Any] else { return [] }
        let lines: [[[Double]]]
        if let multi = g["coordinates"] as? [[[Double]]] { lines = multi }
        else if let line = g["coordinates"] as? [[Double]] { lines = [line] }
        else { return [] }
        return lines.map { line in line.compactMap { c -> GeoPoint? in
            guard c.count >= 2 else { return nil }; let point = GeoPoint(latitude: c[1], longitude: c[0]); return point.isValid ? point : nil
        } }.filter { $0.count > 1 }
    }
    static let parkBoundaries = lines("park-boundaries")
    static let parks: [EarthLayerItem] = points("park-places", kind: .park)
    static let airports: [EarthLayerItem] = points("airports", kind: .airport)
    private static func points(_ resource: String, kind: EarthLayerItem.Kind) -> [EarthLayerItem] {
        features(resource).compactMap { row in
            guard let p = row["properties"] as? [String: Any], let name = p["name"] as? String,
                  let g = row["geometry"] as? [String: Any], let c = g["coordinates"] as? [Double], c.count >= 2 else { return nil }
            let point = GeoPoint(latitude: c[1], longitude: c[0]); guard point.isValid else { return nil }
            let id = String(describing: p["id"] ?? name), detail = p["detail"] as? String ?? ""
            let code = p["code"] as? String ?? ""
            return EarthLayerItem(id: kind.rawValue + "-" + id, kind: kind, title: name + (code.isEmpty ? "" : " (" + code + ")"), point: point,
                detail: detail + (kind == .park ? "\nGeneralized U.S. National Park Service unit. Marker position is approximate." : "\nSelected major airports worldwide. Generalized overview; not for navigation."),
                url: URL(string: kind == .park ? "https://www.naturalearthdata.com/downloads/10m-cultural-vectors/parks-and-protected-lands/" : "https://www.naturalearthdata.com/downloads/10m-cultural-vectors/airports/"), credit: "Natural Earth · Public domain")
        }
    }
    static let roads: [[GeoPoint]] = lines("roads")
    static let water: [[GeoPoint]] = lines("water")
    private static func lines(_ name: String) -> [[GeoPoint]] {
        features(name).flatMap { row -> [[GeoPoint]] in
            guard let g = row["geometry"] as? [String: Any] else { return [] }
            let lines: [[[Double]]]
            if let multi = g["coordinates"] as? [[[Double]]] { lines = multi }
            else if let line = g["coordinates"] as? [[Double]] { lines = [line] }
            else { return [] }
            return lines.map { line in line.compactMap { c -> GeoPoint? in
                guard c.count >= 2 else { return nil }
                let point = GeoPoint(latitude: c[1], longitude: c[0]); return point.isValid ? point : nil
            } }.filter { $0.count > 1 }
        }
    }
    static let cities: [EarthCity] = features("cities").compactMap { row in
        guard let p = row["properties"] as? [String: Any], let name = p["name"] as? String,
              let g = row["geometry"] as? [String: Any], let c = g["coordinates"] as? [Double], c.count >= 2 else { return nil }
        return EarthCity(name: name, point: .init(latitude: c[1], longitude: c[0]), rank: p["scalerank"] as? Int ?? 8)
    }
}
struct EarthLayerItem: Identifiable, Equatable {
    enum Kind: String { case photo, earthquake, wikipedia, park, airport }
    let id: String
    let kind: Kind
    let title: String
    let point: GeoPoint
    let detail: String
    let url: URL?
    var imageURL: URL? = nil
    var credit = ""
    var color: String { switch kind { case .photo: "#77C9FF"; case .earthquake: "#FF9050"; case .wikipedia: "#CFB5FF"; case .park: "#74CF8C"; case .airport: "#9AD9EF" } }
    var symbol: String { switch kind { case .photo: "camera.fill"; case .earthquake: "waveform.path"; case .wikipedia: "book.fill"; case .park: "leaf.fill"; case .airport: "airplane" } }
}
