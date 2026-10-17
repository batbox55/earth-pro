import Foundation

/// Reads public shapefile bundles without executing data or extracting archive paths.
enum ShapefileService {
    static let inputLimit = 64 * 1_024 * 1_024
    static func read(_ url: URL) throws -> CustomDataResult {
        var files: [String: Data] = [:]
        let allowed = ["shp", "shx", "dbf", "prj", "cpg", "json", "qml"]
        if url.pathExtension.lowercased() == "zip" {
            let names = String(decoding: try unzip(["-Z1", url.path], limit: 256 * 1024), as: UTF8.self).split(separator: "\n").map(String.init)
            let shapes = names.filter { !$0.hasPrefix("__MACOSX/") && $0.lowercased().hasSuffix(".shp") }
            guard shapes.count == 1, let shape = shapes.first else { throw KMLError.invalid("Choose a ZIP containing exactly one shapefile dataset, or import each dataset's folder separately.") }
            let stem = String(shape.dropLast(4)).lowercased()
            for name in names where allowed.contains((name as NSString).pathExtension.lowercased()) && String(name.dropLast((name as NSString).pathExtension.count + 1)).lowercased() == stem {
                guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), name.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]\\")) == nil else { throw KMLError.invalid("Unsafe archive member name.") }
                let ext = (name as NSString).pathExtension.lowercased()
                guard files[ext] == nil else { throw KMLError.invalid("Duplicate shapefile sidecar in ZIP.") }
                files[ext] = try unzip(["-p", url.path, name], limit: inputLimit)
                guard files.values.reduce(0, { $0+$1.count }) <= inputLimit else { throw KMLError.invalid("Shapefile bundle exceeds the 64 MB import limit.") }
            }
        } else {
            let directory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true ? url : url.deletingLastPathComponent()
            let all = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            let shapes = url.pathExtension.lowercased() == "shp" ? [url] : all.filter { $0.pathExtension.lowercased() == "shp" }
            guard shapes.count == 1, let shape = shapes.first else { throw KMLError.invalid("Select a folder containing exactly one shapefile dataset.") }
            for file in all where file.deletingPathExtension().lastPathComponent.lowercased() == shape.deletingPathExtension().lastPathComponent.lowercased() && allowed.contains(file.pathExtension.lowercased()) {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? inputLimit+1) <= inputLimit else { throw KMLError.invalid("Shapefile bundle exceeds the 64 MB import limit.") }
                files[file.pathExtension.lowercased()] = try Data(contentsOf: file)
                guard files.values.reduce(0, { $0+$1.count }) <= inputLimit else { throw KMLError.invalid("Shapefile bundle exceeds the 64 MB import limit.") }
            }
        }
        guard let shp = files["shp"], let dbf = files["dbf"], let prj = files["prj"], let wkt = String(data: prj, encoding: .utf8) else {
            throw KMLError.invalid("A shapefile needs matching SHP, DBF and PRJ files. Select their containing folder or a ZIP so the sandbox can read the sidecars. Export to EPSG:4326 if PRJ is missing.")
        }
        let projection = try ShapefileProjection(wkt)
        let encodingText = files["cpg"].map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        let encoding: String.Encoding
        switch encodingText {
        case "UTF-8", "UTF8", "65001": encoding = .utf8
        case nil, "1252", "WINDOWS-1252", "CP1252": encoding = .windowsCP1252
        case "ISO-8859-1", "8859-1": encoding = .isoLatin1
        default: throw KMLError.invalid("Unsupported DBF encoding. Export with UTF-8 or Windows-1252 encoding.")
        }
        var renderer: VectorStyling?
        if let style = files["json"], let object = try? JSONSerialization.jsonObject(with:style) as? [String:Any] {
            renderer = VectorStyling.parse((object["drawingInfo"] as? [String:Any])?["renderer"] as? [String:Any] ?? object["renderer"] as? [String:Any] ?? object)
        }
        if let qml = files["qml"] { renderer = QGISStyleReader.decode(qml) ?? VectorStyling.parse(["type":"unsupportedQML"]) }
        var result = try decode(shp:shp,dbf:dbf,projection:projection,encoding:encoding,shx:files["shx"],requiredFields:renderer?.fields ?? [])
        renderer?.apply(&result)
        result.stylingNotice = (result.stylingNotice ?? "Generated styling") + " · " + projection.notice + " Z/M ordinates are not used for terrain placement."
        return result
    }
    private struct Bytes {
        let data: Data
        func check(_ offset: Int, _ size: Int) throws { guard offset >= 0, size >= 0, offset <= data.count, size <= data.count-offset else { throw KMLError.invalid("Truncated or invalid shapefile/DBF record.") } }
        func u32(_ o: Int, big: Bool = false) throws -> Int {
            try check(o,4)
            let bytes = (0..<4).map { Int(data[o+$0]) }
            return big ? bytes.reduce(0) { ($0<<8)|$1 } : bytes.reversed().reduce(0) { ($0<<8)|$1 }
        }
        func u16(_ o: Int) throws -> Int { try check(o,2); return Int(data[o]) | Int(data[o+1])<<8 }
        func double(_ o: Int) throws -> Double {
            try check(o,8); var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[o+i]) << (8*i) }
            let d = Double(bitPattern:v); guard d.isFinite else { throw CustomDataError.invalidGeometry }; return d
        }
    }
    static func decode(shp: Data, dbf: Data, projection: ShapefileProjection, encoding: String.Encoding = .utf8, shx: Data? = nil, requiredFields: [String] = []) throws -> CustomDataResult {
        guard shp.count <= inputLimit, dbf.count <= inputLimit else { throw KMLError.invalid("Shapefile bundle exceeds the 64 MB import limit.") }
        let s = Bytes(data:shp), d = Bytes(data:dbf)
        guard try s.u32(0,big:true) == 9994, try s.u32(28) == 1000, try s.u32(24,big:true)*2 == shp.count else { throw KMLError.invalid("Invalid shapefile header or declared size.") }
        let shapeType = try s.u32(32)
        let recordCount = try d.u32(4), headerSize = try d.u16(8), recordSize = try d.u16(10)
        guard headerSize >= 33, recordSize >= 1, recordCount <= 2_000_000 else { throw CustomDataError.invalidGeometry }
        try d.check(headerSize, recordCount*recordSize)
        struct Field { let name: String; let type: UInt8; let offset: Int; let size: Int }
        var fields: [Field] = [], cursor = 32, fieldOffset = 1
        while cursor < headerSize-1 && dbf[cursor] != 0x0d {
            try d.check(cursor,32)
            let name = String(decoding:dbf[cursor..<cursor+11].prefix { $0 != 0 }, as:UTF8.self)
            let size = Int(dbf[cursor+16])
            guard size > 0, fieldOffset+size <= recordSize, !name.isEmpty else { throw CustomDataError.invalidGeometry }
            fields.append(.init(name:name,type:dbf[cursor+11],offset:fieldOffset,size:size)); fieldOffset += size; cursor += 32
        }
        guard cursor < headerSize, dbf[cursor] == 0x0d else { throw CustomDataError.invalidGeometry }
        if let shx {
            let index = Bytes(data:shx)
            guard shx.count >= 100, (shx.count-100)%8 == 0, try index.u32(0,big:true) == 9994, try index.u32(24,big:true)*2 == shx.count else { throw KMLError.invalid("Invalid SHX index.") }
        }
        var features: [[String: Any]] = [], offset = 100, row = 0, vertices = 0, partial = false
        while offset < shp.count {
            try Task.checkCancellation()
            guard row < recordCount else { throw KMLError.invalid("SHP and DBF record counts do not match.") }
            let length = try s.u32(offset+4,big:true)*2, start = offset+8
            try s.check(start,length)
            guard length >= 4 else { throw CustomDataError.invalidGeometry }
            if let shx {
                let index = Bytes(data:shx)
                guard try index.u32(100+row*8,big:true)*2 == offset, try index.u32(104+row*8,big:true)*2 == length else { throw KMLError.invalid("SHX index does not match SHP records.") }
            }
            let attributeStart = headerSize+row*recordSize
            let deleted = dbf[attributeStart] == 0x2a
            var properties: [String: Any] = [:]
            for (fieldIndex,field) in fields.enumerated() where fieldIndex < 60 || requiredFields.contains(field.name) || VectorStyling.categoryFields.contains(field.name.lowercased()) {
                let bytes = dbf[(attributeStart+field.offset)..<(attributeStart+field.offset+field.size)]
                guard [UInt8(ascii:"C"), UInt8(ascii:"N"), UInt8(ascii:"F"), UInt8(ascii:"L"), UInt8(ascii:"D")].contains(field.type) else { continue }
                let value = String(data:bytes,encoding:encoding)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                properties[field.name] = String(value.prefix(500))
            }
            offset = start+length; row += 1
            let type = try s.u32(start)
            guard type == 0 || type == shapeType else { throw KMLError.invalid("SHP record type does not match its header.") }
            if deleted || type == 0 { continue }
            let end = start+length
            func coordinate(_ position: Int) throws -> [Double] {
                guard position+16 <= end else { throw CustomDataError.invalidGeometry }
                return try projection.point(x:s.double(position),y:s.double(position+8))
            }
            let geometry: [String: Any]
            if [1,11,21].contains(type) { geometry = ["type":"Point","coordinates":try coordinate(start+4)]; vertices += 1 }
            else if [8,18,28].contains(type) {
                let count = try s.u32(start+36)
                guard count > 0, count <= (end-start-40)/16 else { throw CustomDataError.invalidGeometry }
                if vertices+count > CustomDataService.vertexLimit { partial = true; continue }
                geometry = ["type":"MultiPoint","coordinates":try (0..<count).map { try coordinate(start+40+$0*16) }]; vertices += count
            } else if [3,5,13,15,23,25].contains(type) {
                let parts = try s.u32(start+36), count = try s.u32(start+40), base = start+44+parts*4
                guard parts > 0, parts <= count, base <= end, count <= (end-base)/16 else { throw CustomDataError.invalidGeometry }
                if vertices+count > CustomDataService.vertexLimit { partial = true; continue }
                var starts = try (0..<parts).map { try s.u32(start+44+$0*4) }
                guard starts.first == 0, zip(starts,starts.dropFirst()).allSatisfy({ $0 < $1 }), starts.last! < count else { throw CustomDataError.invalidGeometry }
                starts.append(count)
                let rings = try (0..<parts).map { part in try (starts[part]..<starts[part+1]).map { try coordinate(base+$0*16) } }
                if [5,15,25].contains(type) { geometry = ["type":"MultiPolygon","coordinates":try polygons(rings)] }
                else { geometry = ["type":"MultiLineString","coordinates":rings] }
                vertices += count
            } else { throw KMLError.invalid("Unsupported shapefile geometry type \(type). Multipatch meshes are not supported.") }
            features.append(["type":"Feature","id":row,"properties":properties,"geometry":geometry])
            if features.count >= CustomDataService.featureLimit { partial = offset < shp.count; break }
        }
        if offset == shp.count && row != recordCount { throw KMLError.invalid("SHP and DBF record counts do not match.") }
        var result = try CustomDataService.decodeGeoJSON(data: JSONSerialization.data(withJSONObject:["type":"FeatureCollection","features":features]),requiredFields:requiredFields)
        result.partial = result.partial || partial
        return result
    }
    /// Nesting, rather than input ring order, preserves holes and islands in multipart records.
    static func polygons(_ rings: [[[Double]]]) throws -> [[[[Double]]]] {
        guard rings.allSatisfy({ $0.count >= 4 && $0.first == $0.last }) else { throw CustomDataError.invalidGeometry }
        func area(_ r: [[Double]]) -> Double { abs(zip(r,r.dropFirst()).reduce(0) { $0 + $1.0[0]*$1.1[1]-$1.1[0]*$1.0[1] }) }
        func contains(_ r: [[Double]], _ p: [Double]) -> Bool {
            var inside = false
            for (a,b) in zip(r,r.dropFirst()) where (a[1] > p[1]) != (b[1] > p[1]) {
                if p[0] < (b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0] { inside.toggle() }
            }
            return inside
        }
        let sorted = rings.sorted { area($0) > area($1) }
        var result: [[[[Double]]]] = [], parents: [(ring: [[Double]], depth: Int, polygon: Int)] = []
        for ring in sorted {
            let parent = parents.last { contains($0.ring,ring[0]) }
            let depth = (parent?.depth ?? -1)+1
            let index: Int
            if depth%2 == 0 { index = result.count; result.append([ring]) }
            else { index = parent!.polygon; result[index].append(ring) }
            parents.append((ring,depth,index))
        }
        return result
    }
    private static func unzip(_ arguments: [String], limit: Int) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/unzip"); process.arguments = arguments.first == "-p" ? ["-P", ""] + arguments : arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount:64*1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard data.count+chunk.count <= limit else { throw KMLError.invalid("Shapefile bundle exceeds the 64 MB import limit.") }; data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw KMLError.invalid("Could not read shapefile ZIP.") }
        return data
    }
}
