import SwiftUI
import AppKit

@main struct EarthProApp: App {
    @NSApplicationDelegateAdaptor(EarthAppDelegate.self) private var delegate
    @StateObject private var store: EarthStore
    init() {
        EarthAppIdentity.restorePreferences()
        _store = StateObject(wrappedValue: EarthStore())
    }
    var body: some Scene {
        WindowGroup("Earth Pro") {
            ContentView(store: store)
                .frame(minWidth: 1000, minHeight: 660)
                .onOpenURL { store.importURLs([$0]) }
                .onAppear { delegate.store=store }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Earth Pro") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationIcon: EarthBrand.icon])
                }
            }
            CommandGroup(replacing: .help) {
                Link("Earth Pro Guide & Support", destination: URL(string: "https://zachenson.com/earth-pro/support")!)
                Link("Privacy Policy", destination: URL(string: "https://zachenson.com/earth-pro/privacy")!)
                Link("Earth Pro on the Web", destination: URL(string: "https://zachenson.com/earth-pro/")!)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Google Maps Settings…") { store.googleSettings = true }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Open KML or KMZ…") { store.importFile() }.keyboardShortcut("o")
                Button("Export My Places…") { store.exportKML() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(store.features.isEmpty)
                Button("Print…") { store.printView() }.keyboardShortcut("p").disabled(store.busy)
                Button("Save Image…") { store.saveImage() }.keyboardShortcut("s", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo)
                Button("Redo") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Navigation Controls", isOn: $store.showNavigation)
                Toggle("Status Bar", isOn: $store.showStatus)
                Toggle("Historical Imagery", isOn: $store.historicalImagery)
                Toggle("Sunlight", isOn: Binding(get: { store.sunlight }, set: { store.sunlight = $0; if $0 { store.setMode(.globe) } }))
                Divider()
                Toggle("Latitude / Longitude Grid", isOn: $store.grid)
                Toggle("Terrain", isOn: $store.terrain)
                Menu("Coordinates") { Toggle("Degrees, Minutes, Seconds", isOn: $store.dmsCoordinates) }
                Menu("Distance Units") { Button("Meters / Kilometers") { store.miles = false }; Button("Feet / Miles") { store.miles = true } }
            }
            CommandMenu("History") {
                Toggle("Historical Imagery", isOn: $store.historicalImagery)
                Button(store.historyPlaying ? "Pause Imagery Playback" : "Play Imagery Timeline") { store.toggleHistoryPlayback() }
                Button("Earlier Imagery") { store.stepImagery(days: -store.historyStepDays) }
                Button("Later Imagery") { store.stepImagery(days: store.historyStepDays) }
                Button("Latest Imagery") { store.stopHistoryPlayback(); store.imageryDate = EarthObservation.latest }
                Divider()
                Menu("Recent Searches") {
                    if store.recentSearches.isEmpty { Text("No recent searches") }
                    ForEach(store.recentSearches, id: \.self) { query in Button(query) { store.repeatSearch(query) } }
                }
                Button("Clear Search History") { store.clearSearchHistory() }.disabled(store.recentSearches.isEmpty)
            }
            CommandMenu("Tools") {
                Button("Record Video…") { store.recordVideo() }.disabled(store.recordingFinishing)
                Button("Image Overlays…") { store.showImageOverlays=true }
                Button("Local MCP Control…") { store.showLocalMCP=true }
                Divider()
                Button("Ruler") { store.begin(.ruler) }
                Button("Reset Tilt") { store.setPitch(0) }
                Button("Copy Coordinates") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(EarthObservation.coordinates(store.observationPoint, dms: store.dmsCoordinates), forType: .string)
                }
                Button("Open View in Google Maps") {
                    store.openExternalMap()
                }
            }
            CommandMenu("Add") {
                Button("Plot Address List…") { store.showAddressImport = true }
                Button("Placemark") { store.begin(.placemark) }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Path") { store.begin(.path) }
                Button("Polygon") { store.begin(.polygon) }
                Button("Image Overlay…") { store.importImageOverlay() }
                Button("Custom Data Layer…") { store.showCustomData = true }
            }
            CommandMenu("Explore") {
                Button("Home") { store.home() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Zoom In") { store.zoom(0.65) }.keyboardShortcut("+")
                Button("Zoom Out") { store.zoom(1.5) }.keyboardShortcut("-")
                Button("Reset North") { store.north() }.keyboardShortcut("n")
                Button("Ruler") { store.begin(.ruler) }.keyboardShortcut("r")
                Button("Cancel Drawing") { store.cancelTool() }.keyboardShortcut(.escape, modifiers: [])
                Divider()
                Button(store.touring ? "Stop Tour" : "Tour My Places") { store.touring ? store.stopTour() : store.startTour() }.disabled(store.features.isEmpty)
            }
        }
    }
}
@MainActor final class EarthAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: EarthStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.recording || store.recordingFinishing else { return .terminateNow }
        Task {
            await store.stopVideoRecording()
            while store.recordingFinishing { try? await Task.sleep(for:.milliseconds(50)) }
            sender.reply(toApplicationShouldTerminate:true)
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = EarthBrand.icon
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
