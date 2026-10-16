import SwiftUI

struct GoogleMapsSettingsView: View {
    @ObservedObject var store: EarthStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: "map.fill").font(.system(size: 30)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Google Maps").font(.title2.bold())
                    Text("Connect your own Google Maps Platform project.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close settings")
            }
            Text("Unlock Google satellite and street maps, photorealistic 3D buildings and terrain, address search, and Street View. Google bills usage to your project. Apple Maps, OpenStreetMap streets, and the NASA globe work without a key.").font(.callout).fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label(store.googleKeyLoading ? "Waiting for macOS Keychain access…" : (store.googleKeyAccessError != nil ? "Saved key needs Keychain access" : (store.googleKey == nil ? "No API key saved" : "API key saved in macOS Keychain")), systemImage: store.googleKey == nil ? "key" : "checkmark.shield.fill").font(.headline)
                    SecureField(store.googleKey == nil ? "Paste Google Maps API key" : "Paste a replacement key", text: $key).textFieldStyle(.roundedBorder).accessibilityIdentifier("google-api-key")
                    Text("Save once: the app automatically restores this key on later launches. The key is stored only in Keychain. It is sent to Google when you use Google Maps; it is never included in KML or your places library.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let accessError = store.googleKeyAccessError {
                        Text(accessError).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Retry Saved Key") { store.loadGoogleKey() }
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.red) }
                    HStack {
                        Button("Remove Key", role: .destructive) {
                            do { try store.removeGoogleKey(); key = ""; message = nil } catch { message = error.localizedDescription }
                        }.disabled(store.googleKey == nil)
                        Spacer()
                        Button("Save Key") { save(use: false) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Use Google Maps") {
                            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store.chooseProvider(.google); dismiss() }
                            else { save(use: true) }
                        }.buttonStyle(.borderedProminent).disabled(store.googleKey == nil && key.isEmpty)
                    }
                }.padding(8)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Set up your project").font(.headline)
                Text("1. Enable billing and Maps JavaScript API (including 3D map loads). Enable Geocoding API for address search. Photorealistic 3D uses the same key; coverage and Google usage charges apply.")
                Text("2. Create a dedicated browser key. Set application restrictions to Websites and add this referrer:")
                HStack {
                    Text(GoogleMapServer.referrer).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(GoogleMapServer.referrer, forType: .string) }
                }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                Text("3. Restrict the key to Maps JavaScript API and Geocoding API. Set budgets and quotas in Google Cloud.")
                Text("The viewer uses a local HTTP origin so website restrictions work. Browser API keys are visible to the web runtime; Google Cloud restrictions protect their use.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("Google Cloud setup ↗", destination: URL(string: "https://developers.google.com/maps/documentation/javascript/get-api-key")!)
                    Spacer()
                    Link("Key security guidance ↗", destination: URL(string: "https://developers.google.com/maps/api-security-best-practices")!)
                }
            }.font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack { Text("A saved key is checked by Google when the map loads.").font(.caption).foregroundStyle(.secondary); Spacer(); Button(store.googleKey == nil ? "Continue without a key" : "Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(26).frame(width: 570).onAppear { store.loadGoogleKey() }
    }
    private func save(use: Bool) {
        do { try store.saveGoogleKey(key); key = ""; message = nil; if use { store.chooseProvider(.google); dismiss() } }
        catch { message = error.localizedDescription }
    }
}
