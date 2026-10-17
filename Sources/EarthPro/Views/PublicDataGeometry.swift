import Foundation
import CoreGraphics

/// Outline helpers shared by the native renderers. Rings remain separate, including holes.
enum PublicDataGeometry {
    static func closed(_ ring: [GeoPoint]) -> [GeoPoint] {
        guard ring.count > 1, let first = ring.first, let last = ring.last else { return [] }
        return first == last ? ring : ring + [first]
    }

    static func squaredDistance(_ point: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let x = b.x - a.x, y = b.y - a.y
        let length = x * x + y * y
        let t = length > 0 ? max(0, min(1, ((point.x - a.x) * x + (point.y - a.y) * y) / length)) : 0
        let dx = point.x - (a.x + t * x), dy = point.y - (a.y + t * y)
        return dx * dx + dy * dy
    }
}
