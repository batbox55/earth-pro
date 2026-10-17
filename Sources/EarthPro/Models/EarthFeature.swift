import Foundation
import CoreLocation

struct GeoPoint: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var altitude: Double = 0
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var isValid: Bool { latitude.isFinite && longitude.isFinite && altitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 }
    var label: String { String(format: "%.5f° %@  %.5f° %@", abs(latitude), latitude < 0 ? "S" : "N", abs(longitude), longitude < 0 ? "W" : "E") }
    static func parse(_ text: String) -> GeoPoint? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
        guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]) else { return nil }
        let point = GeoPoint(latitude: latitude, longitude: longitude)
        return point.isValid ? point : nil
    }
}

enum FeatureKind: String, Codable, CaseIterable {
    case point, path, polygon
    var icon: String { switch self { case .point: "mappin.circle.fill"; case .path: "point.topleft.down.to.point.bottomright.curvepath"; case .polygon: "pentagon" } }
    var title: String { switch self { case .point: "Placemark"; case .path: "Path"; case .polygon: "Polygon" } }
    var minimumPoints: Int { self == .point ? 1 : self == .path ? 2 : 3 }
}
enum PinShape: String, Codable, CaseIterable {
    case pin, circle, square, diamond
    var title: String { rawValue.capitalized }
}
enum PinIcon: String, Codable, CaseIterable {
    case location, star, home, flag, mountain, camera, food, car
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .location: "mappin"; case .star: "star.fill"; case .home: "house.fill"
        case .flag: "flag.fill"; case .mountain: "mountain.2.fill"; case .camera: "camera.fill"
        case .food: "fork.knife"; case .car: "car.fill"
        }
    }
}
struct EarthFeature: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var notes = ""
    var kind: FeatureKind
    var points: [GeoPoint]
    var color = "#F5C542"
    var isVisible = true
    // Optional fields preserve compatibility with previously saved libraries.
    var folderID: UUID?
    var pinShape: PinShape?
    var pinIcon: PinIcon?
    var holes: [[GeoPoint]]?
    var vectorStyle: VectorStyle?
    var attributes: [String: String]?
    var sourceID: String?
    var vertexCount: Int { points.count + (holes ?? []).reduce(0) { $0 + $1.count } }
    var resolvedPinShape: PinShape { pinShape ?? .pin }
    var resolvedPinIcon: PinIcon { pinIcon ?? .location }
    var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (kind == .point ? points.count == 1 : points.count >= kind.minimumPoints) && points.allSatisfy(\.isValid) && (holes ?? []).allSatisfy { kind == .polygon && $0.count >= 4 && $0.first == $0.last && $0.allSatisfy(\.isValid) } && (vectorStyle?.isValid ?? true) }
    var center: GeoPoint { points.first ?? .init(latitude: 0, longitude: 0) }
    var distance: Double { GeoMath.length(points, closed: kind == .polygon) }
}

enum GeoMath {
    static let radius = 6_371_008.8
    static func framing(_ points: [GeoPoint]) -> (center: GeoPoint, distance: Double)? {
        let points = points.filter(\.isValid)
        guard let first = points.first else { return nil }
        let latitudes = points.map(\.latitude)
        let offsets = points.map { normalizedLongitude($0.longitude - first.longitude) }
        let center = GeoPoint(latitude: ((latitudes.min() ?? 0) + (latitudes.max() ?? 0)) / 2,
                              longitude: normalizedLongitude(first.longitude + ((offsets.min() ?? 0) + (offsets.max() ?? 0)) / 2))
        let radius = points.map { distance(center, $0) }.max() ?? 0
        return (center, max(750, radius * 3.2))
    }

    static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(dp / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2)
        return 2 * radius * asin(sqrt(min(1, max(0, h))))
    }
    static func length(_ points: [GeoPoint], closed: Bool = false) -> Double {
        guard points.count > 1 else { return 0 }
        var length = zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        if closed, let first = points.first, let last = points.last { length += distance(last, first) }
        return length
    }
    static func area(_ points: [GeoPoint]) -> Double {
        guard points.count > 2 else { return 0 }
        var sum = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            var dl = (b.longitude - a.longitude) * .pi / 180
            if dl > .pi { dl -= 2 * .pi }; if dl < -.pi { dl += 2 * .pi }
            sum += dl * (2 + sin(a.latitude * .pi / 180) + sin(b.latitude * .pi / 180))
        }
        let total = 4 * .pi * radius * radius
        let area = abs(sum * radius * radius / 2).truncatingRemainder(dividingBy: total)
        return min(area, total - area)
    }
    static func normalizedLongitude(_ longitude: Double) -> Double {
        let shifted = (longitude + 180).truncatingRemainder(dividingBy: 360)
        return (shifted < 0 ? shifted + 360 : shifted) - 180
    }
}

enum ViewMode: String, CaseIterable { case globe = "Globe", map = "Map" }
enum MapStyle: String, CaseIterable { case satellite = "Satellite", hybrid = "Satellite + labels", streets = "Streets" }
enum EarthTool: String { case navigate, placemark, path, polygon, ruler
    var title: String { switch self {case .navigate: "Explore"; case .placemark: "Add Placemark"; case .path: "Draw Path"; case .polygon: "Draw Polygon"; case .ruler: "Ruler"} }
}
struct SearchHit: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var point: GeoPoint
    var distance: Double = 15_000
}
