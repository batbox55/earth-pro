import Foundation
import AppKit

struct EarthImageOverlay: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var imageData: Data
    var north: Double
    var south: Double
    var east: Double
    var west: Double
    var rotation = 0.0
    var opacity = 0.7
    var isVisible = true
    var span: Double { let width = east - west; return width > 0 ? width : width + 360 }
    var center: GeoPoint { .init(latitude: (north + south) / 2, longitude: GeoMath.normalizedLongitude(west + span / 2)) }
    func point(u: Double, v: Double) -> GeoPoint {
        let latitude = (north + south) / 2, longitude = west + span / 2
        let scale = max(0.01, cos(latitude * .pi / 180)), a = rotation * .pi / 180
        let x = (u - 0.5) * span * scale, y = (v - 0.5) * (north - south)
        return .init(latitude: latitude + x * sin(a) + y * cos(a), longitude: GeoMath.normalizedLongitude(longitude + (x * cos(a) - y * sin(a)) / scale))
    }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !imageData.isEmpty && imageData.count <= 20_000_000 &&
        [north,south,east,west,rotation,opacity].allSatisfy(\.isFinite) && north > south && north <= 85 && south >= -85 &&
        (-180...180).contains(west) && (-180...180).contains(east) && span > 0 && span <= 180 &&
        (-180...180).contains(rotation) && (0...1).contains(opacity) &&
        [(0.0,0.0),(1,0),(0,1),(1,1)].allSatisfy { abs(point(u:$0.0,v:$0.1).latitude) < 90 }
    }
}
