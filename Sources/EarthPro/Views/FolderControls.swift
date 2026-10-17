import SwiftUI

struct EarthFolderPicker: View {
    @ObservedObject var store: EarthStore
    @Binding var selection: UUID?
    var body: some View {
        Picker("Folder", selection: $selection) {
            Text("Unfiled").tag(UUID?.none)
            ForEach(store.folders) { folder in Text(folder.name).tag(Optional(folder.id)) }
        }
    }
}

struct EarthFolderEditor: View {
    @ObservedObject var store: EarthStore
    var folder: EarthFolder?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(folder == nil ? "New folder" : "Rename folder").font(.title2)
            TextField("Folder name", text: $name).textFieldStyle(.roundedBorder).onSubmit { save() }
            Text("Organize saved places and custom layers together.").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 340).onAppear { name = folder?.name ?? "" }
    }
    private func save() {
        do {
            if let folder { try store.renameFolder(id: folder.id, name: name) }
            else { store.selectedFolderID = try store.createFolder(name: name) }
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
