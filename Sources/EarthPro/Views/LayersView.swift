import SwiftUI
import AppKit

struct LayersView: View {
    @ObservedObject var store: EarthStore
    @State private var layerSearch = ""
    @AppStorage("earthPrimaryLayersExpanded") private var primaryExpanded = true
    @AppStorage("earthExpandedLayerGroups") private var expandedGroups = ""
    private var osm: Bool { store.mode == .map && store.provider == .openStreetMap }
    private var photorealistic: Bool { store.google3DRequested && !store.historicalImagery && !store.streetView && !store.imageOverlays.contains(where: \.isVisible) }
    private var nativeMapOnly: String? { store.mode == .globe ? "Available in Map view. The globe uses bundled Natural Earth data." : osm ? "OpenStreetMap includes these features in its street tiles. Use Apple Maps or Google Maps for separate controls." : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Button { store.updateLayerFeeds(force: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh enabled public data layers")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search layers", text: $layerSearch)
                    .textFieldStyle(.plain).accessibilityIdentifier("layer-search")
                if !layerSearch.isEmpty {
                    Button { layerSearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear layer search")
                }
            }.padding(7).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            ScrollView {
                if !query.isEmpty {
                    searchResults
                } else {
                VStack(alignment: .leading, spacing: 7) {
                    DisclosureGroup(isExpanded: $primaryExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            group("Borders and Labels", icon: "flag", keys: [\EarthLayers.borders, \.labels]) {
                                row("Borders", key: \.borders, help: "Natural Earth country, state and province boundaries. Generalized for globe-scale viewing.")
                                row("Labels", key: \.labels, help: "Country labels. Apple Maps includes road names with the Roads layer.")
                            }
                            row("Places", key: \.places, help: "Cities on the globe; provider points of interest on the map.", disabled: osm ? nativeMapOnly : nil)
                            group("Photos", icon: "camera", keys: [\EarthLayers.photos]) {
                                row("Nearby photos", key: \.photos, help: "Geotagged Wikimedia Commons images within 10 km of your view center. Zoom closer than 250 km.")
                                if store.layers.photos { source(store.photoStatus) }
                            }
                            row("Roads", key: \.roads, help: "Natural Earth major roads on the globe; provider roads in Map view. Apple road names are included with roads.", disabled: osm ? nativeMapOnly : nil)
                            Toggle("3D Buildings", isOn: Binding(get: { store.layers.buildings }, set: { store.setBuildingsLayer($0) }))
                                .disabled(store.provider == .openStreetMap)
                                .help("Use the selected provider: Apple Maps extruded buildings, or Google photorealistic buildings and terrain. OpenStreetMap raster tiles have no 3D geometry.")
                            if store.layers.buildings || store.provider == .openStreetMap { source(store.buildingsLayerDescription) }
                            if store.provider == .google, store.google3DError != nil { Button("Retry Google 3D") { store.retryGoogle() }.font(.caption) }
                            group("Weather", icon: "cloud", keys: [\EarthLayers.clouds]) {
                                row("Cloud cover", key: \.clouds, help: "NASA MODIS daily cloud fraction overlay, not a live forecast. Missing swaths have no data.", disabled: photorealistic ? "Switch off 3D Buildings to show the cloud overlay on the regular Google map." : nil)
                                if store.layers.clouds {
                                    source(store.cloudStatus)
                                    Link("Cloud cover legend ↗", destination: URL(string: "https://gibs.earthdata.nasa.gov/legends/MODIS_Cloud_Fraction_H.png")!).font(.caption2)
                                }
                            }
                            group("Gallery", icon: "square.grid.2x2", keys: [\EarthLayers.earthquakes]) {
                                row("Earthquakes", key: \.earthquakes, help: "USGS magnitude 2.5+ events from the past week; up to 200 strongest. Select a marker for its source.")
                                if store.layers.earthquakes { source(store.earthquakeStatus) }
                                source("Public-data gallery · Google's proprietary collections are not supplied by Maps API.")
                            }
                            group("More", icon: "square.stack", keys: [\EarthLayers.parks, \.transit, \.traffic, \.water, \.wikipedia]) {
                                row("Parks/Recreation Areas", key: \.parks, help: "Bundled U.S. National Park Service boundaries and places, plus provider parks on supported maps. No key needed.")
                                if store.layers.parks { source("Natural Earth · 387 U.S. park units · Generalized boundaries") }
                                row("Transportation", key: \.transit, help: "893 bundled airports worldwide, plus provider transit points and routes on supported maps.")
                                if store.layers.transit { source("Natural Earth airports · Globe markers appear below 6,000 km view distance") }
                                row("Traffic", key: \.traffic, help: "Current provider traffic where available.", disabled: photorealistic ? "Switch off 3D Buildings to show traffic on the regular Google map." : nativeMapOnly)
                                row("Water Body Outlines", key: \.water, help: "Natural Earth lake and reservoir outlines. Bundled, generalized geometry; works without a key.")
                                row("Wikipedia", key: \.wikipedia, help: "Nearby geotagged articles within 10 km. Zoom closer than 250 km and select a marker to read an excerpt.")
                                if store.layers.wikipedia { source(store.wikipediaStatus) }
                                Toggle("Latitude / longitude grid", isOn: $store.grid).disabled(store.mode != .globe).help("Available on the globe")
                            }
                        }.padding(.leading, 3)
                    } label: {
                        HStack(spacing: 5) {
                            LayerGroupCheckbox(values: store.layers.selectionValues, title: "Primary Database") { value in var layers = store.layers; layers.selectAll(value); store.layers = layers }.frame(width: 15, height: 16)
                            Text("Primary Database").fontWeight(.medium)
                        }
                    }
                    Toggle("Terrain", isOn: $store.terrain).disabled(osm || photorealistic).help(photorealistic ? "Terrain is part of Google photorealistic 3D imagery. Switch off 3D Buildings to return to the regular map." : "Bundled coarse global land relief on the globe; provider terrain in Map view. OpenStreetMap street tiles remain flat.")
                    if store.mode == .globe && store.terrain {
                        source("Terrain Tiles / Mapzen · Coarse global relief at true scale. Local terrain detail comes from Map view.")
                        Button("Terrain sources and credits…") {
                            if let url = Bundle.module.url(forResource: "Terrain-Attribution", withExtension: "txt") { NSWorkspace.shared.open(url) }
                        }.buttonStyle(.link).font(.system(size: 9))
                    }
                    Toggle("Saved places", isOn: $store.showPlaces)
                    if osm { source("OpenStreetMap roads, labels and places are baked into its tiles.") }
                    else if store.mode == .map && store.provider == .apple { source("Apple Maps road names follow Roads. Buildings depend on area and map style.") }
                }.padding(.trailing, 5)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.toggleStyle(.checkbox).font(.system(size: 11))
    }
    private var query: String { layerSearch.trimmingCharacters(in: .whitespacesAndNewlines) }
    private let searchableLayers: [(String, WritableKeyPath<EarthLayers, Bool>, String)] = [
        ("Borders", \.borders, "Borders and Labels"),
        ("Labels", \.labels, "Borders and Labels"),
        ("Places", \.places, "Cities points of interest"),
        ("Nearby photos", \.photos, "Photos Wikimedia Commons"),
        ("Roads", \.roads, ""),
        ("3D Buildings", \.buildings, "Photorealistic"),
        ("Cloud cover", \.clouds, "Weather"),
        ("Earthquakes", \.earthquakes, "Gallery USGS"),
        ("Parks/Recreation Areas", \.parks, "More"),
        ("Transportation", \.transit, "More airports transit"),
        ("Traffic", \.traffic, "More"),
        ("Water Body Outlines", \.water, "More lakes reservoirs"),
        ("Wikipedia", \.wikipedia, "More articles")
    ]
    private func matches(_ text: String) -> Bool { text.localizedStandardContains(query) }
    private var matchingLayers: [(String, WritableKeyPath<EarthLayers, Bool>, String)] {
        searchableLayers.filter { matches($0.0 + " " + $0.2 + " Primary Database") }
    }
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(matchingLayers, id: \.0) { title, key, _ in
                if key == \EarthLayers.buildings {
                    Toggle(title, isOn: Binding(get: { store.layers.buildings }, set: { store.setBuildingsLayer($0) }))
                        .disabled(store.provider == .openStreetMap)
                } else {
                    row(title, key: key, help: title, disabled: searchDisabledReason(key))
                }
            }
            if matches("Latitude / longitude grid More Primary Database") {
                Toggle("Latitude / longitude grid", isOn: $store.grid).disabled(store.mode != .globe)
            }
            if matches("Terrain elevation relief") {
                Toggle("Terrain", isOn: $store.terrain).disabled(osm || photorealistic)
            }
            if matches("Saved places") { Toggle("Saved places", isOn: $store.showPlaces) }
            if matchingLayers.isEmpty && !matches("Latitude / longitude grid More Primary Database") && !matches("Terrain elevation relief") && !matches("Saved places") {
                Text("No matching layers").foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 5)
    }
    private func searchDisabledReason(_ key: WritableKeyPath<EarthLayers, Bool>) -> String? {
        if key == \.traffic { return photorealistic ? "Switch off 3D Buildings to show traffic on the regular Google map." : nativeMapOnly }
        if key == \.clouds && photorealistic { return "Switch off 3D Buildings to show clouds on the regular Google map." }
        if osm && (key == \.roads || key == \.places) { return nativeMapOnly }
        return nil
    }
    private func source(_ text: String) -> some View { Text(text).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func row(_ title: String, key: WritableKeyPath<EarthLayers, Bool>, help: String, disabled: String? = nil) -> some View {
        Toggle(title, isOn: Binding(get: { store.layers[keyPath: key] }, set: { value in var layers = store.layers; layers[keyPath: key] = value; if value { layers.primary = true }; store.layers = layers }))
            .disabled(disabled != nil).help(disabled ?? help)
    }
    private func group<Content: View>(_ title: String, icon: String, keys: [WritableKeyPath<EarthLayers, Bool>], @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedGroups.split(separator: "|").contains(Substring(title)) }, set: { value in
            var groups = Set(expandedGroups.split(separator: "|").map(String.init))
            if value { groups.insert(title) } else { groups.remove(title) }
            expandedGroups = groups.sorted().joined(separator: "|")
        })) {
            VStack(alignment: .leading, spacing: 6, content: content).padding(.leading, 3)
        } label: {
            HStack(spacing: 5) {
                LayerGroupCheckbox(values: keys.map { store.layers[keyPath: $0] }, title: title) { value in
                    var layers = store.layers; if value { layers.primary = true }; for key in keys { layers[keyPath: key] = value }; store.layers = layers
                }.frame(width: 15, height: 16)
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 14)
                Text(title)
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
