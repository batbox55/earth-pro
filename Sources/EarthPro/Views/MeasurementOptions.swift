import SwiftUI

struct MeasurementOptions: View {
    @ObservedObject var store: EarthStore
    var showsArea: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Distance", selection: $store.measurementDistanceUnit) {
                ForEach(DistanceUnit.allCases, id: \.self) { Text($0.title).tag($0) }
            }.accessibilityLabel("Measurement distance unit")
            precisionPicker("Distance decimals", selection: $store.measurementDistanceDecimals)
            if showsArea {
                Picker("Area", selection: $store.measurementAreaUnit) {
                    ForEach(AreaUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityLabel("Measurement area unit")
                precisionPicker("Area decimals", selection: $store.measurementAreaDecimals)
            }
        }.pickerStyle(.menu).font(.callout)
        Text("Surface measurements on a spherical Earth. Decimal places control display, not survey accuracy.")
            .font(.caption2).foregroundStyle(.secondary)
    }
    private func precisionPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            Text("Auto (6 sig. digits)").tag(-1)
            ForEach(0...9, id: \.self) { Text("\($0)").tag($0) }
        }.accessibilityLabel(title).help("Automatic removes trailing zeros and shows up to six significant digits. Fixed settings show 0–9 decimal places.")
    }
}
