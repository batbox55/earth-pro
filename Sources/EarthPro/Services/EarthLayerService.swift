import Foundation
import MapKit

/// Public sources remain opt-in; no Google credential is used for these requests.
enum EarthLayerService {
    static func request(_ url: URL, timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = timeout
        request.setValue("EarthPro/1.0 (macOS; Earth Pro)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
    static func earthquakes() async throws -> [EarthLayerItem] {
        try decodeEarthquakes(await request(URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_week.geojson")!))
    }
    static func decodeEarthquakes(_ data: Data) throws -> [EarthLayerItem] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = root?["features"] as? [[String: Any]] ?? []
        return rows.compactMap { row -> (Double, EarthLayerItem)? in
            guard let id = row["id"] as? String, let p = row["properties"] as? [String: Any], let title = p["title"] as? String,
                  let mag = p["mag"] as? Double, mag.isFinite, let g = row["geometry"] as? [String: Any],
                  let c = g["coordinates"] as? [Double], c.count >= 2 else { return nil }
            let point = GeoPoint(latitude: c[1], longitude: c[0]); guard point.isValid else { return nil }
            let date = (p["time"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) } ?? ""
            let detail = "Magnitude \(mag) · \(date)" + (c.count > 2 ? String(format: "\nDepth %.1f km", c[2]) : "")
            return (mag, EarthLayerItem(id: "usgs-" + id, kind: .earthquake, title: title, point: point, detail: detail, url: sourceURL(p["url"] as? String, host: "earthquake.usgs.gov"), credit: "USGS · M2.5+ · Past 7 days"))
        }.sorted { $0.0 > $1.0 }.prefix(200).map(\.1)
    }
    static func photos(near point: GeoPoint) async throws -> [EarthLayerItem] {
        var url = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        url.queryItems = ["action":"query", "format":"json", "generator":"geosearch", "ggscoord":"\(point.latitude)|\(point.longitude)",
                          "ggsradius":"10000", "ggslimit":"40", "ggsnamespace":"6", "prop":"coordinates|imageinfo", "colimit":"max", "iiprop":"url|extmetadata", "iiurlwidth":"640"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return try decodePhotos(await request(url.url!))
    }
    static func decodePhotos(_ data: Data) throws -> [EarthLayerItem] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if root?["error"] != nil { throw URLError(.cannotParseResponse) }
        let query = root?["query"] as? [String: Any], pages = query?["pages"] as? [String: [String: Any]] ?? [:]
        return pages.values.compactMap { row in
            guard let id = row["pageid"] as? Int, let title = row["title"] as? String,
                  let c = (row["coordinates"] as? [[String: Any]])?.first, let lat = c["lat"] as? Double, let lon = c["lon"] as? Double,
                  let info = (row["imageinfo"] as? [[String: Any]])?.first,
                  let source = sourceURL(info["descriptionurl"] as? String, host: "commons.wikimedia.org") else { return nil }
            let point = GeoPoint(latitude: lat, longitude: lon); guard point.isValid else { return nil }
            let meta = info["extmetadata"] as? [String: [String: Any]] ?? [:]
            let artist = plain(meta["Artist"]?["value"] as? String ?? "See source for photographer"), license = plain(meta["LicenseShortName"]?["value"] as? String ?? "See source for license")
            return EarthLayerItem(id: "commons-\(id)", kind: .photo, title: title.replacingOccurrences(of: "File:", with: ""), point: point,
                                  detail: "Wikimedia Commons · Within 10 km of the view center", url: source,
                                  imageURL: sourceURL(info["thumburl"] as? String, host: "upload.wikimedia.org"), credit: "\(artist) · \(license)")
        }.sorted { $0.id < $1.id }
    }
    static func wikipedia(near point: GeoPoint) async throws -> [EarthLayerItem] {
        var url = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        url.queryItems = ["action":"query", "format":"json", "generator":"geosearch", "ggscoord":"\(point.latitude)|\(point.longitude)",
                          "ggsradius":"10000", "ggslimit":"20", "ggsnamespace":"0", "prop":"coordinates|extracts|info", "colimit":"max",
                          "exintro":"1", "explaintext":"1", "exlimit":"max", "exchars":"700", "inprop":"url"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return try decodeWikipedia(await request(url.url!))
    }
    static func decodeWikipedia(_ data: Data) throws -> [EarthLayerItem] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if root?["error"] != nil { throw URLError(.cannotParseResponse) }
        let query = root?["query"] as? [String: Any], pages = query?["pages"] as? [String: [String: Any]] ?? [:]
        return pages.values.compactMap { row in
            guard let id = row["pageid"] as? Int, let title = row["title"] as? String,
                  let c = (row["coordinates"] as? [[String: Any]])?.first,
                  let lat = c["lat"] as? Double, let lon = c["lon"] as? Double,
                  let source = sourceURL(row["fullurl"] as? String, host: "en.wikipedia.org") else { return nil }
            let point = GeoPoint(latitude: lat, longitude: lon); guard point.isValid else { return nil }
            return EarthLayerItem(id: "wikipedia-\(id)", kind: .wikipedia, title: title, point: point,
                detail: String((row["extract"] as? String ?? "Read the article at the original source.").prefix(1200)), url: source,
                credit: "Wikipedia contributors · CC BY-SA 4.0 · Within 10 km of view center")
        }.sorted { $0.id < $1.id }
    }
    private static func plain(_ text: String) -> String {
        String(text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&amp;", with: "&").prefix(400))
    }
    private static func sourceURL(_ text: String?, host: String) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host == host else { return nil }; return url
    }
    static var cloudDate: String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date().addingTimeInterval(-86400))
    }
    static func cloudURL(bbox: String, mercator: Bool, width: Int = 256, height: Int = 256, date: String = cloudDate) -> URL {
        var url = URLComponents(string: "https://gibs.earthdata.nasa.gov/wms/\(mercator ? "epsg3857" : "epsg4326")/best/wms.cgi")!
        url.queryItems = ["SERVICE":"WMS", "VERSION":"1.1.1", "REQUEST":"GetMap", "LAYERS":"MODIS_Terra_Cloud_Fraction_Day", "FORMAT":"image/png", "TRANSPARENT":"TRUE", "SRS":mercator ? "EPSG:3857" : "EPSG:4326", "BBOX":bbox, "WIDTH":"\(width)", "HEIGHT":"\(height)", "TIME":date].map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
}
final class EarthCloudTiles: MKTileOverlay, @unchecked Sendable {
    let date = EarthLayerService.cloudDate
    init() { super.init(urlTemplate: nil); maximumZ = 6; canReplaceMapContent = false }
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let half = 20037508.342789244, size = 2 * half / pow(2, Double(path.z))
        let left = -half + Double(path.x) * size, top = half - Double(path.y) * size
        return EarthLayerService.cloudURL(bbox: "\(left),\(top - size),\(left + size),\(top)", mercator: true, date: date)
    }
}
