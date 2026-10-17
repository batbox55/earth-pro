import SwiftUI
import AppKit

struct SidebarView: View {
    @ObservedObject var store: EarthStore
    @AppStorage("earthSidebarStacked") private var stacked = false
    @AppStorage("earthSidebarPlacesFraction") private var placesFraction = 0.5
    @State private var resizeStartHeight: CGFloat?
    @State private var resizeHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            header
            SidebarPlaceSearch(store: store, resultHeight: stacked ? 78 : 145).padding(.horizontal, 12).padding(.bottom, 10)
            Picker("Sidebar section", selection: Binding(get: { store.sidebarSection }, set: { store.setSidebarSection($0) })) {
                ForEach(SidebarSection.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            if store.sidebarSection == .data {
                PublicDataBrowser(store: store, embedded: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onExitCommand { store.setSidebarSection(.places) }
            } else if stacked {
                stackedPanes
            } else if store.sidebarSection == .places {
                SidebarLibraryPane(store: store)
            } else {
                LayersView(store: store).padding(12)
            }
            Divider()
            footer
        }.background(.regularMaterial)
            .onAppear { if store.sidebarSection == .data { store.showPublicData = true } }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: EarthBrand.icon).resizable().scaledToFit().frame(width: 28, height: 28).accessibilityLabel("Earth Pro logo")
            Text("Earth Pro").font(.system(size: 16, weight: .semibold))
            Spacer()
            Menu {
                Toggle("Show Places and Layers together", isOn: Binding(get: { stacked }, set: { value in
                    stacked = value
                    if value { store.setSidebarSection(.places) }
                }))
                Divider()
                ForEach(SidebarSection.allCases) { section in Button("Show \(section.title)") { stacked = false; store.setSidebarSection(section) } }
            } label: { Image(systemName: stacked ? "rectangle.split.1x2" : "sidebar.left") }
                .menuStyle(.borderlessButton).fixedSize().help("Sidebar layout · Use tabs or stack Places and Layers")
                .accessibilityLabel("Sidebar layout")
        }.padding(12)
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Button { store.googleSettings = true } label: {
                Label("Google Maps settings", systemImage: "key")
                    .font(.system(size: 11)).lineLimit(1)
            }.buttonStyle(.plain).help("Add or manage your optional Google Maps API key")
            Spacer(minLength: 2)
            Button { store.showSourceDates = true } label: { Image(systemName: "clock.badge.questionmark") }
                .buttonStyle(.plain).help("Source update dates").accessibilityLabel("Source update dates")
        }.padding(.horizontal, 12).padding(.vertical, 11)
    }
    private var stackedPanes: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Places + Layers").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button("Use tabs") { stacked = false }.font(.caption).buttonStyle(.plain)
            }.padding(.horizontal, 12).padding(.vertical, 6)
            GeometryReader { geometry in
                let available = max(1, geometry.size.height - 16)
                let lower = min(100, available * 0.35)
                let upper = max(lower, available - min(130, available * 0.45))
                let topHeight = min(max(lower, resizeHeight ?? available * placesFraction), upper)
                VStack(spacing: 0) {
                    SidebarLibraryPane(store: store).frame(height: topHeight)
                    ZStack {
                        Rectangle().fill(.quaternary.opacity(0.4))
                        Capsule().fill(.secondary.opacity(0.5)).frame(width: 32, height: 3)
                    }.frame(height: 16).contentShape(Rectangle())
                        .onHover { if $0 { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                        .help("Drag up to give Layers more room")
                        .accessibilityLabel("Resize Layers section")
                        .accessibilityValue("\(Int((1 - topHeight / available) * 100)) percent for Layers")
                        .accessibilityAdjustableAction { direction in placesFraction = min(0.85, max(0.15, placesFraction + (direction == .increment ? -0.05 : 0.05))) }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("sidebarResize"))
                            .onChanged { value in
                                let start = resizeStartHeight ?? topHeight
                                resizeStartHeight = start
                                resizeHeight = min(max(lower, start + value.translation.height), upper)
                            }
                            .onEnded { value in
                                let start = resizeStartHeight ?? topHeight
                                placesFraction = min(max(lower, start + value.translation.height), upper) / available
                                resizeStartHeight = nil; resizeHeight = nil
                            })
                    LayersView(store: store).padding(12).frame(maxHeight: .infinity)
                }.coordinateSpace(name: "sidebarResize")
            }
        }
    }
}

private struct SidebarPlaceSearch: View {
    @ObservedObject var store: EarthStore
    var resultHeight: CGFloat = 145
    @State private var resultsExpanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search a place", text: Binding(get: { store.searchText }, set: { if store.searchText != $0 { store.searchText = $0 } }))
                        .textFieldStyle(.plain).onSubmit { store.search() }.accessibilityIdentifier("place-search")
                        .help("Search a city, address or latitude/longitude")
                    if !store.searchText.isEmpty {
                        Button { store.searchText = ""; store.search() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear place search")
                    }
                }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                Button { store.search() } label: { Image(systemName: "arrow.right") }
                    .buttonStyle(.borderedProminent).help("Search")
                    .accessibilityLabel("Search for a place").disabled(store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Text(store.provider == .google ? "Google Maps search" : "Apple search").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    if store.recentSearches.isEmpty { Text("No recent searches") }
                    ForEach(store.recentSearches, id: \.self) { query in Button(query) { store.repeatSearch(query) } }
                    Divider()
                    Button("Clear Search History") { store.clearSearchHistory() }.disabled(store.recentSearches.isEmpty)
                } label: { Label("Recent", systemImage: "clock") }.menuStyle(.borderlessButton).fixedSize().font(.caption)
            }
            if store.searching { HStack { ProgressView().controlSize(.mini); Text("Searching…").font(.caption).foregroundStyle(.secondary) } }
            if !store.searchSuggestions.isEmpty || !store.searchHits.isEmpty {
                DisclosureGroup("Search results (\(store.searchSuggestions.count + store.searchHits.count))", isExpanded: $resultsExpanded) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(store.searchSuggestions.prefix(6).enumerated()), id: \.offset) { _, suggestion in
                            Button { store.selectSearchSuggestion(suggestion) } label: {
                                searchRow(title: suggestion.title, subtitle: suggestion.subtitle, icon: "magnifyingglass")
                            }.buttonStyle(.plain)
                        }
                        ForEach(store.searchHits) { hit in
                            HStack(alignment: .top, spacing: 6) {
                                Button { store.selectSearchHit(hit) } label: { searchRow(title: hit.title, subtitle: hit.subtitle, icon: "mappin") }.buttonStyle(.plain)
                                Button { store.saveSearchHit(hit) } label: { Image(systemName: "plus.circle") }
                                    .buttonStyle(.plain).help("Save \(hit.title)").accessibilityLabel("Save \(hit.title)")
                            }
                        }
                    }
                }.frame(maxHeight: resultHeight)
                    .scrollIndicators(.visible)
                }.font(.caption)
            }
        }
    }
    private func searchRow(title: String, subtitle: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
    }
}
