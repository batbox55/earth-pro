import AppKit
import SwiftUI

/// The ring owns one stationary tracking surface, so the moving N never loses the drag.
struct EarthCompassControl: NSViewRepresentable {
    let store: EarthStore
    func makeNSView(context: Context) -> EarthCompassView { EarthCompassView(frame: .zero) }
    func updateNSView(_ view: EarthCompassView, context: Context) {
        view.store = store
        view.heading = store.heading
    }
    static func dismantleNSView(_ view: EarthCompassView, coordinator: ()) {
        view.cancelTracking(); view.store = nil
    }
}

@MainActor final class EarthCompassView: NSView {
    weak var store: EarthStore?
    var heading = 0.0 { didSet { needsDisplay = true; setAccessibilityValue("\(Int(heading.rounded())) degrees") } }
    private var start = NSPoint.zero
    private var lastAngle = 0.0
    private var moved = false
    private var request: UUID?
    private var mode: ViewMode?
    private var provider: MapProvider?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("N")
        toolTip = "Click to reset north; drag N or the compass ring to rotate"
        setAccessibilityHelp(toolTip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let angle = -heading * .pi / 180, radius = min(bounds.width, bounds.height) / 2 - 6
        let point = NSPoint(x: bounds.midX + sin(angle) * radius, y: bounds.midY - cos(angle) * radius)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: NSColor.labelColor]
        let size = ("N" as NSString).size(withAttributes: attributes)
        ("N" as NSString).draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attributes)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let radius = hypot(local.x - bounds.midX, local.y - bounds.midY)
        // Leave the center available to the look pad, with a generous ring hit area.
        let outerRadius = min(bounds.width, bounds.height) / 2
        return !isHidden && radius >= outerRadius - 9 && radius <= outerRadius + 1 ? self : nil
    }
    private func angle(at point: NSPoint) -> Double? {
        let dx = point.x - bounds.midX, dy = bounds.midY - point.y
        guard hypot(dx, dy) >= 10 else { return nil }
        return atan2(dx, dy) * 180 / .pi
    }
    override func mouseDown(with event: NSEvent) {
        guard let store else { return }
        cancelTracking(); store.stopTour()
        start = convert(event.locationInWindow, from: nil)
        guard let angle = angle(at: start) else { return }
        lastAngle = angle; moved = false
        request = store.cameraRequest; mode = store.mode; provider = store.provider
    }
    override func mouseDragged(with event: NSEvent) {
        guard let store, let request, store.cameraRequest == request, store.mode == mode, store.provider == provider else { cancelTracking(); return }
        let point = convert(event.locationInWindow, from: nil)
        if !moved && hypot(point.x - start.x, point.y - start.y) < 3 { return }
        moved = true
        guard let angle = angle(at: point) else { return }
        // North rotates opposite the camera heading. Incremental deltas cross ±180 smoothly.
        let delta = GeoMath.normalizedLongitude(lastAngle - angle)
        lastAngle = angle
        if abs(delta) > 0.001 {
            store.navigationOrbit(dx: delta, dy: 0)
            self.request = store.cameraRequest
            heading = store.heading
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard let store, let request, store.cameraRequest == request else { cancelTracking(); return }
        if moved { mouseDragged(with: event) } else { store.north() }
        heading = store.heading; cancelTracking()
    }
    override func accessibilityPerformPress() -> Bool {
        guard let store else { return false }
        store.north(); heading = store.heading; return true
    }
    func cancelTracking() { request = nil; mode = nil; provider = nil; moved = false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { cancelTracking() } }
}
