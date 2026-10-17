import Foundation

struct VectorStyle: Codable, Equatable, Hashable {
    var fill: String = "#58A6DA"
    var stroke: String = "#2875A5"
    var fillOpacity: Double = 0.35
    var strokeOpacity: Double = 1
    var width: Double = 1.5
    var symbolKind: FeatureKind?
    var hasVisibleGeometry: Bool { (symbolKind != .path && fillOpacity > 0) || (strokeOpacity > 0 && width > 0) }
    var isValid: Bool {
        [fill, stroke].allSatisfy { $0.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil } &&
        fillOpacity.isFinite && (0...1).contains(fillOpacity) && strokeOpacity.isFinite && (0...1).contains(strokeOpacity) && width.isFinite && (0...20).contains(width)
    }
}
struct LayerLegendEntry: Codable, Equatable, Identifiable {
    var label: String
    var style: VectorStyle
    var id: String { label + style.fill + style.stroke }
}
