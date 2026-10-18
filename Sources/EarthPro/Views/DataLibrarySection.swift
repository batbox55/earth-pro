import SwiftUI

/// The same capability registry serves the sidebar and MCP; browsing never loads map data.
struct DataLibrarySection: View {
    @ObservedObject var store: EarthStore
    @State private var expanded = false
    @State private var group = DataLibraryGroup.localData
    @State private var libraries: [DataLibrary] = []
    @State private var selected: DataLibrary?
    @State private var error = ""
    var body: some View {
        DisclosureGroup(isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:9) {
                Picker("Find",selection:$group) {
                    ForEach(DataLibraryGroup.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
                Text("Browse providers by task. Searchable libraries return candidates; add only the layers you choose.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) }
                ForEach(libraries.filter { $0.group == group }) { library in
                    VStack(alignment:.leading,spacing:5) {
                        Text(library.name).font(.callout.weight(.medium)).fixedSize(horizontal:false,vertical:true)
                        Text(library.capability).font(.caption).foregroundStyle(.secondary)
                        if library.canSearch {
                            Button(library.adapter == .stac || library.adapter == .openAerialMap ? "Find scenes…" : "Find datasets…") { selected = library }.font(.caption)
                        }
                        Link("Publisher source & access ↗",destination:library.sourceURL).font(.caption)
                        DisclosureGroup("Access & limitations") {
                            Text("\(library.access)\n\(library.limitation)\nTerms: \(library.terms)\nCatalog check: \(library.verification)\nSource update: not supplied by this directory.\n\(library.workbook) · \(library.sheet), row \(library.row)")
                                .fixedSize(horizontal:false,vertical:true)
                        }.font(.caption2).foregroundStyle(.secondary)
                    }.padding(9).frame(maxWidth:.infinity,alignment:.leading)
                        .background(.quaternary.opacity(0.2),in:RoundedRectangle(cornerRadius:7))
                }
            }.padding(.top,7)
        } label: { Text("Data libraries").font(.callout.weight(.medium)) }
        .onChange(of:expanded) { _,open in
            if open && libraries.isEmpty {
                do { libraries = try DataLibrary.load() } catch { self.error = error.localizedDescription }
            }
        }
        .sheet(item:$selected) { DataLibrarySearchView(store:store,library:$0) }
    }
}

private struct DataLibrarySearchView: View {
    @ObservedObject var store: EarthStore
    let library: DataLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var collection = ""
    @State private var start = ""
    @State private var end = ""
    @State private var collections: [[String:String]] = []
    @State private var rows: [DataLibraryResult] = []
    @State private var loading = false
    @State private var status = ""
    @State private var offset = 0
    @State private var hasMore = false
    @State private var added = Set<String>()
    @State private var task: Task<Void,Never>?
    @State private var generation = UUID()
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(library.name).font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(library.capability+" · "+library.scope).font(.caption).foregroundStyle(.secondary)
            if library.adapter == .stac {
                HStack {
                    TextField("Collection ID",text:$collection).textFieldStyle(.roundedBorder)
                    Menu("Collections") {
                        ForEach(collections.indices,id:\.self) { index in
                            let item = collections[index]
                            Button(item["title"] ?? item["id"] ?? "Collection") { collection = item["id"] ?? "" }
                        }
                    }.disabled(collections.isEmpty)
                    Button("Load collections") { loadCollections() }.disabled(loading)
                }
            } else {
                TextField("Topic or place name",text:$query).textFieldStyle(.roundedBorder).onSubmit { search() }
            }
            if library.adapter == .stac || library.adapter == .openAerialMap {
                HStack {
                    TextField("From YYYY-MM-DD",text:$start)
                    TextField("To YYYY-MM-DD",text:$end)
                }.textFieldStyle(.roundedBorder)
                Text("Scene footprints show coverage, not imagery pixels. Open an asset to inspect its image or download requirements.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            HStack {
                Button("Search this area") { offset = 0; search() }.disabled(loading)
                if loading { ProgressView().controlSize(.small); Button("Cancel") { task?.cancel(); generation = UUID(); loading = false; status = "Search canceled." } }
                Spacer()
                Link("Source & terms ↗",destination:library.sourceURL)
            }
            Text(status.isEmpty ? "Uses the current map or chosen discovery area. Nothing is added until you choose a result." : status)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    ForEach(rows) { row in
                        VStack(alignment:.leading,spacing:5) {
                            Text(row.name).font(.callout.weight(.medium)).fixedSize(horizontal:false,vertical:true)
                            if let date = row.captureDate { Text("Capture: "+date).font(.caption) }
                            if let date = row.updatedAt { Text("Metadata update: "+date).font(.caption) }
                            if let clouds = row.cloudCover { Text(String(format:"Cloud cover: %.1f%%",clouds)).font(.caption) }
                            Text(row.notice).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            if row.displayKind == "service" {
                                Button("Choose layer…") { chooseLayers(row) }.disabled(loading)
                            } else if row.canAdd {
                                Button(added.contains(row.id) ? "Added" : row.footprint != nil ? "Add scene footprint" : "Add vector layer") {
                                    addResult(row)
                                }.disabled(loading || added.contains(row.id) || store.customDataLayers.count >= 8)
                            }
                            if let url = row.sourceURL { Link("Source metadata ↗",destination:url).font(.caption) }
                            if !row.assets.isEmpty {
                                DisclosureGroup("Image assets & previews") {
                                    ForEach(row.assets,id:\.name) { asset in Link(asset.name,destination:asset.url).font(.caption) }
                                }.font(.caption)
                            }
                        }.padding(9).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.2),in:RoundedRectangle(cornerRadius:7))
                    }
                    if hasMore { Button("Next 20") { offset += 20; search() }.disabled(loading) }
                }
            }
        }.padding(18).frame(minWidth:520,idealWidth:600,maxWidth:700,minHeight:460,idealHeight:620,maxHeight:760)
            .onAppear { if library.adapter != .stac { query = store.discoveryQuery } }
            .onDisappear { task?.cancel() }
    }
    private func search() {
        task?.cancel(); generation = UUID(); let epoch = generation
        loading = true; status = "Searching metadata…"; rows = []; hasMore = false
        guard store.distance <= 500_000, let bounds = PublicDataBounds.around(center:store.discoveryManualCenter ?? store.center,distance:store.distance*0.6) else { loading = false; status = "Zoom closer than 500 km before searching this area."; return }
        task = Task {
            defer { if generation == epoch { loading = false } }
            do {
                let page = try await DataLibraryService.shared.searchPage(library,query:query,bounds:bounds,collection:collection.isEmpty ? nil : collection,startDate:start.isEmpty ? nil : start,endDate:end.isEmpty ? nil : end,offset:offset)
                try Task.checkCancellation(); rows = page.results; hasMore = page.hasMore
                status = rows.isEmpty ? "No results for this search. Try another area, topic or date range." : "\(rows.count) \(rows.count == 1 ? "candidate" : "candidates") · verify coverage and publisher access before adding."
            } catch is CancellationError { } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    private func loadCollections() {
        task?.cancel(); generation = UUID(); let epoch = generation
        loading = true
        task = Task {
            defer { if generation == epoch { loading = false } }
            do { let result = try await DataLibraryService.shared.collections(library); try Task.checkCancellation(); collections = result; status = "Choose a collection, then search this area." }
            catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    private func chooseLayers(_ row: DataLibraryResult) {
        task?.cancel(); generation = UUID(); let epoch = generation
        loading = true
        task = Task {
            defer { if generation == epoch { loading = false } }
            do { let result = try await DataLibraryService.shared.layers(row.id); try Task.checkCancellation(); rows = result; hasMore = false; status = "Choose a numbered vector layer." }
            catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    private func addResult(_ row: DataLibraryResult) {
        task?.cancel(); generation = UUID(); let epoch = generation; loading = true
        task = Task {
            defer { if generation == epoch { loading = false } }
            do {
                let checked = try await DataLibraryService.shared.readyResult(row.id)
                try Task.checkCancellation()
                _ = try store.addLibraryResult(checked); added.insert(row.id)
                status = row.footprint != nil ? "Scene footprint added. This does not display imagery pixels." : "Connection added. Check its loading status in Places or Saved layers."
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
}
