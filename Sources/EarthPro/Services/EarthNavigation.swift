import AppKit
import simd

/// Google Earth Pro's Mac navigation mapping, shared by SceneKit, MapKit and WebKit.
enum EarthDragMode: Equatable { case pan, orbit, look, zoom }
enum EarthNavigation {
    static func vector(_ point: GeoPoint) -> SIMD3<Double> {
        let lat = point.latitude * .pi / 180, lon = point.longitude * .pi / 180
        return .init(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
    }
    static func rotatedCamera(center: GeoPoint, heading: Double, rotation: simd_quatd) -> (GeoPoint, Double) {
        let lat = center.latitude * .pi / 180, lon = center.longitude * .pi / 180, h = heading * .pi / 180
        let north = SIMD3<Double>(-sin(lat) * sin(lon), cos(lat), -sin(lat) * cos(lon))
        let east = SIMD3<Double>(cos(lon), 0, -sin(lon))
        let radial = rotation.act(vector(center)), forward = rotation.act(north * cos(h) + east * sin(h))
        let nextLat = asin(max(-1, min(1, radial.y))), nextLon = atan2(radial.x, radial.z)
        let nextNorth = SIMD3<Double>(-sin(nextLat) * sin(nextLon), cos(nextLat), -sin(nextLat) * cos(nextLon))
        let nextEast = SIMD3<Double>(cos(nextLon), 0, -sin(nextLon))
        return (.init(latitude: nextLat * 180 / .pi, longitude: nextLon * 180 / .pi),
                (atan2(simd_dot(forward, nextEast), simd_dot(forward, nextNorth)) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
    }
    /// Exponential easing based on elapsed seconds, independent of event and display cadence.
    static func motionFraction(elapsed: Double, response: Double) -> Double {
        guard elapsed.isFinite, response.isFinite, response > 0 else { return 0 }
        return 1 - exp(-max(0, elapsed) / response)
    }
    static func dragMode(button: Int, modifiers: NSEvent.ModifierFlags) -> EarthDragMode {
        if button == 1 || modifiers.contains(.control) { return .zoom }
        if button == 2 || modifiers.contains(.shift) { return .orbit }
        if modifiers.contains(.command) { return .look }
        return .pan
    }
    static func offset(_ point: GeoPoint, bearing: Double, meters: Double) -> GeoPoint {
        let lat = point.latitude * .pi / 180, lon = point.longitude * .pi / 180
        let angular = meters / GeoMath.radius, b = bearing * .pi / 180
        let nextLat = asin(max(-1, min(1, sin(lat) * cos(angular) + cos(lat) * sin(angular) * cos(b))))
        let nextLon = lon + atan2(sin(b) * sin(angular) * cos(lat), cos(angular) - sin(lat) * sin(nextLat))
        return .init(latitude: nextLat * 180 / .pi, longitude: GeoMath.normalizedLongitude(nextLon * 180 / .pi))
    }
    static func dragDelta(from start: NSPoint, to end: NSPoint, flipped: Bool) -> (dx: Double, dy: Double) {
        (Double(end.x - start.x), Double(end.y - start.y) * (flipped ? -1 : 1))
    }
    static func zoomFactor(delta: Double, precise: Bool, fine: Bool) -> Double {
        exp(max(-0.7, min(0.7, -delta * (precise ? 0.008 : 0.12) * (fine ? 0.2 : 1))))
    }
}

/// Local event routing is needed because MKMapView and WKWebView use private child views.
/// Only events hitting this renderer are captured; sidebars, panels and text fields keep their input.
@MainActor final class EarthNavigationInput {
    weak var view: NSView?
    let store: EarthStore
    var pointAt: ((NSPoint, @escaping (GeoPoint?) -> Void) -> Void)?
    var stopMotion: (() -> Void)?
    var pickLayerAt: ((NSPoint) -> Bool)?
    private var lastPointerUpdate = 0.0
    private var pointerRequest = UUID()
    private var nativePan: (start: NSPoint, moved: Bool)?
    var interruptMotion: (() -> Void)?
    var renderCamera: (() -> Void)?
    private var zoomTimer: Timer?
    private var remainingZoom = 0.0
    private var lastZoomTick = 0.0
    private var zoomAnchor: GeoPoint?
    private var zoomRequest: UUID?
    private let animateZoom: Bool
    private var monitor: Any?
    private var drag: (mode: EarthDragMode, point: NSPoint, button: Int, moved: Bool)?
    private var suppressMomentum = false
    private var generation = 0
    init(view: NSView, store: EarthStore, animateZoom: Bool = true) {
        self.view = view; self.store = store; self.animateZoom = animateZoom
        view.window?.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown, .otherMouseDragged, .otherMouseUp, .scrollWheel, .magnify, .rotate, .keyDown, .mouseMoved]) { [weak self] event in
            guard let self else { return event }; return self.handle(event)
        }
    }
    deinit { zoomTimer?.invalidate(); if let monitor { NSEvent.removeMonitor(monitor) } }
    // Returning nil must be preserved by the monitor closure (nil means consumed).
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let view, let window = view.window, event.window === window,
              store.mode == (view is InteractiveGlobe ? .globe : .map), !store.streetView else { return event }
        if event.type == .keyDown {
            guard window.isKeyWindow, window.attachedSheet == nil, window.childWindows?.contains(where: { $0.isVisible }) != true else { return event }
            guard let responder = window.firstResponder as? NSView, responder === view || responder.isDescendant(of: view) else { return event }
            return key(event) ? nil : event
        }
        let point = view.convert(event.locationInWindow, from: nil)
        let dragging = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type)
        let up = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type)
        if let active = drag, (dragging || up), event.buttonNumber == active.button {
            if up {
                drag = nil; store.navigationIsActive = false
                if !active.moved, active.mode == .zoom, event.clickCount >= 2 { zoom(2, at: point) }
            } else {
                let (dx, dy) = EarthNavigation.dragDelta(from: active.point, to: point, flipped: view.isFlipped)
                if abs(dx) + abs(dy) > 0.5 {
                    store.navigationIsActive = true
                    store.navigateDrag(active.mode, dx: dx, dy: dy, height: view.bounds.height, fine: event.modifierFlags.contains(.option))
                    renderCamera?()
                    drag = (active.mode, point, active.button, true)
                }
            }
            return nil
        }
        if var pan = nativePan {
            if event.type == .leftMouseDragged, hypot(point.x - pan.start.x, point.y - pan.start.y) > 4 { pan.moved = true; nativePan = pan }
            if event.type == .leftMouseUp {
                nativePan = nil
                if !pan.moved, store.tool == .navigate, pickLayerAt?(point) == true { return nil }
            }
        }
        guard let content = window.contentView, let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)), hit === view || hit.isDescendant(of: view) else {
            if event.type == .mouseMoved { pointerRequest = UUID(); store.cursorPoint = nil }
            return event
        }
        window.acceptsMouseMovedEvents = true
        if event.type == .mouseMoved {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPointerUpdate > 0.1 else { return event }
            lastPointerUpdate = now; pointerRequest = UUID(); let request = pointerRequest
            pointAt?(point) { [weak self] target in
                guard let self, self.pointerRequest == request, self.view?.window?.isVisible == true else { return }
                self.store.cursorPoint = target
            }
            return event
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            cancelZoom(); interruptMotion?(); nativePan = nil
            let mode = EarthNavigation.dragMode(button: event.buttonNumber, modifiers: event.modifierFlags)
            if event.type == .leftMouseDown, event.clickCount >= 2, store.tool == .navigate {
                window.makeFirstResponder(view); store.stopTour()
                zoom(event.modifierFlags.contains(.shift) ? 2 : 0.5, at: point)
                drag = (.pan, point, 0, true)
                return nil
            }
            if mode == .pan {
                generation += 1; suppressMomentum = false; store.stopTour()
                nativePan = (point, false)
                window.makeFirstResponder(view)
                return event // Native panning and placemark clicks stay native.
            }
            window.makeFirstResponder(view); store.stopTour(); suppressMomentum = false; generation += 1
            drag = (mode, point, event.buttonNumber, false)
            return nil
        }
        switch event.type {
        case .scrollWheel:
            if suppressMomentum, !event.momentumPhase.isEmpty { return nil }
            interruptMotion?()
            suppressMomentum = false; store.stopTour(); store.navigationIsActive = true
            let fine = event.modifierFlags.contains(.option)
            if event.modifierFlags.contains(.shift) {
                cancelZoom(); generation += 1
                // AppKit can remap Shift-wheel movement onto X, especially for ordinary mice.
                let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
                store.navigationOrbit(dx: 0, dy: Double(delta) * (event.hasPreciseScrollingDeltas ? 0.3 : 3) * (fine ? 0.2 : 1))
            } else {
                zoom(EarthNavigation.zoomFactor(delta: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas, fine: fine), at: point)
            }
            store.navigationIsActive = false
            return nil
        case .magnify:
            interruptMotion?(); store.stopTour()
            let speed = event.modifierFlags.contains(.option) ? 0.2 : 1.0
            zoom(exp(max(-0.7, min(0.7, -Double(event.magnification) * 2 * speed))), at: point)
            return nil
        case .rotate:
            cancelZoom(); generation += 1; interruptMotion?()
            store.stopTour(); store.navigationIsActive = true
            store.navigationOrbit(dx: -Double(event.rotation) * (event.modifierFlags.contains(.option) ? 0.2 : 1), dy: 0)
            store.navigationIsActive = false; return nil
        default: return event
        }
    }
    private func zoom(_ factor: Double, at point: NSPoint) {
        let requestGeneration = generation, requestMode = store.mode, requestProvider = store.provider
        if let pointAt {
            pointAt(point) { [weak self] anchor in
                guard let self, self.view?.window?.isVisible == true, !self.store.streetView, self.generation == requestGeneration, self.store.mode == requestMode, self.store.provider == requestProvider else { return }
                self.easeZoom(factor, anchor: anchor)
            }
        } else { easeZoom(factor, anchor: nil) }
    }
    private func cancelZoom() {
        zoomTimer?.invalidate(); zoomTimer = nil; remainingZoom = 0
    }
    private func easeZoom(_ factor: Double, anchor: GeoPoint?) {
        guard animateZoom else { store.navigationZoom(factor, anchor: anchor); return }
        if zoomRequest != store.cameraRequest { cancelZoom() }
        remainingZoom = max(-2, min(2, remainingZoom + log(factor)))
        zoomAnchor = anchor; zoomRequest = store.cameraRequest
        guard zoomTimer == nil else { return }
        lastZoomTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceZoom() }
        }
        zoomTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func advanceZoom() {
        guard view?.window?.isVisible == true, !store.streetView, zoomRequest == store.cameraRequest else { cancelZoom(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(0.1, max(0, now - lastZoomTick)); lastZoomTick = now
        let fraction = EarthNavigation.motionFraction(elapsed: elapsed, response: 0.065)
        let step = abs(remainingZoom) < 0.001 ? remainingZoom : remainingZoom * fraction
        remainingZoom -= step
        let mode = store.mode
        store.navigationZoom(exp(step), anchor: zoomAnchor)
        // Carry the remainder across the globe/map renderer handoff.
        if store.mode != mode { store.navigationZoom(exp(remainingZoom), anchor: zoomAnchor); remainingZoom = 0 }
        zoomRequest = store.cameraRequest; renderCamera?()
        if abs(remainingZoom) < 0.00001 { cancelZoom() }
    }
    private func key(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return false }
        cancelZoom(); generation += 1; interruptMotion?()
        let fine = event.modifierFlags.contains(.option), shift = event.modifierFlags.contains(.shift)
        let step = fine ? 1.0 : 5.0
        store.navigationIsActive = true
        defer { store.navigationIsActive = false }
        switch event.keyCode {
        case 123: shift ? store.navigationOrbit(dx: step, dy: 0) : store.navigateDrag(.pan, dx: 30 * (fine ? 0.2 : 1), dy: 0, height: Double(view?.bounds.height ?? 800))
        case 124: shift ? store.navigationOrbit(dx: -step, dy: 0) : store.navigateDrag(.pan, dx: -30 * (fine ? 0.2 : 1), dy: 0, height: Double(view?.bounds.height ?? 800))
        case 125: shift ? store.navigationOrbit(dx: 0, dy: step) : store.navigateDrag(.pan, dx: 0, dy: 30 * (fine ? 0.2 : 1), height: Double(view?.bounds.height ?? 800))
        case 126: shift ? store.navigationOrbit(dx: 0, dy: -step) : store.navigateDrag(.pan, dx: 0, dy: -30 * (fine ? 0.2 : 1), height: Double(view?.bounds.height ?? 800))
        case 49: generation += 1; store.stopTour(); suppressMomentum = true; stopMotion?()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "=", "+": store.navigationZoom(fine ? 0.95 : 0.8)
            case "-", "_": store.navigationZoom(fine ? 1.05 : 1.25)
            case "n": store.north()
            case "u": store.setPitch(0)
            case "r": store.home()
            default: return false
            }
        }
        return true
    }
}
