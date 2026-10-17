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
                directionPad(look: true).frame(width: 72, height: 72)
            }.frame(width: 96, height: 96).background(.regularMaterial, in: Circle())
            directionPad(look: false).frame(width: 72, height: 72).padding(5).background(.regularMaterial, in: Circle())
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
            NavigationHoldControl(store: store, look: look, vector: .zero, symbol: look ? "eye.fill" : "hand.raised.fill", title: look ? "Drag to look around; click to reset tilt" : "Drag and hold to pan").frame(width: 24, height: 24)
            arrow("chevron.up", x: 0, y: -24, title: look ? "Look up" : "Move forward", look: look, direction: .init(0, -1))
            arrow("chevron.down", x: 0, y: 24, title: look ? "Look down" : "Move backward", look: look, direction: .init(0, 1))
            arrow("chevron.left", x: -24, y: 0, title: look ? "Look left" : "Move left", look: look, direction: .init(-1, 0))
            arrow("chevron.right", x: 24, y: 0, title: look ? "Look right" : "Move right", look: look, direction: .init(1, 0))
        }
    }
    private func arrow(_ icon: String, x: CGFloat, y: CGFloat, title: String, look: Bool, direction: SIMD2<Double>) -> some View {
        NavigationHoldControl(store: store, look: look, vector: direction, symbol: icon, title: title).frame(width: 24, height: 24).offset(x: x, y: y)
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
            Picker("Imagery source", selection: $store.historyProduct) {
                ForEach(HistoryProduct.allCases) { Text($0.rawValue).tag($0) }
            }
            if store.historyProduct == .wayback {
                Picker("Basemap release", selection: $store.waybackReleaseID) {
                    if store.waybackReleases.isEmpty { Text("Loading / unavailable").tag("") }
                    ForEach(store.waybackReleases) { Text($0.date).tag($0.id) }
                }
                Text("Release dates are publication dates. Pause the pointer over the map to read the capture date beside the coordinates, where metadata exists.").font(.caption)
                if store.waybackReleases.isEmpty { Button("Retry Wayback catalog") { store.loadWayback() } }
            } else {
                HStack {
                    Button { store.stepImagery(days: -store.historyStepDays) } label: { Image(systemName: "chevron.left") }.help("Step backward")
                    DatePicker("Date (UTC)", selection: Binding(get: { store.imageryDate }, set: { store.stopHistoryPlayback(); store.imageryDate = $0 }), in: store.historyProduct.earliest...EarthObservation.latest, displayedComponents: .date).environment(\.timeZone, EarthObservation.calendar.timeZone)
                    Button { store.stepImagery(days: store.historyStepDays) } label: { Image(systemName: "chevron.right") }.help("Step forward")
                }
                Slider(value: Binding(get: { store.imageryDate.timeIntervalSince1970 }, set: { store.stopHistoryPlayback(); store.imageryDate = EarthObservation.calendar.startOfDay(for: Date(timeIntervalSince1970: $0)) }), in: store.historyProduct.earliest.timeIntervalSince1970...EarthObservation.latest.timeIntervalSince1970).accessibilityLabel("Historical imagery timeline")
                HStack {
                    Button { store.toggleHistoryPlayback() } label: { Label(store.historyPlaying ? "Pause" : "Play", systemImage: store.historyPlaying ? "pause.fill" : "play.fill") }
                    Picker("Step", selection: $store.historyStepDays) { Text("1 day").tag(1); Text("30 days").tag(30); Text("365 days").tag(365) }.labelsHidden().frame(width: 90)
                    Button("Latest") { store.stopHistoryPlayback(); store.imageryDate = EarthObservation.latest }
                }.font(.caption)
                HStack {
                    Button("Find dates here") { store.findHistoryDates() }
                    Menu("Available dates") {
                        ForEach(store.historyDates.reversed(), id: \.self) { day in
                            Button(day) {
                                let f = DateFormatter(); f.calendar = EarthObservation.calendar; f.timeZone = EarthObservation.calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
                                if let date = f.date(from: day) { store.stopHistoryPlayback(); store.imageryDate = date }
                            }
                        }
                    }.disabled(store.historyDates.isEmpty)
                }.font(.caption)
            }
            Text(store.historyCatalogStatus).font(.caption)
            Text(store.historyAttribution).font(.caption)
            Text("NASA: dated satellite observations; clouds and gaps are normal. Wayback: archived aerial/satellite basemaps; detail varies by location. All imagery streams at its source resolution.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.mode == .globe { Text(store.archiveStatus).font(.caption2).foregroundStyle(.secondary) }
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
