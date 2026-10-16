import AppKit
import MapKit
import SceneKit

final class EarthGroundImage: NSObject, MKOverlay {
    let item: EarthImageOverlay
    let image: CGImage
    var coordinate: CLLocationCoordinate2D { item.center.coordinate }
    var boundingMapRect: MKMapRect {
        // Date-line overlays are drawn in their nearest wrapped world copy by MapKit.
        let points = [(0.0,0.0),(1,0),(0,1),(1,1)].map { mapPoint(u:$0.0,v:$0.1) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return MKMapRect(x:xs.min()!, y:ys.min()!, width:xs.max()!-xs.min()!, height:ys.max()!-ys.min()!)
    }
    func mapPoint(u: Double, v: Double) -> MKMapPoint {
        let p = MKMapPoint(item.point(u:u,v:v).coordinate), c = MKMapPoint(item.center.coordinate)
        var x = p.x
        if x-c.x > MKMapRect.world.width/2 { x -= MKMapRect.world.width }
        if x-c.x < -MKMapRect.world.width/2 { x += MKMapRect.world.width }
        return MKMapPoint(x:x,y:p.y)
    }
    init?(_ item: EarthImageOverlay) {
        guard let image = NSImage(data:item.imageData)?.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return nil }
        self.item = item; self.image = image
    }
}
final class EarthGroundImageRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let ground = overlay as? EarthGroundImage else { return }
        let n = 12, w = Double(ground.image.width), h = Double(ground.image.height)
        context.setAlpha(ground.item.opacity); context.interpolationQuality = .high
        // A triangle mesh follows Mercator projection and supports rotated, georeferenced images.
        func triangle(_ uv: [(Double,Double)]) {
            let p = uv.map { point(for:ground.mapPoint(u:$0.0,v:$0.1)) }
            let s = uv.map { CGPoint(x:$0.0*w,y:$0.1*h) }
            let dx1=s[1].x-s[0].x, dy1=s[1].y-s[0].y, dx2=s[2].x-s[0].x, dy2=s[2].y-s[0].y
            let det=dx1*dy2-dx2*dy1
            let a=((p[1].x-p[0].x)*dy2-(p[2].x-p[0].x)*dy1)/det
            let c=(dx1*(p[2].x-p[0].x)-dx2*(p[1].x-p[0].x))/det
            let b=((p[1].y-p[0].y)*dy2-(p[2].y-p[0].y)*dy1)/det
            let d=(dx1*(p[2].y-p[0].y)-dx2*(p[1].y-p[0].y))/det
            context.saveGState(); context.beginPath(); context.move(to:p[0]); context.addLine(to:p[1]); context.addLine(to:p[2]); context.closePath(); context.clip()
            context.concatenate(CGAffineTransform(a:a,b:b,c:c,d:d,tx:p[0].x-a*s[0].x-c*s[0].y,ty:p[0].y-b*s[0].x-d*s[0].y))
            context.draw(ground.image,in:CGRect(x:0,y:0,width:w,height:h)); context.restoreGState()
        }
        for y in 0..<n { for x in 0..<n {
            let u=Double(x)/Double(n), v=Double(y)/Double(n), du=Double(x+1)/Double(n), dv=Double(y+1)/Double(n)
            triangle([(u,v),(du,v),(du,dv)]); triangle([(u,v),(du,dv),(u,dv)])
        }}
    }
}

extension EarthImageOverlay {
    @MainActor func globeNode(terrain: Bool) -> SCNNode? {
        guard let image = NSImage(data:imageData) else { return nil }
        let n = 32
        var positions:[SCNVector3]=[], uv:[CGPoint]=[], indices:[Int32]=[]
        for y in 0...n { for x in 0...n {
            let u=Double(x)/Double(n), v=Double(y)/Double(n), p=point(u:u,v:v)
            let lat=p.latitude * .pi/180, lon=p.longitude * .pi/180
            let r=1.0008 + (terrain ? EarthTerrain.elevation(p)/GeoMath.radius : 0)
            positions.append(SCNVector3(r*cos(lat)*sin(lon),r*sin(lat),r*cos(lat)*cos(lon)))
            uv.append(CGPoint(x:u,y:1-v))
        }}
        for y in 0..<n { for x in 0..<n {
            let a=Int32(y*(n+1)+x), b=a+1, c=a+Int32(n+1), d=c+1
            indices += [a,b,c,b,d,c]
        }}
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:positions),SCNGeometrySource(textureCoordinates:uv)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        let material=SCNMaterial(); material.diffuse.contents=image; material.lightingModel = .constant; material.isDoubleSided=true
        material.transparency=opacity; material.writesToDepthBuffer=false
        geometry.materials=[material]; let node=SCNNode(geometry:geometry); node.renderingOrder=1; return node
    }
}
