import SceneKit
import AppKit

/// One bounded tile queue per globe. Coarse ancestors stay until fine tiles arrive.
@MainActor final class GlobeImageryTiles {
    let root = SCNNode()
    private var revision: UUID?
    private var source: ImagerySource?
    private var terrain = false
    private var nodes: [ImageryTile: SCNNode] = [:]
    private var order: [ImageryTile] = []
    private var wanted: Set<ImageryTile> = []
    private var queue: [ImageryTile] = []
    private var tasks: [ImageryTile: Task<Void, Never>] = [:]
    private var failed: Set<ImageryTile> = []
    private var epoch = UUID()
    var report: ((String) -> Void)?
    deinit { tasks.values.forEach { $0.cancel() } }
    func update(source next: ImagerySource, revision: UUID, center: GeoPoint, distance: Double, pitch: Double, size: CGSize, terrain: Bool) {
        if source != next || self.terrain != terrain || self.revision != revision {
            self.revision = revision
            epoch = UUID(); tasks.values.forEach { $0.cancel() }; tasks = [:]; queue = []; failed = []
            root.childNodes.forEach { $0.removeFromParentNode() }; nodes = [:]; order = []
            source = next; self.terrain = terrain
        }
        let plan = ImageryTile.visible(center: center, distance: distance, pitch: pitch, width: size.width * 2, height: size.height * 2, maxZoom: next.maxZoom)
        let desired = Set(plan)
        guard desired != wanted || (nodes.isEmpty && tasks.isEmpty && failed.isEmpty) else { return }
        wanted = desired
        for (tile, task) in tasks where !desired.contains(tile) { task.cancel(); tasks.removeValue(forKey: tile) }
        queue = plan.filter { nodes[$0] == nil && tasks[$0] == nil && !failed.contains($0) }
        for tile in plan where nodes[tile] != nil { order.removeAll { $0 == tile }; order.append(tile) }
        // Protect current ancestors; bound residency as the camera moves.
        while nodes.count > 220, let old = order.first(where: { !desired.contains($0) }) {
            nodes.removeValue(forKey: old)?.removeFromParentNode(); order.removeAll { $0 == old }
        }
        pump()
    }
    private func pump() {
        guard let source else { return }
        if tasks.isEmpty && !queue.isEmpty { report?("Refining imagery…") }
        while tasks.count < 6, !queue.isEmpty {
            let tile = queue.removeFirst(), token = epoch, terrain = self.terrain
            tasks[tile] = Task { [weak self] in
                do {
                    let data = try await ImageryTransport.shared.data(source.url(tile))
                    let image = await Task.detached(priority: .utility) { ImageryTransport.image(data) }.value
                    try Task.checkCancellation()
                    guard let self, self.epoch == token, self.wanted.contains(tile) else { return }
                    if let image {
                        let node = Self.node(tile, image: image, terrain: terrain)
                        self.root.addChildNode(node); self.nodes[tile] = node; self.order.append(tile)
                    } else { self.failed.insert(tile) }
                } catch {
                    if let self, self.epoch == token, !Task.isCancelled { self.failed.insert(tile) }
                }
                guard let self, self.epoch == token else { return }
                self.tasks.removeValue(forKey: tile)
                self.report?(self.queue.isEmpty && self.tasks.isEmpty ? (self.failed.intersection(self.wanted).isEmpty ? "Visible imagery loaded" : "Some tiles unavailable · Showing available imagery") : "Refining imagery…")
                self.pump()
            }
        }
    }
    private static func node(_ tile: ImageryTile, image: CGImage, terrain: Bool) -> SCNNode {
        let count = max(16, 64 >> min(tile.z, 2))
        var vertices: [SCNVector3] = [], uv: [CGPoint] = [], indices: [Int32] = []
        for row in 0...count { for col in 0...count {
            let u = Double(col) / Double(count), v = Double(row) / Double(count)
            let point = GeoPoint(latitude: tile.latitude(v), longitude: tile.west + (tile.east - tile.west) * u)
            let lat = point.latitude * .pi / 180, lon = point.longitude * .pi / 180
            let radius = 1 + (terrain ? EarthTerrain.elevation(point) / GeoMath.radius : 0)
            vertices.append(.init(radius * cos(lat) * sin(lon), radius * sin(lat), radius * cos(lat) * cos(lon)))
            uv.append(.init(x: u, y: v))
        } }
        for row in 0..<count { for col in 0..<count {
            let a = Int32(row * (count + 1) + col), b = a + Int32(count + 1)
            indices += [a, b, b + 1, a, b + 1, a + 1]
        } }
        let geometry = SCNGeometry(sources: [.init(vertices: vertices), .init(textureCoordinates: uv)], elements: [.init(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents = image
        material.diffuse.minificationFilter = .linear; material.diffuse.magnificationFilter = .linear; material.diffuse.mipFilter = .linear; material.diffuse.maxAnisotropy = 8
        material.readsFromDepthBuffer = false; material.writesToDepthBuffer = false; geometry.materials = [material]
        let node = SCNNode(geometry: geometry); node.renderingOrder = -100 + tile.z
        return node
    }
}
