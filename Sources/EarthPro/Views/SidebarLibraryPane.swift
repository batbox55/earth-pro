import SwiftUI
import AppKit

/// The library has one scroll surface: folders contain their places and layer connections.
struct SidebarLibraryPane: View {
    @ObservedObject var store: EarthStore
    @State private var filter = ""
    @State private var renamingFolder: EarthFolder?
    @AppStorage("earthSidebarExpandedFolders") private var expandedFolderIDs = "unfiled"
    @AppStorage("earthSidebarInspectorExpanded") private var inspectorExpanded = true
    @AppStorage("earthSidebarExploreExpanded") private var exploreExpanded = false

    private var query: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var itemCount: Int { store.features.count + store.customDataLayers.count }
    private let destinations: [(String, String, GeoPoint, Double)] = [
        ("San Francisco", "California, United States", .init(latitude: 37.7749, longitude: -122.4194), 14_000),
        ("Yosemite Valley", "Sierra Nevada, California", .init(latitude: 37.7459, longitude: -119.5936), 18_000),
        ("Grand Canyon", "Arizona, United States", .init(latitude: 36.0986, longitude: -112.0985), 30_000),
        ("Mount Everest", "Himalayas, Nepal", .init(latitude: 27.9881, longitude: 86.9250), 25_000)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                libraryHeader
                filterField
                VStack(alignment: .leading, spacing: 3) {
                    Button { store.selectedFolderID = nil } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack").frame(width: 16)
                            Text("All items").fontWeight(.medium)
                            Spacer()
                            Text("\(itemCount)").foregroundStyle(.secondary).monospacedDigit()
                        }.font(.system(size: 12)).padding(8)
                            .background(store.selectedFolderID == nil ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Use Unfiled for new places and layers")
                    Text("New items: \(store.folderName(store.selectedFolderID))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                VStack(alignment: .leading, spacing: 4) {
                    folderSection(nil)
                    ForEach(store.folders) { folder in folderSection(folder) }
                }
                if itemCount == 0 { emptyLibrary }
                else if !query.isEmpty && matchingItemCount == 0 {
                    Text("No matching places or layers").font(.caption).foregroundStyle(.secondary).padding(8)
                }
                if let feature = store.selectedFeature { selectedInspector(feature) }
                exploreSection
            }.padding(12)
        }
        .sheet(isPresented: $store.showFolderEditor) { EarthFolderEditor(store: store) }
        .sheet(item: $renamingFolder) { folder in EarthFolderEditor(store: store, folder: folder) }
        .onChange(of: store.selectedFolderID) { _, id in if let id { setExpanded(id.uuidString, true) } }
        .onChange(of: store.folders.map(\.id)) { oldIDs, newIDs in
            for id in newIDs where !oldIDs.contains(id) { setExpanded(id.uuidString, true) }
        }
    }

    private var libraryHeader: some View {
        HStack {
            Text("Places & layers").font(.system(size: 13, weight: .semibold))
            Spacer()
            Menu {
                Button("New Folder…") { store.showFolderEditor = true }
                Divider()
                Button("Add Placemark") { store.begin(.placemark) }
                Button("Draw Path") { store.begin(.path) }
                Button("Draw Polygon") { store.begin(.polygon) }
                Button("Plot Address List…") { store.showAddressImport = true }
                Divider()
                Button("Import KML or KMZ…") { store.importFile() }
                Button("Import Custom Layer…") { store.importCustomData() }
                Button("Connect or Manage Data…") { store.showCustomData = true }
                Divider()
                Button("Export All Places…") { store.exportKML() }.disabled(store.features.isEmpty)
            } label: { Image(systemName: "plus").font(.system(size: 12, weight: .medium)) }
                .menuStyle(.borderlessButton).fixedSize().help("Add places, folders or data")
                .accessibilityLabel("Add to library")
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("Filter places & layers", text: $filter).textFieldStyle(.plain)
                .accessibilityIdentifier("library-filter")
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear library filter")
            }
        }.font(.system(size: 11)).padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func folderSection(_ folder: EarthFolder?) -> some View {
        let id = folder?.id
        let key = id?.uuidString ?? "unfiled"
        let places = store.features.filter { $0.folderID == id && matches($0) }
        let layers = store.customDataLayers.filter { $0.folderID == id && matches($0) }
        let total = store.features.filter { $0.folderID == id }.count + store.customDataLayers.filter { $0.folderID == id }.count
        let open = !query.isEmpty || isExpanded(key)
        if query.isEmpty || !places.isEmpty || !layers.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Button { setExpanded(key, !open) } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 20, height: 26)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!query.isEmpty)
                        .accessibilityLabel("\(open ? "Collapse" : "Expand") \(folder?.name ?? "Unfiled")")
                    Button { store.selectedFolderID = id; setExpanded(key, true) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: open ? "folder.fill" : "folder").foregroundStyle(.secondary)
                            Text(folder?.name ?? "Unfiled").lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(query.isEmpty ? total : places.count + layers.count)").foregroundStyle(.secondary).monospacedDigit()
                        }.font(.system(size: 12, weight: .medium)).frame(minHeight: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.padding(.trailing, 8)
                    .background(id != nil && store.selectedFolderID == id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contextMenu {
                        if let folder {
                            Button("Rename Folder…") { renamingFolder = folder }
                            Button("Remove Folder") { perform { try store.removeFolder(id: folder.id) } }
                        }
                    }
                if open {
                    ForEach(places) { feature in placeRow(feature) }
                    ForEach(layers) { layer in layerRow(layer) }
                    if places.isEmpty && layers.isEmpty {
                        Text("No items in this folder").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 30).padding(.vertical, 5)
                    }
                }
            }
        }
    }

    private func placeRow(_ feature: EarthFeature) -> some View {
        HStack(spacing: 7) {
            Toggle("Show \(feature.name)", isOn: Binding(get: { store.features.first { $0.id == feature.id }?.isVisible ?? false }, set: { store.setVisibility(feature.id, $0) }))
                .labelsHidden().toggleStyle(.checkbox)
            Image(systemName: feature.kind == .point ? feature.resolvedPinIcon.symbol : feature.kind.icon)
                .foregroundStyle(Color(nsColor: .init(earthHex: feature.color))).frame(width: 15)
            Button { store.fly(to: feature) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.name).font(.system(size: 12)).lineLimit(1)
                    if feature.kind != .point { Text(store.formatDistance(feature.distance)).font(.system(size: 10)).foregroundStyle(.secondary) }
                    else if !feature.notes.isEmpty { Label("Notes", systemImage: "note.text").font(.system(size: 9)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(.leading, 28).padding(.trailing, 8).padding(.vertical, 7)
            .background(store.selection == feature.id ? Color.accentColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contextMenu {
                Button("Fly To") { store.fly(to: feature) }
                Button("Edit…") { store.editingFeature = feature }
                Button(feature.notes.isEmpty ? "Add Notes…" : "Edit Notes…") { store.editingFeature = feature }
                movePlaceMenu(feature.id)
                Button("Export Place…") { store.selection = feature.id; store.exportKML(selectedOnly: true) }
                Divider()
                Button("Delete", role: .destructive) { store.delete(feature) }
            }
    }

    private func layerRow(_ layer: CustomDataLayer) -> some View {
        HStack(spacing: 7) {
            Toggle("Show \(layer.name)", isOn: Binding(get: { store.customDataLayers.first { $0.id == layer.id }?.enabled ?? false }, set: { store.setCustomDataEnabled(layer.id, enabled: $0) }))
                .labelsHidden().toggleStyle(.checkbox)
            Image(systemName: "square.3.layers.3d").foregroundStyle(.secondary).frame(width: 15)
            Button { store.zoomToCustomData(layer) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(layer.name).font(.system(size: 12)).lineLimit(1)
                    Text(layer.category.title).font(.system(size: 9)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if store.customDataLoading.contains(layer.id) { ProgressView().controlSize(.mini) }
        }.padding(.leading, 28).padding(.trailing, 8).padding(.vertical, 7)
            .contextMenu {
                Button("Zoom to Layer") { store.zoomToCustomData(layer) }
                if layer.url != nil {
                    Button("Refresh This View") { store.refreshCustomData(layer.id) }
                        .disabled(!layer.enabled || store.customDataLoading.contains(layer.id))
                }
                Button("Manage Source…") { store.showCustomData = true }
                Menu("Move to Folder") {
                    Button("Unfiled") { perform { try store.moveCustomLayer(id: layer.id, folderID: nil) } }
                    ForEach(store.folders) { folder in Button(folder.name) { perform { try store.moveCustomLayer(id: layer.id, folderID: folder.id) } } }
                }
                Divider()
                Button("Remove Layer", role: .destructive) { store.removeCustomData(layer.id) }
            }
    }

    private func movePlaceMenu(_ id: UUID) -> some View {
        Menu("Move to Folder") {
            Button("Unfiled") { perform { try store.movePlace(id: id, folderID: nil) } }
            ForEach(store.folders) { folder in Button(folder.name) { perform { try store.movePlace(id: id, folderID: folder.id) } } }
        }
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep places and layers together.").font(.system(size: 12, weight: .medium))
            Text("Add a placemark, draw a path, or import data. Use folders to organize your work.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Import KML or KMZ…") { store.importFile() }.font(.caption)
        }.padding(8)
    }

    private func selectedInspector(_ feature: EarthFeature) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            DisclosureGroup(isExpanded: $inspectorExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(feature.center.label).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button(store.searchPin?.id == feature.id ? "Style & Save…" : "Edit…") { store.editingFeature = feature }
                        Spacer(minLength: 4)
                        Button(feature.notes.isEmpty ? "Add Notes…" : "Edit Notes…") { store.editingFeature = feature }
                    }.font(.caption)
                    if !feature.notes.isEmpty { Text(feature.notes).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled) }
                    if feature.kind == .polygon { Text(String(format: "Area %.2f km²", GeoMath.area(feature.points) / 1_000_000)).font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 8)
            } label: { Text(feature.name).font(.system(size: 12, weight: .semibold)).lineLimit(1) }
        }.padding(.horizontal, 4)
    }

    private var exploreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            DisclosureGroup("Explore", isExpanded: $exploreExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(destinations.indices, id: \.self) { index in
                        let destination = destinations[index]
                        Button { store.fly(to: destination.2, distance: destination.3); store.status = destination.0 } label: {
                            HStack(spacing: 8) {
                                Image(systemName: index == 0 ? "building.2" : "mountain.2").frame(width: 19).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(destination.0).font(.system(size: 12))
                                    Text(destination.1).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.top, 10)
            }.font(.system(size: 12, weight: .medium))
        }.padding(.horizontal, 4)
    }

    private var matchingItemCount: Int { store.features.filter(matches).count + store.customDataLayers.filter(matches).count }
    private func matches(_ feature: EarthFeature) -> Bool { query.isEmpty || feature.name.localizedCaseInsensitiveContains(query) || feature.notes.localizedCaseInsensitiveContains(query) }
    private func matches(_ layer: CustomDataLayer) -> Bool { query.isEmpty || layer.name.localizedCaseInsensitiveContains(query) || layer.category.title.localizedCaseInsensitiveContains(query) }
    private func isExpanded(_ key: String) -> Bool { expandedFolderIDs.split(separator: ",").contains(Substring(key)) }
    private func setExpanded(_ key: String, _ expanded: Bool) {
        var keys = Set(expandedFolderIDs.split(separator: ",").map(String.init))
        if expanded { keys.insert(key) } else { keys.remove(key) }
        expandedFolderIDs = keys.sorted().joined(separator: ",")
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { store.error = error.localizedDescription }
    }
}
