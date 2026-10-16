import AppKit

/// Load the shared artwork explicitly because this SwiftPM app bundles loose image resources.
enum EarthBrand {
    static let icon: NSImage = {
        if let url = Bundle.module.url(forResource: "EarthProIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "globe.americas.fill", accessibilityDescription: "Earth Pro") ?? NSImage(size: NSSize(width: 32, height: 32))
    }()
}
