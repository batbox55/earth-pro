import AppKit
import SceneKit

/// A bounded geographic texture mesh preserves concavity and holes without costly
/// camera-time triangulation. Prepared on a utility task and reused while navigating.
enum GlobePolygonFill {
    static func node(_ feature: EarthFeature, terrain: Bool, size: Int = 512, maxSegments: Int = 64) -> SCNNode? {
        let style = feature.vectorStyle ?? VectorStyle(fill:feature.color,fillOpacity:0.2)
        guard style.fillOpacity > 0, feature.points.count >= 3, let first = feature.points.first else { return nil }
        let rings = [feature.points] + (feature.holes ?? [])
        let points = rings.flatMap { $0 }
        let west = points.map { GeoMath.normalizedLongitude($0.longitude-first.longitude) }.min() ?? 0
        let east = points.map { GeoMath.normalizedLongitude($0.longitude-first.longitude) }.max() ?? 0
        let south = points.map(\.latitude).min() ?? 0, north = points.map(\.latitude).max() ?? 0
        let width = east-west, height = north-south
        guard width > 0, height > 0, width <= 180 else { return nil }
        guard let context = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setAllowsAntialiasing(true)
        for ring in rings {
            for (index,p) in ring.enumerated() {
                let point = CGPoint(x:(GeoMath.normalizedLongitude(p.longitude-first.longitude)-west)/width*Double(size), y:(p.latitude-south)/height*Double(size))
                if index == 0 { context.move(to:point) } else { context.addLine(to:point) }
            }
            context.closePath()
        }
        context.setFillColor(NSColor(earthHex:style.fill).withAlphaComponent(style.fillOpacity).cgColor)
        context.drawPath(using:.eoFill)
        guard let image = context.makeImage() else { return nil }
        let columns = min(maxSegments,max(2,Int(ceil(width/0.05)))), rows = min(maxSegments,max(2,Int(ceil(height/0.05))))
        let cellAngle = hypot(width/Double(columns),height/Double(rows)) * .pi/180
        let chordLift = GeoMath.radius * (1-cos(cellAngle/2))
        var positions: [SCNVector3] = [], texture: [CGPoint] = [], indices: [Int32] = []
        for y in 0...rows {
            for x in 0...columns {
                let u = Double(x)/Double(columns), v = Double(y)/Double(rows)
                let lat = south+v*height, lon = GeoMath.normalizedLongitude(first.longitude+west+u*width)
                let point = GeoPoint(latitude:lat,longitude:lon)
                let elevation = terrain ? EarthTerrain.elevation(point) : 0
                // Patch cells follow the same globe surface; tiny lift avoids z-fighting.
                positions.append(spherePosition(point,radius:Float(1+(elevation+5+chordLift)/GeoMath.radius)))
                texture.append(CGPoint(x:u,y:v))
                if x < columns && y < rows {
                    let a = Int32(y*(columns+1)+x), b = a+1, c = a+Int32(columns+1), d = c+1
                    indices += [a,b,c,b,d,c]
                }
            }
        }
        let geometry = SCNGeometry(sources:[.init(vertices:positions),.init(textureCoordinates:texture)],elements:[.init(indices:indices,primitiveType:.triangles)])
        let material = SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents = image
        material.isDoubleSided = true; material.writesToDepthBuffer = false; material.transparencyMode = .aOne
        geometry.materials = [material]
        let node = SCNNode(geometry:geometry); node.renderingOrder = 2; return node
    }
}
