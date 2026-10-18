import SwiftUI

struct UtilityStarter: Identifiable {
    let category: CustomDataCategory
    let name: String
    let path: String
    let coverage: String
    var id: String { path }
    var url: URL { URL(string: "https://ocgis.com/arcpub/rest/services/" + path)! }
    static let all: [Self] = [
        .init(category: .water, name: "JWA water lines", path: "JWA/JWA_Utilities/MapServer/21", coverage: "John Wayne Airport, California only"),
        .init(category: .sewer, name: "OC Sanitation sewer mains", path: "Map_Layers/OC_Sanitation_District/MapServer/11", coverage: "OC Sanitation service area, California"),
        .init(category: .stormwater, name: "OC stormwater channels", path: "Flood/Stormwater_Network/FeatureServer/8", coverage: "Orange County flood control channels, California"),
        .init(category: .electricity, name: "JWA electrical lines", path: "JWA/JWA_Utilities/MapServer/1", coverage: "John Wayne Airport, California only"),
        .init(category: .gas, name: "JWA gas lines", path: "JWA/JWA_Utilities/MapServer/7", coverage: "John Wayne Airport, California only"),
        .init(category: .telecommunications, name: "OC Sanitation fiber lines", path: "Map_Layers/OC_Sanitation_District/MapServer/9", coverage: "OC Sanitation facilities, California")
    ]
}

struct CustomDataView: View {
    @ObservedObject var store: EarthStore
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var name = ""
    @State private var address = ""
    @State private var category: CustomDataCategory = .other
    @State private var format: CustomDataFormat = .arcGIS
    @State private var connectionError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Utilities & custom layers").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Button("Import file…", systemImage: "square.and.arrow.down") { store.importCustomData() }.disabled(store.customDataImporting || store.customDataLayers.count >= 8)
                Button("Connect source…", systemImage: "link") { connecting.toggle() }
                Button("Browse this area…", systemImage: "location.magnifyingglass") {
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        store.openPublicDataBrowser(); store.scheduleDataDiscovery(force: true)
                    }
                }
                Spacer()
                Button("Source dates…") { dismiss(); Task { @MainActor in try? await Task.sleep(for: .milliseconds(300)); store.showSourceDates = true } }
            }
            Text("Shapefile ZIP/folder, KML, KMZ and GeoJSON files · Public GeoJSON or ArcGIS layer URLs").font(.caption).foregroundStyle(.secondary)
            if store.customDataImporting { ProgressView("Importing layer…").controlSize(.small) }
            if connecting { connectionForm }
            if !store.publicDataSupported {
                HStack {
                    Text("Custom vector layers appear on the globe and regular map. Exit Street View or Google 3D to see them.").font(.caption)
                    Button("Switch to Map") { store.usePublicDataMap() }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(CustomDataCategory.allCases) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title).font(.headline)
                            ForEach(store.customDataLayers.filter { $0.category == group }) { layer in card(layer) }
                            if store.placeDataRegion?.isOrangeCounty == true {
                                ForEach(UtilityStarter.all.filter { starter in starter.category == group && !store.customDataLayers.contains(where: { $0.url == starter.url }) }) { starter in
                                    starterCard(starter)
                                }
                            }
                            if store.customDataLayers.allSatisfy({ $0.category != group }) && store.placeDataRegion?.isOrangeCounty != true {
                                Text("Connect a public \(group.title.lowercased()) source for your area, or import a file.").font(.caption).foregroundStyle(.secondary)
                            }
                            if group == .other && store.customDataLayers.allSatisfy({ $0.category != .other }) {
                                Text("Import your own geometry or connect a public data source.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(.vertical, 8)
            }
            Text("Live layers refresh only when requested. ArcGIS loads the current area below 50 km; GeoJSON loads a bounded file. Up to 8 layers, 300 geometries and 16,000 vertices per layer. Polygons preserve holes and display filled colors. Source styling and legends appear below each layer.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(width: 650, height: 690)
    }
    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Layer name", text: $name)
            HStack {
                Picker("Section", selection: $category) { ForEach(CustomDataCategory.allCases) { Text($0.title).tag($0) } }
                Picker("Format", selection: $format) { ForEach(CustomDataFormat.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            TextField("Public GeoJSON, numbered ArcGIS layer, or OpenDataSoft records URL", text: $address).accessibilityLabel("Custom source URL")
            Text("Public sources only; URLs with API tokens or credentials are not saved.").font(.caption).foregroundStyle(.secondary)
            if let connectionError { Text(connectionError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { connecting = false; connectionError = nil }
                Spacer()
                Button("Connect") {
                    do {
                        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CustomDataError.invalidURL }
                        try store.addCustomConnection(name: name, category: category, format: format, url: url)
                        connecting = false; connectionError = nil; address = ""; name = ""
                    } catch { connectionError = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.textFieldStyle(.roundedBorder).padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
    }
    private func starterCard(_ starter: UtilityStarter) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(starter.name).font(.subheadline.weight(.medium))
                Spacer()
                Button("Add") {
                    do { try store.addCustomConnection(name: starter.name, category: starter.category, format: .arcGIS, url: starter.url) }
                    catch { store.error = error.localizedDescription }
                }.disabled(store.customDataLayers.count >= 8)
            }
            Text("OC GIS · \(starter.coverage)").font(.caption).foregroundStyle(.secondary)
            Text("Source updated: Not checked").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Visit this example’s coverage") { store.fly(to: .init(latitude: 33.6757, longitude: -117.8682), distance: starter.category == .stormwater || starter.category == .sewer || starter.category == .telecommunications ? 12_000 : 2_500, detail: store.mode == .map) }
                Spacer()
                Link("Publisher ↗", destination: starter.url)
            }.font(.caption)
        }.padding(10).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
    private func card(_ layer: CustomDataLayer) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Toggle(layer.name, isOn: Binding(get: { store.customDataLayers.first(where: { $0.id == layer.id })?.enabled ?? false }, set: { store.setCustomDataEnabled(layer.id, enabled: $0) })).toggleStyle(.checkbox)
                Spacer()
                Button("Remove") { store.removeCustomData(layer.id) }.font(.caption)
            }
            EarthFolderPicker(store: store, selection: Binding(get: { store.customDataLayers.first(where: { $0.id == layer.id })?.folderID }, set: { folder in
                do { try store.moveCustomLayer(id: layer.id, folderID: folder) } catch { store.error = error.localizedDescription }
            })).font(.caption)
            if let url = layer.url { Link(url.host ?? "Source", destination: url).font(.caption) }
            else { Text("Imported file · Stored locally").font(.caption).foregroundStyle(.secondary) }
            if let starter = UtilityStarter.all.first(where: { $0.url == layer.url }) {
                Text("OC GIS · " + starter.coverage).font(.caption).foregroundStyle(.secondary)
            }
            Text(layer.providerUpdatedAt.map { "Source updated: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Source updated: Not supplied by publisher").font(.caption).foregroundStyle(.secondary)
            if let modified = layer.fileModifiedAt { Text("File modified: " + modified.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
            if let checked = layer.checkedAt { Text("Last checked: " + checked.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
            LayerLegendView(entries: layer.legend ?? [], notice: layer.stylingNotice)
            HStack(alignment: .top) {
                if store.customDataLoading.contains(layer.id) { ProgressView().controlSize(.mini) }
                Text(store.customDataStatus[layer.id] ?? "Ready").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Zoom to data") { store.zoomToCustomData(layer) }.disabled((layer.url == nil ? layer.features : store.customDataSnapshots[layer.id] ?? []).isEmpty)
                if layer.url != nil { Button("Refresh this view") { store.refreshCustomData(layer.id) }.disabled(!layer.enabled || store.customDataLoading.contains(layer.id)) }
            }.font(.caption)
        }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
