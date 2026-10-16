import SwiftUI

struct FeatureEditor: View {
    @ObservedObject var store: EarthStore
    @State private var feature: EarthFeature
    @State private var latitude: String
    @State private var longitude: String
    @State private var invalid = false
    init(store: EarthStore, feature: EarthFeature) {
        self.store = store
        _feature = State(initialValue: feature)
        _latitude = State(initialValue: String(format: "%.7f", feature.center.latitude))
        _longitude = State(initialValue: String(format: "%.7f", feature.center.longitude))
    }
    private let colors = ["#F5C542", "#FF6B5E", "#53B8F6", "#77CC9C", "#C49BFF"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(feature.kind.title, systemImage: feature.kind.icon).font(.title2)
            Form {
                TextField("Name", text: $feature.name)
                if feature.kind == .point {
                    TextField("Latitude", text: $latitude)
                    TextField("Longitude", text: $longitude)
                } else {
                    MeasurementOptions(store: store, showsArea: feature.kind == .polygon)
                    LabeledContent("Geometry", value: "\(feature.points.count) points")
                    LabeledContent(feature.kind == .polygon ? "Perimeter" : "Length", value: store.formatMeasurementDistance(feature.distance))
                    if feature.kind == .polygon { LabeledContent("Area", value: store.formatMeasurementArea(GeoMath.area(feature.points))) }
                }
            }.textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 6) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $feature.notes).font(.body).frame(height: 95).padding(5).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }
            HStack(spacing: 12) {
                Text("Color").font(.caption).foregroundStyle(.secondary)
                ForEach(colors, id: \.self) { color in
                    Button { feature.color = color } label: { Circle().fill(Color(nsColor: .init(earthHex: color))).frame(width: 22, height: 22).overlay { if feature.color.uppercased() == color { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black) } } }.buttonStyle(.plain).accessibilityLabel("Color \(color)")
                }
            }
            ColorPicker("Custom color", selection: Binding(get: { Color(nsColor: NSColor(earthHex: feature.color)) }, set: { color in
                if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                    feature.color = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                }
            }), supportsOpacity: false)
            if feature.kind == .point {
                HStack(spacing: 16) {
                    Image(nsImage: EarthPinAppearance.image(feature)).frame(width: 40, height: 48).accessibilityLabel("Pin preview")
                    VStack {
                        Picker("Shape", selection: Binding(get: { feature.resolvedPinShape }, set: { feature.pinShape = $0 })) {
                            ForEach(PinShape.allCases, id: \.self) { shape in Text(shape.title).tag(shape) }
                        }
                        Picker("Icon", selection: Binding(get: { feature.resolvedPinIcon }, set: { feature.pinIcon = $0 })) {
                            ForEach(PinIcon.allCases, id: \.self) { icon in Label(icon.title, systemImage: icon.symbol).tag(icon) }
                        }
                    }
                }
            }
            if invalid { Text("Enter a name and valid latitude (−90…90) and longitude (−180…180).").font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { store.cancelTool() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Place") {
                    if feature.kind == .point {
                        guard let lat = Double(latitude), let lon = Double(longitude) else { invalid = true; return }
                        feature.points = [.init(latitude: lat, longitude: lon, altitude: feature.center.altitude)]
                    }
                    guard feature.isValid else { invalid = true; return }; store.save(feature)
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 420)
    }
}
