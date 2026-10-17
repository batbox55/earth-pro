import Foundation

/// Publisher classification is resolved once during loading, never during camera updates.
struct VectorStyling {
    static let categoryFields = ["zone", "zoning", "zone_code", "zoning_code", "zoneclass", "fld_zone", "lottype", "landuse", "land_use", "class", "type", "category"]
    struct Rule {
        var label: String
        var style: VectorStyle
        var value: String?
        var minimum: Double?
        var maximum: Double?
    }
    var fields: [String]
    var delimiter: String
    var rules: [Rule]
    var fallback: VectorStyle?
    var fallbackLabel: String
    var supported: Bool
    var simplifiedPatterns = false

    static func arcGIS(_ data: Data) -> VectorStyling? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let drawing = object["drawingInfo"] as? [String: Any], let renderer = drawing["renderer"] as? [String: Any] else { return nil }
        return parse(renderer)
    }
    static func parse(_ renderer: [String: Any]) -> VectorStyling {
        let type = renderer["type"] as? String ?? ""
        var result = VectorStyling(fields: [], delimiter: renderer["fieldDelimiter"] as? String ?? ", ", rules: [], fallback: symbol(renderer["defaultSymbol"]), fallbackLabel: renderer["defaultLabel"] as? String ?? "Other values", supported: true)
        if !(renderer["visualVariables"] as? [Any] ?? []).isEmpty || !(renderer["valueExpression"] as? String ?? "").isEmpty { result.supported = false }
        switch type {
        case "simple":
            if let style = symbol(renderer["symbol"]) { result.rules = [.init(label: renderer["label"] as? String ?? "All features", style: style)] }
            else { result.supported = false }
        case "uniqueValue":
            result.fields = (1...3).compactMap { renderer["field\($0)"] as? String }.filter { !$0.isEmpty }
            guard !result.fields.isEmpty else { result.supported = false; return result }
            for info in renderer["uniqueValueInfos"] as? [[String: Any]] ?? [] {
                guard let style = symbol(info["symbol"]), let value = scalar(info["value"]) else { result.supported = false; continue }
                result.rules.append(.init(label: info["label"] as? String ?? value, style: style, value: value))
            }
        case "classBreaks":
            result.fields = [renderer["field"] as? String ?? ""]
            if let normalization = renderer["normalizationType"] as? String, normalization != "esriNormalizeByNothing" { result.supported = false; return result }
            var low = (renderer["minValue"] as? NSNumber)?.doubleValue ?? -Double.greatestFiniteMagnitude
            for info in renderer["classBreakInfos"] as? [[String: Any]] ?? [] {
                guard let high = (info["classMaxValue"] as? NSNumber)?.doubleValue, let style = symbol(info["symbol"]) else { result.supported = false; continue }
                result.rules.append(.init(label: info["label"] as? String ?? "\(low) – \(high)", style: style, minimum: (info["classMinValue"] as? Double) ?? low, maximum: high)); low = high
            }
        default: result.supported = false
        }
        if result.rules.count > 128 { result.rules = []; result.supported = false }
        let symbols = [renderer["symbol"], renderer["defaultSymbol"]] + (renderer["uniqueValueInfos"] as? [[String:Any]] ?? []).map { $0["symbol"] } + (renderer["classBreakInfos"] as? [[String:Any]] ?? []).map { $0["symbol"] }
        result.simplifiedPatterns = symbols.contains { raw in
            guard let symbol = raw as? [String:Any], symbol["type"] as? String == "esriSFS", let style = symbol["style"] as? String else { return false }
            return style != "esriSFSSolid" && style != "esriSFSNull"
        }
        return result
    }
    static func scalar(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        return (value as? NSNumber)?.stringValue
    }
    static func symbol(_ raw: Any?) -> VectorStyle? {
        guard let s = raw as? [String: Any], let type = s["type"] as? String, ["esriSFS", "esriSLS", "esriSMS"].contains(type) else { return nil }
        func color(_ raw: Any?) -> (String, Double)? {
            guard let numbers = raw as? [NSNumber], numbers.count >= 3 else { return nil }
            let v = numbers.map(\.doubleValue)
            guard v.allSatisfy(\.isFinite), v.allSatisfy({ (0...255).contains($0) }) else { return nil }
            return (String(format: "#%02X%02X%02X", Int(v[0]), Int(v[1]), Int(v[2])), v.count > 3 ? v[3] / 255 : 1)
        }
        let c = color(s["color"]) ?? ("#58A6DA", 1)
        let outline = s["outline"] as? [String: Any] ?? s
        let o = color(outline["color"]) ?? c
        let styleName = s["style"] as? String ?? ""
        // Polygon hatching uses the publisher color as a solid fill, disclosed in the legend notice.
        return VectorStyle(fill: c.0, stroke: o.0, fillOpacity: styleName == "esriSFSNull" || type == "esriSLS" ? 0 : c.1,
                           strokeOpacity: (outline["style"] as? String) == "esriSLSNull" ? 0 : o.1,
                           width: min(20, max(0, (outline["width"] as? Double ?? 1.5) * 1.333)), symbolKind: type == "esriSLS" ? .path : type == "esriSMS" ? .point : .polygon)
    }
    func apply(_ result: inout CustomDataResult) {
        guard supported, !rules.isEmpty else {
            result.stylingNotice = "Publisher renderer is unsupported; using generated colors."
            Self.generated(&result, resetStyles:true); return
        }
        if !result.features.isEmpty && fields.contains(where: { field in !result.features.contains(where: { $0.attributes?[field] != nil }) }) {
            result.stylingNotice = "Source classification attributes are unavailable; using generated colors."
            Self.generated(&result, resetStyles:true); return
        }
        for index in result.features.indices {
            let attributes = result.features[index].attributes ?? [:]
            let value = fields.map { attributes[$0] ?? "" }.joined(separator: delimiter)
            let matched = rules.first { rule in
                if let expected = rule.value { return value == expected }
                if let high = rule.maximum, let low = rule.minimum, let number = Double(value) { return number >= low && number <= high }
                return fields.isEmpty
            }
            let style = matched?.style ?? fallback ?? VectorStyle(fillOpacity: 0, strokeOpacity: 0, width: 0)
            result.features[index].vectorStyle = style; result.features[index].color = style.fill
        }
        result.legend = rules.reduce(into: []) { entries, rule in
            let entry = LayerLegendEntry(label:rule.label,style:rule.style)
            if !entries.contains(entry) { entries.append(entry) }
        }
        if let fallback { result.legend.append(.init(label: fallbackLabel, style: fallback)) }
        result.stylingNotice = simplifiedPatterns ? "Publisher colors and categories · hatch fills shown solid" : "Publisher styling"
        if !result.features.isEmpty, result.features.allSatisfy({ $0.vectorStyle?.hasVisibleGeometry != true }) {
            result.stylingNotice = "Source styling is fully transparent; using visible generated colors."
            Self.generated(&result,resetStyles:true)
        }
    }
    static func generated(_ result: inout CustomDataResult, resetStyles: Bool = false) {
        if resetStyles { for i in result.features.indices { result.features[i].vectorStyle = nil } }
        let fields = categoryFields
        let keys = result.features.first?.attributes?.keys.sorted() ?? []
        let field = fields.compactMap { candidate in keys.first { $0.lowercased() == candidate } }.first
        let palette = ["#4E9CD5", "#EDAF49", "#64B883", "#BA8DD0", "#E27D78", "#62BEC5", "#B2B85E", "#9B9CE0"]
        let suppliedStyles = result.features.contains { $0.vectorStyle != nil }
        var entries: [LayerLegendEntry] = [], colors: [String: VectorStyle] = [:]
        for i in result.features.indices {
            if let style = result.features[i].vectorStyle {
                let label = result.features[i].attributes?["title"] ?? "Feature style"
                if !entries.contains(where: { $0.style == style }) { entries.append(.init(label: label, style: style)) }; continue
            }
            let label = field.flatMap { result.features[i].attributes?[$0] } ?? "All features"
            let bounded = colors[label] != nil || colors.count < 31 ? label : "Other values"
            var style = colors[bounded] ?? VectorStyle(fill: palette[colors.count % palette.count], stroke: palette[colors.count % palette.count])
            style.symbolKind = result.features[i].kind
            if colors[bounded] == nil { colors[bounded] = style }
            if !entries.contains(where: { $0.label == bounded && $0.style == style }) { entries.append(.init(label:bounded,style:style)) }
            result.features[i].vectorStyle = style; result.features[i].color = style.fill
        }
        result.legend = Array(entries.prefix(128))
        if result.stylingNotice == nil { result.stylingNotice = suppliedStyles ? "Embedded feature styles · generated colors for unstyled features" : field.map { "Generated colors by \($0) · no publisher style supplied" } ?? "Generated style · no publisher style supplied" }
    }
    static func simpleStyle(_ properties: [String: Any]) -> VectorStyle? {
        guard properties["fill"] != nil || properties["stroke"] != nil || properties["marker-color"] != nil else { return nil }
        var style = VectorStyle()
        style.fill = properties["fill"] as? String ?? properties["marker-color"] as? String ?? style.fill
        style.stroke = properties["stroke"] as? String ?? style.fill
        style.fillOpacity = properties["fill-opacity"] as? Double ?? style.fillOpacity
        style.strokeOpacity = properties["stroke-opacity"] as? Double ?? style.strokeOpacity
        style.width = properties["stroke-width"] as? Double ?? style.width
        return style.isValid ? style : nil
    }
}
