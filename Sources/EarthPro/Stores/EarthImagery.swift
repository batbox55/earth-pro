import Foundation
import AppKit

@MainActor extension EarthStore {
    var activeHistoricalImagery: ImagerySource? {
        guard historicalImagery else { return nil }
        if historyProduct == .wayback { return selectedWayback.map(ImagerySource.wayback) }
        return .nasa(historyProduct, date: imageryDate)
    }
    var activeGlobeImagery: ImagerySource? { historicalImagery ? activeHistoricalImagery : .current }
    var selectedWayback: WaybackRelease? { waybackReleases.first { $0.id == waybackReleaseID } }
    var historicalSignature: String { activeHistoricalImagery?.template ?? "" }
    var historyAttribution: String { activeHistoricalImagery?.credit ?? historyCatalogStatus }
    func loadWayback() {
        guard waybackReleases.isEmpty, !waybackLoading else { return }
        waybackLoading = true; historyCatalogStatus = "Loading Wayback releases…"
        Task { [weak self] in
            do {
                let data = try await ImageryTransport.shared.data(URL(string: "https://s3-us-west-2.amazonaws.com/config.maptiles.arcgis.com/waybackconfig.json")!)
                let releases = try WaybackRelease.decode(data)
                guard let self else { return }
                self.waybackReleases = releases; self.waybackLoading = false
                self.waybackReleaseID = releases.first?.id ?? ""
                self.historyCatalogStatus = releases.isEmpty ? "No Wayback releases returned" : "\(releases.count) archived basemap releases · Capture dates vary by location"
            } catch { self?.waybackLoading = false; self?.historyCatalogStatus = "Wayback unavailable · Retry when connected" }
        }
    }
    func scheduleImageryMetadata() {
        imageryMetadataTask?.cancel(); imageryMetadataTask = nil
        captureDate = nil; captureSource = ""
        guard historicalImagery, historyProduct == .wayback, let release = selectedWayback else { return }
        let point = observationPoint, signature = historicalSignature, distance = distance
        imageryMetadataTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(650))
                let span = max(0.00001, min(180, distance / GeoMath.radius * 180 / .pi))
                var url = URLComponents(url: release.metadata.appendingPathComponent("identify"), resolvingAgainstBaseURL: false)!
                url.queryItems = ["f":"json", "geometry":"\(point.longitude),\(point.latitude)", "geometryType":"esriGeometryPoint", "sr":"4326", "tolerance":"1", "mapExtent":"\(point.longitude-span),\(point.latitude-span),\(point.longitude+span),\(point.latitude+span)", "imageDisplay":"1000,1000,96", "returnGeometry":"false", "layers":"visible"].map { .init(name: $0.key, value: $0.value) }
                let data = try await ImageryTransport.shared.data(url.url!)
                let metadata = try ImageryCatalog.capture(data)
                guard !Task.isCancelled, let self, self.historicalSignature == signature, self.observationPoint == point else { return }
                self.captureDate = metadata?.date; self.captureSource = metadata?.source ?? ""
            } catch { /* Unknown metadata never becomes an invented capture date. */ }
        }
    }
    func findHistoryDates() {
        historyCatalogTask?.cancel(); historyDates = []
        guard historicalImagery, historyProduct != .wayback else { if historyProduct == .wayback { loadWayback() }; return }
        let product = historyProduct, center = center, date = imageryDate
        historyCatalogStatus = "Checking available dates near this view…"
        historyCatalogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
                let days = try await ImageryCatalog.dates(product: product, center: center, around: date)
                guard !Task.isCancelled, let self, self.historyProduct == product else { return }
                self.historyDates = days
                self.historyCatalogStatus = days.isEmpty ? "No catalog observations in this area/date window · Try another date" : "\(days.count) observation days near this view · ±15 days · Clouds/gaps possible"
            } catch { if !Task.isCancelled { self?.historyCatalogStatus = "Date catalog unavailable · Tiles can still be requested" } }
        }
    }
}

enum ImageryCatalog {
    static func capture(_ data: Data) throws -> (date: String, source: String)? {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        for row in root?["results"] as? [[String: Any]] ?? [] {
            guard let a = row["attributes"] as? [String: Any] else { continue }
            let raw = a["SRC_DATE2"] as? String ?? ""
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = EarthObservation.calendar.timeZone; f.dateFormat = "M/d/yyyy"; f.isLenient = false
            if let date = f.date(from: raw) { return (EarthObservation.day(date), a["SRC_DESC"] as? String ?? "Esri World Imagery") }
        }
        return nil
    }
    static func decodeDates(_ data: Data) throws -> [String] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let feed = root?["feed"] as? [String: Any]
        return Array(Set((feed?["entry"] as? [[String: Any]] ?? []).compactMap { row in
            guard let time = row["time_start"] as? String, time.count >= 10 else { return nil as String? }
            return String(time.prefix(10))
        })).sorted()
    }
    static func dates(product: HistoryProduct, center: GeoPoint, around date: Date) async throws -> [String] {
        var u = URLComponents(string: "https://cmr.earthdata.nasa.gov/search/granules.json")!
        let shortName = product == .landsat ? "HLSL30" : product == .sentinel ? "HLSS30" : "MOD09GA"
        let collection: [String: String] = product == .modis ? ["short_name": shortName, "version": "061"] : ["collection_concept_id": product == .landsat ? "C2021957657-LPCLOUD" : "C2021957295-LPCLOUD"]
        u.queryItems = (collection.merging([ "bounding_box":"\(max(-180,center.longitude-0.1)),\(max(-85,center.latitude-0.1)),\(min(180,center.longitude+0.1)),\(min(85,center.latitude+0.1))", "temporal":"\(EarthObservation.day(date.addingTimeInterval(-15*86400)))T00:00:00Z,\(EarthObservation.day(date.addingTimeInterval(16*86400)))T00:00:00Z", "page_size":"200", "sort_key":"-start_date"]) { _, new in new }).map { .init(name: $0.key, value: $0.value) }
        return try decodeDates(await ImageryTransport.shared.data(u.url!))
    }
}
