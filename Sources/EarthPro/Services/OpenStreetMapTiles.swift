import MapKit

/// Interactive street tiles, using the provider's HTTP caching and attribution policy.
final class OpenStreetMapTiles: MKTileOverlay, @unchecked Sendable {
    var onFailure: (() -> Void)?
    private var reportedFailure = false
    private let session: URLSession
    override init(urlTemplate: String?) {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024, diskPath: "EarthPro-OpenStreetMap")
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 2
        config.httpAdditionalHeaders = ["User-Agent": "EarthPro/1.0 (macOS; Earth Pro)"]
        session = URLSession(configuration: config)
        super.init(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        canReplaceMapContent = true; minimumZ = 0; maximumZ = 19
    }
    convenience init() { self.init(urlTemplate: nil) }
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        session.dataTask(with: url(forTilePath: path)) { [weak self] data, response, error in
            if let error { self?.reportFailure(); result(nil, error); return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                self?.reportFailure(); result(nil, URLError(.badServerResponse)); return
            }
            result(data, nil)
        }.resume()
    }
    private func reportFailure() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.reportedFailure else { return }
            self.reportedFailure = true; self.onFailure?()
        }
    }
    deinit { session.invalidateAndCancel() }
}
