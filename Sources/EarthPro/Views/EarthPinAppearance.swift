import AppKit

/// One marker artwork shared by the native maps, globe, and Google renderers.
@MainActor
enum EarthPinAppearance {
    static let size = NSSize(width: 40, height: 48)
    private static let images = NSCache<NSString, NSImage>()
    private static let urls = NSCache<NSString, NSString>()
    private static func key(_ feature: EarthFeature) -> NSString {
        "\(feature.color)|\(feature.resolvedPinShape.rawValue)|\(feature.resolvedPinIcon.rawValue)" as NSString
    }
    static func anchor(_ feature: EarthFeature) -> NSPoint {
        NSPoint(x: 20, y: feature.resolvedPinShape == .pin ? 45 : 23)
    }
    static func image(_ feature: EarthFeature) -> NSImage {
        let key = key(feature)
        if let cached = images.object(forKey: key) { return cached }
        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 5, y: 10, width: 30, height: 30)
            let shape: NSBezierPath
            switch feature.resolvedPinShape {
            case .pin:
                shape = NSBezierPath()
                shape.move(to: NSPoint(x: 20, y: 3))
                shape.curve(to: NSPoint(x: 5, y: 28), controlPoint1: NSPoint(x: 15, y: 12), controlPoint2: NSPoint(x: 5, y: 18))
                shape.curve(to: NSPoint(x: 35, y: 28), controlPoint1: NSPoint(x: 5, y: 47), controlPoint2: NSPoint(x: 35, y: 47))
                shape.curve(to: NSPoint(x: 20, y: 3), controlPoint1: NSPoint(x: 35, y: 18), controlPoint2: NSPoint(x: 25, y: 12))
                shape.close()
            case .circle: shape = NSBezierPath(ovalIn: body)
            case .square: shape = NSBezierPath(roundedRect: body, xRadius: 5, yRadius: 5)
            case .diamond:
                shape = NSBezierPath()
                for (index, point) in [NSPoint(x: 20, y: 43), NSPoint(x: 38, y: 25), NSPoint(x: 20, y: 7), NSPoint(x: 2, y: 25)].enumerated() {
                    if index == 0 { shape.move(to: point) } else { shape.line(to: point) }
                }
                shape.close()
            }
            NSColor(earthHex: feature.color).setFill(); shape.fill()
            NSColor.white.setStroke(); shape.lineWidth = 1.8; shape.stroke()
            if let symbol = NSImage(systemSymbolName: feature.resolvedPinIcon.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) {
                let tinted = NSImage(size: symbol.size)
                tinted.lockFocus(); NSColor.white.set(); symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.white.setFill(); NSRect(origin: .zero, size: symbol.size).fill(using: .sourceIn); tinted.unlockFocus()
                let scale = min(16 / symbol.size.width, 16 / symbol.size.height)
                let width = symbol.size.width * scale, height = symbol.size.height * scale
                let centerY: CGFloat = feature.resolvedPinShape == .pin ? 28 : 25
                tinted.draw(in: NSRect(x: 20 - width / 2, y: centerY - height / 2, width: width, height: height))
            }
            return true
        }
        // SceneKit must receive raster pixels; it can evaluate lazy drawing handlers on its render thread.
        let raster: NSImage
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let cgImage = bitmap.cgImage {
            raster = NSImage(cgImage: cgImage, size: size)
        } else { raster = image }
        images.setObject(raster, forKey: key); return raster
    }
    static func dataURL(_ feature: EarthFeature) -> String {
        let key = key(feature)
        if let cached = urls.object(forKey: key) { return cached as String }
        guard let tiff = image(feature).tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return "" }
        let url = "data:image/png;base64," + png.base64EncodedString()
        urls.setObject(url as NSString, forKey: key); return url
    }
}
