import Foundation

/// Provider edits, catalog maintenance, local file edits and imagery capture dates are different facts.
struct SourceFreshness: Codable, Equatable, Sendable {
    var providerUpdatedAt: Date?
    var checkedAt: Date?
    var status: String
    var provenance: String = "Source updated"

    var updateLabel: String {
        guard let providerUpdatedAt else { return "Source updated: Not supplied" }
        return "\(provenance): \(Self.dateText(providerUpdatedAt))"
    }
    var checkedLabel: String? { checkedAt.map { "Metadata checked: \(Self.dateText($0))" } }
    static func dateText(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}
