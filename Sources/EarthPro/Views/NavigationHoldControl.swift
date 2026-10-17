import SwiftUI
import AppKit

/// NSButton's normal tracking loop is discrete. This bridge keeps the camera moving
/// at a time-based rate while held, including when a dragged joystick stops moving.
struct NavigationHoldControl: NSViewRepresentable {
    let store: EarthStore
    let look: Bool
    let vector: SIMD2<Double>
    let symbol: String
    let title: String
    func makeNSView(context: Context) -> NavigationHoldButton {
        let button = NavigationHoldButton(frame: .zero)
        button.isBordered = false; button.imagePosition = .imageOnly; button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.setAccessibilityLabel(title); button.toolTip = title
        return button
    }
    func updateNSView(_ button: NavigationHoldButton, context: Context) { button.store = store; button.look = look; button.fixedVector = vector }
    static func dismantleNSView(_ button: NavigationHoldButton, coordinator: ()) { button.stop(); button.store = nil }
}
@MainActor final class NavigationHoldButton: NSButton {
    weak var store: EarthStore?
    var look = false
    var fixedVector = SIMD2<Double>.zero
    private var vector = SIMD2<Double>.zero
    private var start = NSPoint.zero
    private var moved = false
    private var timer: Timer?
    private var lastTick = 0.0
    private var appliedSeconds = 0.0
    private var request: UUID?
    private var mode: ViewMode?
    private var provider: MapProvider?
    deinit { timer?.invalidate() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stop() } }
    override func mouseDown(with event: NSEvent) {
        guard let store else { return }
        stop(); store.stopTour(); vector = fixedVector; moved = false; appliedSeconds = 0
        start = convert(event.locationInWindow, from: nil); request = store.cameraRequest; mode = store.mode; provider = store.provider
        lastTick = ProcessInfo.processInfo.systemUptime; highlight(true)
        advance(seconds: 1 / 60)
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func mouseDragged(with event: NSEvent) {
        guard fixedVector == .zero else { return }
        let p = convert(event.locationInWindow, from: nil)
        let delta = SIMD2<Double>(Double(p.x - start.x), Double(start.y - p.y)) / 18
        let length = hypot(delta.x, delta.y)
        moved = moved || length > 0.12
        vector = length < 0.12 ? .zero : delta / max(1, length)
    }
    override func mouseUp(with event: NSEvent) {
        guard let store, request == store.cameraRequest, mode == store.mode, provider == store.provider else { stop(); return }
        let reset = fixedVector == .zero && !moved && look
        // A short physical click should match the accessible press, regardless of
        // how many timer callbacks AppKit delivered before the mouse was released.
        if fixedVector != .zero, appliedSeconds < 0.16 { advance(seconds: 0.16 - appliedSeconds) }
        stop(); if reset { store.setPitch(0) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard let store else { return false }
        if fixedVector == .zero { if look { store.setPitch(0) } }
        else { store.navigationPad(look: look, x: fixedVector.x, y: fixedVector.y, seconds: 0.16) }
        return true
    }
    private func tick() {
        guard let store, window?.isKeyWindow == true, window?.attachedSheet == nil, store.cameraRequest == request, store.mode == mode, store.provider == provider else { stop(); return }
        let now = ProcessInfo.processInfo.systemUptime, elapsed = min(0.05, max(0, now - lastTick)); lastTick = now
        advance(seconds: elapsed)
    }
    private func advance(seconds: Double) {
        guard let store else { return }
        if vector != .zero {
            store.navigationPad(look: look, x: vector.x, y: vector.y, seconds: seconds)
            appliedSeconds += seconds; request = store.cameraRequest
        }
    }
    func stop() { timer?.invalidate(); timer = nil; request = nil; mode = nil; provider = nil; vector = .zero; highlight(false) }
}
