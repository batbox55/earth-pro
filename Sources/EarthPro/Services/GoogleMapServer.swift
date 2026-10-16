import Foundation
import Network

/// A real loopback HTTP origin lets WebKit send Google's required website referrer.
/// Only the bundled page at an unpredictable path is served; no key or library is served.
final class GoogleMapServer {
    static let shared = GoogleMapServer()
    static let origin = "http://127.0.0.1:18793"
    static let referrer = origin + "/*"
    private let requestedPort: UInt16
    private var boundPort: UInt16
    init(port: UInt16 = 18793) { requestedPort = port; boundPort = port }
    func stop() {
        queue.async { [self] in
            ready = false; listener?.cancel(); listener = nil
            connections.values.forEach { $0.cancel() }
        }
    }
    private let queue = DispatchQueue(label: "EarthPro.GoogleMapHTTP")
    private let path = "/" + UUID().uuidString + "/map"
    private var listener: NWListener?
    private var ready = false
    private var waiting: [(Result<URL, Error>) -> Void] = []
    private var connections: [UUID: NWConnection] = [:]

    func start(_ completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            if ready { DispatchQueue.main.async { completion(.success(self.url)) }; return }
            waiting.append(completion)
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requestedPort)!)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.boundPort = self.listener?.port?.rawValue ?? self.requestedPort; self.ready = true; self.finish(.success(self.url))
                    case .failed:
                        self.ready = false; self.listener?.cancel(); self.listener = nil
                        self.finish(.failure(KMLError.invalid("Google Maps could not open its local viewer on port 18793. Close another copy of Earth Pro or the app using that port, then retry.")))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            } catch { self.finish(.failure(KMLError.invalid("The local Google Maps viewer could not start."))) }
        }
    }
    private var url: URL { URL(string: "http://127.0.0.1:\(boundPort)" + path)! }
    private func finish(_ result: Result<URL, Error>) {
        let callbacks = waiting; waiting = []
        DispatchQueue.main.async { callbacks.forEach { $0(result) } }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 12 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
            if case .failed = state { connection?.cancel() }
        }
        connection.start(queue: queue)
        receive(connection, data: Data())
        queue.asyncAfter(deadline: .now() + 8) { connection.cancel() }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = data; if let chunk { request.append(chunk) }
            guard request.count <= 8192 else { connection.cancel(); return }
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                let lines = text.components(separatedBy: "\r\n")
                let validHost = lines.contains { $0.lowercased() == "host: 127.0.0.1:\(self.boundPort)" }
                let validPath = lines.first == "GET \(self.path) HTTP/1.1"
                let body: Data
                let status: String
                if validHost, validPath, let file = Bundle.module.url(forResource: "GoogleMap", withExtension: "html"), let html = try? Data(contentsOf: file) { body = html; status = "200 OK" }
                else { body = Data("Not found".utf8); status = "404 Not Found" }
                var response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: strict-origin-when-cross-origin\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil { connection.cancel() }
            else { self.receive(connection, data: request) }
        }
    }
}
