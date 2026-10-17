import Foundation

/// A user collection shared by saved places and custom data layer references.
struct EarthFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
}
