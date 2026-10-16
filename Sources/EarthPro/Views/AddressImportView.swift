import SwiftUI

@MainActor struct AddressImportView: View {
    @ObservedObject var store: EarthStore
    @StateObject private var importer = AddressPinImporter()
    @State private var text = ""
    @State private var color = "#E234A8"
    @Environment(\.dismiss) private var dismiss
    private var addresses: [String] { AddressPinImporter.addresses(text) }
    private var waitingForGoogle: Bool { store.provider == .google && !store.googleReady }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Plot Address List", systemImage: "mappin.and.ellipse").font(.title2)
            Text("Paste one complete address per line, including the city or postal code. Blank lines and duplicate addresses are skipped. Coordinate pairs also work.").font(.callout).foregroundStyle(.secondary)
            Text(store.provider == .google ? "Address lookup: Google Maps · Uses your connected key" : "Address lookup: Apple Maps · No API key needed").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).padding(6).frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("Addresses, one per line").disabled(importer.running)
            HStack {
                Text("\(addresses.count) unique addresses · Maximum \(AddressPinImporter.limit)").font(.caption).foregroundStyle(addresses.count > AddressPinImporter.limit ? .red : .secondary)
                Spacer()
                Picker("Pin color", selection: $color) {
                    Text("Magenta").tag("#E234A8"); Text("Blue").tag("#53B8F6"); Text("Green").tag("#77CC9C")
                    Text("Gold").tag("#F5C542"); Text("Coral").tag("#FF6B5E"); Text("Purple").tag("#C49BFF")
                }.frame(width: 170).disabled(importer.running)
            }
            if importer.running {
                ProgressView(value: Double(importer.completedCount), total: Double(max(1, importer.rows.count)))
                Text("Looking up addresses: \(importer.completedCount) of \(importer.rows.count). Stopping keeps the matches already found.").font(.caption)
            } else if !importer.rows.isEmpty {
                Text("\(importer.plottedCount) pins plotted · \(importer.failures.count) unresolved" + (importer.completedCount < importer.rows.count ? " · Stopped early" : "")).font(.headline)
            }
            if !importer.rows.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(importer.rows) { row in
                            HStack(alignment: .top) {
                                Image(systemName: row.match != nil ? "checkmark.circle.fill" : row.failure != nil ? "exclamationmark.circle" : "clock")
                                    .foregroundStyle(row.match != nil ? Color.green : row.failure != nil ? .orange : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.address).font(.callout)
                                    if let hit = row.match { Text(hit.title).font(.caption).foregroundStyle(.secondary) }
                                    if let failure = row.failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                            }
                        }
                    }.padding(6)
                }.frame(height: 140)
            }
            if waitingForGoogle { Text("Waiting for Google Maps to connect…").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if !importer.running, !importer.failures.isEmpty {
                    Button("Use Unresolved Addresses") { text = importer.failures.map(\.address).joined(separator: "\n") }
                }
                Spacer()
                if importer.running { Button("Stop") { importer.stop() } }
                else {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Plot Addresses") {
                        importer.plot(addresses, color: color, resolve: { try await store.resolveAddressForPins($0) }, commit: { store.addAddressPins($0) })
                    }.buttonStyle(.borderedProminent).disabled(addresses.isEmpty || addresses.count > AddressPinImporter.limit || waitingForGoogle)
                }
            }
        }.padding(24).frame(width: 570).interactiveDismissDisabled(importer.running)
            .onAppear { if store.provider == .google { store.setMode(.map) } }
            .onDisappear { importer.stop() }
    }
}
