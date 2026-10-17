import Foundation

/// QGIS simple fill/line symbols, categorized and graduated renderers.
/// Advanced geometry generators, expressions and multilayer symbols are not approximated silently.
final class QGISStyleReader: NSObject, XMLParserDelegate {
    var type = "", field = "", currentSymbol: String?, currentLayer = ""
    var symbols: [String: [String: String]] = [:], symbolLayers: [String: Int] = [:]
    var categories: [(String,String,String)] = [], ranges: [(Double,Double,String,String)] = []
    var supported = true, symbolDepth = 0
    static func decode(_ data: Data) -> VectorStyling? {
        guard data.count <= CustomDataService.byteLimit else { return nil }
        let reader = QGISStyleReader(), parser = XMLParser(data:data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), !reader.type.isEmpty else { return nil }
        var result = VectorStyling(fields:reader.field.isEmpty ? [] : [reader.field],delimiter:", ",rules:[],fallback:nil,fallbackLabel:"Other values",supported:reader.supported)
        func style(_ id: String) -> VectorStyle? {
            guard let p = reader.symbols[id], reader.symbolLayers[id] == 1 else { return nil }
            func color(_ raw: String?, fallback: String) -> (String,Double) {
                guard let raw else { return (fallback,1) }
                let values = raw.split(separator:",").compactMap { Double($0) }
                if values.count >= 3, values.allSatisfy({ $0.isFinite && (0...255).contains($0) }) {
                    return (String(format:"#%02X%02X%02X",Int(values[0]),Int(values[1]),Int(values[2])),values.count > 3 ? values[3]/255 : 1)
                }
                return (raw,1)
            }
            let fill = color(p["color"],fallback:"#58A6DA"), stroke = color(p["outline_color"] ?? p["line_color"],fallback:fill.0)
            let width = Double(p["outline_width"] ?? p["line_width"] ?? "0.4") ?? 0.4
            let unit = p["outline_width_unit"] ?? p["line_width_unit"] ?? "MM"
            guard ["MM","Pixel","Point"].contains(unit), [nil,"solid","no"].contains(p["style"]), [nil,"solid","no"].contains(p["outline_style"] ?? p["line_style"]) else { return nil }
            let style = VectorStyle(fill:fill.0,stroke:stroke.0,fillOpacity:p["style"] == "no" || p["__class"] == "SimpleLine" ? 0 : fill.1,strokeOpacity:p["outline_style"] == "no" || p["line_style"] == "no" ? 0 : stroke.1,width:min(20,max(0,width*(unit == "MM" ? 3.7795 : unit == "Point" ? 1.3333 : 1))))
            return style.isValid ? style : nil
        }
        switch reader.type {
        case "singleSymbol":
            if let s = style("0") { result.rules = [.init(label:"All features",style:s)] } else { result.supported = false }
        case "categorizedSymbol":
            for (value,label,symbol) in reader.categories {
                guard let s = style(symbol) else { result.supported = false; continue }
                result.rules.append(.init(label:label,style:s,value:value))
            }
        case "graduatedSymbol":
            for (low,high,label,symbol) in reader.ranges {
                guard let s = style(symbol) else { result.supported = false; continue }
                result.rules.append(.init(label:label,style:s,minimum:low,maximum:high))
            }
        default: result.supported = false
        }
        return result
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String:String]) {
        switch name {
        case "renderer-v2": type = a["type"] ?? ""; field = a["attr"] ?? ""
        case "symbol": symbolDepth += 1; if symbolDepth == 1 { currentSymbol = a["name"]; if let id = currentSymbol { symbols[id] = [:] } } else { supported = false }
        case "layer":
            if let id = currentSymbol { currentLayer = a["class"] ?? ""; symbolLayers[id,default:0] += 1; symbols[id]?["__class"] = currentLayer; if !["SimpleFill","SimpleLine","SimpleMarker"].contains(currentLayer) { supported = false } }
        case "prop", "Option":
            if let id = currentSymbol, let key = a["k"] ?? a["name"], let value = a["v"] ?? a["value"] { symbols[id]?[key] = value; if key == "active" && value == "true" { supported = false } }
        case "category":
            if a["render"] == "false" { supported = false }
            categories.append((a["value"] ?? "",a["label"] ?? a["value"] ?? "",a["symbol"] ?? ""))
        case "range":
            if let low = Double(a["lower"] ?? ""), let high = Double(a["upper"] ?? ""), low.isFinite, high.isFinite { ranges.append((low,high,a["label"] ?? "\(low) – \(high)",a["symbol"] ?? "")) }
        case "data_defined_properties": break
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "symbol" { symbolDepth -= 1; if symbolDepth == 0 { currentSymbol = nil } }
    }
}
