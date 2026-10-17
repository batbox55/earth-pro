import SwiftUI

/// Reuses custom connections and their bounded current-view loading. Nothing is enabled by browsing.
struct CatalogDataSection: View {
    @ObservedObject var store: EarthStore
    @State private var expanded = false
    @State private var page: CatalogSearchPage?
    @State private var offset = 0
    @State private var loading = false
    @State private var message = ""
    @State private var selected: CatalogDataSource?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Search layer topics or place names above to search the workbook worldwide. With an empty search, names matching the chosen area are suggested; check each source’s actual coverage.")
                    .font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView("Searching source catalog…").controlSize(.small) }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let page {
                    Text("\(page.total) \(page.total == 1 ? "match" : "matches") · \(page.catalogCount) indexed sources").font(.caption2).foregroundStyle(.secondary)
                    if page.total == 0 { Text("No catalog matches. Try a city, publisher, utility type or zoning topic.").font(.caption) }
                    ForEach(page.records) { source in sourceCard(source) }
                    HStack {
                        if offset > 0 { Button("Previous") { offset = max(0, offset - 30); search() } }
                        if offset + 30 < page.total { Button("Next 30") { offset += 30; search() } }
                    }.font(.caption)
                }
            }.padding(.top, 7)
        } label: {
            Text("Workbook layers & sources" + (page.map { " (\($0.total))" } ?? "")).font(.callout.weight(.medium))
        }
        .onChange(of: expanded) { _, open in if open { search() } else { searchTask?.cancel(); loading = false } }
        .onChange(of: store.discoveryQuery) { _, _ in offset = 0; if expanded { search() } }
        .onChange(of: store.placeDataRegion) { _, _ in offset = 0; if expanded { search() } }
        .onDisappear { searchTask?.cancel() }
        .sheet(item: $selected) { source in
            if let service = source.service { DiscoveredServiceView(store: store, service: service, initialCategory: source.category) }
        }
    }
    private func search() {
        searchTask?.cancel(); loading = true; message = ""
        let query = store.discoveryQuery, region = store.placeDataRegion, offset = offset
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(200))
                let result = try await CatalogDataIndex.shared.search(query: query, region: region, offset: offset)
                guard !Task.isCancelled else { return }
                page = result; loading = false
            } catch is CancellationError { }
            catch { guard !Task.isCancelled else { return }; message = "Catalog unavailable: \(error.localizedDescription)"; loading = false }
        }
    }
    private func sourceCard(_ source: CatalogDataSource) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(source.name).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Text([source.publisher, source.geography, source.topic].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let format = source.connectionFormat {
                let saved = store.customDataLayers.contains { $0.url == source.url }
                Button(saved ? "Added" : "Add layer") {
                    do { try store.addCustomConnection(name: source.name, category: source.category, format: format, url: source.url) }
                    catch { message = error.localizedDescription }
                }.disabled(saved || store.customDataLayers.count >= 8).font(.caption)
            } else if source.service != nil {
                Button("Choose layer…") { selected = source }.font(.caption)
            } else {
                Text("Source link · Requires another format, setup or access").font(.caption2).foregroundStyle(.secondary)
            }
            Link("Publisher source & terms ↗", destination: source.sourceURL).font(.caption)
            DisclosureGroup("Access, dates & workbook details") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Login required: \(source.access) · Workbook check: \(source.verification)")
                    Text("Source update: checked after connection; not verified by this catalog.\(source.workbookModified.map { " Workbook modification value: " + $0 } ?? "")")
                    Text("Workbook terms excerpt: \(source.terms)")
                    Text("\(source.workbook) · \(source.sheet) row \(source.row) · Indexed \(source.indexedOn)")
                }.fixedSize(horizontal: false, vertical: true)
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
    }
}
