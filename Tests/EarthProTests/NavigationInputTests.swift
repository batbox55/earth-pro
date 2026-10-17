import AppKit
import XCTest
@testable import EarthPro

// Exercise the AppKit adapter with events directly, without posting OS input or opening test windows.
private final class InputTestWindow: NSWindow {
    var testResponder: NSResponder?
    override var isKeyWindow: Bool { true }
    override var isVisible: Bool { true }
    override var firstResponder: NSResponder? { testResponder }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool { testResponder = responder; return true }
}
private final class InputTestSurface: NSView {
    var testFlipped = false
    override var isFlipped: Bool { testFlipped }
    override var acceptsFirstResponder: Bool { true }
}
private final class InputTestEvent: NSEvent {
    var kind: NSEvent.EventType = .scrollWheel
    weak var targetWindow: NSWindow?
    var point = NSPoint(x: 250, y: 250)
    var flags: NSEvent.ModifierFlags = []
    var scroll: CGFloat = 0
    var horizontalScroll: CGFloat = 0
    var precise = true
    var pinch: CGFloat = 0
    var twist: Float = 0
    var button = 0
    var clicks = 1
    var code: UInt16 = 0
    var text: String?
    var momentum: NSEvent.Phase = []
    override var type: NSEvent.EventType { kind }
    override var window: NSWindow? { targetWindow }
    override var locationInWindow: NSPoint { point }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var scrollingDeltaY: CGFloat { scroll }
    override var scrollingDeltaX: CGFloat { horizontalScroll }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var magnification: CGFloat { pinch }
    override var rotation: Float { twist }
    override var buttonNumber: Int { button }
    override var clickCount: Int { clicks }
    override var keyCode: UInt16 { code }
    override var charactersIgnoringModifiers: String? { text }
    override var momentumPhase: NSEvent.Phase { momentum }
}

final class NavigationInputTests: XCTestCase {
    @MainActor func testCompassClickAndDragFollowTheRingWithoutResetOrWrapJumps() {
        let (window, _, store, _, event) = fixture()
        let compass = EarthCompassView(frame: NSRect(x: 0, y: 0, width: 82, height: 82))
        window.contentView!.addSubview(compass); compass.store = store
        func move(_ angle: Double) {
            let radians = angle * .pi / 180
            event.point = compass.convert(NSPoint(x: 41 + sin(radians) * 35, y: 41 - cos(radians) * 35), to: nil)
        }
        let center = store.center, distance = store.distance, pitch = store.pitch
        store.heading = 0
        move(0); compass.mouseDown(with: event)
        move(90); compass.mouseDragged(with: event)
        XCTAssertEqual(store.heading, 270, accuracy: 0.001)
        compass.mouseUp(with: event)
        XCTAssertEqual(store.heading, 270, accuracy: 0.001, "Releasing a drag must not reset north")
        XCTAssertEqual(store.center, center); XCTAssertEqual(store.distance, distance); XCTAssertEqual(store.pitch, pitch)
        XCTAssertTrue(store.navigationIsActive)
        store.heading = 190
        move(170); compass.mouseDown(with: event)
        move(-170); compass.mouseDragged(with: event); compass.mouseUp(with: event)
        XCTAssertEqual(store.heading, 170, accuracy: 0.001)
        move(-170); compass.mouseDown(with: event); compass.mouseUp(with: event)
        XCTAssertEqual(store.heading, 0); XCTAssertTrue(store.navigationIsActive)
        store.heading = 120
        XCTAssertTrue(compass.accessibilityPerformPress()); XCTAssertEqual(store.heading, 0)
        compass.removeFromSuperview()
    }
    @MainActor func testCompassCancelsWhenAnotherCameraRequestTakesOver() {
        let (window, _, store, _, event) = fixture()
        let compass = EarthCompassView(frame: NSRect(x: 0, y: 0, width: 82, height: 82))
        window.contentView!.addSubview(compass); compass.store = store; store.heading = 75
        event.point = compass.convert(NSPoint(x: 41, y: 6), to: nil); compass.mouseDown(with: event)
        store.cameraRequest = UUID()
        event.point = compass.convert(NSPoint(x: 76, y: 41), to: nil)
        compass.mouseDragged(with: event); compass.mouseUp(with: event)
        XCTAssertEqual(store.heading, 75)
        XCTAssertNil(compass.hitTest(NSPoint(x: 41, y: 41)), "The compass must leave its center to the look pad")
        compass.removeFromSuperview()
    }
    @MainActor private func fixture(flipped: Bool = false, animateZoom: Bool = false) -> (InputTestWindow, InputTestSurface, EarthStore, EarthNavigationInput, InputTestEvent) {
        _ = NSApplication.shared
        let window = InputTestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let surface = InputTestSurface(frame: NSRect(x: 100, y: 100, width: 300, height: 300)); surface.testFlipped = flipped
        root.addSubview(surface); window.contentView = root; window.testResponder = surface
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.mode = .map; store.distance = 10_000; store.latitude = 0; store.longitude = 0; store.pitch = 20
        let input = EarthNavigationInput(view: surface, store: store, animateZoom: animateZoom)
        input.pointAt = { _, completion in completion(nil) }
        let event = InputTestEvent(); event.targetWindow = window
        return (window, surface, store, input, event)
    }
    @MainActor func testPointerCoordinatesIgnoreSidebarAndDelayedResults() {
        let (window, _, store, input, event) = fixture()
        defer { window.close() }
        var complete: ((GeoPoint?) -> Void)?
        input.pointAt = { _, completion in complete = completion }
        event.kind = .mouseMoved
        XCTAssertNotNil(input.handle(event)); XCTAssertNotNil(complete)
        complete?(.init(latitude: 37, longitude: -122))
        XCTAssertEqual(store.cursorPoint, .init(latitude: 37, longitude: -122))
        event.point = NSPoint(x: 25, y: 25)
        XCTAssertNotNil(input.handle(event)); XCTAssertNil(store.cursorPoint)
        complete?(.init(latitude: 40, longitude: 20))
        XCTAssertNil(store.cursorPoint)
    }
    @MainActor func testNavigationHoldButtonMovesAndReleases() {
        let (window, surface, store, _, event) = fixture()
        defer { window.close() }
        let button = NavigationHoldButton(frame: NSRect(x: 0, y: 0, width: 30, height: 30)); surface.addSubview(button)
        button.store = store; button.fixedVector = .init(1, 0)
        let start = store.center
        event.kind = .leftMouseDown; button.mouseDown(with: event)
        XCTAssertGreaterThan(GeoMath.distance(start, store.center), 0)
        event.kind = .leftMouseUp; button.mouseUp(with: event)
        let released = store.center
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        XCTAssertEqual(store.center, released)
        XCTAssertTrue(button.accessibilityPerformPress()); XCTAssertNotEqual(store.center, released)
    }
    @MainActor func testLookArrowQuickClickHasUsefulStepAndCancellationDoesNotResetTilt() {
        let (window, surface, store, _, event) = fixture()
        defer { window.close() }
        let button = NavigationHoldButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        surface.addSubview(button); button.store = store; button.look = true; button.fixedVector = .init(1, 0)
        let heading = store.heading
        button.mouseDown(with: event); button.mouseUp(with: event)
        XCTAssertGreaterThanOrEqual(store.heading - heading, 5, "A quick click must make a visible heading step, not depend on timer delivery")
        button.fixedVector = .zero
        button.mouseDown(with: event)
        store.setPitch(45) // Another camera action takes over while the button is held.
        button.mouseUp(with: event)
        XCTAssertEqual(store.pitch, 45, "An interrupted center press must not reset the new camera")
    }
    @MainActor func testLookArrowsRepeatSmoothlyAndStopOnRelease() {
        let (window, surface, store, _, event) = fixture()
        defer { window.close() }
        let button = NavigationHoldButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        surface.addSubview(button); button.store = store; button.look = true
        for direction in [SIMD2<Double>(1, 0), .init(-1, 0), .init(0, 1), .init(0, -1)] {
            store.heading = 180; store.pitch = 40
            button.fixedVector = direction
            button.mouseDown(with: event); button.mouseUp(with: event)
            XCTAssertEqual(store.heading, 180 + direction.x * 7.2, accuracy: 0.001)
            XCTAssertEqual(store.pitch, 40 + direction.y * 4.8, accuracy: 0.001)
        }
        button.fixedVector = .init(1, 0)
        button.mouseDown(with: event)
        let first = store.heading
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertGreaterThan(store.heading, first, "Holding must keep moving without further mouse events")
        button.mouseUp(with: event)
        let released = store.heading
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        XCTAssertEqual(store.heading, released)
        button.mouseUp(with: event)
        XCTAssertEqual(store.heading, released, "A second release must not add another step")
    }
    @MainActor func testLargerCompassLeavesArrowTargetsToThePad() {
        let (window, _, store, _, _) = fixture()
        defer { window.close() }
        let compass = EarthCompassView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        window.contentView!.addSubview(compass); compass.store = store
        for offset in [NSPoint(x: 12, y: 36), NSPoint(x: -12, y: -36), NSPoint(x: 36, y: 12), NSPoint(x: -36, y: -12)] {
            XCTAssertNil(compass.hitTest(NSPoint(x: 48 + offset.x, y: 48 + offset.y)))
        }
        XCTAssertTrue(compass.hitTest(NSPoint(x: 48, y: 6)) === compass)
        XCTAssertTrue(compass.hitTest(NSPoint(x: 48 + 42 / sqrt(2), y: 48 + 42 / sqrt(2))) === compass)
    }
    @MainActor func testWheelPinchAndRotationAreConsumedOnceAndRespectOption() {
        let (window, _, store, input, event) = fixture()
        defer { window.close() }
        event.scroll = 12
        XCTAssertNil(input.handle(event)); XCTAssertLessThan(store.distance, 10_000)
        let wheelDistance = store.distance
        event.flags = .shift
        XCTAssertNil(input.handle(event)); XCTAssertGreaterThan(store.pitch, 20); XCTAssertEqual(store.distance, wheelDistance)
        event.kind = .magnify; event.flags = []; event.pinch = 0.1; store.distance = 10_000
        XCTAssertNil(input.handle(event)); let regularPinch = store.distance
        event.flags = .option; store.distance = 10_000
        XCTAssertNil(input.handle(event)); XCTAssertGreaterThan(store.distance, regularPinch); XCTAssertLessThan(store.distance, 10_000)
        event.flags = []; event.pinch = -0.1; store.distance = 10_000
        XCTAssertNil(input.handle(event)); XCTAssertGreaterThan(store.distance, 10_000)
        event.kind = .rotate; event.flags = []; event.twist = 20; store.heading = 100
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.heading, 80)
        event.flags = .option; store.heading = 100
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.heading, 96)
    }
    @MainActor func testLayerMarkerClickDoesNotStealPanning() {
        let (window, _, _, input, event) = fixture()
        defer { window.close() }
        var selections = 0
        input.pickLayerAt = { _ in selections += 1; return true }
        event.kind = .leftMouseDown
        XCTAssertTrue(input.handle(event) === event)
        event.kind = .leftMouseUp
        XCTAssertNil(input.handle(event)); XCTAssertEqual(selections, 1)
        event.kind = .leftMouseDown; XCTAssertTrue(input.handle(event) === event)
        event.kind = .leftMouseDragged; event.point.x += 30; XCTAssertTrue(input.handle(event) === event)
        event.kind = .leftMouseUp; XCTAssertTrue(input.handle(event) === event)
        XCTAssertEqual(selections, 1)
    }
    @MainActor func testShiftWheelTiltsOnEitherAppKitAxisWithoutZooming() {
        let (window, _, store, input, event) = fixture()
        defer { window.close() }
        event.flags = .shift; event.precise = false
        event.horizontalScroll = 4
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.pitch, 32)
        XCTAssertEqual(store.distance, 10_000)
        event.horizontalScroll = 0; event.scroll = -4
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.pitch, 20)
        event.flags = [.shift, .option]; event.horizontalScroll = 4; event.scroll = 0
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.pitch, 22.4, accuracy: 0.001)
        event.flags = []; event.horizontalScroll = 0; event.scroll = 1
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.distance, 10_000 * exp(-0.12), accuracy: 0.001)
    }
    @MainActor func testDocumentedMacKeyboardNavigation() {
        let (window, _, store, input, event) = fixture()
        defer { window.close() }
        event.kind = .keyDown; event.code = 123
        XCTAssertNil(input.handle(event)); XCTAssertLessThan(store.longitude, 0)
        event.code = 124
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.longitude, 0, accuracy: 0.001)
        event.flags = .shift; event.code = 123
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.heading, 5)
        event.code = 124
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.heading, 0)
        event.code = 125
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.pitch, 25)
        event.code = 126
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.pitch, 20)
        event.flags = [.shift, .option]; event.code = 123
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.heading, 1)
        event.flags = []; event.code = 0; event.text = "n"
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.heading, 0)
        event.text = "u"
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.pitch, 0)
        event.text = "r"
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.mode, .globe)
        XCTAssertEqual(store.distance, 16_000_000)
    }
    @MainActor func testDelayedProjectionCannotZoomAfterProviderChanges() {
        let (window, _, store, input, event) = fixture()
        defer { window.close() }
        var delayed: ((GeoPoint?) -> Void)?
        input.pointAt = { _, completion in delayed = completion }
        event.scroll = 12
        XCTAssertNil(input.handle(event)); XCTAssertNotNil(delayed)
        store.chooseProvider(.openStreetMap)
        delayed?(nil)
        XCTAssertEqual(store.distance, 10_000)
        XCTAssertEqual(store.provider, .openStreetMap)
    }
    @MainActor func testZoomEasesToCombinedTargetAndSpaceStopsIt() async throws {
        let (window, _, store, input, event) = fixture(animateZoom: true)
        defer { window.close() }
        let settled = expectation(description: "Zoom reaches combined wheel target")
        let target = 10_000 * exp(-0.192)
        var fulfilled = false
        input.renderCamera = {
            if !fulfilled, abs(store.distance - target) < 0.01 { fulfilled = true; settled.fulfill() }
        }
        event.scroll = 12
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.distance, 10_000)
        XCTAssertNil(input.handle(event))
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(store.distance, target, accuracy: 0.01)
        XCTAssertNil(input.handle(event))
        event.kind = .keyDown; event.code = 49
        XCTAssertNil(input.handle(event))
        let stopped = store.distance
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.distance, stopped)
    }
    @MainActor func testModifierDragsHaveSameDirectionInFlippedWebAndNativeViews() {
        for flipped in [false, true] {
            let (window, _, store, input, event) = fixture(flipped: flipped)
            defer { window.close() }
            // Window coordinates always increase upward; the renderer may convert them to flipped coordinates.
            event.kind = .leftMouseDown; event.flags = .control
            XCTAssertNil(input.handle(event))
            event.kind = .leftMouseDragged; event.point.y += 30
            XCTAssertNil(input.handle(event)); XCTAssertGreaterThan(store.distance, 10_000)
            event.kind = .leftMouseUp; XCTAssertNil(input.handle(event))
            store.pitch = 20
            event.kind = .leftMouseDown; event.flags = .shift
            XCTAssertNil(input.handle(event))
            event.kind = .leftMouseDragged; event.point.y -= 30
            XCTAssertNil(input.handle(event)); XCTAssertGreaterThan(store.pitch, 20)
            event.kind = .leftMouseUp; XCTAssertNil(input.handle(event))
        }
    }
    @MainActor func testSidebarTextEntryAndStreetViewKeepTheirOwnInput() {
        let (window, _, store, input, event) = fixture()
        defer { window.close() }
        event.scroll = 20; event.point = NSPoint(x: 30, y: 250)
        XCTAssertTrue(input.handle(event) === event); XCTAssertEqual(store.distance, 10_000)
        window.testResponder = NSTextView()
        event.kind = .keyDown; event.text = "r"
        XCTAssertTrue(input.handle(event) === event); XCTAssertEqual(store.mode, .map)
        event.kind = .scrollWheel; event.point = NSPoint(x: 250, y: 250); store.streetView = true
        XCTAssertTrue(input.handle(event) === event); XCTAssertEqual(store.distance, 10_000)
    }
    @MainActor func testDoubleClickAndSpaceCancelPendingZoomAndMomentum() {
        let (window, _, store, input, event) = fixture()
        defer { window.close() }
        event.kind = .leftMouseDown; event.clicks = 2
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.distance, 5_000)
        event.kind = .leftMouseUp; XCTAssertNil(input.handle(event))
        event.kind = .leftMouseDown; event.flags = .shift
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.distance, 10_000)
        event.kind = .leftMouseUp; XCTAssertNil(input.handle(event))
        var delayed: ((GeoPoint?) -> Void)?
        input.pointAt = { _, callback in delayed = callback }
        event.kind = .scrollWheel; event.flags = []; event.scroll = 10
        XCTAssertNil(input.handle(event)); XCTAssertNotNil(delayed)
        var stopped = false; input.stopMotion = { stopped = true }
        event.kind = .keyDown; event.code = 49
        XCTAssertNil(input.handle(event)); XCTAssertTrue(stopped)
        delayed?(nil); XCTAssertEqual(store.distance, 10_000)
        event.kind = .scrollWheel; event.momentum = .changed
        XCTAssertNil(input.handle(event)); XCTAssertEqual(store.distance, 10_000)
    }
    @MainActor func testOverlayReleaseCannotInspectGeometryBehindIt() {
        let (window, _, _, input, event) = fixture()
        defer { window.close() }
        var picks = 0; input.pickLayerAt = { _ in picks += 1; return true }
        event.kind = .leftMouseDown; _ = input.handle(event)
        let panel = NSTextField(frame: NSRect(x: 200, y: 200, width: 100, height: 100))
        window.contentView!.addSubview(panel)
        event.kind = .leftMouseUp
        XCTAssertTrue(input.handle(event) === event)
        XCTAssertEqual(picks, 0)
    }

}
