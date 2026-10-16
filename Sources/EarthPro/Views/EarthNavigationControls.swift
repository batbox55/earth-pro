import SwiftUI
import AppKit

/// Familiar look / move / zoom stack. All actions use the same camera model as gestures.
struct EarthNavigationControls: View {
    @ObservedObject var store: EarthStore
    var settings: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(.primary.opacity(0.35), lineWidth: 2)
                Circle().stroke(.primary.opacity(0.15), lineWidth: 9).padding(3)
                EarthCompassControl(store: store)
                directionPad(look: true).frame(width: 58, height: 58)
            }.frame(width: 82, height: 82).background(.regularMaterial, in: Circle())
            directionPad(look: false).frame(width: 58, height: 58).padding(5).background(.regularMaterial, in: Circle())
            VStack(spacing: 5) {
                Button { store.navigationZoom(0.8) } label: { Image(systemName: "plus").frame(width: 30, height: 25) }.help("Zoom in").buttonRepeatBehavior(.enabled)
                EarthZoomSlider(value: Binding(get: { -log(store.distance) }, set: { store.navigationZoom(exp(-$0) / store.distance) })).frame(width: 24, height: 130)
                Button { store.navigationZoom(1.25) } label: { Image(systemName: "minus").frame(width: 30, height: 25) }.help("Zoom out").buttonRepeatBehavior(.enabled)
            }.padding(.vertical, 5).background(.regularMaterial, in: Capsule())
            HStack(spacing: 8) {
                Button { store.home() } label: { Image(systemName: "globe.americas") }.help("Return to Earth")
                Button(action: settings) { Image(systemName: "slider.horizontal.3") }.help("Camera controls")
            }.padding(8).background(.regularMaterial, in: Capsule())
        }.buttonStyle(.plain)
    }
    private func directionPad(look: Bool) -> some View {
        ZStack {
            Circle().fill(.primary.opacity(0.06))
            NavigationHoldControl(store: store, look: look, vector: .zero, symbol: look ? "eye.fill" : "hand.raised.fill", title: look ? "Drag to look around; click to reset tilt" : "Drag and hold to pan").frame(width: 20, height: 20)
            arrow("chevron.up", x: 0, y: -21, title: look ? "Look up" : "Move forward", look: look, direction: .init(0, -1))
            arrow("chevron.down", x: 0, y: 21, title: look ? "Look down" : "Move backward", look: look, direction: .init(0, 1))
            arrow("chevron.left", x: -21, y: 0, title: look ? "Look left" : "Move left", look: look, direction: .init(-1, 0))
            arrow("chevron.right", x: 21, y: 0, title: look ? "Look right" : "Move right", look: look, direction: .init(1, 0))
        }
    }
    private func arrow(_ icon: String, x: CGFloat, y: CGFloat, title: String, look: Bool, direction: SIMD2<Double>) -> some View {
        NavigationHoldControl(store: store, look: look, vector: direction, symbol: icon, title: title).frame(width: 19, height: 19).offset(x: x, y: y)
    }

}
struct ImageryTimeline: View {
    @ObservedObject var store: EarthStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Historical imagery", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                Button { store.historicalImagery = false } label: { Image(systemName: "xmark") }.help("Close historical imagery")
            }
            HStack {
                Button { store.stepImagery(days: -store.historyStepDays) } label: { Image(systemName: "chevron.left") }.help("Step backward")
                DatePicker("Date (UTC)", selection: Binding(get: { store.imageryDate }, set: { store.stopHistoryPlayback(); store.imageryDate = $0 }), in: EarthObservation.earliest...EarthObservation.latest, displayedComponents: .date).environment(\.timeZone, EarthObservation.calendar.timeZone)
                Button { store.stepImagery(days: store.historyStepDays) } label: { Image(systemName: "chevron.right") }.help("Step forward")
            }
            // Keep the native slider continuous: a daily step creates thousands of AppKit tick views.
            // The binding still snaps every selected value to a UTC day.
            Slider(value: Binding(get: { store.imageryDate.timeIntervalSince1970 }, set: { store.stopHistoryPlayback(); store.imageryDate = EarthObservation.calendar.startOfDay(for: Date(timeIntervalSince1970: $0)) }), in: EarthObservation.earliest.timeIntervalSince1970...EarthObservation.latest.timeIntervalSince1970).accessibilityLabel("Historical imagery timeline")
            HStack {
                Button { store.toggleHistoryPlayback() } label: { Label(store.historyPlaying ? "Pause" : "Play", systemImage: store.historyPlaying ? "pause.fill" : "play.fill") }
                Picker("Step", selection: $store.historyStepDays) { Text("1 day").tag(1); Text("30 days").tag(30); Text("365 days").tag(365) }.labelsHidden().frame(width: 100)
                Spacer()
                Button("Latest") { store.stopHistoryPlayback(); store.imageryDate = EarthObservation.latest }
            }.font(.caption)
            HStack { Text("2000"); Spacer(); Text(EarthObservation.day(EarthObservation.latest)) }.font(.caption2).foregroundStyle(.secondary)
            Text(store.mode == .globe ? store.archiveStatus : "NASA Terra / MODIS · " + EarthObservation.day(store.imageryDate)).font(.caption)
            Text("Daily satellite swaths · 250 m source resolution. Clouds and coverage gaps may obscure the surface. This archive is separate from Google’s historical imagery.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.mode == .globe { Button("Retry imagery") { store.refreshArchive() }.font(.caption) }
        }.padding(14).frame(width: 360).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct EarthZoomSlider: NSViewRepresentable {
    @Binding var value: Double
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: -log(45_000_000), maxValue: -log(150), target: context.coordinator, action: #selector(Coordinator.change(_:)))
        slider.frame = NSRect(x: 0, y: 0, width: 24, height: 130); slider.isVertical = true; slider.isContinuous = true; slider.controlSize = .small
        slider.setAccessibilityLabel("Zoom level")
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) { context.coordinator.changed = { value = $0 }; slider.doubleValue = value }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? { CGSize(width: 24, height: 130) }
    final class Coordinator: NSObject {
        var changed: ((Double) -> Void)?
        @objc func change(_ slider: NSSlider) { changed?(slider.doubleValue) }
    }
}
