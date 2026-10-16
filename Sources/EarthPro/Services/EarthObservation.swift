import Foundation
import MapKit

/// Dates and solar geometry use UTC, independently of the Mac's time zone.
enum EarthObservation {
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    static let earliest = calendar.date(from: DateComponents(year: 2000, month: 2, day: 24))!
    static var latest: Date { calendar.startOfDay(for: Date().addingTimeInterval(-86400)) }
    static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    static func archiveURL(date: Date, bbox: String, mercator: Bool, width: Int = 256, height: Int = 256) -> URL {
        var url = URLComponents(url: EarthLayerService.cloudURL(bbox: bbox, mercator: mercator, width: width, height: height, date: day(date)), resolvingAgainstBaseURL: false)!
        url.queryItems = url.queryItems?.map { $0.name == "LAYERS" ? URLQueryItem(name: "LAYERS", value: "MODIS_Terra_CorrectedReflectance_TrueColor") : $0 }
        return url.url!
    }
    static func elevation(at point: GeoPoint) async throws -> Double {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
        url.queryItems = [URLQueryItem(name: "latitude", value: String(format: "%.4f", point.latitude)), URLQueryItem(name: "longitude", value: String(format: "%.4f", point.longitude))]
        return try decodeElevation(await EarthLayerService.request(url.url!))
    }
    static func hasCoverage(_ data: Data) -> Bool {
        guard let bitmap = NSBitmapImageRep(data: data) else { return false }
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 32)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 64)) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { return true }
            }
        }
        return false
    }
    static func decodeElevation(_ data: Data) throws -> Double {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let meters = (root?["elevation"] as? [Double])?.first, meters.isFinite, (-12_000...10_000).contains(meters) else { throw URLError(.cannotParseResponse) }
        return meters
    }
    static func coordinates(_ point: GeoPoint, dms: Bool) -> String {
        guard dms else { return point.label }
        func angle(_ value: Double, positive: String, negative: String) -> String {
            let hundredths = Int((abs(value) * 360_000).rounded()), degrees = hundredths / 360_000, minutes = hundredths / 6000 % 60
            let seconds = Double(hundredths % 6000) / 100
            return String(format: "%d°%02d′%05.2f″ %@", degrees, minutes, seconds, value < 0 ? negative : positive)
        }
        return angle(point.latitude, positive: "N", negative: "S") + "  " + angle(point.longitude, positive: "E", negative: "W")
    }
    static func eyeAltitude(distance: Double, pitch: Double) -> Double {
        sqrt(pow(GeoMath.radius, 2) + pow(distance, 2) + 2 * GeoMath.radius * distance * cos(pitch * .pi / 180)) - GeoMath.radius
    }
    static func sunPoint(at date: Date) -> GeoPoint {
        let days = date.timeIntervalSince1970 / 86400 - 10957.5
        let mean = (280.46 + 0.9856474 * days) * .pi / 180, anomaly = (357.528 + 0.9856003 * days) * .pi / 180
        let longitude = mean + (1.915 * sin(anomaly) + 0.02 * sin(2 * anomaly)) * .pi / 180
        let obliquity = (23.439 - 0.0000004 * days) * .pi / 180
        let declination = asin(sin(obliquity) * sin(longitude)), rightAscension = atan2(cos(obliquity) * sin(longitude), cos(longitude))
        let sidereal = (280.46061837 + 360.98564736629 * days) * .pi / 180
        return GeoPoint(latitude: declination * 180 / .pi, longitude: GeoMath.normalizedLongitude((rightAscension - sidereal) * 180 / .pi))
    }
}
final class EarthArchiveTiles: MKTileOverlay, @unchecked Sendable {
    let date: Date
    init(date: Date) { self.date = date; super.init(urlTemplate: nil); maximumZ = 9; canReplaceMapContent = false }
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let half = 20037508.342789244, size = 2 * half / pow(2, Double(path.z)), left = -half + Double(path.x) * size, top = half - Double(path.y) * size
        return EarthObservation.archiveURL(date: date, bbox: "\(left),\(top-size),\(left+size),\(top)", mercator: true)
    }
}
