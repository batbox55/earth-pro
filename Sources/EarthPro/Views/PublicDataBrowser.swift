import SwiftUI

/// Area discovery fetches metadata only. Geometry loads only after a source is added.
struct PublicDataBrowser: View {
    @ObservedObject var store: EarthStore
    var embedded = false
    @State private var query = ""
    @State private var savedOnly = false
    @State private var areaQuery = ""
    @State private var selectedService: DiscoveredDataService?
    @State private var directoryExpanded = false
    @State private var resultLimit = 30
    @State private var filteredPortals: [PublicDataPortal] = []
    @State private var filterTask: Task<Void, Never>?

    private var starters: [PublicDataSource] {
        PublicDataSource.starters.filter { source in
            (savedOnly ? store.publicDataEnabled.contains(source.kind) : source.kind == .flood || store.placeDataRegion?.isOrangeCounty == true) &&
            (query.isEmpty || "\(source.title) \(source.publisher) \(source.coverage)".localizedStandardContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Find data").font(.headline)
                    Text(store.placeDataArea).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 5)
                Menu {
                    Button("Manage layers and connections…") { store.showCustomData = true }
                    Button("Import data file…") { store.importCustomData() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Data source actions")
                if !embedded {
                    Button { store.showPublicData = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Close public data browser")
                        .accessibilityLabel("Close public data browser").keyboardShortcut(.cancelAction)
                }
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Follow map", isOn: Binding(get: { store.discoveryFollowsMap }, set: { enabled in
                    if enabled { store.resumeMapDataDiscovery() } else { store.discoveryFollowsMap = false; store.discoveryManualCenter = store.center; store.scheduleDataDiscovery(force: true) }
                })).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button("Refresh area") { store.scheduleDataDiscovery(force: true) }.font(.caption).disabled(store.discoveryLoading)
            }
            DisclosureGroup("Choose another area") {
            VStack(alignment: .leading, spacing: 7) {
                TextField("County, city, state…", text: $areaQuery).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.setDataDiscoveryArea(areaQuery) } }
                Button("Use area") { Task { await store.setDataDiscoveryArea(areaQuery) } }.disabled(areaQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.top, 5)
            }.font(.caption).help("Changes source discovery only; keeps your map in place")
            HStack(spacing: 6) {
                TextField("Search layer topics: water, parcels…", text: $store.discoveryQuery)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Search public service topics")
                if !store.discoveryQuery.isEmpty {
                    Button { store.discoveryQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear layer topic search")
                }
            }
            Text("Search public datasets, then choose a layer to add to your map.").font(.caption2).foregroundStyle(.secondary)
            Picker("Sources", selection: $savedOnly) {
                Text("Nearby").tag(false)
                Text("Saved").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
                LazyVStack(alignment: .leading, spacing: 12) {
                    if savedOnly {
                        Text("YOUR ADDED LAYERS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(starters, id: \.kind) { PublicDataSourceCard(store: store, source: $0) }
                        ForEach(store.customDataLayers) { layer in
                            HStack { Text(layer.name); Spacer(); Text(layer.category.title).foregroundStyle(.secondary) }.font(.callout)
                        }
                        if starters.isEmpty && store.customDataLayers.isEmpty {
                            Text("No saved layers. Choose Nearby to find sources.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Manage saved layers and connections…") { store.showPublicData = false; store.showCustomData = true }
                    } else {
                        DataLibrarySection(store: store)
                        discoveredServices
                        CatalogDataSection(store: store)
                        directory
                        DisclosureGroup("Reference layers for this area") {
                            ForEach(starters, id: \.kind) { PublicDataSourceCard(store: store, source: $0) }
                            Text("Flood mapping covers participating U.S. communities. Regional reference layers appear only in their area; existing added layers remain in Saved.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.font(.caption)
                    }
                }.padding(.bottom, 8)
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(embedded ? 12 : 16)
            .frame(width: embedded ? nil : 380)
            .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: embedded ? 0 : 12))
            .task { await store.loadPublicDataCatalog(); filterDirectory(); store.scheduleDataDiscovery(force: true) }
            .sheet(item: $selectedService) { DiscoveredServiceView(store: store, service: $0) }
            .onChange(of: store.discoveryQuery) { _, _ in store.scheduleDataDiscovery(force: true) }
            .onChange(of: query) { _, _ in resultLimit = 30; filterDirectory(); if !query.isEmpty { directoryExpanded = true } }
            .onChange(of: store.publicDataCounties.count) { _, _ in filterDirectory() }
            .onChange(of: store.placeDataRegion) { _, _ in filterDirectory(); directoryExpanded = true }
            .onDisappear {
                filterTask?.cancel()
                store.discoveryTask?.cancel(); store.discoveryGeneration = UUID(); store.discoveryLoading = false
            }
    }

    private func filterDirectory() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        filterTask?.cancel()
        let portals = store.publicDataCounties
        let region = store.placeDataRegion
        filterTask = Task {
            let result = await Task.detached(priority: .utility) {
                portals.filter { portal in
                    needle.isEmpty ? region?.matches(portal) == true : "\(portal.name) \(portal.county) \(portal.state) \(portal.fips)".localizedStandardContains(needle)
                }
            }.value
            guard !Task.isCancelled else { return }
            filteredPortals = result
        }
    }

    private var discoveredServices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PUBLIC SERVICES FOR THIS AREA").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if store.discoveryLoading { ProgressView().controlSize(.small) }
            Text(store.discoveryStatus.isEmpty ? "Finding sources for the map center…" : store.discoveryStatus).font(.caption).foregroundStyle(.secondary)
            ForEach(store.discoveredData) { source in
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Button("Choose layer…") { selectedService = source }.font(.caption)
                    Text("Publisher account: " + source.publisher).font(.caption).foregroundStyle(.secondary)
                    Text(source.modifiedAt.map { "Catalog item modified: " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "Catalog item modified: Not supplied").font(.caption2).foregroundStyle(.secondary)
                    Link("Coverage, credits and reuse terms ↗", destination: source.itemURL).font(.caption)
                }.padding(9).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var directory: some View {
        DisclosureGroup(isExpanded: $directoryExpanded) {
            LazyVStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search county, state or FIPS directory", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("Search local public data").accessibilityIdentifier("public-data-search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear public data search")
                }
            }.padding(8).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                Text("Candidate portals from the county catalog. These links open the publisher’s site; they are not automatically available map layers. Access and reuse terms vary.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.publicDataCounties.isEmpty {
                    Text("County catalog unavailable.").font(.caption).foregroundStyle(.secondary)
                } else if filteredPortals.isEmpty {
                    Text(query.isEmpty ? "No county catalog match for this area. Search a county, state or FIPS to browse elsewhere." : "No matching county sources.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(filteredPortals.prefix(resultLimit))) { portal in
                    VStack(alignment: .leading, spacing: 3) {
                        Link(destination: portal.url) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(portal.name).lineLimit(2)
                                Spacer(minLength: 4)
                                Image(systemName: "arrow.up.right.square").font(.caption)
                            }
                        }.font(.callout).accessibilityLabel("Open source: \(portal.name), \(portal.county), \(portal.state)")
                        Text("\(portal.county), \(portal.state) · FIPS \(portal.fips)").font(.caption).foregroundStyle(.secondary)
                        Text("Source updated: Not supplied · Catalog discovered: \(portal.discovered ?? "Unknown")")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("Candidate · \(portal.siteType) · Login required: \(portal.access)")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 3)
                    Divider()
                }
                if filteredPortals.count > resultLimit {
                    Button("Show more (\(filteredPortals.count - resultLimit) remaining)") { resultLimit += 30 }.font(.caption)
                }
            }.padding(.top, 8)
        } label: {
            Text(query.isEmpty ? "County portals for this area (\(filteredPortals.count))" : "County directory matches (\(filteredPortals.count))").font(.callout.weight(.medium))
        }
    }

}

private struct PublicDataSourceCard: View {
    @ObservedObject var store: EarthStore
    let source: PublicDataSource
    private var enabled: Bool { store.publicDataEnabled.contains(source.kind) }
    private var loading: Bool { store.publicDataLoading.contains(source.kind) }
    private var opacity: Binding<Double> {
        Binding(get: { store.publicDataOpacity[source.kind] ?? 0.7 }, set: { store.setPublicDataOpacity(source.kind, opacity: $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title).font(.subheadline.weight(.semibold))
                    Text(source.publisher).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 5)
                Button(enabled ? "Remove" : "Add") { store.setPublicData(source.kind, enabled: !enabled) }
                    .accessibilityLabel("\(enabled ? "Remove" : "Add") \(source.title)")
            }
            if enabled {
                if !store.publicDataSupported {
                    Text("This layer is available on the globe and regular map, outside Street View and Google photorealistic 3D.").font(.caption).foregroundStyle(.secondary)
                    Button("Switch to Map to show this layer") { store.usePublicDataMap() }.font(.caption)
                }
                Toggle("Visible", isOn: Binding(get: { !store.publicDataHidden.contains(source.kind) }, set: { store.setPublicDataVisible(source.kind, visible: $0) }))
                    .toggleStyle(.checkbox).font(.caption)
                HStack(spacing: 8) {
                    Text("Opacity").font(.caption)
                    Slider(value: opacity, in: 0.1...1).accessibilityLabel("\(source.title) opacity")
                    Text(opacity.wrappedValue, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit().frame(width: 32, alignment: .trailing)
                }
                HStack(alignment: .top, spacing: 6) {
                    if loading { ProgressView().controlSize(.mini) }
                    Text(store.publicDataStatus[source.kind] ?? "Waiting for the view to settle…")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                HStack {
                    Button("Zoom closer") { store.zoomToPublicData(source.kind) }
                    Spacer()
                    Button("Retry") { store.refreshPublicData(force: true) }.disabled(loading)
                }.font(.caption)
            }
            DisclosureGroup("Source and coverage") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.coverage)
                    Text(source.terms)
                    Text(store.sourceFreshness[source.id]?.updateLabel ?? "Source updated: Not supplied · Metadata not checked")
                    if let checked = store.sourceFreshness[source.id]?.checkedLabel { Text(checked) }
                    Button("View source dates") { store.showSourceDates = true }
                    Link("Open source ↗", destination: source.sourceURL)
                }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }.font(.caption)
        }.padding(11).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }
}


struct PublicDataDetailView: View {
    @ObservedObject var store: EarthStore
    let feature: PublicDataFeature
    private var source: PublicDataSource { PublicDataSource.source(feature.kind) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(source.title).font(.headline)
                Spacer()
                Button("Done") { store.publicDataSelection = nil }.keyboardShortcut(.cancelAction)
            }
            Text(source.publisher).font(.caption).foregroundStyle(.secondary)
            Text(source.coverage).font(.caption).foregroundStyle(.secondary)
            Divider()
            if store.publicDataDetailLoading {
                HStack { ProgressView().controlSize(.small); Text("Loading source details…") }.font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if store.publicDataAttributes.isEmpty {
                            Text("No additional attributes supplied. Open the original source for availability and details.").foregroundStyle(.secondary)
                        }
                        ForEach(store.publicDataAttributes.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(key).font(.caption).foregroundStyle(.secondary)
                                Text(store.publicDataAttributes[key] ?? "").font(.callout).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 380)
            }
            Text(source.terms).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("Open original source ↗", destination: source.sourceURL)
                Spacer()
                Button("Retry") { store.showPublicDataDetails(feature) }.disabled(store.publicDataDetailLoading)
            }.font(.caption)
        }.padding(20).frame(width: 440).frame(minHeight: 260)
    }
}


struct DiscoveredServiceView: View {
    @ObservedObject var store: EarthStore
    let service: DiscoveredDataService
    var initialCategory: CustomDataCategory = .other
    @Environment(\.dismiss) private var dismiss
    @State private var layers: [DiscoveredDataLayer] = []
    @State private var loading = true
    @State private var message = ""
    @State private var category: CustomDataCategory = .other
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(service.name).font(.headline); Spacer(); Button("Done") { dismiss() } }
            Text("Choose a vector layer to save as a custom connection. Adding is explicit; coverage, availability and reuse terms vary.").font(.caption).foregroundStyle(.secondary)
            Picker("Section", selection: $category) { ForEach(CustomDataCategory.allCases) { Text($0.title).tag($0) } }
            if loading { ProgressView("Reading service layer list…") }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(layers) { layer in
                        HStack {
                            Text(layer.name)
                            Spacer()
                            let saved = store.customDataLayers.contains { $0.url == layer.url }
                            Button(saved ? "Added" : "Add") {
                                do { try store.addCustomConnection(name: layer.name, category: category, format: .arcGIS, url: layer.url) }
                                catch { message = error.localizedDescription }
                            }.disabled(saved || store.customDataLayers.count >= 8)
                        }
                    }
                }
            }
            Link("Publisher coverage and terms ↗", destination: service.itemURL).font(.caption)
            Text("Catalog modification is not necessarily the data update date. Provider update dates are checked after connecting.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 500, height: 420)
            .task {
                do {
                    category = initialCategory
                    layers = try await PlaceDataDiscoveryService.shared.layers(in: service)
                    if layers.isEmpty { message = "No supported vector layers listed. Open the publisher’s source for details." }
                } catch { message = error.localizedDescription }
                loading = false
            }
    }
}
