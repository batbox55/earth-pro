import Foundation

/// WKT1/ESRI projection definitions used by common municipal shapefiles.
/// Unsupported datums/methods are rejected instead of guessing coordinates.
struct ShapefileProjection {
    let method: String
    let parameters: [String: Double]
    let a: Double
    let e: Double
    let unit: Double
    let notice: String
    static func normalized(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    init(_ wkt: String) throws {
        func matches(_ pattern: String) -> [[String]] {
            guard let r = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
            return r.matches(in: wkt, range: NSRange(wkt.startIndex..., in: wkt)).map { m in
                (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: wkt).map { String(wkt[$0]) } ?? "" }
            }
        }
        let lower = wkt.lowercased()
        let datum = Self.normalized(matches("(?:DATUM|ENSEMBLE)\\s*\\[\\s*\"([^\"]+)\"").first?.first ?? "")
        let datums = ["dwgs1984","wgs1984","wgs84","worldgeodeticsystem1984","dnorthamerican1983","northamerican1983","northamericandatum1983","nad83","dnad1983","etrs89","detrs1989","europeanterrestrialreferencesystem1989"]
        guard datums.contains(where: { datum.hasPrefix($0) }) else {
            throw KMLError.invalid("Unsupported or missing shapefile datum. Export as WGS84 / EPSG:4326; NAD27 and grid-based datum transformations are not supported.")
        }
        let spheroid = matches("(?:SPHEROID|ELLIPSOID)\\s*\\[\\s*\"[^\"]*\"\\s*,\\s*([0-9.eE+\\-]+)\\s*,\\s*([0-9.eE+\\-]+)").first
        a = spheroid.flatMap { Double($0[0]) } ?? 6378137
        let invF = spheroid.flatMap { Double($0[1]) } ?? 298.257223563
        let f = invF == 0 ? 0 : 1 / invF
        e = sqrt(f * (2 - f))
        guard a.isFinite, a > 6_000_000, a < 7_000_000, e.isFinite, e < 0.1 else { throw CustomDataError.invalidGeometry }
        let projected = lower.range(of: "proj(?:cs|crs)\\s*\\[", options: .regularExpression) != nil
        let rawMethod = matches("(?:PROJECTION|METHOD)\\s*\\[\\s*\"([^\"]+)\"").first?.first ?? ""
        method = projected ? Self.normalized(rawMethod) : "geographic"
        let allowed = ["geographic", "transversemercator", "lambertconformalconic", "lambertconformalconic2sp", "lambertconicconformal2sp", "mercator", "mercator1sp", "mercatorvarianta", "popularvisualisationpseudomercator", "mercatorauxiliarysphere", "albers", "albersconicequalarea"]
        guard allowed.contains(method) else { throw KMLError.invalid("Unsupported projection \(rawMethod). Reproject the file to EPSG:4326 before importing.") }
        var p: [String: Double] = [:]
        for pair in matches("PARAMETER\\s*\\[\\s*\"([^\"]+)\"\\s*,\\s*([0-9.eE+\\-]+)") {
            guard let value = Double(pair[1]), value.isFinite else { throw CustomDataError.invalidGeometry }
            p[Self.normalized(pair[0])] = value
        }
        parameters = p
        let units = matches("(?:UNIT|LENGTHUNIT)\\s*\\[\\s*\"([^\"]+)\"\\s*,\\s*([0-9.eE+\\-]+)")
        unit = projected ? units.last.flatMap { Double($0[1]) } ?? 1 : 1
        guard unit.isFinite, unit > 0, unit <= 2000 else { throw CustomDataError.invalidGeometry }
        notice = lower.contains("1983") || lower.contains("nad83") || lower.contains("etrs") ? "NAD83/ETRS89 datum approximated as WGS84; not survey-grade." : "Coordinates converted from the supplied PRJ to WGS84."
        if method == "geographic" {
            let angular = matches("(?:UNIT|ANGLEUNIT)\\s*\\[\\s*\"([^\"]+)\"\\s*,\\s*([0-9.eE+\\-]+)").first
            guard angular == nil || abs((Double(angular![1]) ?? 0) - .pi / 180) < 1e-10 else { throw KMLError.invalid("Geographic shapefiles must use degrees.") }
        }
        // Non-Greenwich prime meridians require an additional transformation.
        if let meridian = matches("PRIMEM\\s*\\[\\s*\"[^\"]*\"\\s*,\\s*([0-9.eE+\\-]+)").first?.first, let v = Double(meridian), v != 0 { throw CustomDataError.invalidGeometry }
    }
    func parameter(_ names: [String], _ fallback: Double = 0) -> Double { names.compactMap { parameters[Self.normalized($0)] }.first ?? fallback }
    func point(x: Double, y: Double) throws -> [Double] {
        guard x.isFinite, y.isFinite else { throw CustomDataError.invalidGeometry }
        if method == "geographic" {
            guard abs(x) <= 180, abs(y) <= 90 else { throw CustomDataError.invalidGeometry }
            return [x, y]
        }
        let rad = Double.pi / 180
        let lon0 = parameter(["central_meridian", "longitude_of_origin", "longitude_of_natural_origin", "longitude_of_false_origin"]) * rad
        let lat0 = parameter(["latitude_of_origin", "latitude_of_natural_origin", "latitude_of_false_origin"]) * rad
        let xx = (x - parameter(["false_easting", "easting_at_false_origin"])) * unit
        let yy = (y - parameter(["false_northing", "northing_at_false_origin"])) * unit
        var k = parameter(["scale_factor", "scale_factor_at_natural_origin"], 1)
        if method.contains("mercator"), method != "transversemercator", parameters["scalefactor"] == nil, parameters["scalefactoratnaturalorigin"] == nil, let standard = parameters["standardparallel1"] {
            let p = standard * rad; k = cos(p) / sqrt(1-e*e*pow(sin(p),2))
        }
        guard k > 0 else { throw CustomDataError.invalidGeometry }
        func m(_ phi: Double) -> Double { cos(phi) / sqrt(1 - e * e * pow(sin(phi), 2)) }
        func t(_ phi: Double) -> Double { tan(.pi / 4 - phi / 2) / pow((1 - e * sin(phi)) / (1 + e * sin(phi)), e / 2) }
        func latitude(_ ts: Double) -> Double {
            var phi = .pi / 2 - 2 * atan(ts)
            for _ in 0..<15 { phi = .pi / 2 - 2 * atan(ts * pow((1 - e * sin(phi)) / (1 + e * sin(phi)), e / 2)) }
            return phi
        }
        let phi: Double, lambda: Double
        if method == "transversemercator" {
            let e2 = e * e, ep = e2 / (1 - e2)
            func meridional(_ p: Double) -> Double { a * ((1 - e2 / 4 - 3 * pow(e2, 2) / 64 - 5 * pow(e2, 3) / 256) * p - (3 * e2 / 8 + 3 * pow(e2, 2) / 32 + 45 * pow(e2, 3) / 1024) * sin(2*p) + (15 * pow(e2, 2) / 256 + 45 * pow(e2, 3) / 1024) * sin(4*p) - 35 * pow(e2, 3) / 3072 * sin(6*p)) }
            let mu = (meridional(lat0) + yy / k) / (a * (1 - e2 / 4 - 3 * pow(e2,2) / 64 - 5 * pow(e2,3) / 256))
            let e1 = (1 - sqrt(1 - e2)) / (1 + sqrt(1 - e2))
            let p = mu + (3*e1/2 - 27*pow(e1,3)/32)*sin(2*mu) + (21*pow(e1,2)/16 - 55*pow(e1,4)/32)*sin(4*mu) + 151*pow(e1,3)/96*sin(6*mu) + 1097*pow(e1,4)/512*sin(8*mu)
            let n = a / sqrt(1 - e2 * pow(sin(p), 2)), r = a * (1-e2) / pow(1-e2*pow(sin(p),2), 1.5)
            let tt = pow(tan(p),2), c = ep * pow(cos(p),2), d = xx / (n*k)
            guard abs(d) < 0.1 else { throw KMLError.invalid("Coordinates fall outside the supported Transverse Mercator zone.") }
            phi = p - n*tan(p)/r * (d*d/2 - (5+3*tt+10*c-4*c*c-9*ep)*pow(d,4)/24 + (61+90*tt+298*c+45*tt*tt-252*ep-3*c*c)*pow(d,6)/720)
            lambda = lon0 + (d - (1+2*tt+c)*pow(d,3)/6 + (5-2*c+28*tt-3*c*c+8*ep+24*tt*tt)*pow(d,5)/120) / cos(p)
        } else if method.contains("lambert") {
            let p1 = parameter(["standard_parallel_1", "latitude_of_1st_standard_parallel"], lat0 / rad) * rad
            let p2 = parameter(["standard_parallel_2", "latitude_of_2nd_standard_parallel"], p1 / rad) * rad
            let n = abs(p1-p2) < 1e-12 ? sin(p1) : log(m(p1)/m(p2)) / log(t(p1)/t(p2))
            guard n.isFinite, abs(n) > 1e-12 else { throw CustomDataError.invalidGeometry }
            let f = m(p1) / (n * pow(t(p1), n)), rho0 = a*f*pow(t(lat0),n)
            let sign = n < 0 ? -1.0 : 1.0, rho = sign * hypot(xx, rho0-yy)
            phi = rho == 0 ? sign * .pi / 2 : latitude(pow(rho/(a*f),1/n))
            lambda = lon0 + atan2(sign*xx, sign*(rho0-yy))/n
        } else if method.contains("albers") {
            func q(_ p: Double) -> Double {
                let s = sin(p)
                return e < 1e-12 ? 2*s : (1-e*e) * (s/(1-e*e*s*s) - log((1-e*s)/(1+e*s))/(2*e))
            }
            let p1 = parameter(["standard_parallel_1", "latitude_of_1st_standard_parallel"]) * rad
            let p2 = parameter(["standard_parallel_2", "latitude_of_2nd_standard_parallel"]) * rad
            let n = abs(p1-p2) < 1e-12 ? sin(p1) : (pow(m(p1),2)-pow(m(p2),2))/(q(p2)-q(p1))
            guard abs(n) > 1e-12 else { throw CustomDataError.invalidGeometry }
            let c = pow(m(p1),2)+n*q(p1), rho0 = a*sqrt(c-n*q(lat0))/n
            let sign = n < 0 ? -1.0 : 1.0, rho = sign*hypot(xx,rho0-yy), target = (c-pow(rho*n/a,2))/n
            var low = -Double.pi/2, high = Double.pi/2
            for _ in 0..<50 { let mid = (low+high)/2; if q(mid) < target { low = mid } else { high = mid } }
            guard abs(target) <= q(.pi/2)+1e-9 else { throw CustomDataError.invalidGeometry }
            phi = (low+high)/2; lambda = lon0+atan2(sign*xx,sign*(rho0-yy))/n
        } else {
            let sphere = method.contains("pseudo") || method.contains("auxiliary")
            phi = sphere ? atan(sinh(yy/(a*k))) : latitude(exp(-yy/(a*k)))
            lambda = lon0+xx/(a*k)
        }
        let lat = phi/rad, lon = lambda/rad
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180.001 else { throw CustomDataError.invalidGeometry }
        return [GeoMath.normalizedLongitude(lon), lat]
    }
}
