import MapKit

/// Debounces typing and replaces the completer so late responses cannot restore stale suggestions.
@MainActor
final class PlaceSearchCompleter: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    private var completer: MKLocalSearchCompleter?
    private var pending: Task<Void, Never>?
    private let receive: ([MKLocalSearchCompletion]) -> Void
    init(receive: @escaping ([MKLocalSearchCompletion]) -> Void) { self.receive = receive }
    func update(_ text: String) {
        pending?.cancel(); completer?.delegate = nil; completer?.cancel(); completer = nil
        receive([])
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, GeoPoint.parse(query) == nil else { return }
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let completer = MKLocalSearchCompleter()
            completer.resultTypes = [.address, .pointOfInterest]
            completer.delegate = self; self.completer = completer
            completer.queryFragment = query
        }
    }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard completer === self.completer else { return }
        receive(Array(completer.results.prefix(6)))
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard completer === self.completer else { return }; receive([])
    }
}
