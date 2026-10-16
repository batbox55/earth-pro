import Foundation

struct KMLImport {
    var features: [EarthFeature]
    var skipped: Int
    var warnings: [String]
}
enum KMLError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
enum KMLService {
    static let maxBytes = 20 * 1024 * 1024
    static func read(_ url: URL) throws -> KMLImport {
        let data: Data
        if url.pathExtension.lowercased() == "kmz" {
            let listing = try unzip(["-Z1", url.path], limit: 256 * 1024)
            let names = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.lowercased().hasSuffix(".kml") }
            guard let name = names.first(where: { $0.lowercased() == "doc.kml" }) ?? names.first else { throw KMLError.invalid("This KMZ archive contains no KML document.") }
            data = try unzip(["-p", url.path, name], limit: maxBytes)
        } else {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxBytes else { throw KMLError.invalid("Choose a KML document smaller than 20 MB.") }
            data = try Data(contentsOf: url)
        }
        return try decode(data)
    }
    private static func unzip(_ arguments: [String], limit: Int) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit { process.terminate(); process.waitUntilExit(); throw KMLError.invalid("This archive's KML document is too large to import (20 MB maximum).") }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw KMLError.invalid("The KMZ archive could not be read.") }
        return data
    }
    static func decode(_ data: Data) throws -> KMLImport {
        guard data.count <= maxBytes else { throw KMLError.invalid("The KML document exceeds 20 MB.") }
        let delegate = KMLReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw KMLError.invalid("Invalid KML: \(parser.parserError?.localizedDescription ?? "The XML could not be parsed.")") }
        guard delegate.sawKML else { throw KMLError.invalid("This file is not a KML document.") }
        guard !delegate.features.isEmpty else { throw KMLError.invalid("No supported placemarks were found. Import Point, LineString, or Polygon geometry.") }
        return .init(features: delegate.features, skipped: delegate.skipped, warnings: Array(Set(delegate.warnings)).sorted())
    }
    static func encode(_ features: [EarthFeature]) -> Data {
        let placemarks = features.map { feature -> String in
            let coords = feature.points.map { "\($0.longitude),\($0.latitude),\($0.altitude)" }.joined(separator: " ")
            let geometry: String
            switch feature.kind {
            case .point: geometry = "<Point><coordinates>\(coords)</coordinates></Point>"
            case .path: geometry = "<LineString><tessellate>1</tessellate><coordinates>\(coords)</coordinates></LineString>"
            case .polygon:
                var ring = feature.points
                if ring.first != ring.last, let first = ring.first { ring.append(first) }
                let text = ring.map { "\($0.longitude),\($0.latitude),\($0.altitude)" }.joined(separator: " ")
                geometry = "<Polygon><outerBoundaryIs><LinearRing><coordinates>\(text)</coordinates></LinearRing></outerBoundaryIs></Polygon>"
            }
            let color = kmlColor(feature.color)
            let pinStyle = feature.kind == .point ? "<ExtendedData><Data name=\"earthProPinShape\"><value>\(feature.resolvedPinShape.rawValue)</value></Data><Data name=\"earthProPinIcon\"><value>\(feature.resolvedPinIcon.rawValue)</value></Data></ExtendedData>" : ""
            return "<Placemark><name>\(escape(feature.name))</name><description>\(escape(feature.notes))</description><visibility>\(feature.isVisible ? 1 : 0)</visibility><Style><IconStyle><color>\(color)</color></IconStyle><LineStyle><color>\(color)</color><width>3</width></LineStyle><PolyStyle><color>66\(color.dropFirst(2))</color></PolyStyle></Style>\(pinStyle)\(geometry)</Placemark>"
        }.joined(separator: "\n")
        return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document><name>Earth Pro Places</name>\(placemarks)</Document></kml>".utf8)
    }
    static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;") }
    private static func kmlColor(_ hex: String) -> String {
        let h = hex.replacingOccurrences(of: "#", with: "")
        guard h.count == 6 else { return "ff42c5f5" }
        return "ff" + h.suffix(2) + h.dropFirst(2).prefix(2) + h.prefix(2)
    }
}

private final class KMLReader: NSObject, XMLParserDelegate {
    var features: [EarthFeature] = [], skipped = 0, warnings: [String] = []
    var sawKML = false
    private var stack: [String] = [], text = "", inPlacemark = false
    private var name = "", notes = "", visible = true, color = "#F5C542"
    private var pinShape: PinShape?, pinIcon: PinIcon?, dataName: String?
    private var kind: FeatureKind?, points: [GeoPoint] = [], geometries: [(FeatureKind, [GeoPoint])] = []
    private func tag(_ element: String) -> String { String(element.split(separator: ":").last ?? Substring(element)) }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let element = tag(elementName); stack.append(element); text = ""
        if element == "kml" { sawKML = true }
        if element == "Placemark" { inPlacemark = true; name = ""; notes = ""; color = "#F5C542"; visible = true; geometries = []; pinShape = nil; pinIcon = nil; dataName = nil }
        if inPlacemark {
            if element == "Data" { dataName = attributes["name"] }
            switch element { case "Point": kind = .point; points = []; case "LineString": kind = .path; points = []; case "Polygon": kind = .polygon; points = []; case "innerBoundaryIs": warnings.append("Polygon holes were omitted; only outer boundaries are supported."); default: break }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = tag(elementName), value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inPlacemark {
            if element == "value", stack.contains("ExtendedData") {
                if dataName == "earthProPinShape" { pinShape = PinShape(rawValue: value) }
                if dataName == "earthProPinIcon" { pinIcon = PinIcon(rawValue: value) }
            }
            if element == "Data" { dataName = nil }
            if stack.suffix(2).elementsEqual(["Placemark", "name"]) { name = value }
            if stack.suffix(2).elementsEqual(["Placemark", "description"]) { notes = value }
            if stack.suffix(2).elementsEqual(["Placemark", "visibility"]) { visible = value != "0" }
            if element == "color", value.count == 8, stack.contains("IconStyle") || stack.contains("LineStyle") {
                let h = String(value.dropFirst(2)); color = "#" + h.suffix(2) + h.dropFirst(2).prefix(2) + h.prefix(2)
            }
            if element == "coordinates", !stack.contains("innerBoundaryIs") {
                let parsed = value.split(whereSeparator: \.isWhitespace).map { token -> GeoPoint? in
                    let numbers = token.split(separator: ",", omittingEmptySubsequences: false)
                    guard numbers.count >= 2, let lon = Double(numbers[0]), let lat = Double(numbers[1]) else { return nil }
                    let altitude = numbers.count > 2 ? (Double(numbers[2]) ?? 0) : 0
                    let p = GeoPoint(latitude: lat, longitude: lon, altitude: altitude)
                    return p.isValid ? p : nil
                }
                points = parsed.contains(where: { $0 == nil }) ? [] : parsed.compactMap { $0 }
            }
            if ["Point", "LineString", "Polygon"].contains(element), let kind {
                if kind == .polygon, points.count > 3, points.first == points.last { points.removeLast() }
                geometries.append((kind, points)); self.kind = nil
            }
            if element == "Placemark" {
                if geometries.isEmpty { skipped += 1 }
                for (index, geometry) in geometries.enumerated() {
                    var f = EarthFeature(name: name.isEmpty ? "Imported \(geometry.0.title)" : name, notes: notes, kind: geometry.0, points: geometry.1, color: color, isVisible: visible, pinShape: pinShape, pinIcon: pinIcon)
                    if index > 0 { f.name += " (\(index + 1))" }
                    if f.isValid { features.append(f) } else { skipped += 1 }
                }
                inPlacemark = false
            }
        }
        if !stack.isEmpty { stack.removeLast() }; text = ""
    }
}
