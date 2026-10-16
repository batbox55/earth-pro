import SwiftUI
import MapKit
import AppKit

extension NSColor {
    convenience init(earthHex hex: String) {
        let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xf5c542
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
private final class FeatureAnnotation: NSObject, MKAnnotation {
    let feature: EarthFeature
    var coordinate: CLLocationCoordinate2D { feature.center.coordinate }
    var title: String? { feature.name }
    var subtitle: String? { feature.notes.isEmpty ? nil : feature.notes }
    init(_ feature: EarthFeature) { self.feature = feature }
}
private final class LayerAnnotation: NSObject, MKAnnotation {
    let item: EarthLayerItem?
    let text: String
    let point: GeoPoint
    var coordinate: CLLocationCoordinate2D { point.coordinate }
    var title: String? { text }
    init(_ item: EarthLayerItem) { self.item = item; text = item.title; point = item.point }
    init(country: EarthCountry) { item = nil; text = country.name; point = country.label }
}
private final class LayerMarkerView: MKMarkerAnnotationView {
    var activate: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { activate?(); return true }
}
final class PickingMapView: MKMapView {
    override var acceptsFirstResponder: Bool { true }
    var isPicking = false
    var onReady: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.onReady?() } }
    }
    var pick: ((CLLocationCoordinate2D) -> Void)?
    override func mouseDown(with event: NSEvent) {
        if isPicking { pick?(convert(convert(event.locationInWindow, from: nil), toCoordinateFrom: self)) }
        else { super.mouseDown(with: event) }
    }
}
struct MapCanvas: NSViewRepresentable {
    @ObservedObject var store: EarthStore
    func makeCoordinator() -> Coordinator { Coordinator(store) }
    func makeNSView(context: Context) -> PickingMapView {
        let map = PickingMapView(frame: NSRect(x: 0, y: 0, width: 960, height: 760))
        let input = EarthNavigationInput(view: map, store: store)
        input.pointAt = { [weak map] point, completion in
            guard let map else { completion(nil); return }
            let coordinate = map.convert(point, toCoordinateFrom: map)
            let point = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
            completion(point.isValid ? point : nil)
        }
        input.pickLayerAt = { [weak map, weak store] point in
            guard let map, let store else { return false }
            for annotation in map.annotations {
                guard let layer = annotation as? LayerAnnotation, let item = layer.item,
                      let marker = map.view(for: annotation), !marker.isHidden,
                      map.convert(marker.bounds, from: marker).insetBy(dx: -3, dy: -3).contains(point) else { continue }
                store.layerSelection = item; return true
            }
            return false
        }
        input.stopMotion = { [weak map] in if let map { map.setCamera(map.camera, animated: false) } }
        context.coordinator.input = input
        map.delegate = context.coordinator; map.showsCompass = false; map.showsScale = false; map.showsZoomControls = false
        map.isRotateEnabled = true; map.isPitchEnabled = true
        map.pick = { [weak store] c in store?.pick(.init(latitude: c.latitude, longitude: c.longitude)) }
        context.coordinator.map = map
        map.onReady = { [weak map, weak coordinator = context.coordinator] in
            if let map { coordinator?.update(map) }
        }
        store.mapSnapshot = { [weak map, weak store] in
            guard let map, let store else { throw KMLError.invalid("The map view has closed.") }
            guard let bitmap = map.bitmapImageRepForCachingDisplay(in: map.bounds) else { throw KMLError.invalid("The map could not be captured.") }
            map.cacheDisplay(in: map.bounds, to: bitmap)
            let image = NSImage(size: map.bounds.size); image.addRepresentation(bitmap)
            return NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                let source = store.provider == .openStreetMap ? "© OpenStreetMap contributors · openstreetmap.org/copyright" : "Map data © Apple"
                let credit = (source + " · Borders: Natural Earth" + (store.layers.clouds && store.layers.primary ? " · Clouds: NASA GIBS" : "")) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black]
                let width = min(rect.width - 16, credit.size(withAttributes: attributes).width + 12)
                NSColor.white.withAlphaComponent(0.95).setFill(); NSBezierPath(rect: NSRect(x: 8, y: 8, width: width, height: 23)).fill()
                credit.draw(in: NSRect(x: 14, y: 13, width: width - 12, height: 16), withAttributes: attributes)
                return true
            }

        }
        return map
    }
    func updateNSView(_ map: PickingMapView, context: Context) { map.window?.acceptsMouseMovedEvents = true; context.coordinator.update(map) }
    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        let store: EarthStore
        weak var map: MKMapView?
        var input: EarthNavigationInput?
        var lastCamera: UUID?
        var appearance = ""
        var streetTiles: OpenStreetMapTiles?
        var archiveTiles: EarthArchiveTiles?
        var cloudTiles: EarthCloudTiles?
        var lastLayers: EarthLayers?
        var lastLayerRevision: UUID?
        var lastLabelDetail = false
        var drawn: [EarthFeature] = []
        var lastVertices: [GeoPoint] = []
        var lastTool: EarthTool = .navigate
        var lastSelection: UUID?
        var colors: [ObjectIdentifier: NSColor] = [:]
        var settingCamera = false
        init(_ store: EarthStore) { self.store = store }
        var imageRevision: UUID?
        var imageBase=""
        func update(_ map: PickingMapView) {
            map.isPicking = store.tool != .navigate
            let style = store.provider.rawValue + store.mapStyle.rawValue + String(store.terrain) + String(describing: store.layers)
            if appearance != style {
                appearance = style
                if let archiveTiles { map.removeOverlay(archiveTiles); self.archiveTiles = nil }
                if let streetTiles { map.removeOverlay(streetTiles); self.streetTiles = nil }
                map.isPitchEnabled = store.provider != .openStreetMap
                map.showsPitchControl = false
                if store.provider == .openStreetMap {
                    map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
                    let tiles = OpenStreetMapTiles(); streetTiles = tiles
                    tiles.onFailure = { [weak self, weak tiles] in
                        guard let self, self.streetTiles === tiles, self.store.provider == .openStreetMap else { return }
                        self.store.status = "OpenStreetMap unavailable · Choose Apple Maps above, or switch to Globe"
                    }
                    map.addOverlay(tiles, level: .aboveLabels)
                } else {
                let elevation: MKMapConfiguration.ElevationStyle = store.terrain ? .realistic : .flat
                let enabled = store.layers.enabled
                var categories: [MKPointOfInterestCategory] = []
                if enabled["parks"] == true { categories += [.park, .nationalPark] }
                if enabled["transit"] == true { categories += [.publicTransport, .airport] }
                var excluded: [MKPointOfInterestCategory] = []
                if enabled["parks"] != true { excluded += [.park, .nationalPark] }
                if enabled["transit"] != true { excluded += [.publicTransport, .airport] }
                let poi = enabled["places"] == true ? MKPointOfInterestFilter(excluding: excluded) : MKPointOfInterestFilter(including: categories)
                if enabled["roads"] == true {
                    if store.mapStyle == .streets {
                        let configuration = MKStandardMapConfiguration(elevationStyle: elevation)
                        configuration.pointOfInterestFilter = poi; configuration.showsTraffic = enabled["traffic"] == true; map.preferredConfiguration = configuration
                    } else {
                        let configuration = MKHybridMapConfiguration(elevationStyle: elevation)
                        configuration.pointOfInterestFilter = poi; configuration.showsTraffic = enabled["traffic"] == true; map.preferredConfiguration = configuration
                    }
                } else { map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: elevation) }
                map.showsBuildings = enabled["buildings"] == true
                map.showsTraffic = enabled["traffic"] == true
                }
            }
            if store.historicalImagery {
                if archiveTiles?.date != store.imageryDate {
                    if let archiveTiles { map.removeOverlay(archiveTiles) }
                    let tiles = EarthArchiveTiles(date: store.imageryDate); archiveTiles = tiles; map.addOverlay(tiles, level: .aboveLabels)
                }
            } else if let archiveTiles { map.removeOverlay(archiveTiles); self.archiveTiles = nil }
            if store.layers.primary && store.layers.clouds {
                if cloudTiles == nil { let tiles = EarthCloudTiles(); cloudTiles = tiles; map.addOverlay(tiles, level: .aboveLabels) }
            } else if let cloudTiles { map.removeOverlay(cloudTiles); self.cloudTiles = nil }
            if map.window != nil, map.bounds.width > 1, map.bounds.height > 1, lastCamera != store.cameraRequest {
                let initial = lastCamera == nil
                lastCamera = store.cameraRequest; settingCamera = true
                let camera = MKMapCamera(lookingAtCenter: store.center.coordinate, fromDistance: store.distance, pitch: store.terrain && store.provider != .openStreetMap ? store.pitch : 0, heading: store.heading)
                map.setCamera(camera, animated: !initial && !store.navigationIsActive)
                settingCamera = false
            }
            let visible = store.renderedFeatures
            let labelDetail = store.distance < 6_000_000
            if drawn != visible || lastVertices != store.vertices || lastTool != store.tool || lastSelection != store.selection || lastLayers != store.layers || lastLayerRevision != store.layerRevision || lastLabelDetail != labelDetail {
                lastLayers = store.layers; lastLayerRevision = store.layerRevision; lastLabelDetail = labelDetail
                drawn = visible; lastVertices = store.vertices; lastTool = store.tool; lastSelection = store.selection
                map.removeAnnotations(map.annotations); map.removeOverlays(map.overlays.filter { !($0 is MKTileOverlay) && !($0 is EarthGroundImage) }); colors = [:]
                let enabled = store.layers.enabled
                if enabled["borders"] == true {
                    let lines = EarthBaseData.countries.flatMap(\.outlines).map { points -> MKPolyline in
                        let coordinates = points.map(\.coordinate); return MKPolyline(coordinates: coordinates, count: coordinates.count)
                    }
                    let borders = MKMultiPolyline(lines); colors[ObjectIdentifier(borders)] = .systemYellow; map.addOverlay(borders)
                    let regionLines = EarthBaseData.regions.map { points -> MKPolyline in
                        let coordinates = points.map(\.coordinate); return MKPolyline(coordinates: coordinates, count: coordinates.count)
                    }
                    let regions = MKMultiPolyline(regionLines); colors[ObjectIdentifier(regions)] = .lightGray; map.addOverlay(regions)
                }
                if enabled["parks"] == true {
                    let lines = EarthBaseData.parkBoundaries.map { points -> MKPolyline in
                        let coordinates = points.map(\.coordinate); return MKPolyline(coordinates: coordinates, count: coordinates.count)
                    }
                    let parks = MKMultiPolyline(lines); colors[ObjectIdentifier(parks)] = .systemGreen; map.addOverlay(parks)
                }
                if enabled["water"] == true {
                    let lines = EarthBaseData.water.map { points -> MKPolyline in
                        let coordinates = points.map(\.coordinate); return MKPolyline(coordinates: coordinates, count: coordinates.count)
                    }
                    let water = MKMultiPolyline(lines); colors[ObjectIdentifier(water)] = .systemCyan; map.addOverlay(water)
                }
                if enabled["labels"] == true {
                    for country in EarthBaseData.countries where country.rank <= (labelDetail ? 6 : 3) { map.addAnnotation(LayerAnnotation(country: country)) }
                }
                for item in store.visibleLayerItems { map.addAnnotation(LayerAnnotation(item)) }
                for feature in visible {
                    if feature.kind == .point { map.addAnnotation(FeatureAnnotation(feature)) }
                    else { add(feature.points, polygon: feature.kind == .polygon, color: NSColor(earthHex: feature.color), to: map) }
                }
                add(store.vertices, polygon: store.tool == .polygon && store.vertices.count > 2, color: .systemYellow, to: map)
                for (index, point) in store.vertices.enumerated() {
                    let pin = MKPointAnnotation(); pin.coordinate = point.coordinate; pin.title = "Point \(index + 1)"; map.addAnnotation(pin)
                }
            }
            let base=style+String(store.historicalImagery)+EarthObservation.day(store.imageryDate)
            if imageRevision != store.imageOverlayRevision || imageBase != base {
                imageRevision=store.imageOverlayRevision; imageBase=base
                map.removeOverlays(map.overlays.filter{$0 is EarthGroundImage})
                for item in store.imageOverlays where item.isVisible { if let overlay=EarthGroundImage(item) { map.addOverlay(overlay,level:.aboveLabels) } }
            }

        }
        func add(_ points: [GeoPoint], polygon: Bool, color: NSColor, to map: MKMapView) {
            guard points.count > 1 else { return }
            let coordinates = points.map(\.coordinate)
            let overlay: MKOverlay = polygon ? MKPolygon(coordinates: coordinates, count: coordinates.count) : MKGeodesicPolyline(coordinates: coordinates, count: coordinates.count)
            colors[ObjectIdentifier(overlay)] = color; map.addOverlay(overlay)
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !settingCamera, lastCamera != nil else { return }
            let camera = mapView.camera
            let request = store.cameraRequest
            // Publishing after the AppKit callback avoids changing SwiftUI state in updateNSView.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.store.mode == .map, self.store.cameraRequest == request else { return }
                self.store.latitude = camera.centerCoordinate.latitude; self.store.longitude = camera.centerCoordinate.longitude
                self.store.distance = camera.centerCoordinateDistance; self.store.heading = camera.heading; self.store.pitch = camera.pitch
            }
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay is EarthGroundImage { return EarthGroundImageRenderer(overlay:overlay) }
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            let color = colors[ObjectIdentifier(overlay)] ?? .systemYellow
            if let lines = overlay as? MKMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: lines); renderer.strokeColor = color.withAlphaComponent(0.8); renderer.lineWidth = 1; return renderer
            }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon); renderer.strokeColor = color; renderer.fillColor = color.withAlphaComponent(0.2); renderer.lineWidth = 2.5; return renderer
            }
            if let line = overlay as? MKPolyline { let renderer = MKPolylineRenderer(polyline: line); renderer.strokeColor = color; renderer.lineWidth = 3; return renderer }
            return MKOverlayRenderer(overlay: overlay)
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let layer = annotation as? LayerAnnotation {
                if let item = layer.item {
                    let marker = LayerMarkerView(annotation: annotation, reuseIdentifier: nil)
                    marker.activate = { [weak store] in store?.layerSelection = item }
                    marker.setAccessibilityRole(.button); marker.setAccessibilityLabel("View " + item.kind.rawValue + ": " + item.title)
                    marker.markerTintColor = NSColor(earthHex: item.color); marker.glyphImage = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.kind.rawValue)
                    marker.canShowCallout = true; return marker
                }
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
                let field = NSTextField(labelWithString: layer.text); field.font = .systemFont(ofSize: 11, weight: .medium)
                field.textColor = .white; field.backgroundColor = NSColor.black.withAlphaComponent(0.55); field.drawsBackground = true; field.sizeToFit()
                view.frame = field.bounds; view.addSubview(field); view.canShowCallout = false; view.collisionMode = .rectangle; view.displayPriority = .defaultLow
                return view
            }
            if let feature = (annotation as? FeatureAnnotation)?.feature {
                let marker = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
                marker.image = EarthPinAppearance.image(feature)
                let anchor = EarthPinAppearance.anchor(feature)
                marker.centerOffset = NSPoint(x: 20 - anchor.x, y: 24 - anchor.y)
                marker.canShowCallout = true; marker.collisionMode = .rectangle
                marker.displayPriority = .required
                return marker
            }
            let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
            marker.canShowCallout = true; marker.markerTintColor = .systemYellow
            return marker
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let annotation = view.annotation as? FeatureAnnotation { store.selection = annotation.feature.id; store.status = annotation.feature.name }
            if let annotation = view.annotation as? LayerAnnotation, let item = annotation.item { store.layerSelection = item }
        }
        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) { DispatchQueue.main.async { [weak self] in self?.store.status = "Map imagery unavailable · Check your connection or switch to Globe" } }
    }
}
