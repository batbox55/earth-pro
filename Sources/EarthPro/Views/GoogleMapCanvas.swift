import SwiftUI
import WebKit

struct GoogleMapCanvas: NSViewRepresentable {
    @ObservedObject var store: EarthStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let url = Bundle.module.url(forResource: "Google3D", withExtension: "js"), let script = try? String(contentsOf: url, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let url = Bundle.module.url(forResource:"GoogleImages",withExtension:"js"), let script=try? String(contentsOf:url,encoding:.utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentStart,forMainFrameOnly:true))
        }
        let key = (try? JSONEncoder().encode(store.googleKey ?? "")).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        configuration.userContentController.addUserScript(WKUserScript(source: "window.earthKey = \(key);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "earth")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 760), configuration: configuration)
        let input = EarthNavigationInput(view: web, store: store)
        input.pointAt = { [weak web, weak coordinator = context.coordinator] point, completion in
            guard let web, coordinator?.ready == true else { completion(nil); return }
            let y = web.isFlipped ? point.y : web.bounds.height - point.y
            web.evaluateJavaScript("window.earthPointAt(\(point.x), \(y))") { result, _ in
                guard let result = result as? [String: Double], let lat = result["lat"], let lng = result["lng"] else { completion(nil); return }
                let point = GeoPoint(latitude: lat, longitude: lng)
                completion(point.isValid ? point : nil)
            }
        }
        input.stopMotion = { [weak web] in web?.evaluateJavaScript("window.earthStopMotion?.()", completionHandler: nil) }
        context.coordinator.input = input
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        context.coordinator.web = web
        GoogleMapServer.shared.start { [weak web, weak coordinator = context.coordinator] result in
            guard let web, let coordinator else { return }
            switch result {
            case .success(let url): web.load(URLRequest(url: url))
            case .failure(let error): coordinator.store.googleError = error.localizedDescription
            }
        }
        store.mapSnapshot = { [weak web] in
            guard let web else { throw KMLError.invalid("Google Maps is not ready for an image export.") }
            return try await web.takeSnapshot(configuration: nil)
        }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) { web.window?.acceptsMouseMovedEvents = true; context.coordinator.update() }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.evaluateJavaScript("window.earth3D?.dispose()", completionHandler: nil)
        web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName: "earth")
        web.navigationDelegate = nil; web.uiDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let store: EarthStore
        weak var web: WKWebView?
        var input: EarthNavigationInput?
        var ready = false
        var lastPayload = ""
        var lastLayers = ""
        var geometryFeatures: [EarthFeature]?
        var geometryVertices: [GeoPoint] = []
        var geometryTool: EarthTool?
        var geometryRevision = UUID()
        var publicDataRevision: UUID?
        var imageRevision: UUID?
        init(store: EarthStore) { self.store = store }
        func update() {
            if let size = web?.bounds.size, size != store.publicDataViewSize, size.width > 1, size.height > 1 {
                DispatchQueue.main.async { [weak store] in store?.publicDataViewSize = size }
            }
            guard ready else { return }
            if publicDataRevision != store.publicDataRevision {
                publicDataRevision = store.publicDataRevision
                let items: [[String: Any]] = store.publicDataVectors.map { kind, feature in
                    let style = feature.vectorStyle ?? VectorStyle()
                    return ["id":feature.sourceID ?? "", "kind":kind.rawValue, "color":style.stroke,"opacity":style.strokeOpacity,
                            "fill":style.fill,"fillOpacity":style.fillOpacity,"width":style.width,
                            "rings":([feature.points]+(feature.holes ?? [])).map { $0.map { ["lat":$0.latitude,"lng":$0.longitude] } }]
                }
                if let data = try? JSONSerialization.data(withJSONObject: items), let json = String(data: data, encoding: .utf8) {
                    web?.evaluateJavaScript("window.earthPublicData(\(json));", completionHandler: nil)
                }
            }
            if imageRevision != store.imageOverlayRevision {
                imageRevision=store.imageOverlayRevision
                let items:[[String:Any]]=store.imageOverlays.filter(\.isVisible).map { item in
                    ["image":"data:image/png;base64,"+item.imageData.base64EncodedString(),"opacity":item.opacity,
                     "points":(0...12).flatMap { y in (0...12).map { x in let p=item.point(u:Double(x)/12,v:Double(y)/12);return ["lat":p.latitude,"lng":p.longitude] } }]
                }
                if let data=try? JSONSerialization.data(withJSONObject:items),let json=String(data:data,encoding:.utf8) { web?.evaluateJavaScript("window.earthImages(\(json));",completionHandler:nil) }
            }
            let layerSignature = store.historicalSignature + String(describing: store.layers) + store.layerRevision.uuidString + String(store.terrain) + String(store.historicalImagery) + EarthObservation.day(store.imageryDate)
            if lastLayers != layerSignature {
                lastLayers = layerSignature
                let countries: [[String: Any]] = EarthBaseData.countries.map { country in
                    ["name": country.name, "lat": country.label.latitude, "lng": country.label.longitude, "rank": country.rank,
                     "outlines": country.outlines.map { $0.map { ["lat": $0.latitude, "lng": $0.longitude] } }]
                }
                let items: [[String: Any]] = store.visibleLayerItems.map { ["id": $0.id, "title": $0.title, "lat": $0.point.latitude, "lng": $0.point.longitude, "color": $0.color] }
                let payload: [String: Any] = ["archiveTemplate": store.activeHistoricalImagery?.template ?? "", "archiveZoom": store.activeHistoricalImagery?.maxZoom ?? 9, "archiveCredit": store.activeHistoricalImagery?.credit ?? "", "enabled": store.layers.enabled, "terrain": store.terrain, "countries": countries, "regions": EarthBaseData.regions.map { $0.map { ["lat": $0.latitude, "lng": $0.longitude] } }, "parks": store.layers.enabled["parks"] == true ? EarthBaseData.parkBoundaries.map { $0.map { ["lat": $0.latitude, "lng": $0.longitude] } } : [], "water": store.layers.enabled["water"] == true ? EarthBaseData.water.map { $0.map { ["lat": $0.latitude, "lng": $0.longitude] } } : [], "items": items, "cloudDate": EarthLayerService.cloudDate]
                if let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) {
                    web?.evaluateJavaScript("window.earthLayers(\(json));", completionHandler: nil)
                }
            }
            let features = store.renderedFeatures
            var geometryPayload: [String:Any] = [:]
            if geometryFeatures != features || geometryVertices != store.vertices || geometryTool != store.tool {
                let encoder = JSONEncoder()
                guard let featureData = try? encoder.encode(features), var featureJSON = (try? JSONSerialization.jsonObject(with:featureData)) as? [[String:Any]],
                      let verticesData = try? encoder.encode(store.vertices), let verticesJSON = try? JSONSerialization.jsonObject(with:verticesData) else { return }
                for index in features.indices where features[index].kind == .point {
                    featureJSON[index]["pinImage"] = EarthPinAppearance.dataURL(features[index])
                    featureJSON[index]["pinAnchorY"] = EarthPinAppearance.anchor(features[index]).y
                }
                geometryFeatures = features; geometryVertices = store.vertices; geometryTool = store.tool; geometryRevision = UUID()
                geometryPayload = ["features":featureJSON,"vertices":verticesJSON]
            }
            var payload: [String: Any] = ["lat": store.latitude, "lng": store.longitude, "distance": store.distance, "heading": store.heading, "pitch": store.terrain ? store.pitch : 0,
                "camera": store.cameraRequest.uuidString, "style": store.mapStyle == .streets ? "roadmap" : (store.mapStyle == .hybrid ? "hybrid" : "satellite"),
                "geometryRevision":geometryRevision.uuidString, "drawing": store.tool != .navigate, "tool": store.tool.rawValue,
                "images": store.imageOverlays.contains(where: \.isVisible),
                "buildings": store.layers.primary && store.layers.buildings, "archive": store.historicalImagery,
                "groundAltitude": max(0, EarthTerrain.sampledElevation(store.center) ?? 0),
                "street": store.streetView, "streetRequest": store.streetRequest.uuidString]
            payload.merge(geometryPayload) { _, new in new }
            if let query = store.googleQuery { payload["query"] = ["id": query.id.uuidString, "text": query.text] }
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8), json != lastPayload else { return }
            lastPayload = json
            web?.evaluateJavaScript("window.earthUpdate(\(json));", completionHandler: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "127.0.0.1", message.frameInfo.securityOrigin.port == 18793,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                geometryFeatures = nil; ready = true; store.googleError = nil; store.googleReady = true
                store.status = "Google Maps · Drag to explore · Pegman opens Street View"; update()
            case "error":
                store.streetView = false
                store.googleReady = false
                store.googleError = body["message"] as? String ?? "Google Maps is unavailable."
                store.status = "Google Maps unavailable · Check settings or use Apple Maps"
                store.searching = false
                if let pending = store.pendingAddressLookup {
                    store.finishAddressLookup(id: pending.id, result: .failure(KMLError.invalid(store.googleError ?? "Google Maps disconnected.")))
                }
            case "tilesReady": store.transitionImage = nil
            case "threeD":
                store.google3DActive = body["active"] as? Bool ?? false
                store.google3DError = body["error"] as? Bool == true ? body["message"] as? String : nil
                if let message = body["message"] as? String, !message.isEmpty { store.status = message }
            case "camera3D":
                guard store.google3DRequested, !store.streetView, !store.historicalImagery,
                      let point = point(body), body["request"] as? String == store.cameraRequest.uuidString,
                      let distance = body["distance"] as? Double, distance.isFinite, (100...45_000_000).contains(distance),
                      let heading = body["heading"] as? Double, heading.isFinite,
                      let pitch = body["pitch"] as? Double, pitch.isFinite, (0...80).contains(pitch) else { return }
                store.latitude = point.latitude; store.longitude = point.longitude; store.distance = distance
                store.heading = heading; store.pitch = pitch; store.cursorPoint = nil
            case "notice": store.status = body["message"] as? String ?? "Google Maps is unavailable."
            case "street":
                store.streetView = body["visible"] as? Bool ?? false
                store.status = store.streetView ? "Street View · Drag to look around · Click arrows to move" : "Google Maps · Drag to explore"
            case "streetMetadata":
                store.updateStreetImagery(date: body["date"] as? String, loading: body["loading"] as? Bool ?? false, request: body["request"] as? String)
            case "pick": if let point = point(body), !store.streetView { store.pick(point) }
            case "publicDataSelect":
                guard store.tool == .navigate, let id = body["id"] as? String,
                      let rawKind = body["kind"] as? String, let kind = PublicDataKind(rawValue: rawKind),
                      let feature = store.publicDataFeatures.first(where: { $0.id == id && $0.kind == kind }) else { return }
                store.showPublicDataDetails(feature)
            case "layerSelect":
                if let id = body["id"] as? String { store.layerSelection = store.visibleLayerItems.first { $0.id == id } }
            case "select":
                if let text = body["id"] as? String, let id = UUID(uuidString: text), let feature = store.renderedFeatures.first(where: { $0.id == id }) {
                    store.selection = id; store.status = feature.name
                }
            case "camera":
                guard !store.google3DActive, let point = point(body), body["request"] as? String == store.cameraRequest.uuidString,
                      let zoom = body["zoom"] as? Double, zoom.isFinite, (0...24).contains(zoom),
                      let height = body["height"] as? Double, height > 0, height < 20_000 else { return }
                store.latitude = point.latitude; store.longitude = point.longitude
                store.distance = max(100, min(45_000_000, 156543.03392 * cos(point.latitude * .pi / 180) * height / pow(2, zoom)))
                if let heading = body["heading"] as? Double, heading.isFinite { store.heading = heading }
                if let pitch = body["pitch"] as? Double, pitch.isFinite { store.pitch = pitch }
            case "search":
                guard let text = body["id"] as? String, let id = UUID(uuidString: text) else { return }
                let status = body["status"] as? String ?? "ERROR"
                let results = body["results"] as? [[String: Any]] ?? []
                let hits = results.compactMap { row -> SearchHit? in
                    guard let point = point(row), let title = row["title"] as? String else { return nil }
                    return SearchHit(title: title, subtitle: "Google Maps", point: point)
                }
                if store.receiveAddressLookup(id: id, hits: hits, status: status) { return }
                guard id == store.googleQuery?.id else { return }
                store.searching = false; store.googleQuery = nil; store.searchHits = hits
                if let hit = store.searchHits.first { store.selectSearchHit(hit); store.status = "Google Maps · \(store.searchHits.count) search results" }
                else { store.status = status == "ZERO_RESULTS" ? "No Google address results. Try a city, address, or coordinates." : "Google search unavailable. Enable Geocoding API and check key restrictions, billing, and quotas." }
            default: break
            }
        }
        private func point(_ body: [String: Any]) -> GeoPoint? {
            guard let lat = body["lat"] as? Double, let lng = body["lng"] as? Double else { return nil }
            let point = GeoPoint(latitude: lat, longitude: lng)
            return point.isValid ? point : nil
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme == "https" {
                NSWorkspace.shared.open(url); decisionHandler(.cancel); return
            }
            if action.targetFrame?.isMainFrame == true {
                let url = action.request.url
                decisionHandler(url?.scheme == "http" && url?.host == "127.0.0.1" && url?.port == 18793 ? .allow : .cancel)
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme == "https" { NSWorkspace.shared.open(url) }
            return nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            store.streetView = false
            ready = false; store.googleReady = false; store.googleError = "The Google Maps viewer stopped. Retry to reconnect."
        }
        private func failed(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            store.streetView = false
            ready = false; store.googleReady = false; store.googleError = "The Google Maps viewer could not connect. Check your connection and retry."
        }
    }
}
