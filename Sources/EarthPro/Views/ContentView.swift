import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: EarthStore
    @State private var sidebar = true
    @State private var dropTarget = false
    @State private var imageryDetails = false
    @State private var cameraOptions = false
    @AppStorage("earthNavigationHintDismissed") private var hintDismissed = false
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if sidebar { SidebarView(store: store).frame(minWidth: 260, idealWidth: 295, maxWidth: 360) }
                viewport.frame(minWidth: 650)
            }
            if store.showStatus { statusBar }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { Button { sidebar.toggle() } label: { Image(systemName: "sidebar.left") }.help("Show or hide sidebar") }
            ToolbarItemGroup(placement: .principal) {
                toolButton("Placemark", icon: "mappin.and.ellipse", tool: .placemark)
                Button { store.showAddressImport = true } label: { Label("Plot Address List", systemImage: "list.bullet.clipboard") }
                    .help("Paste a list of addresses and plot pins").accessibilityIdentifier("plot-address-list")
                toolButton("Path", icon: "point.topleft.down.to.point.bottomright.curvepath", tool: .path)
                toolButton("Polygon", icon: "pentagon", tool: .polygon)
                Button { store.showImageOverlays = true } label: { Label("Image Overlays", systemImage: "photo.on.rectangle.angled") }
                    .labelStyle(.iconOnly).help("Manage image overlays")
                    .accessibilityIdentifier("image-overlays-toolbar")
                Button { store.historicalImagery.toggle() } label: { Label("Historical Imagery", systemImage: "clock.arrow.circlepath") }.help("Browse dated NASA and Wayback imagery").tint(store.historicalImagery ? .accentColor : .primary)
                Button { store.sunlight.toggle(); if store.sunlight { store.setMode(.globe) } } label: { Label("Sunlight", systemImage: "sun.max") }.help("Show sunlight on the globe").tint(store.sunlight ? .accentColor : .primary)
                Divider().frame(height: 20)
                toolButton("Ruler", icon: "ruler", tool: .ruler)
                Button { store.touring ? store.stopTour() : store.startTour() } label: { Label(store.touring ? "Stop Tour" : "Tour", systemImage: store.touring ? "stop.fill" : "play.rectangle") }.disabled(store.features.isEmpty).help("Fly through visible saved places")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.showLocalMCP = true } label: { Label(store.mcpEnabled ? "Local MCP · On" : "Local MCP · Off", systemImage: "network") }
                    .labelStyle(.iconOnly).tint(store.mcpEnabled ? .green : .primary)
                    .help(store.mcpEnabled ? "Local MCP is on · Manage local LLM control" : "Local MCP is off · Manage local LLM control")
                    .accessibilityIdentifier("local-mcp-toolbar")
                Button { store.importFile() } label: { Label("Open", systemImage: "folder") }.help("Open KML or KMZ")
                Button { store.exportKML() } label: { Label("Export", systemImage: "square.and.arrow.up") }.disabled(store.features.isEmpty).help("Export all saved places as KML")
                Button { store.googleSettings = true } label: { Label("Connect Google", systemImage: "key") }.help("Optional: connect your own Google Maps API key. Apple Maps and OpenStreetMap need no key.")
                Button { store.openExternalMap() } label: { Label("View in Google Maps", systemImage: "map") }.help("Open this view in Google Maps")
                Button { store.printView() } label: { Label("Print", systemImage: "printer") }.disabled(store.busy)
                Button { store.recordVideo() } label: { Label(store.recording ? "Stop Recording" : "Record Video", systemImage:store.recording ? "stop.circle.fill" : "record.circle") }.disabled(store.recordingFinishing).tint(store.recording ? .red : .primary)
                Button { store.saveImage() } label: { Label("Save Image", systemImage: "camera") }.disabled(store.busy)
            }
        }
        .alert("Earth Pro", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .sheet(item: $store.publicDataSelection) { feature in PublicDataDetailView(store: store, feature: feature) }
        .sheet(isPresented: $store.showCustomData) { CustomDataView(store: store) }
        .sheet(isPresented: $store.showSourceDates) { SourceDatesView(store: store) }
        .sheet(isPresented: $store.showAddressImport) { AddressImportView(store: store) }
        .sheet(isPresented: $store.showImageOverlays) { ImageOverlaysView(store:store) }
        .sheet(isPresented: $store.showLocalMCP) { LocalMCPView(store:store) }
        .sheet(isPresented: $store.googleSettings) { GoogleMapsSettingsView(store: store) }
        .onAppear { store.restoreMCPPreference(); store.loadImageOverlays(); store.restoreGoogleSession(); store.updateLayerFeeds(); store.updateElevation() }
        .onChange(of: store.mode) { store.stopHistoryPlayback(); store.cursorPoint = nil; store.updateLayerFeeds(); store.refreshArchive() }
        .onChange(of: store.latitude) { store.cursorPoint = nil; store.scheduleNearbyLayerRefresh(); store.updateElevation() }
        .onChange(of: store.longitude) { store.cursorPoint = nil; store.scheduleNearbyLayerRefresh(); store.updateElevation() }
        .onChange(of: store.distance) { store.scheduleNearbyLayerRefresh() }
        .onChange(of: store.cursorPoint) { store.updateElevation(); store.scheduleImageryMetadata() }
        .onChange(of: store.latitude) { store.scheduleImageryMetadata() }
        .onChange(of: store.longitude) { store.scheduleImageryMetadata() }
        .onChange(of: store.distance) { store.scheduleImageryMetadata() }
        .onChange(of: store.cameraRequest) { store.refreshPublicData(); if store.showPublicData { store.scheduleDataDiscovery() } }
        .onChange(of: store.latitude) { if store.showPublicData { store.scheduleDataDiscovery() } }
        .onChange(of: store.longitude) { if store.showPublicData { store.scheduleDataDiscovery() } }
        .onChange(of: store.distance) { if store.showPublicData { store.scheduleDataDiscovery() } }
        .onChange(of: store.showPublicData) {
            if store.showPublicData {
                sidebar = true
                if store.sidebarSection != .data { store.setSidebarSection(.data) }
                store.scheduleDataDiscovery()
            } else {
                store.discoveryTask?.cancel()
                if sidebar && store.sidebarSection == .data { store.setSidebarSection(.places) }
            }
        }
        .onChange(of: store.sidebarSection) { if store.sidebarSection == .data { sidebar = true } }
        .onChange(of: sidebar) {
            if sidebar && store.sidebarSection == .data { store.showPublicData = true }
            else if !sidebar { store.showPublicData = false }
        }
        .onChange(of: store.mode) { store.refreshPublicData() }
        .onChange(of: store.provider) { store.refreshPublicData() }
        .onChange(of: store.layers) { store.refreshPublicData() }
        .onChange(of: store.streetView) { store.refreshPublicData() }
        .onChange(of: store.latitude) { store.refreshPublicData() }
        .onChange(of: store.longitude) { store.refreshPublicData() }
        .onChange(of: store.distance) { store.refreshPublicData() }
        .onChange(of: store.miles) { store.updateElevation() }
        .sheet(item: $store.layerSelection) { LayerItemDetail(item: $0) }
        .sheet(item: $store.editingFeature) { feature in FeatureEditor(store: store, feature: feature) }
        .onDisappear { store.stopHistoryPlayback() }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url, ["kml", "kmz"].contains(url.pathExtension.lowercased()) { urls.append(url) }
                }
                if !urls.isEmpty { store.importURLs(urls) }
            }
            return true
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 8).stroke(.blue, lineWidth: 4).allowsHitTesting(false) } }
    }
    private func toolButton(_ title: String, icon: String, tool: EarthTool) -> some View {
        Button { store.tool == tool ? store.cancelTool() : store.begin(tool) } label: { Label(title, systemImage: icon) }
            .tint(store.tool == tool ? .accentColor : .primary).help(title)
    }
    private var viewport: some View {
        ZStack(alignment: .topLeading) {
            if store.mode == .globe { GlobeCanvas(store: store).frame(maxWidth: .infinity, maxHeight: .infinity) } else if store.provider == .google {
                if store.googleKey != nil { GoogleMapCanvas(store: store).id(store.googleRevision).onDisappear { store.googleReady = false }.frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { Color(nsColor: .windowBackgroundColor).overlay { googleSetup } }
            } else { MapCanvas(store: store).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let image = store.transitionImage, store.mode == .map {
                Image(nsImage: image).resizable().scaledToFill().clipped().allowsHitTesting(false)
                    .overlay(alignment: .bottomLeading) { Text("Loading destination…").padding(8).background(.regularMaterial) }
                    .task(id: store.cameraRequest) {
                        try? await Task.sleep(for: .seconds(8))
                        if !Task.isCancelled { store.transitionImage = nil }
                    }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if !store.streetView {
                    Picker("View", selection: Binding(get: { store.mode }, set: { mode in DispatchQueue.main.async { store.setMode(mode) } })) { ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 160).padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    Group {
                        Picker("Map provider", selection: Binding(get: { store.provider }, set: { value in DispatchQueue.main.async { store.chooseProvider(value) } })) {
                            ForEach(MapProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 155).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                        if store.mode == .map && store.provider != .openStreetMap { Picker("Map style", selection: $store.mapStyle) { ForEach(MapStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 190).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)) }
                    }
                    }
                    Spacer()
                    if store.mode == .map, store.provider == .google, store.googleKey != nil {
                        Button(store.streetView ? "Exit Street View" : "Street View", systemImage: "figure.walk") { store.toggleStreetView() }
                            .disabled(!store.googleReady).padding(9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    }
                    if store.touring { Button("Stop Tour", systemImage: "stop.fill") { store.stopTour() }.padding(9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)) }
                }
                if store.mode == .map, store.provider == .google, let failure = store.googleError {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Google Maps needs attention", systemImage: "exclamationmark.triangle").font(.headline)
                        Text(failure).font(.callout).fixedSize(horizontal: false, vertical: true)
                        HStack { Button("Settings…") { store.googleSettings = true }; Button("Retry") { store.retryGoogle() }; Button("Use Apple Maps") { store.chooseProvider(.apple) } }
                    }.padding(16).frame(width: 360).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if store.recording || store.recordingFinishing {
                    HStack { Image(systemName:"record.circle.fill").foregroundStyle(.red); Text(store.recordingFinishing ? "Saving video…" : "Recording map view · 720p · silent"); if store.recording { Text(store.recordingStarted,style:.timer); Button("Stop & Save") { Task { await store.stopVideoRecording() } } } }.font(.caption).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                }
                if !store.recording && !store.recordingFinishing, let url=store.recordedVideoURL {
                    HStack { Label("Video saved",systemImage:"checkmark.circle"); Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.font(.caption).padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                }
                if store.historicalImagery { ImageryTimeline(store: store) }
                if store.sunlight && store.mode == .globe {
                    HStack {
                        Label("Sunlight", systemImage: "sun.max")
                        DatePicker("Time (UTC)", selection: $store.sunlightDate).environment(\.timeZone, EarthObservation.calendar.timeZone)
                        Button("Now") { store.sunlightDate = Date() }
                        Button { store.sunlight = false } label: { Image(systemName: "xmark") }.help("Hide sunlight")
                    }.font(.caption).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                if !hintDismissed, store.tool == .navigate {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "hand.draw").font(.title2)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Grab the globe. Go anywhere.").font(.headline)
                            Text("Drag to explore. Scroll or pinch to move closer.\nApple Maps and OpenStreetMap need no key. Google is optional.").font(.callout)
                        }
                        Button { hintDismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss navigation tips")
                    }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if store.tool != .navigate { DrawingPanel(store: store).frame(width: 340) }
                Spacer()
                HStack(alignment: .bottom) {
                    if store.mode == .globe {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("EARTH").font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(3)
                            Text(store.activeGlobeImagery?.credit ?? "NASA / Goddard Space Flight Center SVS · Natural Earth").font(.system(size: 9))
                            if store.terrain { Text("Terrain: Mapzen · USGS · NOAA and contributors").font(.system(size: 9)) }
                        }.foregroundStyle(.white.opacity(0.7)).padding(8).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                    }
                    if store.mode == .map, store.provider == .openStreetMap {
                        Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                            .font(.caption).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
                    if store.layers.primary && store.provider != .google && (store.layers.clouds || store.layers.photos || store.layers.earthquakes || store.layers.wikipedia) {
                        VStack(alignment: .leading, spacing: 3) {
                            if store.layers.clouds { Text("Cloud fraction: NASA MODIS · " + EarthLayerService.cloudDate) }
                            if store.layers.wikipedia { Text("Articles: Wikipedia contributors · CC BY-SA 4.0") }
                            if store.layers.photos { Text("Photos: Wikimedia Commons") }
                            if store.layers.earthquakes { Text("Earthquakes: USGS · Past 7 days") }
                        }.font(.system(size: 9)).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Spacer()
                    if !store.customDataFeatures.isEmpty {
                        Button { store.showCustomData = true } label: {
                            Text("Custom data: " + store.customDataLayers.filter(\.enabled).map(\.name).joined(separator: " · "))
                                .font(.system(size: 9)).lineLimit(2).multilineTextAlignment(.trailing)
                        }.buttonStyle(.plain).padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .help("Custom layer sources, coverage and update dates")
                    }
                    if !store.publicDataFeatures.isEmpty {
                        Button { store.openPublicDataBrowser() } label: {
                            Text("Public data: " + Array(Set(PublicDataKind.allCases.filter { kind in store.publicDataFeatures.contains { $0.kind == kind } }.map { PublicDataSource.source($0).publisher })).sorted().joined(separator: " · "))
                                .font(.system(size: 9)).multilineTextAlignment(.trailing)
                        }.buttonStyle(.plain).padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .help("Public-data source, coverage and terms")
                    }
                }
            }.padding(18)
            if store.showNavigation && !store.streetView {
                VStack { HStack { Spacer(); navigationControls }; Spacer() }.padding(.top, 70).padding(.trailing, 18)
            }
        }
    }
    private var googleSetup: some View {
        VStack(spacing: 14) {
            Image(systemName: "map.fill").font(.system(size: 44)).foregroundStyle(.blue)
            Text("Explore with Google Maps").font(.title2.bold())
            Text("Add your API key to use Google satellite imagery,\naddress search, and Street View.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Add Google Maps API Key…") { store.googleSettings = true }.buttonStyle(.borderedProminent)
            Button("Continue with Apple Maps") { store.chooseProvider(.apple) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
    private var navigationControls: some View {
        EarthNavigationControls(store: store) { cameraOptions.toggle() }
            .popover(isPresented: $cameraOptions, arrowEdge: .leading) { cameraPanel }
    }
    private var cameraPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Camera").font(.headline)
            Group {
                HStack { Text("Heading"); Spacer(); Text(String(format: "%.0f°", store.heading)).monospacedDigit() }
                Slider(value: Binding(get: { store.heading }, set: { store.heading = $0; store.cameraRequest = UUID() }), in: 0...360).accessibilityLabel("Camera heading")
                HStack { Text("Tilt"); Spacer(); Text(String(format: "%.0f°", store.pitch)).monospacedDigit() }
                Slider(value: Binding(get: { store.pitch }, set: { store.setPitch($0) }), in: 0...80).disabled(store.mode == .map && (!store.terrain || store.provider == .openStreetMap)).accessibilityLabel("Camera tilt")
            }
            Text("Drag to pan · Scroll or pinch to zoom\nShift-scroll to tilt · Middle/Shift-drag to orbit\n⌘-drag to look · Control/right-drag to zoom\nTwist trackpad to rotate · Space stops motion\nOption slows movement · N north · U top-down · R Earth").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(store.center.label).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            HStack {
                Button("Copy Coordinates") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(format: "%.6f, %.6f", store.latitude, store.longitude), forType: .string) }
                Button("Save Place…") { store.editingFeature = EarthFeature(name: "Untitled Placemark", kind: .point, points: [store.center]); cameraOptions = false }
            }
        }.font(.callout).padding(20).frame(width: 300)
    }
    private var observationDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Imagery and terrain information").font(.headline)
            Text(store.imageryInformation)
            if store.showingStreetImagery {
                Text(store.imageryDateHelp)
            } else if store.historicalImagery {
                Text(store.historyAttribution + ". Available imagery loads as tiles. Clouds and gaps may show the underlying map. Release dates are separate from capture dates.")
                Link("NASA GIBS imagery information ↗", destination: URL(string: "https://nasa-gibs.github.io/gibs-api-docs/")!)
            } else {
                Text(store.imageryDateHelp)
            }
            Divider()
            Text(store.elevationSource)
            Text("Elevation starts with a coarse bundled estimate, including ocean-floor depths. Online Copernicus GLO-90 data refines land elevations after the pointer stops. Globe terrain remains a separate coarse model.")
            Link("Open-Meteo / Copernicus elevation source ↗", destination: URL(string: "https://open-meteo.com/en/docs/elevation-api")!)
            Link("Bundled terrain sources ↗", destination: URL(string: "https://github.com/tilezen/joerd/blob/master/docs/attribution.md")!)
            Text("The free elevation endpoint is intended for non-commercial use.").font(.caption).foregroundStyle(.secondary)
            Text("Eye altitude is the approximate camera height above a spherical Earth. Terrain clearance is not included.")
        }.font(.callout).padding(20).frame(width: 360)
    }
    private var statusBar: some View {
        HStack(spacing: 10) {
            if store.busy || store.searching { ProgressView().controlSize(.mini) }
            Text(store.imageryInformation).lineLimit(1).onTapGesture { imageryDetails = true }.popover(isPresented: $imageryDetails) { observationDetails }.help(store.imageryDateHelp)
            Spacer(minLength: 4)
            Text(store.imageryDateLabel).monospacedDigit().fixedSize().help(store.imageryDateHelp)
                .accessibilityIdentifier("imagery-date")
                .onTapGesture { imageryDetails = true }
            Divider().frame(height: 12)
            Text(EarthObservation.coordinates(store.observationPoint, dms: store.dmsCoordinates)).monospacedDigit().textSelection(.enabled).help(store.cursorPoint == nil ? "View center coordinates" : "Pointer coordinates")
            Divider().frame(height: 12)
            Text(store.elevationStatus).monospacedDigit().help(store.elevationSource + ". Elevation at the pointer, or view center. Coarse estimates are marked; online land refinement requires internet.")
            Divider().frame(height: 12)
            Text(store.eyeAltitudeLabel).monospacedDigit().help("Approximate camera height above the reference sphere, calculated from camera distance and tilt. Terrain clearance is not included.")
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28).background(.bar)
    }

}

private struct DrawingPanel: View {
    @ObservedObject var store: EarthStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(store.tool.title).font(.headline); Spacer(); Button { store.cancelTool() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Cancel drawing") }
            Text(store.tool == .placemark ? "Click the globe or map to choose a location." : "Click the globe or map to add points.").font(.callout).foregroundStyle(.secondary)
            if store.tool != .placemark {
                Text("\(store.vertices.count) points").foregroundStyle(.secondary)
                MeasurementOptions(store: store, showsArea: store.tool == .polygon)
                Text(store.tool == .polygon ? "Perimeter" : "Length").font(.caption).foregroundStyle(.secondary)
                Text(store.formatMeasurementDistance(store.drawingDistance)).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit().textSelection(.enabled).minimumScaleFactor(0.6).lineLimit(1)
                if store.tool == .polygon {
                    Text("Area").font(.caption).foregroundStyle(.secondary)
                    Text(store.formatMeasurementArea(GeoMath.area(store.vertices))).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit().textSelection(.enabled).minimumScaleFactor(0.6).lineLimit(1)
                }
                HStack {
                    Button("Undo Point") { _ = store.vertices.popLast() }.disabled(store.vertices.isEmpty)
                    Spacer()
                    Button(store.tool == .ruler ? "Save Path…" : "Finish…") { store.finishDrawing() }.buttonStyle(.borderedProminent).disabled(!store.canFinish)
                }
            }
        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
    }
}
