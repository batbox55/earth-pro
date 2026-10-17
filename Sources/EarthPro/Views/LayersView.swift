import SwiftUI
import AppKit

struct LayersView: View {
    @ObservedObject var store: EarthStore
    @State private var layerSearch = ""
    @AppStorage("earthSidebarLayerGroups") private var expandedGroups = "Map details"
    private var osm: Bool { store.mode == .map && store.provider == .openStreetMap }
    private var photorealistic: Bool { store.google3DRequested && !store.historicalImagery && !store.streetView && !store.imageOverlays.contains(where: \.isVisible) }
    private var nativeMapOnly: String? { store.mode == .globe ? "Available in Map view. The globe uses bundled Natural Earth data." : osm ? "OpenStreetMap includes these features in its street tiles. Use Apple Maps or Google Maps for separate controls." : nil }
    private var query: String { layerSearch.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search layers", text: $layerSearch).textFieldStyle(.plain).accessibilityIdentifier("layer-search")
                if !query.isEmpty {
                    Button { layerSearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear layer search").accessibilityLabel("Clear layer search")
                }
            }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    addedData
                    Divider()
                    HStack {
                        Toggle("Map features", isOn: $store.layers.primary).toggleStyle(.switch).controlSize(.small).fontWeight(.semibold)
                            .help("Enable or pause built-in map features without changing individual selections")
                        Menu {
                            Button("Show all map features") { selectAll(true) }
                            Button("Hide all map features") { selectAll(false) }
                            Button("Restore default layers") { store.restoreDefaultLayers() }
                            Button("Refresh live layers") { store.updateLayerFeeds(force: true) }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("Map feature actions").accessibilityLabel("Map feature actions")
                    }
                    HStack(spacing: 6) {
                        LayerGroupCheckbox(values: store.layers.selectionValues, title: "All map feature selections", changed: selectAll).frame(width: 16, height: 18)
                        Text("All map feature selections").foregroundStyle(.secondary)
                    }
                    if !store.layers.primary { source("Map features are paused. Turn on a layer or the switch above to show them.") }
                    if query.isEmpty {
                        group("Map details", keys: [\.borders, \.labels, \.roads, \.places]) {
                            builtInRow("Borders", key: \.borders)
                            builtInRow("Labels", key: \.labels)
                            builtInRow("Roads", key: \.roads)
                            builtInRow("Places", key: \.places)
                        }
                        group("Terrain & 3D") { terrainRow; gridRow; builtInRow("3D Buildings", key: \.buildings) }
                        group("Nature & transport", keys: [\.parks, \.transit, \.water, \.traffic]) {
                            builtInRow("Parks / recreation areas", key: \.parks)
                            builtInRow("Transportation", key: \.transit)
                            builtInRow("Water body outlines", key: \.water)
                            builtInRow("Traffic", key: \.traffic)
                        }
                        group("Photos & articles", keys: [\.photos, \.wikipedia]) {
                            builtInRow("Nearby photos", key: \.photos)
                            builtInRow("Wikipedia", key: \.wikipedia)
                        }
                        group("Weather & events", keys: [\.clouds, \.earthquakes]) {
                            builtInRow("Cloud cover", key: \.clouds)
                            builtInRow("Earthquakes", key: \.earthquakes)
                        }
                    } else {
                        ForEach(matchingLayers, id: \.0) { title, key, _ in builtInRow(title, key: key) }
                        if matches("Terrain elevation relief Terrain & 3D") { terrainRow }
                        if matches("Latitude longitude grid Terrain & 3D") { gridRow }
                    }
                    if query.isEmpty || matches("Saved places library pins") {
                        Divider()
                        Toggle("Saved places", isOn: $store.showPlaces).help("Show the places, notes and shapes saved in your library")
                    }
                    if query.isEmpty {
                        if osm { source("OpenStreetMap roads, labels and places are baked into its tiles.") }
                        else if store.mode == .map && store.provider == .apple { source("Apple Maps road names follow Roads. Buildings depend on area and map style.") }
                    }
                    if !query.isEmpty && matchingLayers.isEmpty && matchingCustomData.isEmpty && matchingPublicData.isEmpty && !matches("Terrain elevation relief Terrain & 3D Latitude longitude grid Saved places library pins") {
                        Text("No matching layers").foregroundStyle(.secondary)
                    }
                }.padding(.trailing, 3).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.toggleStyle(.checkbox).font(.system(size: 12))
    }
    private func selectAll(_ value: Bool) { var layers = store.layers; layers.selectAll(value); store.layers = layers }
    private func matches(_ text: String) -> Bool { text.localizedStandardContains(query) }
    private let searchableLayers: [(String, WritableKeyPath<EarthLayers, Bool>, String)] = [
        ("Borders", \.borders, "Map details boundaries"), ("Labels", \.labels, "Map details country names"),
        ("Roads", \.roads, "Map details"), ("Places", \.places, "Map details Cities points of interest"),
        ("3D Buildings", \.buildings, "Terrain & 3D Photorealistic"),
        ("Parks / recreation areas", \.parks, "Nature & transport"), ("Transportation", \.transit, "Nature & transport airports transit"),
        ("Water body outlines", \.water, "Nature & transport lakes reservoirs"), ("Traffic", \.traffic, "Nature & transport"),
        ("Nearby photos", \.photos, "Photos & articles Wikimedia Commons"), ("Wikipedia", \.wikipedia, "Photos & articles"),
        ("Cloud cover", \.clouds, "Weather & events NASA"), ("Earthquakes", \.earthquakes, "Weather & events USGS")
    ]
    private var matchingLayers: [(String, WritableKeyPath<EarthLayers, Bool>, String)] {
        searchableLayers.filter { matches($0.0 + " " + $0.2 + " Map features") }
    }
    @ViewBuilder private func builtInRow(_ title: String, key: WritableKeyPath<EarthLayers, Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if key == \.buildings {
                Toggle(title, isOn: Binding(get: { store.layers.buildings }, set: { store.setBuildingsLayer($0) }))
                    .disabled(store.provider == .openStreetMap).help("Apple Maps extruded buildings or Google photorealistic buildings and terrain. OpenStreetMap raster tiles have no 3D geometry.")
            } else {
                Toggle(title, isOn: Binding(get: { store.layers[keyPath: key] }, set: { value in
                    var layers = store.layers; layers[keyPath: key] = value; if value { layers.primary = true }; store.layers = layers
                })).disabled(disabledReason(key) != nil).help(disabledReason(key) ?? layerHelp(key))
            }
            if let reason = disabledReason(key) { source(reason).padding(.leading, 20) }
            if key == \.buildings {
                if store.layers.buildings || store.provider == .openStreetMap { source(store.buildingsLayerDescription).padding(.leading, 20) }
                if store.provider == .google, store.google3DError != nil { Button("Retry Google 3D") { store.retryGoogle() }.padding(.leading, 20) }
            }
            if store.layers[keyPath: key] {
                if key == \.photos { source(store.photoStatus).padding(.leading, 20) }
                if key == \.wikipedia { source(store.wikipediaStatus).padding(.leading, 20) }
                if key == \.earthquakes {
                    source(store.earthquakeStatus).padding(.leading, 20)
                    source("USGS public data · Google's proprietary collections are not supplied by Maps API.").padding(.leading, 20)
                }
                if key == \.clouds {
                    source(store.cloudStatus).padding(.leading, 20)
                    Link("Cloud cover legend ↗", destination: URL(string: "https://gibs.earthdata.nasa.gov/legends/MODIS_Cloud_Fraction_H.png")!).padding(.leading, 20)
                }
                if key == \.parks { source("Natural Earth · 387 U.S. park units · Generalized boundaries").padding(.leading, 20) }
                if key == \.transit { source("Natural Earth airports · Globe markers appear below 6,000 km view distance").padding(.leading, 20) }
            }
        }
    }
    private var terrainRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Terrain", isOn: $store.terrain).disabled(osm || photorealistic)
                .help("Bundled coarse global land relief on the globe; provider terrain in Map view. OpenStreetMap street tiles remain flat.")
            if photorealistic { source("Terrain is included in Google photorealistic 3D. Switch off 3D Buildings to use the regular map.") }
            else if osm { source("OpenStreetMap street tiles remain flat.") }
            if store.mode == .globe && store.terrain {
                source("Terrain Tiles / Mapzen · Coarse global relief at true scale. Local terrain detail comes from Map view.")
                Button("Terrain sources and credits…") {
                    if let url = Bundle.module.url(forResource: "Terrain-Attribution", withExtension: "txt") { NSWorkspace.shared.open(url) }
                }.buttonStyle(.link)
            }
        }
    }
    private var gridRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Latitude / longitude grid", isOn: $store.grid).disabled(store.mode != .globe).help("Available on the globe")
            if store.mode != .globe { source("Available in Globe view.") }
        }
    }
    private func layerHelp(_ key: WritableKeyPath<EarthLayers, Bool>) -> String {
        switch key {
        case \.borders: "Natural Earth country, state and province boundaries. Generalized for globe-scale viewing."
        case \.labels: "Country labels. Apple Maps includes road names with the Roads layer."
        case \.places: "Cities on the globe; provider points of interest on the map."
        case \.roads: "Natural Earth major roads on the globe; provider roads in Map view. Apple road names are included with roads."
        case \.photos: "Geotagged Wikimedia Commons images within 10 km of your view center. Zoom closer than 250 km."
        case \.clouds: "NASA MODIS daily cloud fraction overlay, not a live forecast. Missing swaths have no data."
        case \.earthquakes: "USGS magnitude 2.5+ events from the past week; up to 200 strongest. Select a marker for its source."
        case \.parks: "Bundled U.S. National Park Service boundaries and places, plus provider parks on supported maps. No key needed."
        case \.transit: "893 bundled airports worldwide, plus provider transit points and routes on supported maps."
        case \.traffic: "Current provider traffic where available."
        case \.water: "Natural Earth lake and reservoir outlines. Bundled, generalized geometry; works without a key."
        case \.wikipedia: "Nearby geotagged articles within 10 km. Zoom closer than 250 km and select a marker to read an excerpt."
        default: "Map feature"
        }
    }
    private func disabledReason(_ key: WritableKeyPath<EarthLayers, Bool>) -> String? {
        if key == \.traffic { return photorealistic ? "Switch off 3D Buildings to show traffic on the regular Google map." : nativeMapOnly }
        if key == \.clouds && photorealistic { return "Switch off 3D Buildings to show clouds on the regular Google map." }
        if osm && (key == \.roads || key == \.places) { return nativeMapOnly }
        return nil
    }
    private var matchingCustomData: [CustomDataLayer] {
        store.customDataLayers.filter { query.isEmpty || matches("\($0.name) \($0.category.title) Custom layers Utilities My data") }
    }
    private var matchingPublicData: [PublicDataSource] {
        PublicDataSource.starters.filter { store.publicDataEnabled.contains($0.kind) && (query.isEmpty || matches("\($0.title) \($0.publisher) \($0.coverage) Public data My data")) }
    }
    private var addedData: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("My data").fontWeight(.semibold)
                Spacer()
                Menu {
                    Button("Find data near this view…") { store.openPublicDataBrowser() }
                    Button("Import / connect custom layers…") { store.showCustomData = true }
                    Button("Source update dates…") { store.showSourceDates = true }
                    Button("Refresh enabled public layers") { store.refreshPublicData(force: true) }
                } label: { Image(systemName: "plus.circle") }.menuStyle(.borderlessButton).fixedSize().help("Add or manage data layers").accessibilityLabel("Add or manage data layers")
            }
            if query.isEmpty && store.customDataLayers.isEmpty && store.publicDataEnabled.isEmpty {
                source("Add public data, utilities or your own map layers.")
                Button("Find data…") { store.openPublicDataBrowser() }
            }
            ForEach(matchingPublicData, id: \.kind) { publicLayerRow($0) }
            ForEach(CustomDataCategory.allCases) { category in
                let layers = matchingCustomData.filter { $0.category == category }
                if !layers.isEmpty {
                    if category == .other || !query.isEmpty {
                        ForEach(layers) { customLayerRow($0) }
                    } else {
                        DisclosureGroup(category.title) {
                            VStack(alignment: .leading, spacing: 10) { ForEach(layers) { customLayerRow($0) } }.padding(.top, 5)
                        }
                    }
                }
            }
        }
    }
    private func customLayerRow(_ layer: CustomDataLayer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Toggle(layer.name, isOn: Binding(get: { store.customDataLayers.first(where: { $0.id == layer.id })?.enabled ?? false }, set: { store.setCustomDataEnabled(layer.id, enabled: $0) }))
                    .help(store.customDataStatus[layer.id] ?? "Custom vector layer")
                Spacer(minLength: 0)
                Menu {
                    Button("Manage layer…") { store.showCustomData = true }
                    Button("Zoom to data") { store.zoomToCustomData(layer) }
                    if layer.url != nil { Button("Refresh this view") { store.refreshCustomData(layer.id) } }
                    Button("Source update dates…") { store.showSourceDates = true }
                    Button("Remove layer") { store.removeCustomData(layer.id) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(layer.name)")
            }
            if let folder = store.folders.first(where: { $0.id == layer.folderID }) { source(folder.name).padding(.leading, 20) }
            HStack(alignment: .top, spacing: 4) {
                if store.customDataLoading.contains(layer.id) { ProgressView().controlSize(.mini) }
                source(store.customDataStatus[layer.id] ?? (layer.url == nil ? "Imported file · Stored locally" : "Saved connection · Refresh this view to load"))
            }.padding(.leading, 20)
            source(store.sourceFreshness[layer.id.uuidString]?.updateLabel ?? layer.providerUpdatedAt.map { "Source updated: " + SourceFreshness.dateText($0) } ?? "Source updated: Not supplied").padding(.leading, 20)
        }.contextMenu {
            Button("Manage layer…") { store.showCustomData = true }
            Button("Zoom to data") { store.zoomToCustomData(layer) }
            if layer.url != nil { Button("Refresh this view") { store.refreshCustomData(layer.id) } }
            Button("Remove layer") { store.removeCustomData(layer.id) }
        }
    }
    private func publicLayerRow(_ item: PublicDataSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(item.title, isOn: Binding(get: { !store.publicDataHidden.contains(item.kind) }, set: { store.setPublicDataVisible(item.kind, visible: $0) }))
                .contextMenu {
                    Button("Source settings…") { store.openPublicDataBrowser() }
                    Button("Zoom to data") { store.zoomToPublicData(item.kind) }
                    Button("Retry") { store.refreshPublicData(force: true) }
                    Button("Remove layer") { store.setPublicData(item.kind, enabled: false) }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    if store.publicDataLoading.contains(item.kind) { ProgressView().controlSize(.mini) }
                    source(store.publicDataStatus[item.kind] ?? item.publisher)
                }
                source(store.sourceFreshness[item.id]?.updateLabel ?? "Source updated: Not supplied")
                HStack(spacing: 6) {
                    Text("Opacity").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { store.publicDataOpacity[item.kind] ?? 0.7 }, set: { store.setPublicDataOpacity(item.kind, opacity: $0) }), in: 0...1).accessibilityLabel("\(item.title) opacity")
                }
            }.padding(.leading, 20)
        }
    }
    private func source(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func group<Content: View>(_ title: String, keys: [WritableKeyPath<EarthLayers, Bool>] = [], @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            DisclosureGroup(isExpanded: Binding(get: { expandedGroups.split(separator: "|").contains(Substring(title)) }, set: { value in
                var groups = Set(expandedGroups.split(separator: "|").map(String.init))
                if value { groups.insert(title) } else { groups.remove(title) }
                expandedGroups = groups.sorted().joined(separator: "|")
            })) {
                VStack(alignment: .leading, spacing: 6, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4).padding(.leading, 20)
            } label: {
                HStack(spacing: 6) {
                    if !keys.isEmpty {
                        LayerGroupCheckbox(values: keys.map { store.layers.primary && store.layers[keyPath: $0] }, title: title) { value in
                            var layers = store.layers; if value { layers.primary = true }; for key in keys { layers[keyPath: key] = value }; store.layers = layers
                        }.frame(width: 16, height: 18)
                    }
                    Text(title).fontWeight(.medium)
                }
            }
        }
    }
}
private struct LayerGroupCheckbox: NSViewRepresentable {
    var values: [Bool]
    var title: String
    var changed: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.allowsMixedState = true; button.controlSize = .small; button.setAccessibilityLabel(title)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.changed = changed; context.coordinator.allOn = values.allSatisfy { $0 }
        button.state = values.allSatisfy { $0 } ? .on : values.contains(true) ? .mixed : .off
        button.isEnabled = context.environment.isEnabled
    }
    final class Coordinator: NSObject {
        var changed: ((Bool) -> Void)?
        var allOn = false
        @objc func toggle(_ sender: NSButton) { changed?(!allOn) }
    }
}
struct LayerItemDetail: View {
    let item: EarthLayerItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label(item.title, systemImage: item.symbol).font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            if let url = item.imageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else if phase.error != nil { Label("Preview unavailable · Open the original source below", systemImage: "photo").font(.callout).frame(height: 120) }
                    else { ProgressView().frame(height: 160) }
                }.frame(maxHeight: 300)
            }
            Text(item.detail).font(.callout)
            Text(item.credit).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let url = item.url { Link("Open original source ↗", destination: url) }
        }.padding(24).frame(width: 520)
    }
}
