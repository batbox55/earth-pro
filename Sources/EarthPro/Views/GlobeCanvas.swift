import SwiftUI
import SceneKit
import simd
import AppKit

private func spherePosition(_ point: GeoPoint, radius: Float = 1) -> SCNVector3 {
    let lat = Float(point.latitude * .pi / 180), lon = Float(point.longitude * .pi / 180)
    return SCNVector3(radius * cos(lat) * sin(lon), radius * sin(lat), radius * cos(lat) * cos(lon))
}
final class InteractiveGlobe: SCNView {
    weak var store: EarthStore?
    var dragging = false
    private var lastPoint = NSPoint.zero
    private var moved = false
    private var grabbed: GeoPoint?
    private var lastTime = 0.0
    private var velocity = SIMD3<Double>.zero
    private var coast: Timer?
    private var lastCoastTick = 0.0
    private var motionRequest: UUID?
    var renderCamera: (() -> Void)?
    var pickPublicData: ((NSPoint) -> Bool)?
    deinit { coast?.invalidate() }
    func interruptMotion() { coast?.invalidate(); coast = nil; velocity = .zero }
    private func apply(_ rotation: simd_quatd) {
        guard let store else { return }
        let (center, heading) = EarthNavigation.rotatedCamera(center: store.center, heading: store.heading, rotation: rotation)
        store.navigationIsActive = true
        store.latitude = center.latitude; store.longitude = center.longitude; store.heading = heading
        store.cameraRequest = UUID(); motionRequest = store.cameraRequest; renderCamera?()
    }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { interruptMotion(); return }
        // Schedule the first frame after SwiftUI has attached and sized the SceneKit view.
        DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
    }
    override func layout() {
        super.layout()
        renderCamera?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: store?.tool == .navigate ? .openHand : .crosshair) }
    override func mouseDown(with event: NSEvent) {
        if store?.tool == .navigate { NSCursor.closedHand.set() }
        interruptMotion(); lastPoint = convert(event.locationInWindow, from: nil)
        grabbed = earthPoint(at: lastPoint); lastTime = event.timestamp
        moved = false; window?.makeFirstResponder(self)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let store, store.tool == .navigate else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - lastPoint.x, dy = point.y - lastPoint.y
        moved = true; dragging = true
        if let grabbed, let underCursor = earthPoint(at: point) {
            var rotation = simd_quatd(from: EarthNavigation.vector(underCursor), to: EarthNavigation.vector(grabbed))
            if event.modifierFlags.contains(.option) { rotation = simd_slerp(simd_quatd(angle: 0, axis: .init(0, 1, 0)), rotation, 0.2) }
            let dt = max(0.001, min(0.1, event.timestamp - lastTime))
            let speed = min(2, rotation.angle / dt)
            let fraction = EarthNavigation.motionFraction(elapsed: dt, response: 0.028)
            velocity = velocity * (1 - fraction) + (speed > 0.00001 ? rotation.axis * speed * fraction : .zero)
            apply(rotation)
        } else {
            store.navigateDrag(.pan, dx: Double(dx), dy: Double(dy), height: Double(bounds.height), fine: event.modifierFlags.contains(.option))
            velocity = .zero; renderCamera?()
        }
        lastPoint = point; lastTime = event.timestamp
        // Reanchor after fine movement or a ray crossing the limb, avoiding a jump on re-entry.
        grabbed = earthPoint(at: point)
    }
    func earthPoint(at location: NSPoint) -> GeoPoint? {
        guard let hit = hitTest(location, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]).first(where: { $0.node.name == "earth" }) else { return nil }
        let vector = simd_normalize(SIMD3<Double>(Double(hit.worldCoordinates.x), Double(hit.worldCoordinates.y), Double(hit.worldCoordinates.z)))
        return GeoPoint(latitude: asin(max(-1, min(1, vector.y))) * 180 / .pi, longitude: atan2(vector.x, vector.z) * 180 / .pi)
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        if store?.tool == .navigate { NSCursor.openHand.set() }
        if moved, event.timestamp - lastTime < 0.08, simd_length(velocity) > 0.03 {
            lastCoastTick = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let store = self.store, self.window?.isVisible == true,
                          store.mode == .globe, store.tool == .navigate, store.cameraRequest == self.motionRequest,
                          simd_length(self.velocity) > 0.015 else { self?.interruptMotion(); return }
                    let speed = simd_length(self.velocity)
                    let now = ProcessInfo.processInfo.systemUptime
                    let elapsed = min(0.1, max(0, now - self.lastCoastTick)); self.lastCoastTick = now
                    let fraction = EarthNavigation.motionFraction(elapsed: elapsed, response: 0.23)
                    self.apply(simd_quatd(angle: speed * 0.23 * fraction, axis: self.velocity / speed))
                    self.velocity *= 1 - fraction
                }
            }
            coast = timer; RunLoop.main.add(timer, forMode: .common)
        }
        if !moved, let store, let hit = hitTest(convert(event.locationInWindow, from: nil), options: nil).first,
           let name = hit.node.name, name.hasPrefix("layer:"), let item = store.visibleLayerItems.first(where: { "layer:" + $0.id == name }) {
            store.layerSelection = item; return
        }
        if !moved, let store, store.tool == .navigate,
           let name = hitTest(convert(event.locationInWindow, from: nil), options: nil).first?.node.name,
           name.hasPrefix("feature:"), let id = UUID(uuidString: String(name.dropFirst(8))) {
            store.selection = id; return
        }
        if !moved, store?.tool == .navigate, pickPublicData?(convert(event.locationInWindow, from: nil)) == true { return }
        guard !moved, let store, let point = earthPoint(at: convert(event.locationInWindow, from: nil)) else { return }
        store.pick(point)
    }

}
struct GlobeCanvas: NSViewRepresentable {
    @ObservedObject var store: EarthStore
    func makeCoordinator() -> Coordinator { Coordinator(store) }
    func makeNSView(context: Context) -> InteractiveGlobe {
        let view = InteractiveGlobe()
        view.store = store;
        let input = EarthNavigationInput(view: view, store: store)
        view.renderCamera = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.update(view) }
        }
        view.pickPublicData = { [weak coordinator = context.coordinator, weak view] point in
            guard let view else { return false }
            return coordinator?.pickPublicData(at: point, in: view) ?? false
        }
        input.renderCamera = view.renderCamera
        input.interruptMotion = { [weak view] in view?.interruptMotion() }
        input.pointAt = { [weak view] point, completion in completion(view?.earthPoint(at: point)) }
        input.stopMotion = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            view.interruptMotion()
            let presented = coordinator.camera.presentation
            let position = presented.position, orientation = presented.orientation
            coordinator.camera.removeAllAnimations()
            coordinator.camera.position = position; coordinator.camera.orientation = orientation
            if let target = view.earthPoint(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY)) {
                let surface = spherePosition(target)
                let d = SCNVector3(position.x - surface.x, position.y - surface.y, position.z - surface.z)
                let length = sqrt(Double(d.x * d.x + d.y * d.y + d.z * d.z))
                store.latitude = target.latitude; store.longitude = target.longitude; store.distance = length * GeoMath.radius
                let dot = Double(d.x * surface.x + d.y * surface.y + d.z * surface.z) / max(0.0001, length)
                store.pitch = acos(max(-1, min(1, dot))) * 180 / .pi
            }
        }
        context.coordinator.input = input; view.scene = context.coordinator.scene
        view.backgroundColor = NSColor(srgbRed: 0.015, green: 0.025, blue: 0.045, alpha: 1)
        view.antialiasingMode = .multisampling4X; view.preferredFramesPerSecond = 60
        view.pointOfView = context.coordinator.camera; view.autoenablesDefaultLighting = false
        view.setAccessibilityLabel("Interactive Earth globe. Drag to pan. Scroll or pinch to zoom. Shift-scroll tilts. Shift or middle-button drag rotates and tilts. Command-drag looks around. Control-drag zooms. Option slows navigation.")
        store.globeSnapshot = { [weak view] in view?.snapshot() ?? NSImage(size: .init(width: 1, height: 1)) }
        return view
    }
    func updateNSView(_ view: InteractiveGlobe, context: Context) { view.window?.acceptsMouseMovedEvents = true; context.coordinator.update(view) }
    @MainActor final class Coordinator {
        let store: EarthStore
        let scene = SCNScene(), camera = SCNNode(), overlay = SCNNode(), grid = SCNNode()
        let imageGround = SCNNode()
        let publicDataRoot = SCNNode()
        var publicDataRevision: UUID?
        var publicDataTerrain: Bool?
        var publicDataSegments: [(PublicDataFeature, [SCNVector3])] = []
        var publicDataBuild: Task<[(PublicDataFeature, [SCNVector3])], Never>?
        let imageryTiles = GlobeImageryTiles()
        var lastImages: UUID?
        var lastImageTerrain: Bool?
        let earth = SCNNode(), parks = SCNNode()
        lazy var flatEarth = Self.earthMesh()
        lazy var reliefEarth = Self.earthMesh(terrain: true)
        var lastTerrain: Bool?
        var layerNodes: [(EarthLayerItem, SCNNode)] = []
        let archive = SCNNode(), sunlight = SCNNode(), ambient = SCNNode()
        let roads = SCNNode(), water = SCNNode()
        let borders = SCNNode(), labels = SCNNode(), cities = SCNNode(), dataMarkers = SCNNode(), clouds = SCNNode()
        var countryLabels: [(Int, SCNNode)] = [], cityLabels: [(Int, SCNNode)] = []
        var lastLayerRevision: UUID?
        var lastLayerItems: [EarthLayerItem] = []
        var input: EarthNavigationInput?
        var lastCamera: UUID?
        var drawn: [EarthFeature] = [], vertices: [GeoPoint] = []
        var lastCustomTerrain: Bool?
        var lastSelection: UUID?
        var lastTool: EarthTool = .navigate
        init(_ store: EarthStore) {
            self.store = store
            imageryTiles.report = { [weak store] text in
                DispatchQueue.main.async {
                    guard let store, store.mode == .globe, store.historicalImagery else { return }
                    store.archiveStatus = text; store.archiveLoading = text == "Refining imagery…"
                }
            }
            camera.camera = SCNCamera(); camera.camera?.fieldOfView = 38; camera.camera?.zNear = 0.01; camera.camera?.zFar = 200
            scene.rootNode.addChildNode(camera)
            scene.rootNode.addChildNode(imageryTiles.root)
            scene.rootNode.addChildNode(publicDataRoot)
            earth.geometry = flatEarth; earth.name = "earth"; earth.renderingOrder = -200
            let material = SCNMaterial(); material.lightingModel = .constant
            if let url = Bundle.module.url(forResource: "earth", withExtension: "png") { material.diffuse.contents = NSImage(contentsOf: url) }
            else { material.diffuse.contents = NSColor.systemBlue }
            material.diffuse.wrapS = .repeat; material.diffuse.magnificationFilter = .linear
            earth.geometry?.materials = [material]; scene.rootNode.addChildNode(earth)
            scene.rootNode.addChildNode(overlay); scene.rootNode.addChildNode(grid)
            [borders, roads, water, parks, labels, cities, dataMarkers, clouds, archive, sunlight, ambient].forEach { scene.rootNode.addChildNode($0) }
            makeGrid(); makeStars()
            borders.addChildNode(lineNode(borderSegments(EarthBaseData.countries.flatMap(\.outlines)), color: NSColor(srgbRed: 1, green: 0.86, blue: 0.35, alpha: 0.8), radius: 1.003))
            borders.addChildNode(lineNode(borderSegments(EarthBaseData.regions), color: NSColor(white: 0.8, alpha: 0.6), radius: 1.003))
            for country in EarthBaseData.countries {
                let node = labelNode(country.name, at: country.label, color: .white)
                labels.addChildNode(node); countryLabels.append((country.rank, node))
            }
            for city in EarthBaseData.cities {
                let node = labelNode("• " + city.name, at: city.point, color: .init(white: 0.9, alpha: 1))
                cities.addChildNode(node); cityLabels.append((city.rank, node))
            }
            parks.addChildNode(lineNode(borderSegments(EarthBaseData.parkBoundaries), color: NSColor(srgbRed: 0.35, green: 0.95, blue: 0.5, alpha: 0.9), radius: 1.003))
            roads.addChildNode(lineNode(borderSegments(EarthBaseData.roads), color: NSColor(srgbRed: 1, green: 0.73, blue: 0.42, alpha: 0.85), radius: 1.002))
            water.addChildNode(lineNode(borderSegments(EarthBaseData.water), color: NSColor(srgbRed: 0.3, green: 0.8, blue: 1, alpha: 0.9), radius: 1.002))
            sunlight.light = SCNLight(); sunlight.light?.type = .directional; sunlight.light?.intensity = 1100
            ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 130
            archive.renderingOrder = -1
            archive.geometry = Self.earthMesh(); archive.scale = SCNVector3(1.0005, 1.0005, 1.0005)
            let archiveMaterial = SCNMaterial(); archiveMaterial.lightingModel = .constant; archiveMaterial.writesToDepthBuffer = false; archiveMaterial.readsFromDepthBuffer = false; archiveMaterial.blendMode = .alpha
            archive.geometry?.materials = [archiveMaterial]
            clouds.geometry = Self.earthMesh()
            let cloudMaterial = SCNMaterial(); cloudMaterial.lightingModel = .constant; cloudMaterial.transparency = 0.6
            cloudMaterial.writesToDepthBuffer = false; clouds.geometry?.materials = [cloudMaterial]; clouds.scale = SCNVector3(1.006, 1.006, 1.006)
        }
        func borderSegments(_ outlines: [[GeoPoint]]) -> [GeoPoint] {
            var segments: [GeoPoint] = []
            for line in outlines { for (a, b) in zip(line, line.dropFirst()) {
                let count = max(1, Int(GeoMath.distance(a, b) / 100_000) + 1)
                let dl = GeoMath.normalizedLongitude(b.longitude - a.longitude)
                for i in 0..<count {
                    let t = Double(i) / Double(count), u = Double(i + 1) / Double(count)
                    segments += [.init(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + dl * t), .init(latitude: a.latitude + (b.latitude - a.latitude) * u, longitude: a.longitude + dl * u)]
                }
            } }
            return segments
        }
        static func earthMesh(terrain: Bool = false) -> SCNGeometry {
            let rows = terrain ? 360 : 90, columns = terrain ? 720 : 180
            var positions: [SCNVector3] = [], uv: [CGPoint] = [], indices: [Int32] = []
            for row in 0...rows {
                let v = Double(row) / Double(rows)
                for column in 0...columns {
                    let u = Double(column) / Double(columns)
                    let point = GeoPoint(latitude: 90 - v * 180, longitude: u * 360 - 180)
                    let radius = Float(1 + (terrain ? EarthTerrain.elevation(point) / GeoMath.radius : 0))
                    positions.append(spherePosition(point, radius: radius))
                    uv.append(CGPoint(x: u, y: v))
                }
            }
            for row in 0..<rows { for column in 0..<columns {
                let a = Int32(row * (columns + 1) + column), b = a + Int32(columns + 1)
                indices += [a, b, b + 1, a, b + 1, a + 1]
            } }
            var normals = positions
            if terrain {
                for row in 1..<rows { for col in 0...columns {
                    let west = positions[row * (columns + 1) + (col == 0 ? columns - 1 : col - 1)]
                    let east = positions[row * (columns + 1) + (col == columns ? 1 : col + 1)]
                    let north = positions[(row - 1) * (columns + 1) + col], south = positions[(row + 1) * (columns + 1) + col]
                    let e = SIMD3<Float>(Float(east.x - west.x), Float(east.y - west.y), Float(east.z - west.z))
                    let n = SIMD3<Float>(Float(north.x - south.x), Float(north.y - south.y), Float(north.z - south.z))
                    let normal = simd_normalize(simd_cross(e, n)); normals[row * (columns + 1) + col] = SCNVector3(normal.x, normal.y, normal.z)
                } }
            }
            return SCNGeometry(sources: [.init(vertices: positions), .init(normals: normals), .init(textureCoordinates: uv)], elements: [.init(indices: indices, primitiveType: .triangles)])
        }
        func makeStars() {
            var positions: [SCNVector3] = []
            for i in 0..<900 {
                let y = 1 - 2 * (Float(i) + 0.5) / 900
                let angle = Float(i) * 2.3999632, r = sqrt(1 - y * y)
                positions.append(.init(70 * r * cos(angle), 70 * y, 70 * r * sin(angle)))
            }
            let element = SCNGeometryElement(indices: Array(0..<Int32(positions.count)), primitiveType: .point)
            element.pointSize = 1.2; element.minimumPointScreenSpaceRadius = 0.4; element.maximumPointScreenSpaceRadius = 1
            let geometry = SCNGeometry(sources: [.init(vertices: positions)], elements: [element])
            let material = SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents = NSColor(white: 0.6, alpha: 1); geometry.materials = [material]
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        }
        func makeGrid() {
            var lines: [GeoPoint] = []
            for lon in stride(from: -180, to: 180, by: 15) {
                for lat in stride(from: -90, to: 90, by: 3) { lines += [.init(latitude: Double(lat), longitude: Double(lon)), .init(latitude: Double(lat + 3), longitude: Double(lon))] }
            }
            for lat in stride(from: -75, through: 75, by: 15) {
                for lon in stride(from: -180, to: 180, by: 3) { lines += [.init(latitude: Double(lat), longitude: Double(lon)), .init(latitude: Double(lat), longitude: Double(lon + 3))] }
            }
            grid.addChildNode(lineNode(lines, color: NSColor.white.withAlphaComponent(0.25), radius: 1.002))
        }
        func lineNode(_ segments: [GeoPoint], color: NSColor, radius: Float = 1.005, grounded: Bool = false) -> SCNNode {
            let points = segments.map { point in
                spherePosition(point, radius: grounded ? Float(1 + ((store.terrain ? EarthTerrain.elevation(point) : 0) + 3) / GeoMath.radius) : radius)
            }
            let geometry = SCNGeometry(sources: [.init(vertices: points)], elements: [.init(indices: Array(0..<Int32(points.count)), primitiveType: .line)])
            let material = SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents = color; material.isDoubleSided = true
            geometry.materials = [material]; return SCNNode(geometry: geometry)
        }
        func draw(_ feature: EarthFeature, grounded: Bool = false) {
            let color = NSColor(earthHex: feature.color)
            if feature.kind == .point {
                let node = SCNNode()
                node.name = "feature:" + feature.id.uuidString
                let artwork = SCNNode(geometry: SCNPlane(width: 40, height: 48))
                artwork.name = node.name
                node.addChildNode(artwork)
                let material = SCNMaterial(); material.lightingModel = .constant
                let pinImage = EarthPinAppearance.image(feature)
                var imageRect = NSRect(origin: .zero, size: pinImage.size)
                material.diffuse.contents = pinImage.cgImage(forProposedRect: &imageRect, context: nil, hints: nil)
                material.isDoubleSided = true
                material.writesToDepthBuffer = false
                artwork.geometry?.materials = [material]
                let anchor = EarthPinAppearance.anchor(feature)
                artwork.pivot = SCNMatrix4MakeTranslation(0, 24 - anchor.y, 0)
                node.constraints = [SCNBillboardConstraint()]
                let elevation = store.terrain ? max(0, EarthTerrain.sampledElevation(feature.center) ?? 0) : 0
                node.position = spherePosition(feature.center, radius: Float(1 + elevation / GeoMath.radius + 0.000005))
                overlay.addChildNode(node)
            } else {
                var points = feature.points
                if feature.kind == .polygon, let first = points.first { points.append(first) }
                var segments: [GeoPoint] = []
                for (a, b) in zip(points, points.dropFirst()) {
                    let dl = GeoMath.normalizedLongitude(b.longitude - a.longitude)
                    let count = max(1, min(180, Int(GeoMath.distance(a, b) / 80_000) + 1))
                    for i in 0..<count {
                        let t1 = Double(i) / Double(count), t2 = Double(i + 1) / Double(count)
                        segments += [.init(latitude: a.latitude + (b.latitude - a.latitude) * t1, longitude: a.longitude + dl * t1), .init(latitude: a.latitude + (b.latitude - a.latitude) * t2, longitude: a.longitude + dl * t2)]
                    }
                }
                overlay.addChildNode(lineNode(segments, color: color, grounded: grounded))
            }
        }
        func labelNode(_ title: String, at point: GeoPoint, color: NSColor) -> SCNNode {
            let font = NSFont.systemFont(ofSize: 20, weight: .medium)
            let size = (title as NSString).size(withAttributes: [.font: font])
            let image = NSImage(size: NSSize(width: size.width + 12, height: 32), flipped: false) { rect in
                NSColor.black.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                (title as NSString).draw(at: NSPoint(x: 6, y: 4), withAttributes: [.font: font, .foregroundColor: color]); return true
            }
            let plane = SCNPlane(width: 0.024 * image.size.width / image.size.height, height: 0.024)
            let material = SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents = image
            material.isDoubleSided = true; plane.materials = [material]
            let node = SCNNode(geometry: plane); node.position = spherePosition(point, radius: 1.012)
            node.constraints = [SCNBillboardConstraint()]; return node
        }
        func updateLayers(_ view: InteractiveGlobe) {
            if lastTerrain != store.terrain {
                lastTerrain = store.terrain
                let material = earth.geometry?.firstMaterial
                earth.geometry = store.terrain ? reliefEarth : flatEarth
                if let material { earth.geometry?.materials = [material] }
            }
            archive.isHidden = !store.historicalImagery || store.archiveImage == nil
            if archive.geometry?.firstMaterial?.diffuse.contents as? NSImage !== store.archiveImage { archive.geometry?.firstMaterial?.diffuse.contents = store.archiveImage }
            let lighting: SCNMaterial.LightingModel = store.sunlight ? .lambert : .constant
            scene.rootNode.childNode(withName: "earth", recursively: false)?.geometry?.firstMaterial?.lightingModel = lighting
            archive.geometry?.firstMaterial?.lightingModel = lighting
            sunlight.isHidden = !store.sunlight; ambient.isHidden = !store.sunlight
            sunlight.position = spherePosition(EarthObservation.sunPoint(at: store.sunlightDate), radius: 10)
            sunlight.look(at: SCNVector3Zero)
            let enabled = store.layers.enabled
            borders.isHidden = enabled["borders"] != true; labels.isHidden = enabled["labels"] != true; cities.isHidden = enabled["places"] != true
            roads.isHidden = enabled["roads"] != true || store.distance > 6_000_000
            water.isHidden = enabled["water"] != true
            parks.isHidden = enabled["parks"] != true
            let detail = store.distance < 6_000_000
            var occupied: [CGRect] = []
            func showLabel(_ node: SCNNode, rank: Int, limit: Int, enabled: Bool) {
                let normal = simd_normalize(node.simdPosition)
                guard enabled, rank <= limit, simd_dot(normal, camera.simdPosition - node.simdPosition) > 0.2,
                      let plane = node.geometry as? SCNPlane else { node.isHidden = true; return }
                let projected = view.projectPoint(node.position)
                let depth = Double(simd_distance(camera.simdPosition, node.simdPosition))
                let scale = Double(view.bounds.height) / max(0.01, 2 * tan(19 * .pi / 180) * depth)
                let width = Double(plane.width) * scale, height = Double(plane.height) * scale
                let rect = CGRect(x: Double(projected.x) - width / 2, y: Double(projected.y) - height / 2, width: width, height: height).insetBy(dx: -3, dy: -2)
                node.isHidden = occupied.contains { $0.intersects(rect) }
                if !node.isHidden { occupied.append(rect) }
            }
            for (rank, node) in countryLabels.sorted(by: { $0.0 < $1.0 }) { showLabel(node, rank: rank, limit: detail ? 6 : 3, enabled: enabled["labels"] == true) }
            for (rank, node) in cityLabels.sorted(by: { $0.0 < $1.0 }) { showLabel(node, rank: rank, limit: detail ? 5 : 1, enabled: enabled["places"] == true) }
            clouds.isHidden = enabled["clouds"] != true || store.cloudImage == nil
            if lastLayerRevision != store.layerRevision {
                lastLayerRevision = store.layerRevision; clouds.geometry?.firstMaterial?.diffuse.contents = store.cloudImage
            }
            let items = store.visibleLayerItems
            if lastLayerItems != items {
                lastLayerItems = items; dataMarkers.childNodes.forEach { $0.removeFromParentNode() }; layerNodes = []
                for item in items {
                    let sphere = SCNSphere(radius: 0.008); sphere.segmentCount = 8
                    let node = SCNNode(geometry: sphere); node.name = "layer:" + item.id
                    let material = SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents = NSColor(earthHex: item.color)
                    node.geometry?.materials = [material]; node.position = spherePosition(item.point, radius: 1.016); dataMarkers.addChildNode(node); layerNodes.append((item, node))
                }
            }
            let markerScale = Float(max(0.000002, min(0.012, store.distance / GeoMath.radius * 0.004)) / 0.008)
            for (item, node) in layerNodes {
                node.scale = SCNVector3(markerScale, markerScale, markerScale)
                node.isHidden = (item.kind == .park || item.kind == .airport) && (store.distance > 6_000_000 || GeoMath.distance(store.center, item.point) > store.distance)
            }
        }
        func updatePublicData() {
            guard publicDataRevision != store.publicDataRevision || publicDataTerrain != store.terrain else { return }
            publicDataRevision = store.publicDataRevision; publicDataTerrain = store.terrain
            publicDataRoot.childNodes.forEach { $0.removeFromParentNode() }; publicDataSegments.removeAll()
            publicDataBuild?.cancel()
            let features = store.publicDataFeatures, terrain = store.terrain, revision = store.publicDataRevision
            let build = Task.detached(priority: .utility) { () -> [(PublicDataFeature, [SCNVector3])] in
                var result: [(PublicDataFeature, [SCNVector3])] = []
                for feature in features {
                    guard !Task.isCancelled else { return [] }
                    var segments: [SCNVector3] = []
                    for ring in feature.rings {
                        let points = PublicDataGeometry.closed(ring).map { point in
                            let elevation = terrain ? EarthTerrain.elevation(point) : 0
                            return spherePosition(point, radius: Float(1 + (elevation + 3) / GeoMath.radius))
                        }
                        for (a, b) in zip(points, points.dropFirst()) { segments += [a, b] }
                    }
                    result.append((feature, segments))
                }
                return result
            }
            publicDataBuild = build
            Task { [weak self] in
                let segments = await build.value
                guard let self, !build.isCancelled, self.publicDataRevision == revision, self.publicDataTerrain == terrain else { return }
                self.publicDataSegments = segments
                self.publicDataBuild = nil
                for kind in PublicDataKind.allCases {
                    let positions = segments.filter { $0.0.kind == kind }.flatMap { $0.1 }
                    guard !positions.isEmpty else { continue }
                    let geometry = SCNGeometry(sources: [.init(vertices: positions)], elements: [.init(indices: Array(0..<Int32(positions.count)), primitiveType: .line)])
                    let material = SCNMaterial(); material.lightingModel = .constant
                    material.diffuse.contents = NSColor(earthHex: PublicDataSource.source(kind).color).withAlphaComponent(self.store.publicDataOpacity[kind] ?? 0.9)
                    material.writesToDepthBuffer = false; material.isDoubleSided = true
                    geometry.materials = [material]
                    let node = SCNNode(geometry: geometry); node.renderingOrder = 10
                    self.publicDataRoot.addChildNode(node)
                }
            }
        }
        func pickPublicData(at point: NSPoint, in view: SCNView) -> Bool {
            var closest: PublicDataFeature?, best: CGFloat = 36
            let camera = camera.presentation.simdWorldPosition
            for (feature, segments) in publicDataSegments where segments.count > 1 {
                for index in stride(from: 0, to: segments.count - 1, by: 2) {
                    let a = segments[index], b = segments[index + 1]
                    let normal = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
                    guard simd_dot(normal, camera - normal) > 0 else { continue }
                    let pa = view.projectPoint(a), pb = view.projectPoint(b)
                    guard (0...1).contains(pa.z), (0...1).contains(pb.z) else { continue }
                    let distance = PublicDataGeometry.squaredDistance(point, to: CGPoint(x: CGFloat(pa.x), y: CGFloat(pa.y)), CGPoint(x: CGFloat(pb.x), y: CGFloat(pb.y)))
                    if distance < best { best = distance; closest = feature }
                }
            }
            guard let closest else { return false }
            store.showPublicDataDetails(closest); return true
        }
        func update(_ view: InteractiveGlobe) {
            if store.publicDataViewSize != view.bounds.size {
                let size = view.bounds.size
                DispatchQueue.main.async { [weak store] in if size.width > 1 && size.height > 1 { store?.publicDataViewSize = size } }
            }
            updatePublicData()
            if lastCamera != store.cameraRequest {
                let initial = lastCamera == nil; lastCamera = store.cameraRequest
                SCNTransaction.begin(); SCNTransaction.animationDuration = initial || view.dragging || store.navigationIsActive ? 0 : 0.6
                let surfaceRadius = Float(1 + (store.terrain ? EarthTerrain.elevation(store.center) / GeoMath.radius : 0))
                let target = spherePosition(store.center, radius: surfaceRadius)
                let lat = Float(store.latitude * .pi / 180), lon = Float(store.longitude * .pi / 180)
                let h = Float(store.heading * .pi / 180), p = Float(store.pitch * .pi / 180)
                let north = SIMD3<Float>(-sin(lat) * sin(lon), cos(lat), -sin(lat) * cos(lon))
                let east = SIMD3<Float>(cos(lon), 0, -sin(lon))
                let targetPosition = SIMD3<Float>(Float(target.x), Float(target.y), Float(target.z))
                let radial = simd_normalize(targetPosition)
                let forward = north * cos(h) + east * sin(h)
                let range = Float(store.distance / GeoMath.radius)
                camera.camera?.zNear = max(0.0000001, min(0.01, Double(range) * 0.01))
                camera.simdPosition = targetPosition + range * (radial * cos(p) - forward * sin(p))
                let up = radial * sin(p) + forward * cos(p)
                camera.look(at: target, up: SCNVector3(up.x, up.y, up.z), localFront: SCNVector3(0, 0, -1))
                SCNTransaction.commit()
            }
            if imageGround.parent == nil { scene.rootNode.addChildNode(imageGround) }
            if lastImages != store.imageOverlayRevision || lastImageTerrain != store.terrain {
                lastImages=store.imageOverlayRevision; lastImageTerrain=store.terrain
                imageGround.childNodes.forEach{$0.removeFromParentNode()}
                for item in store.imageOverlays where item.isVisible { if let node=item.globeNode(terrain:store.terrain) { imageGround.addChildNode(node) } }
            }
            if store.mode == .globe, view.bounds.width > 1, view.bounds.height > 1, let source = store.activeGlobeImagery {
                imageryTiles.update(source: source, revision: store.imageryTileRevision, center: store.center, distance: store.distance, pitch: store.pitch, size: view.bounds.size, terrain: store.terrain)
            }
            updateLayers(view)
            grid.isHidden = !store.grid || !store.layers.primary
            let visible = store.renderedFeatures
            if drawn != visible || vertices != store.vertices || lastSelection != store.selection || lastTool != store.tool || lastCustomTerrain != store.terrain {
                lastCustomTerrain = store.terrain
                drawn = visible; vertices = store.vertices; lastSelection = store.selection; lastTool = store.tool
                overlay.childNodes.forEach { $0.removeFromParentNode() }
                let customIDs = Set(store.customDataFeatures.map(\.id))
                visible.forEach { draw($0, grounded: customIDs.contains($0.id)) }
                if !store.vertices.isEmpty {
                    draw(.init(name: "Drawing", kind: store.tool == .polygon && store.vertices.count > 2 ? .polygon : .path, points: store.vertices))
                    for point in store.vertices { draw(.init(name: "Vertex", kind: .point, points: [point])) }
                }
            }
            // Keep placemarks legible while zooming, without raising them above their coordinates.
            for node in overlay.childNodes where node.name?.hasPrefix("feature:") == true {
                let range = simd_distance(camera.presentation.simdWorldPosition, node.simdWorldPosition)
                let scale = range * 2 * tan(Float(38 * Double.pi / 360)) / Float(view.bounds.height > 1 ? view.bounds.height : 800)
                node.childNodes.first?.scale = SCNVector3(scale, scale, scale)
            }
        }
    }
}
