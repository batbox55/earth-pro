import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case places, layers, data
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
