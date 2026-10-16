import SwiftUI
import AppKit

struct SidebarView: View {
    @ObservedObject var store: EarthStore
    @State private var placeFilter = ""
    @AppStorage("earthSidebarPlacesFraction") private var placesFraction = 0.5
    @State private var resizeStartHeight: CGFloat?
    @State private var resizeHeight: CGFloat?
    private var filteredPlaces: [EarthFeature] {
        let query = placeFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? store.features : store.features.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query) }
    }
    private let destinations: [(String, String, GeoPoint, Double)] = [
        ("San Francisco", "California, United States", .init(latitude: 37.7749, longitude: -122.4194), 14_000),
        ("Yosemite Valley", "Sierra Nevada, California", .init(latitude: 37.7459, longitude: -119.5936), 18_000),
        ("Grand Canyon", "Arizona, United States", .init(latitude: 36.0986, longitude: -112.0985), 30_000),
        ("Mount Everest", "Himalayas, Nepal", .init(latitude: 27.9881, longitude: 86.9250), 25_000)
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: EarthBrand.icon).resizable().renderingMode(.original).interpolation(.high).scaledToFit().frame(width: 38, height: 38).accessibilityLabel("Earth Pro logo")
                VStack(alignment: .leading, spacing: 1) { Text("Earth Pro").font(.system(size: 19, weight: .medium)); Text("EXPLORE · MEASURE · DISCOVER").font(.system(size: 8, weight: .medium)).tracking(0.6).foregroundStyle(.secondary) }
                Spacer()
            }.padding(18)
            Divider()
            GeometryReader { geometry in
                let available = max(0, geometry.size.height - 18)
                let topHeight = min(max(100, resizeHeight ?? (available * placesFraction)), max(100, available - 220))
                VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text("Search").font(.headline); Spacer(); Text(store.provider == .google ? "Google Maps" : "Apple search").font(.system(size: 9)).foregroundStyle(.secondary) }
                            HStack(spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                    TextField("City, address, or coordinates", text: Binding(get: { store.searchText }, set: { if store.searchText != $0 { store.searchText = $0 } })).textFieldStyle(.plain).onSubmit { store.search() }.accessibilityIdentifier("place-search")
                                    if !store.searchText.isEmpty { Button { store.searchText = ""; store.search() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Clear search") }
                                }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                                Button { store.search() } label: { Image(systemName: "arrow.right") }.buttonStyle(.borderedProminent).help("Search").disabled(store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            if !store.recentSearches.isEmpty {
                                Menu("History") {
                                    ForEach(store.recentSearches, id: \.self) { query in Button(query) { store.repeatSearch(query) } }
                                    Divider(); Button("Clear Search History") { store.clearSearchHistory() }
                                }.font(.caption).fixedSize()
                            }
                            if store.searching { HStack { ProgressView().controlSize(.small); Text("Searching…").font(.caption).foregroundStyle(.secondary) } }
                        }.padding(.horizontal, 16).padding(.vertical, 14)
                        if !store.searchSuggestions.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Suggestions · Apple Maps").font(.system(size: 9)).foregroundStyle(.secondary).padding(.bottom, 4)
                                ForEach(Array(store.searchSuggestions.prefix(6).enumerated()), id: \.offset) { _, suggestion in
                                    Button { store.selectSearchSuggestion(suggestion) } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(suggestion.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                                if !suggestion.subtitle.isEmpty { Text(suggestion.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
                                            }
                                            Spacer(minLength: 0)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal, 16).padding(.bottom, 10)
                        }
                        if !store.searchHits.isEmpty {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(store.searchHits) { hit in
                                        HStack(alignment: .top, spacing: 8) {
                                            Button { store.selectSearchHit(hit) } label: {
                                                HStack(alignment: .top, spacing: 9) {
                                                    Image(systemName: "mappin").foregroundStyle(.red).frame(width: 16)
                                                    VStack(alignment: .leading, spacing: 4) { Text(hit.title).font(.system(size: 12, weight: .medium)); Text(hit.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
                                                    Spacer(minLength: 0)
                                                }.contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                            Button { store.saveSearchHit(hit) } label: { Image(systemName: "plus.circle") }.buttonStyle(.plain).help("Save \(hit.title)")
                                        }.padding(.horizontal, 16).padding(.vertical, 11)
                                    }
                    }
                }.frame(maxHeight: 220)
            }
            Divider()
            HStack {
                Label("My Places", systemImage: "folder").font(.headline)
                Spacer()
                Text("\(store.features.count)").font(.caption).foregroundStyle(.secondary)
                Menu { Button("Plot Address List…") { store.showAddressImport = true }; Button("Import KML or KMZ…") { store.importFile() }; Button("Export All…") { store.exportKML() }.disabled(store.features.isEmpty) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 16).padding(.vertical, 13)
            if store.features.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Your places, kept here.").font(.system(size: 12, weight: .medium))
                    Text("Add a placemark, draw a path, or open a KML file to start exploring.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open KML or KMZ…") { store.importFile() }.font(.system(size: 11))
                }.padding(.horizontal, 18).padding(.bottom, 18)
            } else {
                TextField("Filter saved places", text: $placeFilter).textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.bottom, 8)
                if filteredPlaces.isEmpty { Text("No matching places").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10) }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredPlaces) { feature in
                            HStack(spacing: 8) {
                                Toggle("Show \(feature.name)", isOn: Binding(get: { store.features.first(where: { $0.id == feature.id })?.isVisible ?? false }, set: { store.setVisibility(feature.id, $0) })).labelsHidden().toggleStyle(.checkbox)
                                Image(systemName: feature.kind == .point ? feature.resolvedPinIcon.symbol : feature.kind.icon).foregroundStyle(Color(nsColor: .init(earthHex: feature.color))).frame(width: 17)
                                Button { store.fly(to: feature) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(feature.name).font(.system(size: 12)).lineLimit(1)
                                        if feature.kind != .point { Text(store.formatDistance(feature.distance)).font(.system(size: 10)).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }.padding(.horizontal, 12).padding(.vertical, 9)
                                .background(store.selection == feature.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .contextMenu {
                                    Button("Fly To") { store.fly(to: feature) }
                                    Button("Edit…") { store.editingFeature = feature }
                                    Button("Export Place…") { store.selection = feature.id; store.exportKML(selectedOnly: true) }
                                    Divider()
                                    Button("Delete", role: .destructive) { store.delete(feature) }
                                }
                        }
                    }.padding(.horizontal, 6)
                }.frame(minHeight: 70, maxHeight: .infinity)
            }
            if store.features.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("EXPLORE").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                    ForEach(destinations.indices, id: \.self) { i in
                        let destination = destinations[i]
                        Button { store.fly(to: destination.2, distance: destination.3); store.status = destination.0 } label: {
                            HStack(spacing: 10) {
                                Image(systemName: i == 0 ? "building.2" : "mountain.2").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) { Text(destination.0).font(.system(size: 12, weight: .medium)); Text(destination.1).font(.system(size: 10)).foregroundStyle(.secondary) }
                                Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(18)
                Spacer(minLength: 15)
            }
            if let feature = store.selectedFeature {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(feature.name).font(.system(size: 12, weight: .semibold)).lineLimit(1); Spacer(); Button(store.searchPin?.id == feature.id ? "Style & Save…" : "Edit…") { store.editingFeature = feature }.font(.caption) }
                    Text(feature.center.label).font(.system(size: 10)).foregroundStyle(.secondary)
                    if !feature.notes.isEmpty { Text(feature.notes).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3) }
                    if feature.kind == .polygon { Text(String(format: "Area %.2f km²", GeoMath.area(feature.points) / 1_000_000)).font(.caption).foregroundStyle(.secondary) }
                }.padding(16)
            }
                    }
                }.frame(height: topHeight)
                ZStack {
                    Rectangle().fill(.quaternary.opacity(0.35))
                    Capsule().fill(.secondary.opacity(0.5)).frame(width: 32, height: 3)
                }.frame(height: 18).contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .help("Drag up to give Layers more room")
                    .accessibilityLabel("Resize Layers section")
                    .accessibilityValue("\(Int((1 - placesFraction) * 100)) percent for Layers")
                    .accessibilityAdjustableAction { direction in
                        let change = direction == .increment ? -0.05 : 0.05
                        placesFraction = min(max(100 / max(1, available), placesFraction + change), max(0, (available - 220) / max(1, available)))
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("sidebarResize"))
                        .onChanged { value in
                            let start = resizeStartHeight ?? topHeight
                            resizeStartHeight = start
                            resizeHeight = min(max(100, start + value.translation.height), max(100, available - 220))
                        }
                        .onEnded { value in
                            let start = resizeStartHeight ?? topHeight
                            let finalHeight = min(max(100, start + value.translation.height), max(100, available - 220))
                            var transaction = Transaction(); transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                placesFraction = finalHeight / max(1, available)
                                resizeHeight = nil; resizeStartHeight = nil
                            }
                        })
                VStack(alignment: .leading, spacing: 10) {
                    LayersView(store: store)
                Divider()
                Button { store.googleSettings = true } label: {
                    HStack { Image(systemName: "key"); Text("Google Maps settings"); Spacer(); Image(systemName: store.googleKey == nil ? "plus.circle" : "checkmark.circle.fill").foregroundStyle(store.googleKey == nil ? Color.secondary : Color.green) }
                }.buttonStyle(.plain).help("Add or manage your Google Maps API key")
                }.toggleStyle(.checkbox).font(.system(size: 11)).padding(16)
                    .frame(minHeight: 220, maxHeight: .infinity)
                }.coordinateSpace(name: "sidebarResize")
            }
        }.background(.regularMaterial)
    }
}
