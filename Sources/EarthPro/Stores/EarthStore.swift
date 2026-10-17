import SwiftUI
import AppKit
import MapKit
import UniformTypeIdentifiers

@MainActor final class EarthStore: ObservableObject {
    @Published var sidebarSection: SidebarSection = .places
    @Published var folders: [EarthFolder] = []
    @Published var selectedFolderID: UUID?
    @Published var showFolderEditor = false
    var foldersWritable = true
    @Published var placeDataArea = "Current map view"
    @Published var placeDataRegion: PlaceDataRegion?
    @Published var discoveredData: [DiscoveredDataService] = []
    @Published var discoveryStatus = ""
    @Published var discoveryQuery = ""
    @Published var discoveryLoading = false
    @Published var discoveryFollowsMap = true
    var discoveryManualCenter: GeoPoint?
    var discoveryTask: Task<Void, Never>?
    var discoveryGeneration = UUID()
    var discoveryLastCenter: GeoPoint?
    var discoveryLastLookup = Date.distantPast
    @Published var showCustomData = false
    @Published var showSourceDates = false
    @Published var sourceFreshness: [String: SourceFreshness] = [:]
    var sourceFreshnessTask: Task<Void, Never>?
    @Published var customDataLayers: [CustomDataLayer] = []
    @Published var customDataSnapshots: [UUID: [EarthFeature]] = [:]
    @Published var customDataStatus: [UUID: String] = [:]
    @Published var customDataLoading: Set<UUID> = []
    @Published var customDataImporting = false
    @Published var customDataImportError: String?
    @Published var customDataLastImportedID: UUID?
    var customDataTasks: [UUID: Task<Void, Never>] = [:]
    var customDataSaveTask: Task<Void, Never>?
    var customDataGenerations: [UUID: UUID] = [:]
    var customDataWritable = true
    @Published var showPublicData = false
    @Published var publicDataEnabled: Set<PublicDataKind> = []
    @Published var publicDataHidden: Set<PublicDataKind> = []
    @Published var publicDataOpacity: [PublicDataKind: Double] = [:]
    @Published var publicDataStatus: [PublicDataKind: String] = [:]
    @Published var publicDataLoading: Set<PublicDataKind> = []
    @Published var publicDataSnapshots: [PublicDataKind: PublicDataSnapshot] = [:]
    @Published var publicDataRevision = UUID()
    @Published var publicDataSelection: PublicDataFeature?
    @Published var publicDataAttributes: [String: String] = [:]
    @Published var publicDataDetailLoading = false
    @Published var publicDataCounties: [PublicDataPortal] = []
    var publicDataViewSize = CGSize(width: 1200, height: 800) { didSet { if oldValue != publicDataViewSize { refreshPublicData() } } }
    var publicDataTask: Task<Void, Never>?
    var publicDataDetailTask: Task<Void, Never>?
    var publicDataSaveTask: Task<Void, Never>?
    var publicDataGeneration = UUID()
    var publicDataVisibilityKey = ""
    var publicDataFetchScale: [PublicDataKind: Double] = [:]
    var publicDataFetch: ((PublicDataKind, PublicDataBounds, Double) async throws -> PublicDataSnapshot)?
    @Published var imageryTileRevision = UUID()
    @Published var historyProduct: HistoryProduct = .modis { didSet { stopHistoryPlayback(); imageryDate = max(imageryDate, historyProduct.earliest); refreshArchive(); scheduleImageryMetadata() } }
    @Published var waybackReleases: [WaybackRelease] = []
    @Published var waybackReleaseID = "" { didSet { scheduleImageryMetadata() } }
    @Published var waybackLoading = false
    @Published var historyDates: [String] = []
    @Published var historyCatalogStatus = "Select a source and date"
    @Published var captureDate: String?
    @Published var captureSource = ""
    @Published var transitionImage: NSImage?
    var imageryMetadataTask: Task<Void, Never>?
    var historyCatalogTask: Task<Void, Never>?
    @Published var historicalImagery = false { didSet { if !historicalImagery { stopHistoryPlayback() } else if mode == .map { pitch = 0; cameraRequest = UUID() }; refreshArchive() } }
    @Published var imageryDate = EarthObservation.latest { didSet { refreshArchive() } }
    @Published var historyPlaying = false
    @Published var historyStepDays = 30
    @Published var archiveLoading = false
    private var historyTimer: Timer?
    private var archiveCache: [String: NSImage] = [:]
    private var archiveCacheOrder: [String] = []
    @Published var recentSearches: [String] = []
    @Published var archiveImage: NSImage?
    @Published var archiveLoadedDate: String?
    @Published var archiveStatus = "NASA MODIS · Daily archive · 250 m source resolution"
    @Published var sunlight = false
    @Published var sunlightDate = Date()
    @Published var showNavigation = true
    @Published var showStatus = true
    @Published var dmsCoordinates = true
    @Published var cursorPoint: GeoPoint?
    @Published var elevationSource = "Terrain elevation"
    @Published var elevationMeters: Double?
    @Published var elevationStatus = "Elevation —"
    private var elevationTask: Task<Void, Never>?
    private var elevationCache: [String: Double] = [:]
    private var archiveTask: Task<Void, Never>?
    private var archiveGeneration = UUID()
    @Published var imageOverlays: [EarthImageOverlay] = [] { didSet { imageOverlayRevision=UUID() } }
    @Published var imageOverlayRevision=UUID()
    @Published var showImageOverlays=false
    @Published var overlayEditingID: UUID?
    var imageOverlaysWritable=true
    @Published var recording=false
    @Published var recordingFinishing=false
    @Published var recordingStarted=Date()
    @Published var recordedVideoURL: URL?
    @Published var recordingURL: URL?
    var recordingTask: Task<Void,Never>?
    var movieWriter: EarthMovieWriter?
    @Published var showLocalMCP=false
    @Published var mcpEnabled=false
    @Published var mcpStatus="Off"
    var mcpPreferenceRestored = false
    var localMCP: EarthMCPServer?
    @Published var features: [EarthFeature] = []
    @Published var selection: UUID?
    @Published var editingFeature: EarthFeature?
    @Published var showAddressImport = false
    var pendingAddressLookup: (id: UUID, continuation: CheckedContinuation<SearchHit, Error>)?
    var addressLookupTimeout: Task<Void, Never>?
    @Published var mode: ViewMode = .globe
    @Published var mapStyle: MapStyle = .hybrid
    @Published var provider: MapProvider = .apple
    @Published private(set) var googleKey: String?
    @Published var googleKeyLoading = false
    @Published var googleKeyAccessError: String?
    private var googleKeyGeneration = UUID()
    private var googleKeyInteraction = false
    private var pendingGoogleSelection = false
    private var googleSessionRestored = false
    private let googleKeyReader: @Sendable (Bool) throws -> String?
    private let googlePreferences: UserDefaults
    @Published var googleSettings = false
    @Published var googleRevision = UUID()
    @Published var google3DActive = false
    @Published var google3DError: String?
    @Published var googleReady = false
    @Published var googleError: String?
    @Published var googleQuery: (id: UUID, text: String)?
    @Published var streetView = false {
        didSet { if !streetView { streetImageryDate = nil; streetImageryLoading = false } }
    }
    @Published var streetRequest = UUID() {
        didSet { streetImageryDate = nil; streetImageryLoading = false }
    }
    @Published var streetImageryDate: String?
    @Published var streetImageryLoading = false
    @Published var layers = EarthLayers() {
        didSet {
            if savesProviderPreference, let data = try? JSONEncoder().encode(layers) { UserDefaults.standard.set(data, forKey: "earthLayers") }
            updateLayerFeeds()
        }
    }
    @Published var layerItems: [EarthLayerItem] = []
    @Published var layerSelection: EarthLayerItem?
    @Published var layerRevision = UUID()
    @Published var wikipediaStatus = "Zoom to a city to load nearby articles"
    private var wikipediaTask: Task<Void, Never>?
    private var wikipediaCenter: GeoPoint?
    @Published var photoStatus = "Zoom to a city, then enable photos"
    @Published var earthquakeStatus = "USGS · M2.5+ · Past 7 days"
    @Published var cloudStatus = "NASA MODIS · Daily cloud fraction"
    @Published var cloudImage: NSImage?
    private var photoTask: Task<Void, Never>?
    private var earthquakeTask: Task<Void, Never>?
    private var cloudTask: Task<Void, Never>?
    private var photoCenter: GeoPoint?
    private var earthquakeLoaded = false
    private var earthquakeGeneration = UUID()
    private var cloudGeneration = UUID()
    @Published var terrain = true { didSet { if !terrain { pitch = 0 }; cameraRequest = UUID(); saveLayerFlag("earthTerrain", terrain) } }
    @Published var grid = false { didSet { saveLayerFlag("earthGrid", grid) } }
    @Published var showPlaces = true { didSet { saveLayerFlag("earthSavedPlaces", showPlaces) } }
    @Published var latitude = 22.0
    @Published var longitude = -95.0
    @Published var distance = 16_000_000.0
    @Published var heading = 0.0
    @Published var pitch = 0.0
    @Published var cameraRequest = UUID()
    @Published var tool: EarthTool = .navigate
    @Published var vertices: [GeoPoint] = []
    @Published var searchText = "" { didSet { if searchText != oldValue { updateSearchSuggestions() } } }
    @Published var searchSuggestions: [MKLocalSearchCompletion] = []
    @Published var searchPin: EarthFeature?
    @Published var searchHits: [SearchHit] = []
    @Published var searching = false
    @Published var busy = false
    @Published var status = "Drag to explore · Scroll to zoom · Double-click for satellite detail"
    @Published var error: String?
    @Published var measurementDistanceUnit: DistanceUnit = .meters { didSet { saveMeasurementPreferences() } }
    @Published var measurementAreaUnit: AreaUnit = .squareMeters { didSet { saveMeasurementPreferences() } }
    @Published var measurementDistanceDecimals = 2 { didSet { saveMeasurementPreferences() } }
    @Published var measurementAreaDecimals = 2 { didSet { saveMeasurementPreferences() } }
    @Published var miles = false
    @Published var touring = false
    private var lastNavigationInput = Date.distantPast
    // Keep camera changes immediate through the next SwiftUI render after each input event.
    var navigationIsActive: Bool {
        get { Date().timeIntervalSince(lastNavigationInput) < 0.18 }
        set { if newValue { lastNavigationInput = Date() } }
    }
    var globeSnapshot: (() -> NSImage)?
    var mapSnapshot: (() async throws -> NSImage)?
    private var searchTask: Task<Void, Never>?
    private var localSearch: MKLocalSearch?
    private lazy var searchCompleter = PlaceSearchCompleter { [weak self] in self?.searchSuggestions = $0 }
    private var tourTask: Task<Void, Never>?
    private var undoHistory: [[EarthFeature]] = []
    private var redoHistory: [[EarthFeature]] = []
    let libraryURL: URL
    var writable = true
    private let savesProviderPreference: Bool

    var center: GeoPoint { .init(latitude: latitude, longitude: longitude) }
    var selectedFeature: EarthFeature? { features.first { $0.id == selection } ?? (searchPin?.id == selection ? searchPin : nil) ?? customDataFeatures.first { $0.id == selection } }
    var renderedFeatures: [EarthFeature] { (showPlaces ? features.filter { $0.isVisible && $0.id != searchPin?.id } : []) + (searchPin.map { [$0] } ?? []) + customDataFeatures }
    var drawingDistance: Double { GeoMath.length(vertices, closed: tool == .polygon) }
    var canFinish: Bool { vertices.count >= (tool == .polygon ? 3 : 2) }
    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    init(libraryURL: URL? = nil,
         googleKeyReader: (@Sendable (Bool) throws -> String?)? = nil,
         googlePreferences: UserDefaults = .standard) {
        if let googleKeyReader { self.googleKeyReader = googleKeyReader }
        else if libraryURL == nil { self.googleKeyReader = { try GoogleMapsKeychain.read(allowInteraction: $0) } }
        else { self.googleKeyReader = { _ in nil } }
        self.googlePreferences = googlePreferences
        savesProviderPreference = libraryURL == nil
        self.libraryURL = libraryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EarthPro/library.json")
        if libraryURL == nil, UserDefaults.standard.string(forKey: "freeMapProvider") == MapProvider.openStreetMap.rawValue { provider = .openStreetMap }
        if libraryURL == nil {
            if let value = UserDefaults.standard.string(forKey: "earthMeasurementDistance"), let unit = DistanceUnit(rawValue: value) { measurementDistanceUnit = unit }
            if let value = UserDefaults.standard.string(forKey: "earthMeasurementArea"), let unit = AreaUnit(rawValue: value) { measurementAreaUnit = unit }
            let previousDecimals = UserDefaults.standard.object(forKey: "earthMeasurementDecimals") as? Int ?? 2
            measurementDistanceDecimals = max(-1, min(9, UserDefaults.standard.object(forKey: "earthMeasurementDistanceDecimals") as? Int ?? previousDecimals))
            measurementAreaDecimals = max(-1, min(9, UserDefaults.standard.object(forKey: "earthMeasurementAreaDecimals") as? Int ?? previousDecimals))
            recentSearches = Array((UserDefaults.standard.stringArray(forKey: "earthRecentSearches") ?? []).prefix(20))
            if let flag = UserDefaults.standard.object(forKey: "earthTerrain") as? Bool { terrain = flag }
            if let flag = UserDefaults.standard.object(forKey: "earthGrid") as? Bool { grid = flag }
            if let flag = UserDefaults.standard.object(forKey: "earthSavedPlaces") as? Bool { showPlaces = flag }
        }
        if libraryURL == nil, let data = UserDefaults.standard.data(forKey: "earthLayers"), let saved = try? JSONDecoder().decode(EarthLayers.self, from: data) { layers = saved }
        do {
            if FileManager.default.fileExists(atPath: self.libraryURL.path) {
                let data = try Data(contentsOf: self.libraryURL)
                features = try JSONDecoder().decode([EarthFeature].self, from: data)
                guard features.allSatisfy(\.isValid) else { throw KMLError.invalid("The saved library contains invalid geometry.") }
            }
        } catch {
            features = []; writable = false
            self.error = "Your places could not be read at \(self.libraryURL.path). The existing file has been preserved. New work can be exported as KML. \(error.localizedDescription)"
        }
        restorePublicDataSettings()
        restoreCustomData()
        restoreFolders()
        if libraryURL == nil, let value = UserDefaults.standard.string(forKey: "earthSidebarSection"), let section = SidebarSection(rawValue: value) {
            sidebarSection = section; showPublicData = section == .data
        }
    }

    func setSidebarSection(_ section: SidebarSection) {
        sidebarSection = section; showPublicData = section == .data
        if savesProviderPreference { UserDefaults.standard.set(section.rawValue, forKey: "earthSidebarSection") }
    }

    func restoreGoogleSession() {
        guard !googleSessionRestored else { return }
        googleSessionRestored = true
        loadGoogleKey(allowInteraction: false, selectGoogle: googlePreferences.string(forKey: "earthMapProvider") == MapProvider.google.rawValue)
    }
    func loadGoogleKey(allowInteraction: Bool = true, selectGoogle: Bool = false) {
        pendingGoogleSelection = pendingGoogleSelection || selectGoogle
        if googleKey != nil {
            if pendingGoogleSelection { pendingGoogleSelection = false; chooseProvider(.google); googleSettings = false }
            return
        }
        // An explicit user request can escalate a silent launch-time read. Stale reads
        // cannot overwrite a newly saved key or resurrect an explicitly removed key.
        guard !googleKeyLoading || (allowInteraction && !googleKeyInteraction) else { return }
        googleKeyLoading = true; googleKeyAccessError = nil; googleKeyInteraction = allowInteraction
        googleKeyGeneration = UUID(); let generation = googleKeyGeneration, reader = googleKeyReader
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.googleKeyGeneration == generation, self.googleKeyLoading else { return }
            self.googleKeyLoading = false
            self.googleKeyAccessError = "macOS Keychain has not responded yet. Approve any Keychain prompt or retry the saved key; re-entry is not required."
            self.status = "Google key waiting for Keychain · Free maps remain available"
        }
        Task { [weak self] in
            let result = await Task.detached { Result { try reader(allowInteraction) } }.value
            guard let self, self.googleKeyGeneration == generation else { return }
            self.googleKeyLoading = false
            switch result {
            case .success(let key):
                self.googleKey = key
                if key != nil, self.pendingGoogleSelection {
                    self.pendingGoogleSelection = false; self.chooseProvider(.google); self.googleSettings = false
                }
            case .failure:
                self.googleKeyAccessError = "The saved key could not be accessed. Allow macOS Keychain access and retry; you do not need to enter the key again."
                self.status = "Google key needs Keychain access · Free maps remain available"
            }
        }
    }
    func saveGoogleKey(_ input: String) throws {
        guard let key = GoogleMapsKeychain.normalized(input) else { throw KMLError.invalid("Enter an API key containing only letters, numbers, underscores, and hyphens (20–200 characters).") }
        try GoogleMapsKeychain.write(key)
        googleKeyGeneration = UUID(); googleKeyLoading = false; googleKeyAccessError = nil; googleKey = key; retryGoogle()
    }
    func removeGoogleKey() throws {
        try GoogleMapsKeychain.remove(); googleKeyGeneration = UUID(); googleKeyLoading = false; googleKeyAccessError = nil; googleKey = nil; pendingGoogleSelection = false
        chooseProvider(.apple)
    }
    func chooseProvider(_ value: MapProvider) {
        guard value != .google || googleKey != nil else { googleSettings = true; loadGoogleKey(selectGoogle: true); return }
        stopTour(); streetView = false; streetRequest = UUID()
        searchTask?.cancel(); localSearch?.cancel(); searching = false; searchHits = []; googleQuery = nil
        searchCompleter.update(""); searchSuggestions = []
        pendingGoogleSelection = false
        if savesProviderPreference { googlePreferences.set(value.rawValue, forKey: "earthMapProvider") }
        google3DActive = false; google3DError = nil
        provider = value
        if value == .google {
            retryGoogle()
            setMode(.map)
            status = "Google Maps · Your project’s usage and billing apply"
        } else {
            if savesProviderPreference { UserDefaults.standard.set(value.rawValue, forKey: "freeMapProvider") }
            if value == .openStreetMap { pitch = 0 }
            status = "\(value.rawValue) · No API key needed · Drag to explore"
        }
        if layers.primary && layers.buildings { configureBuildingsView() }
        cameraRequest = UUID()
    }
    func retryGoogle() {
        google3DActive = false; google3DError = nil; googleReady = false; googleError = nil; streetView = false; streetRequest = UUID(); googleRevision = UUID()
    }
    func toggleStreetView() {
        guard provider == .google, googleKey != nil else { googleSettings = true; return }
        cancelTool(); streetView.toggle(); streetRequest = UUID()
        if streetView { status = "Looking for nearby Street View…" }
    }
    private func remember() { undoHistory.append(features); if undoHistory.count > 40 { undoHistory.removeFirst() }; redoHistory = [] }
    func persist() {
        guard writable else { status = "Library unavailable · Export KML to keep your work"; return }
        do {
            try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(features).write(to: libraryURL, options: .atomic)
        } catch { self.error = "Could not save your places: \(error.localizedDescription)" }
    }
    func save(_ feature: EarthFeature) {
        var feature = feature; feature.name = feature.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard feature.isValid else { error = "A name and valid coordinates are required."; return }
        if feature.folderID == nil, !features.contains(where: { $0.id == feature.id }) { feature.folderID = selectedFolderID }
        remember()
        if let i = features.firstIndex(where: { $0.id == feature.id }) { features[i] = feature } else { features.append(feature) }
        if searchPin?.id == feature.id { searchPin = nil }
        selection = feature.id; editingFeature = nil; tool = .navigate; vertices = []
        status = "Saved \(feature.name)"; persist()
    }
    func addAddressPins(_ pins: [EarthFeature]) {
        let valid = pins.filter { $0.kind == .point && $0.isValid }
        guard !valid.isEmpty else { return }
        remember(); features += valid; showPlaces = true; searchPin = nil
        persist()
        if let viewport = AddressPinImporter.viewport(valid.map(\.center)) {
            fly(to: viewport.center, distance: viewport.distance); pitch = 0; cameraRequest = UUID()
        }
        selection = valid.count == 1 ? valid.first?.id : nil
        status = "Plotted \(valid.count) addresses · Saved in My Places · Undo available"
    }
    func delete(_ feature: EarthFeature) {
        remember(); features.removeAll { $0.id == feature.id }
        if selection == feature.id { selection = nil }; persist(); status = "Deleted \(feature.name) · Undo available"
    }
    func setVisibility(_ id: UUID, _ visible: Bool) {
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        remember(); features[index].isVisible = visible; persist()
    }
    func undo() { guard let old = undoHistory.popLast() else { return }; redoHistory.append(features); features = old; persist(); status = "Undone" }
    func redo() { guard let next = redoHistory.popLast() else { return }; undoHistory.append(features); features = next; persist(); status = "Redone" }
    func setMode(_ newMode: ViewMode) {
        guard newMode != mode else { return }
        mode = newMode
        streetView = false; streetRequest = UUID()
        if newMode == .globe { distance = max(distance, 5_000_000); heading = 0; pitch = 0 }
        else { distance = min(distance, 4_000_000) }
        cameraRequest = UUID()
    }
    func fly(to point: GeoPoint, distance: Double = 15_000, detail: Bool = true, interruptTour: Bool = true) {
        guard point.isValid else { error = "This place has invalid coordinates."; return }
        if interruptTour { stopTour() }; cancelTool(); cursorPoint = nil
        if detail, mode == .globe { transitionImage = globeSnapshot?() }
        streetView = false; streetRequest = UUID()
        latitude = max(-85, min(85, point.latitude)); longitude = GeoMath.normalizedLongitude(point.longitude)
        self.distance = max(100, min(40_000_000, distance)); heading = 0
        if detail { mode = .map; pitch = terrain && !historicalImagery && provider != .openStreetMap && distance < 100_000 ? 45 : 0 }
        cameraRequest = UUID(); status = point.label
    }
    func fly(to feature: EarthFeature, interruptTour: Bool = true) {
        guard let frame = GeoMath.framing(feature.points) else { error = "This place has no valid coordinates."; return }
        selection = feature.id
        fly(to: frame.center, distance: frame.distance, interruptTour: interruptTour)
        status = feature.name
    }
    func home() { stopTour(); cancelTool(); streetView = false; streetRequest = UUID(); latitude = 22; longitude = -95; distance = 16_000_000; heading = 0; pitch = 0; mode = .globe; cameraRequest = UUID(); status = "Earth · Drag to explore" }
    func zoom(_ factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        distance = max(150, min(45_000_000, distance * factor))
        // A tiled globe now remains detailed at close range; zoom never replaces its renderer.
        cameraRequest = UUID()
    }
    func navigationZoom(_ factor: Double, anchor: GeoPoint? = nil, automaticallyTilt: Bool = false) {
        guard factor.isFinite, factor > 0 else { return }
        navigationIsActive = true
        let oldDistance = distance
        zoom(factor)
        if let anchor, anchor.isValid {
            let ratio = distance / oldDistance
            latitude = max(-85, min(85, anchor.latitude + (latitude - anchor.latitude) * ratio))
            longitude = GeoMath.normalizedLongitude(anchor.longitude + GeoMath.normalizedLongitude(longitude - anchor.longitude) * ratio)
        }
        if automaticallyTilt, terrain, provider != .openStreetMap { pitch = max(0, min(60, 60 * (1 - distance / 200_000))) }
        cameraRequest = UUID()
    }
    func navigationOrbit(dx: Double, dy: Double, look: Bool = false) {
        guard dx.isFinite, dy.isFinite else { return }
        navigationIsActive = true
        let oldPitch = pitch
        let eye = EarthNavigation.offset(center, bearing: heading + 180, meters: distance * sin(oldPitch * .pi / 180))
        heading = (heading + dx).truncatingRemainder(dividingBy: 360)
        if heading < 0 { heading += 360 }
        pitch = mode == .map && (!terrain || provider == .openStreetMap) ? 0 : max(0, min(80, pitch + dy))
        if look {
            distance = max(150, min(45_000_000, distance * cos(oldPitch * .pi / 180) / cos(pitch * .pi / 180)))
            let target = EarthNavigation.offset(eye, bearing: heading, meters: distance * sin(pitch * .pi / 180))
            latitude = max(-85, min(85, target.latitude)); longitude = target.longitude
        }
        cameraRequest = UUID()
    }
    func navigateDrag(_ mode: EarthDragMode, dx: Double, dy: Double, height: Double, fine: Bool = false) {
        guard dx.isFinite, dy.isFinite, height.isFinite, height > 0 else { return }
        let speed = fine ? 0.2 : 1.0
        switch mode {
        case .orbit, .look: navigationOrbit(dx: -dx * 0.3 * speed, dy: -dy * 0.3 * speed, look: mode == .look)
        case .zoom: navigationZoom(exp(max(-0.7, min(0.7, dy * 0.01 * speed))), automaticallyTilt: true)
        case .pan:
            navigationIsActive = true
            let h = heading * .pi / 180
            let scale = distance * 2 * tan(19 * .pi / 180) / height * speed
            let east = -(dx * cos(h) + dy * sin(h)) * scale
            let north = (dx * sin(h) - dy * cos(h)) * scale
            let target = EarthNavigation.offset(center, bearing: atan2(east, north) * 180 / .pi, meters: hypot(east, north))
            latitude = max(-85, min(85, target.latitude)); longitude = target.longitude
            cameraRequest = UUID()
        }
    }
    func navigationPad(look: Bool, x: Double, y: Double, seconds: Double) {
        guard x.isFinite, y.isFinite, seconds.isFinite, seconds > 0 else { return }
        let elapsed = min(0.2, seconds), length = max(1, hypot(x, y)), dx = x / length, dy = y / length
        stopTour(); navigationIsActive = true
        if look { navigationOrbit(dx: dx * 45 * elapsed, dy: dy * 30 * elapsed, look: true) }
        else if dx != 0 || dy != 0 {
            let target = EarthNavigation.offset(center, bearing: heading + atan2(dx, -dy) * 180 / .pi, meters: distance * 0.18 * hypot(dx, dy) * elapsed)
            latitude = max(-85, min(85, target.latitude)); longitude = target.longitude; cameraRequest = UUID()
        }
    }
    func north() { stopTour(); navigationIsActive = true; heading = 0; cameraRequest = UUID() }
    func setPitch(_ value: Double) { guard value.isFinite else { return }; pitch = max(0, min(80, value)); cameraRequest = UUID() }
    func begin(_ tool: EarthTool) {
        stopTour(); streetView = false; streetRequest = UUID(); self.tool = tool; vertices = []
        status = tool == .placemark ? "Click the globe or map to place a marker" : "Click to add points · Finish when ready"
    }
    func pick(_ point: GeoPoint) {
        guard point.isValid else { return }
        if tool == .placemark { editingFeature = EarthFeature(name: "Untitled Placemark", kind: .point, points: [point]); return }
        guard tool != .navigate else { status = point.label; return }
        vertices.append(point); status = "\(vertices.count) points · \(formatMeasurementDistance(drawingDistance))"
    }
    func finishDrawing() {
        guard canFinish else { return }
        let kind: FeatureKind = tool == .polygon ? .polygon : .path
        editingFeature = EarthFeature(name: tool == .ruler ? "Measured Path" : "Untitled \(kind.title)", kind: kind, points: vertices)
    }
    func cancelTool() { tool = .navigate; vertices = []; editingFeature = nil; status = "Drag to explore · Scroll to zoom" }
    private func saveMeasurementPreferences() {
        guard savesProviderPreference else { return }
        UserDefaults.standard.set(measurementDistanceUnit.rawValue, forKey: "earthMeasurementDistance")
        UserDefaults.standard.set(measurementAreaUnit.rawValue, forKey: "earthMeasurementArea")
        UserDefaults.standard.set(max(-1, min(9, measurementDistanceDecimals)), forKey: "earthMeasurementDistanceDecimals")
        UserDefaults.standard.set(max(-1, min(9, measurementAreaDecimals)), forKey: "earthMeasurementAreaDecimals")
    }
    func formatMeasurementDistance(_ meters: Double) -> String {
        let unit = measurementDistanceUnit.resolved(meters: meters)
        return MeasurementText.format(unit.value(meters: meters), symbol: unit.symbol, decimals: measurementDistanceDecimals)
    }
    func formatMeasurementArea(_ squareMeters: Double) -> String {
        let unit = measurementAreaUnit.resolved(squareMeters: squareMeters)
        return MeasurementText.format(unit.value(squareMeters: squareMeters), symbol: unit.symbol, decimals: measurementAreaDecimals)
    }
    func formatDistance(_ meters: Double) -> String {
        if miles { return String(format: "%.2f mi", meters / 1609.344) }
        return meters < 1000 ? String(format: "%.0f m", meters) : String(format: "%.2f km", meters / 1000)
    }
    func rememberSearch(_ text: String) {
        let query = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !query.isEmpty else { return }
        recentSearches.removeAll { $0.localizedCaseInsensitiveCompare(query) == .orderedSame }
        recentSearches.insert(query, at: 0); recentSearches = Array(recentSearches.prefix(20))
        if savesProviderPreference { UserDefaults.standard.set(recentSearches, forKey: "earthRecentSearches") }
    }
    func clearSearchHistory() { recentSearches = []; if savesProviderPreference { UserDefaults.standard.removeObject(forKey: "earthRecentSearches") } }
    func repeatSearch(_ query: String) { searchText = query; search() }
    private func updateSearchSuggestions() {
        searchTask?.cancel(); localSearch?.cancel(); googleQuery = nil; searching = false
        searchHits = []; searchSuggestions = []
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { searchPin = nil }
        searchCompleter.update(searchText)
    }
    func suggestSearch(_ query: String) {
        if searchText == query { updateSearchSuggestions() } else { searchText = query }
    }
    func selectSearchHit(_ hit: SearchHit) {
        guard hit.point.isValid else { return }
        searchSuggestions = []; searchCompleter.update("")
        searchPin = features.first(where: { $0.id == hit.id }) ?? .init(id: hit.id, name: hit.title, notes: hit.subtitle, kind: .point, points: [hit.point], color: "#E234A8")
        // A selected result should reveal the address, rather than the entire result region.
        fly(to: hit.point, distance: min(hit.distance, 750))
        selection = hit.id
    }
    func selectSearchSuggestion(_ completion: MKLocalSearchCompletion) {
        let query = [completion.title, completion.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        searchText = query
        if provider == .google { search(); return }
        search(request: MKLocalSearch.Request(completion: completion))
    }
    func search() { search(request: nil) }
    private func search(request completionRequest: MKLocalSearch.Request?) {
        searchTask?.cancel(); localSearch?.cancel(); googleQuery = nil
        searchCompleter.update(""); searchSuggestions = []; searchPin = nil
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searching = false; searchHits = []; searchPin = nil; return }
        rememberSearch(query)
        if let point = GeoPoint.parse(query) {
            searching = false; searchHits = [.init(title: "Coordinates", subtitle: point.label, point: point, distance: 50_000)]; selectSearchHit(searchHits[0]); return
        }
        searching = true; searchHits = []; status = "Searching for \(query)…"
        if provider == .google {
            guard googleKey != nil else { searching = false; googleSettings = true; return }
            guard googleError == nil else { searching = false; status = "Reconnect Google Maps before searching"; return }
            setMode(.map); googleQuery = (UUID(), query)
            return
        }
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = completionRequest ?? MKLocalSearch.Request(); if completionRequest == nil { request.naturalLanguageQuery = query }
                let search = MKLocalSearch(request: request); self.localSearch = search
                let response = try await search.start()
                guard !Task.isCancelled else { return }
                searchHits = response.mapItems.prefix(12).map { item in
                    let c = item.placemark.coordinate
                    let subtitle = [item.placemark.locality, item.placemark.administrativeArea, item.placemark.country].compactMap { $0 }.joined(separator: ", ")
                    return SearchHit(title: item.name ?? query, subtitle: subtitle, point: .init(latitude: c.latitude, longitude: c.longitude), distance: response.mapItems.count == 1 ? max(5000, min(4_000_000, response.boundingRegion.span.latitudeDelta * 140_000)) : 15_000)
                }
                searching = false
                if let first = searchHits.first { selectSearchHit(first); status = "\(searchHits.count) search result\(searchHits.count == 1 ? "" : "s")" }
                else { status = "No results for “\(query)”. Try a city, address, or latitude, longitude." }
            } catch {
                guard !Task.isCancelled else { return }
                searching = false; status = "Search unavailable · Check your internet connection or enter coordinates"
                self.error = "Place search could not finish: \(error.localizedDescription). You can still navigate the globe and search by latitude, longitude."
            }
        }
    }
    func saveSearchHit(_ hit: SearchHit) { selectSearchHit(hit); editingFeature = searchPin }
    func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "kml") ?? .xml, UTType(filenameExtension: "kmz") ?? .zip]; panel.allowsMultipleSelection = true
        panel.message = "Open KML or KMZ places, paths, and polygons."
        guard panel.runModal() == .OK else { return }; importURLs(panel.urls)
    }
    func importURLs(_ urls: [URL]) {
        guard !busy else { return }; busy = true; status = "Importing places…"
        let destinationFolder = selectedFolderID
        Task {
            let result = await Task.detached { () -> Result<KMLImport, Error> in
                do {
                    var all = KMLImport(features: [], skipped: 0, warnings: [])
                    for url in urls {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let parsed = try KMLService.read(url); all.features += parsed.features; all.skipped += parsed.skipped; all.warnings += parsed.warnings
                    }
                    return .success(all)
                } catch { return .failure(error) }
            }.value
            busy = false
            switch result {
            case .success(let imported):
                remember(); features += imported.features.map { feature in
                    var feature = feature; feature.folderID = folders.contains(where: { $0.id == destinationFolder }) ? destinationFolder : nil; return feature
                }; persist()
                if let first = imported.features.first { fly(to: first) }
                status = "Imported \(imported.features.count) places" + (imported.skipped > 0 ? " · Skipped \(imported.skipped) unsupported or invalid items" : "")
                if !imported.warnings.isEmpty { error = imported.warnings.joined(separator: "\n") }
            case .failure(let failure): error = failure.localizedDescription; status = "Import failed · Your existing places are unchanged"
            }
        }
    }
    func exportKML(selectedOnly: Bool = false) {
        let selected = selectedOnly ? features.filter { $0.id == selection } : features
        guard !selected.isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "kml") ?? .xml]; panel.nameFieldStringValue = selectedOnly ? "\(selected[0].name).kml" : "My Places.kml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try KMLService.encode(selected).write(to: url, options: .atomic); status = "Exported \(selected.count) places to \(url.lastPathComponent)" } catch { self.error = error.localizedDescription }
    }
    func saveImage() {
        guard !busy else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Earth View.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let image: NSImage
                if mode == .globe, let capture = globeSnapshot { image = capture() }
                else if let capture = mapSnapshot { image = try await capture() }
                else { throw KMLError.invalid("The current view is not ready for export.") }
                guard let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { throw KMLError.invalid("The image could not be encoded.") }
                try png.write(to: url, options: .atomic); status = "Saved \(url.lastPathComponent)"
            } catch { self.error = error.localizedDescription }
        }
    }
    func startTour() {
        let places = features.filter { $0.isVisible }
        guard !places.isEmpty else { return }
        cancelTool(); touring = true
        tourTask = Task { [weak self] in
            for place in places {
                guard !Task.isCancelled, let self else { return }
                self.fly(to: place, interruptTour: false); self.status = "Tour · \(place.name)"
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
            self?.touring = false
        }
    }
    func stopTour() { tourTask?.cancel(); touring = false }
}

@MainActor extension EarthStore {
    var google3DRequested: Bool { mode == .map && provider == .google && layers.primary && layers.buildings }
    var buildingsLayerDescription: String {
        switch provider {
        case .apple: return "Apple Maps · Extruded buildings in street view; zoom to a city."
        case .openStreetMap: return "OpenStreetMap raster tiles do not include 3D buildings. Choose Apple Maps or Google Maps."
        case .google:
            if let error = google3DError { return error }
            if historicalImagery || streetView || imageOverlays.contains(where: \.isVisible) { return "Google photorealistic 3D pauses for image overlays, historical imagery and Street View."
            }
            return "Google photorealistic buildings + terrain · Coverage varies. Terrain is part of the 3D imagery; cloud and traffic overlays require 2D."
        }
    }
    func restoreDefaultLayers() {
        layers = EarthLayers()
        terrain = true
        grid = false
        showPlaces = true
        google3DActive = false
        google3DError = nil
        cameraRequest = UUID()
    }
    func setBuildingsLayer(_ value: Bool) {
        if value && provider == .openStreetMap { status = buildingsLayerDescription; return }
        var updated = layers; updated.buildings = value
        if value { updated.primary = true }
        layers = updated
        google3DError = nil
        if value { configureBuildingsView() }
        else { google3DActive = false; cameraRequest = UUID() }
    }
    private func configureBuildingsView() {
        guard provider != .openStreetMap else { status = buildingsLayerDescription; return }
        terrain = true; setMode(.map); setPitch(55)
        if provider == .apple { mapStyle = .streets }
        else { mapStyle = .hybrid; historicalImagery = false; streetView = false; streetRequest = UUID() }
        status = buildingsLayerDescription
    }
    private func saveLayerFlag(_ key: String, _ flag: Bool) { if savesProviderPreference { UserDefaults.standard.set(flag, forKey: key) } }
    var visibleLayerItems: [EarthLayerItem] {
        guard layers.primary else { return [] }
        let feeds = layerItems.filter { item in
            switch item.kind { case .photo: layers.photos; case .earthquake: layers.earthquakes; case .wikipedia: layers.wikipedia; case .park: layers.parks; case .airport: layers.transit }
        }
        return feeds + (layers.parks ? EarthBaseData.parks : []) + (layers.transit ? EarthBaseData.airports : [])
    }
    func updateLayerFeeds(force: Bool = false) {
        scheduleNearbyLayerRefresh(force: force)
        if layers.primary && layers.earthquakes {
            if force || (!earthquakeLoaded && earthquakeTask == nil) {
                earthquakeTask?.cancel(); earthquakeGeneration = UUID(); let generation = earthquakeGeneration
                earthquakeStatus = "Loading USGS earthquakes…"
                earthquakeTask = Task { [weak self] in
                    do {
                        let items = try await EarthLayerService.earthquakes()
                        guard !Task.isCancelled, let self, self.earthquakeGeneration == generation else { return }
                        self.layerItems.removeAll { $0.kind == .earthquake }; self.layerItems += items
                        self.earthquakeLoaded = true; self.layerRevision = UUID()
                        self.earthquakeStatus = "USGS · \(items.count) earthquakes · Past 7 days"
                    } catch { if !Task.isCancelled { self?.earthquakeStatus = "USGS unavailable · Use Refresh to retry" } }
                    if self?.earthquakeGeneration == generation { self?.earthquakeTask = nil }
                }
            }
        } else { earthquakeTask?.cancel(); earthquakeTask = nil; earthquakeGeneration = UUID() }
        if layers.primary && layers.clouds && mode == .globe {
            if (cloudImage == nil || force) && cloudTask == nil {
                cloudGeneration = UUID(); let generation = cloudGeneration
                cloudStatus = "Loading NASA cloud cover…"
                cloudTask = Task { [weak self] in
                    do {
                        let data = try await EarthLayerService.request(EarthLayerService.cloudURL(bbox: "-180,-90,180,90", mercator: false, width: 1024, height: 512))
                        guard !Task.isCancelled, let self, self.cloudGeneration == generation else { return }
                        guard let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                        self.cloudImage = image; self.layerRevision = UUID()
                        self.cloudStatus = "NASA MODIS · \(EarthLayerService.cloudDate) · Cloud fraction 0–100%"
                    } catch { if !Task.isCancelled { self?.cloudStatus = "NASA unavailable · Use Refresh to retry" } }
                    if self?.cloudGeneration == generation { self?.cloudTask = nil }
                }
            }
        } else { cloudTask?.cancel(); cloudTask = nil; cloudGeneration = UUID() }
    }
    private func scheduleWikipediaRefresh(force: Bool) {
        wikipediaTask?.cancel(); wikipediaTask = nil
        guard layers.primary && layers.wikipedia else { return }
        guard distance <= 250_000 else { wikipediaStatus = "Zoom closer to load articles (view under 250 km)"; return }
        if !force, let wikipediaCenter, GeoMath.distance(wikipediaCenter, center) < 3000 { return }
        let center = center
        wikipediaTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
                guard let self, !Task.isCancelled else { return }
                self.wikipediaStatus = "Loading nearby Wikipedia articles…"
                let items = try await EarthLayerService.wikipedia(near: center)
                guard !Task.isCancelled else { return }
                self.layerItems.removeAll { $0.kind == .wikipedia }; self.layerItems += items
                self.wikipediaCenter = center; self.layerRevision = UUID()
                self.wikipediaStatus = "Wikipedia · \(items.count) articles within 10 km"
            } catch { if !Task.isCancelled { self?.wikipediaStatus = "Wikipedia unavailable · Use Refresh to retry" } }
        }
    }
    func scheduleNearbyLayerRefresh(force: Bool = false) {
        scheduleWikipediaRefresh(force: force)
        photoTask?.cancel(); photoTask = nil
        guard layers.primary && layers.photos else { return }
        guard distance <= 250_000 else { photoStatus = "Zoom closer to load photos (view under 250 km)"; return }
        if !force, let photoCenter, GeoMath.distance(photoCenter, center) < 3000 { return }
        let center = center
        photoTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
                guard let self, !Task.isCancelled else { return }
                self.photoStatus = "Loading nearby Wikimedia photos…"
                let items = try await EarthLayerService.photos(near: center)
                guard !Task.isCancelled else { return }
                self.layerItems.removeAll { $0.kind == .photo }; self.layerItems += items
                self.photoCenter = center; self.layerRevision = UUID()
                self.photoStatus = "Wikimedia Commons · \(items.count) photos within 10 km"
            } catch { if !Task.isCancelled { self?.photoStatus = "Photos unavailable · Use Refresh to retry" } }
        }
    }
}

@MainActor extension EarthStore {
    var observationPoint: GeoPoint { cursorPoint ?? center }
    var showingStreetImagery: Bool { mode == .map && provider == .google && streetView }
    func updateStreetImagery(date: String?, loading: Bool, request: String?) {
        guard showingStreetImagery, request == streetRequest.uuidString else { return }
        streetImageryLoading = loading
        streetImageryDate = !loading && date?.range(of: #"^[0-9]{4}(-(0[1-9]|1[0-2]))?$"#, options: .regularExpression) != nil ? date : nil
    }
    var imageryDateLabel: String {
        if showingStreetImagery {
            return "Street View date: " + (streetImageryDate ?? (streetImageryLoading ? "Loading…" : "Not supplied"))
        }
        if historicalImagery, historyProduct == .wayback {
            return "Captured: " + (captureDate ?? "Not supplied")
        }
        if historicalImagery {
            return "Imagery day: \(EarthObservation.day(imageryDate)) UTC"
        }
        if mode == .globe { return "Imagery date: Not supplied" }
        if provider == .openStreetMap || (mapStyle == .streets && !google3DActive) {
            return "Imagery date: N/A"
        }
        return "Imagery date: Not supplied"
    }
    var imageryDateHelp: String {
        if showingStreetImagery {
            return "Capture month or year supplied by Google for the panorama currently displayed. Updates as you move through Street View; some panoramas have no date. This is not the satellite map's acquisition date."
        }
        if historicalImagery {
            if historyProduct == .wayback { return "Image capture date at this location and approximate view scale. Basemap release: \(selectedWayback?.date ?? "unavailable"). \(captureSource). Release dates are not capture dates; some locations have no metadata." }
            return "NASA observation day (UTC), not an exact acquisition time at the pointer. Clouds and coverage gaps may show underlying imagery. Use Available dates to find observations near the view center."
        }
        if mode == .globe { return "Esri imagery streams at increasing detail. Capture dates are not supplied by the current basemap; use Wayback for location-specific capture metadata. NASA Blue Marble is the offline composite fallback." }
        return "This provider does not expose imagery acquisition dates at the pointer through the map API. Copyright years are not imagery dates."
    }
    var imageryInformation: String {
        if showingStreetImagery { return "Imagery: Google Street View" }
        if historicalImagery {
            return historyAttribution
        }
        if mode == .globe { return "Imagery: Esri tiled imagery · NASA composite fallback" }
        if provider == .google && google3DActive { return "Imagery: Google photorealistic 3D · Acquisition date not supplied" }
        if provider == .openStreetMap || mapStyle == .streets { return "Imagery: Street map · Date not supplied" }
        return "Imagery: \(provider.rawValue) · Acquisition date not supplied"
    }
    var eyeAltitudeLabel: String { "Eye alt ≈ " + formatDistance(EarthObservation.eyeAltitude(distance: distance, pitch: pitch)) }
    func refreshArchive() {
        archiveTask?.cancel(); archiveTask = nil; archiveGeneration = UUID(); imageryTileRevision = UUID()
        archiveImage = nil; archiveLoadedDate = nil; archiveLoading = false
        archiveStatus = "Imagery loads as visible tiles; missing coverage shows the base globe/map"
        findHistoryDates(); scheduleImageryMetadata()
    }
    func updateElevation() {
        elevationTask?.cancel(); elevationTask = nil
        let point = observationPoint
        let key = String(format: "%.3f,%.3f", point.latitude, point.longitude)
        if let cached = elevationCache[key] { elevationMeters = cached; elevationStatus = elevationLabel(cached); elevationSource = "Copernicus GLO-90 · 90 m · via Open-Meteo"; return }
        let coarse = EarthTerrain.sampledElevation(point)
        elevationMeters = coarse; elevationStatus = coarse.map { elevationLabel($0) + " · coarse" } ?? "Elev —"
        elevationSource = "Terrain Tiles / Mapzen · Coarse bundled elevation"
        elevationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1000))
                guard self != nil, !Task.isCancelled else { return }
                let meters = try await EarthObservation.elevation(at: point)
                guard !Task.isCancelled, let self else { return }
                if meters == 0, let coarse, coarse < -1 {
                    self.elevationSource = "Terrain Tiles / Mapzen · Coarse terrain / seafloor estimate; land service returned sea level"; return
                }
                if self.elevationCache.count > 500 { self.elevationCache.removeAll() }
                self.elevationCache[key] = meters; self.elevationMeters = meters; self.elevationStatus = self.elevationLabel(meters); self.elevationSource = "Copernicus GLO-90 · 90 m · via Open-Meteo"
            } catch { if !Task.isCancelled { if coarse == nil { self?.elevationStatus = "Elev unavailable" }; self?.elevationSource = "Online elevation unavailable · Showing coarse bundled data where available" } }
        }
    }
    private func elevationLabel(_ meters: Double) -> String { String(format: "Elev ≈ %.0f %@", miles ? meters * 3.28084 : meters, miles ? "ft" : "m") }
    func stepImagery(days: Int) { stopHistoryPlayback(); if !historicalImagery { historicalImagery = true }; imageryDate = max(historyProduct.earliest, min(EarthObservation.latest, imageryDate.addingTimeInterval(Double(days) * 86400))) }
    func toggleHistoryPlayback() {
        if historyPlaying { stopHistoryPlayback(); return }
        historicalImagery = true
        guard historyProduct != .wayback else { return }
        if imageryDate >= EarthObservation.latest { imageryDate = max(historyProduct.earliest, EarthObservation.latest.addingTimeInterval(-Double(historyStepDays) * 86400 * 12)) }
        historyPlaying = true
        historyTimer = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.advanceHistoryPlayback()
            }
        }
        if let historyTimer { RunLoop.main.add(historyTimer, forMode: .common) }
    }
    func stopHistoryPlayback() { historyTimer?.invalidate(); historyTimer = nil; historyPlaying = false }
    func advanceHistoryPlayback() {
        guard historyPlaying, !archiveLoading else { return }
        if imageryDate >= EarthObservation.latest { stopHistoryPlayback(); return }
        imageryDate = min(EarthObservation.latest, imageryDate.addingTimeInterval(Double(historyStepDays) * 86400))
    }
    func openExternalMap() {
        if let url = URL(string: "https://www.google.com/maps/@?api=1&map_action=map&center=\(latitude),\(longitude)&basemap=satellite") { NSWorkspace.shared.open(url) }
    }
    func printView() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                let image: NSImage
                if mode == .globe, let capture = globeSnapshot { image = capture() }
                else if let capture = mapSnapshot { image = try await capture() }
                else { throw KMLError.invalid("The current view is not ready to print.") }
                let page = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
                let picture = NSImageView(frame: NSRect(x: 0, y: 40, width: 720, height: 480)); picture.image = image; picture.imageScaling = .scaleProportionallyUpOrDown; page.addSubview(picture)
                let caption = NSTextField(wrappingLabelWithString: imageryInformation + "\n" + EarthObservation.coordinates(center, dms: dmsCoordinates) + " · " + eyeAltitudeLabel + " · Map imagery © " + (mode == .globe || historicalImagery ? "NASA" : provider.rawValue))
                caption.frame = NSRect(x: 8, y: 0, width: 704, height: 38); caption.font = .systemFont(ofSize: 10); page.addSubview(caption)
                NSPrintOperation(view: page).run()
            } catch { self.error = error.localizedDescription }
        }
    }
}
