import Foundation

/// Bundled zoom-2 Terrain Tiles DEM: 1024² Web Mercator samples, signed little-endian meters.
/// This is coarse globe relief. Local detail still comes from the selected map provider.
enum EarthTerrain {
    static let size = 1024
    static let heights: [Int16] = {
        guard let url = Bundle.module.url(forResource: "terrain-dem", withExtension: "bin"), let data = try? Data(contentsOf: url), data.count == size * size * 2 else { return [] }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
    }()
    static func sampledElevation(_ point: GeoPoint) -> Double? {
        guard point.isValid, abs(point.latitude) <= 85.05112878, heights.count == size * size else { return nil }
        let latitude = max(-85.05112878, min(85.05112878, point.latitude)) * .pi / 180
        let x = (point.longitude + 180) / 360 * Double(size) - 0.5
        let y = (1 - log(tan(.pi / 4 + latitude / 2)) / .pi) / 2 * Double(size) - 0.5
        let ix = Int(floor(x)), iy = Int(floor(y)), tx = x - floor(x), ty = y - floor(y)
        func sample(_ x: Int, _ y: Int) -> Double { Double(heights[max(0, min(size - 1, y)) * size + (x % size + size) % size]) }
        let a = sample(ix, iy) * (1 - tx) + sample(ix + 1, iy) * tx
        let b = sample(ix, iy + 1) * (1 - tx) + sample(ix + 1, iy + 1) * tx
        return a * (1 - ty) + b * ty
    }
    static func elevation(_ point: GeoPoint) -> Double {
        let clamped = GeoPoint(latitude: max(-85.05112878, min(85.05112878, point.latitude)), longitude: point.longitude)
        guard point.isValid else { return 0 }
        return max(0, sampledElevation(clamped) ?? 0) * max(0, min(1, (90 - abs(point.latitude)) / 5))
    }
}
