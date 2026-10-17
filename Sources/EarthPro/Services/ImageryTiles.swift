import Foundation
import MapKit
import ImageIO

enum HistoryProduct: String, CaseIterable, Identifiable {
    case modis = "NASA MODIS · 250 m", landsat = "NASA Landsat HLS · 30 m", sentinel = "NASA Sentinel HLS · 30 m", wayback = "Esri Wayback · Aerial"
    var id: String { rawValue }
    var layer: String {
        switch self {
        case .modis: return "MODIS_Terra_CorrectedReflectance_TrueColor"
        case .landsat: return "HLS_L30_Nadir_BRDF_Adjusted_Reflectance"
        case .sentinel: return "HLS_S30_Nadir_BRDF_Adjusted_Reflectance"
        case .wayback: return ""
        }
    }
    var maxZoom: Int { self == .wayback ? 19 : self == .modis ? 9 : 12 }
    var earliest: Date {
        let parts: (Int, Int, Int) = self == .landsat ? (2013, 4, 11) : self == .sentinel ? (2015, 11, 28) : (2000, 2, 24)
        return EarthObservation.calendar.date(from: DateComponents(year: parts.0, month: parts.1, day: parts.2))!
    }
}

struct WaybackRelease: Identifiable, Hashable {
    let id: String
    let date: String
    let template: String
    let metadata: URL
    static func decode(_ data: Data) throws -> [Self] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] ?? [:]
        return root.compactMap { key, row in
            guard let title = row["itemTitle"] as? String, let range = title.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression),
                  let template = row["itemURL"] as? String, let u = URL(string: template.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")), u.scheme == "https", u.host == "wayback.maptiles.arcgis.com",
                  let text = row["metadataLayerUrl"] as? String, let metadata = URL(string: text), metadata.scheme == "https", metadata.host == "metadata.maptiles.arcgis.com" else { return nil }
            return Self(id: key, date: String(title[range]), template: template, metadata: metadata)
        }.sorted { $0.date > $1.date }
    }
}

struct ImageryTile: Hashable {
    let z: Int, x: Int, y: Int
    var parent: Self? { z > 0 ? .init(z: z - 1, x: x / 2, y: y / 2) : nil }
    var west: Double { Double(x) / pow(2, Double(z)) * 360 - 180 }
    var east: Double { Double(x + 1) / pow(2, Double(z)) * 360 - 180 }
    func latitude(_ v: Double) -> Double { atan(sinh(.pi * (1 - 2 * (Double(y) + v) / pow(2, Double(z))))) * 180 / .pi }
    static func at(_ p: GeoPoint, zoom: Int) -> Self {
        let n = pow(2, Double(zoom)), lat = max(-85.05112878, min(85.05112878, p.latitude)) * .pi / 180
        let lon = GeoMath.normalizedLongitude(p.longitude)
        return .init(z: zoom, x: min(Int(n) - 1, max(0, Int(floor((lon + 180) / 360 * n)))), y: min(Int(n) - 1, max(0, Int(floor((1 - asinh(tan(lat)) / .pi) / 2 * n)))))
    }
    static func visible(center: GeoPoint, distance: Double, pitch: Double, width: Double, height: Double, maxZoom: Int) -> [Self] {
        let footprint = max(1, distance * 2 * tan(19 * .pi / 180) * max(1, width / max(1, height)))
        let target = Int(ceil(log2(max(1, 40_075_016 * max(0.05, cos(center.latitude * .pi / 180)) * max(256, width) / (256 * footprint)))))
        var z = max(1, min(maxZoom, target))
        var tiles: Set<Self> = []
        // Sample a bounded footprint, with a larger margin for tilted views.
        let radius = min(85.0, max(0.002, footprint / GeoMath.radius * 180 / .pi * (0.7 + pitch / 80)))
        while true {
            tiles = []
            let top = Self.at(.init(latitude: min(85, center.latitude + radius), longitude: center.longitude), zoom: z)
            let bottom = Self.at(.init(latitude: max(-85, center.latitude - radius), longitude: center.longitude), zoom: z)
            let n = 1 << z, c = Self.at(center, zoom: z)
            let columns = min(n / 2, max(1, Int(ceil(radius / max(0.08, cos(center.latitude * .pi / 180)) / 360 * Double(n)))))
            if (2 * columns + 1) * (bottom.y - top.y + 1) > 96, z > 1 { z -= 1; continue }
            for y in top.y...bottom.y { for dx in -columns...columns { tiles.insert(.init(z: z, x: ((c.x + dx) % n + n) % n, y: y)) } }
            break
        }
        // Parents arrive first and stay resident while children sharpen.
        for tile in Array(tiles) { var p = tile.parent; while let value = p { tiles.insert(value); p = value.parent } }
        return tiles.sorted { $0.z == $1.z ? ($0.y == $1.y ? $0.x < $1.x : $0.y < $1.y) : $0.z < $1.z }
    }
}

struct ImagerySource: Hashable {
    let template: String
    let maxZoom: Int
    let credit: String
    static let current = Self(template: "https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}", maxZoom: 19, credit: "Powered by Esri · Esri, Maxar, Earthstar Geographics and the GIS User Community")
    static func nasa(_ product: HistoryProduct, date: Date) -> Self {
        Self(template: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/\(product.layer)/default/\(EarthObservation.day(date))/GoogleMapsCompatible_Level\(product.maxZoom)/{z}/{y}/{x}.png", maxZoom: product.maxZoom, credit: "NASA GIBS · \(product.rawValue) · \(EarthObservation.day(date)) UTC · Coverage varies")
    }
    static func wayback(_ release: WaybackRelease) -> Self {
        Self(template: release.template.replacingOccurrences(of: "{level}", with: "{z}").replacingOccurrences(of: "{row}", with: "{y}").replacingOccurrences(of: "{col}", with: "{x}"), maxZoom: 19, credit: "Powered by Esri · World Imagery Wayback · Release \(release.date) · Esri and imagery contributors")
    }
    func url(_ t: ImageryTile) -> URL { URL(string: template.replacingOccurrences(of: "{z}", with: String(t.z)).replacingOccurrences(of: "{x}", with: String(t.x)).replacingOccurrences(of: "{y}", with: String(t.y)))! }
}

/// Provider-controlled HTTP caching; no offline download or bulk prefetch.
final class ImageryTransport: @unchecked Sendable {
    static let shared = ImageryTransport()
    let session: URLSession
    init() {
        let c = URLSessionConfiguration.default
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("EarthPro/Imagery", isDirectory: true)
        c.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024, directory: cacheURL)
        c.requestCachePolicy = .useProtocolCachePolicy; c.httpMaximumConnectionsPerHost = 6
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 40
        c.httpAdditionalHeaders = ["User-Agent": "EarthPro/1.0 (macOS; Earth Pro)"]
        session = URLSession(configuration: c)
    }
    func data(_ url: URL) async throws -> Data {
        for attempt in 0...2 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 200 { guard data.count < 16 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }; return data }
            if [429,502,503,504].contains(http.statusCode), attempt < 2 {
                let delay = min(15, max(0.75 * pow(2, Double(attempt)), Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0))
                try await Task.sleep(for: .seconds(delay)); continue
            }
            throw URLError(.badServerResponse)
        }
        throw URLError(.badServerResponse)
    }
    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        // GIBS returns valid, completely transparent PNGs for missing observations.
        // Keep the underlying imagery visible and report these as unavailable coverage.
        if image.alphaInfo != .none && image.alphaInfo != .noneSkipFirst && image.alphaInfo != .noneSkipLast {
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32)); return true
            }
            if drawn && !stride(from: 3, to: pixels.count, by: 4).contains(where: { pixels[$0] > 0 }) { return nil }
        }
        return image
    }
}

final class HistoricalTileOverlay: MKTileOverlay, @unchecked Sendable {
    let source: ImagerySource
    init(source: ImagerySource) { self.source = source; super.init(urlTemplate: source.template); maximumZ = source.maxZoom; canReplaceMapContent = false }
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        Task { do { result(try await ImageryTransport.shared.data(source.url(.init(z: path.z, x: path.x, y: path.y))), nil) } catch { result(nil, error) } }
    }
}
