import SwiftUI

struct ImageOverlaysView: View {
    @ObservedObject var store: EarthStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EarthImageOverlay?
    @State private var failure: String?
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("Image Overlays").font(.title2); Spacer(); Button("Add Image…") { store.importImageOverlay() }; Button("Done") { dismiss() } }
            Text("Place a local image over the Earth. Enter its geographic bounds, then adjust rotation and transparency. Images are copied into your overlay library.").font(.callout).foregroundStyle(.secondary)
            HStack(alignment:.top,spacing:20) {
                ScrollView { VStack(alignment:.leading) {
                    ForEach(store.imageOverlays) { item in
                        HStack {
                            Toggle("Show \(item.name)",isOn:Binding(get:{store.imageOverlays.first(where:{$0.id==item.id})?.isVisible ?? false},set:{value in
                                if let i=store.imageOverlays.firstIndex(where:{$0.id==item.id}) { store.imageOverlays[i].isVisible=value; store.persistImageOverlays(); if draft?.id==item.id { draft?.isVisible=value } }
                            })).labelsHidden()
                            Button(item.name) { draft=item; failure=nil }.buttonStyle(.plain)
                        }.padding(6)
                    }
                }}.frame(width:170)
                Divider()
                if draft != nil {
                    Form {
                        TextField("Name",text:binding(\.name))
                        TextField("North",value:binding(\.north),format:.number)
                        TextField("South",value:binding(\.south),format:.number)
                        TextField("East",value:binding(\.east),format:.number)
                        TextField("West",value:binding(\.west),format:.number)
                        TextField("Rotation (°)",value:binding(\.rotation),format:.number)
                        Slider(value:binding(\.opacity),in:0...1) { Text("Opacity") }
                        Text("Opacity \(Int((draft?.opacity ?? 0)*100))% · Positive rotation is counterclockwise.").font(.caption).foregroundStyle(.secondary)
                        if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                        HStack {
                            Button("Delete",role:.destructive) {
                                if let id=draft?.id { store.imageOverlays.removeAll{$0.id==id};store.persistImageOverlays();draft=nil }
                            }
                            Button("Fly To") { if let d=draft { store.fly(to:d.center,distance:max(1000,(d.north-d.south)*111_000*3)) } }
                            Spacer()
                            Button("Apply") { if let d=draft { do { try store.saveImageOverlay(d); failure=nil } catch { failure=error.localizedDescription } } }.buttonStyle(.borderedProminent)
                        }
                    }.textFieldStyle(.roundedBorder)
                } else { Text("Add an image or select an overlay to edit.").foregroundStyle(.secondary).frame(maxWidth:.infinity) }
            }.frame(minHeight:340)
            Text("Bounds: ±85° latitude; maximum 180° longitude span. West > East crosses the date line. Image overlays use the regular Google map while Google photorealistic 3D is enabled.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width:690).onAppear { draft=store.imageOverlays.first(where:{$0.id==store.overlayEditingID}) ?? store.imageOverlays.first }
            .onChange(of:store.overlayEditingID) { draft=store.imageOverlays.first(where:{$0.id==store.overlayEditingID}) }
    }
    private func binding<T>(_ key: WritableKeyPath<EarthImageOverlay,T>) -> Binding<T> {
        let initial=draft![keyPath:key]
        return Binding(get:{draft.map{$0[keyPath:key]} ?? initial},set:{draft?[keyPath:key]=$0})
    }
}
