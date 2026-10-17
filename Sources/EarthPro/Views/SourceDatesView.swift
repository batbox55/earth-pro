import SwiftUI

struct SourceDatesView: View {
    @ObservedObject var store: EarthStore
    private let external: [(String, String)] = [
        ("Apple Maps", "A global dataset update date is not supplied. Satellite capture dates are not exposed by MapKit."),
        ("Google Maps & photorealistic 3D", "A global dataset update date is not supplied. Street View capture dates appear in the map status bar when supplied for the selected panorama."),
        ("OpenStreetMap", "Continuously edited; the tiles in a view can have different refresh times. No verified tile-wide update date is supplied here."),
        ("Esri World Imagery", "Capture dates vary by location. When capture metadata is available it appears in the map status bar; it is not the service update date."),
        ("NASA GIBS historical imagery", "The selected observation day is shown in History. An observation day is not a service update date; coverage and processing vary by product."),
        ("Esri Wayback", "History shows each archived basemap release date. Local image capture dates appear separately when supplied; release dates do not establish when an image was taken."),
        ("USGS earthquakes", "Event times belong to individual earthquakes. The current feed refresh time is not a dataset-wide update date."),
        ("Wikimedia photos", "Photo upload and capture times vary by item. A global source update date is not supplied."),
        ("Wikipedia places", "Pages can be edited independently. A global source update date is not supplied."),
        ("Open-Meteo elevation", "Elevation products have different acquisition and publication dates. A verified dataset update date is not supplied by the query response."),
        ("NASA cloud cover", "The requested observation day is \(EarthLayerService.cloudDate) UTC. This is an observation selection, not a verified service update date; clouds and gaps may vary."),
        ("Natural Earth & bundled terrain", "Bundled overview boundaries, places, roads and terrain do not supply a verified publisher update timestamp in the app. Local bundle file dates do not establish when the geographic data changed.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Source dates").font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh metadata") { store.refreshSourceDates(force: true) }
                Button("Done") { store.showSourceDates = false }.keyboardShortcut(.cancelAction)
            }
            Text("A publisher update, a catalog edit, an image capture and a download are different dates. Unknown dates remain unknown.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    Text("PUBLIC LAYERS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(PublicDataSource.starters) { source in
                        sourceRow(source.title, detail: source.publisher, freshness: store.sourceFreshness[source.id], url: source.sourceURL)
                    }
                    if !store.customDataLayers.isEmpty {
                        Text("CUSTOM LAYERS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(store.customDataLayers) { layer in
                            VStack(alignment: .leading, spacing: 4) {
                                sourceRow(layer.name, detail: layer.category.title, freshness: store.sourceFreshness[layer.id.uuidString] ?? SourceFreshness(providerUpdatedAt: layer.providerUpdatedAt, checkedAt: layer.checkedAt, status: layer.providerUpdatedAt == nil ? "No verified publisher dataset update date supplied." : "Publisher-provided dataset timestamp."), url: layer.url)
                                if let date = layer.fileModifiedAt {
                                    Text("Local file modified: \(SourceFreshness.dateText(date)) · Not a publisher update date")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("MAPS, IMAGERY & LIVE SOURCES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(external, id: \.0) { name, description in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(.headline)
                            Text("Source updated: Not supplied").font(.caption).foregroundStyle(.secondary)
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                    Text("County portal directory: publisher update dates are not supplied by the compiled directory. Each entry’s discovery date describes the catalog entry, not the underlying dataset.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).frame(width: 600, height: 620)
            .task { store.refreshSourceDates() }
    }

    private func sourceRow(_ title: String, detail: String, freshness: SourceFreshness?, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Text(freshness?.updateLabel ?? "Source updated: Not supplied · Metadata not checked").font(.callout)
            if let checked = freshness?.checkedLabel { Text(checked).font(.caption).foregroundStyle(.secondary) }
            if let status = freshness?.status, !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            if let url { Link("Open source", destination: url).font(.caption) }
            Divider()
        }
    }
}
