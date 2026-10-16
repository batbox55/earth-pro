import Foundation

enum DistanceUnit: String, CaseIterable {
    case automaticMetric, automaticImperial, millimeters, centimeters, meters, kilometers, inches, feet, yards, miles, nauticalMiles
    var title: String {
        switch self {
        case .automaticMetric: "Automatic metric"
        case .automaticImperial: "Automatic imperial"
        case .millimeters: "Millimeters (mm)"
        case .centimeters: "Centimeters (cm)"
        case .meters: "Meters (m)"
        case .kilometers: "Kilometers (km)"
        case .inches: "Inches (in)"
        case .feet: "Feet (ft)"
        case .yards: "Yards (yd)"
        case .miles: "Miles (mi)"
        case .nauticalMiles: "Nautical miles (nmi)"
        }
    }
    var symbol: String {
        switch self {
        case .automaticMetric, .automaticImperial: ""
        case .millimeters: "mm"; case .centimeters: "cm"; case .meters: "m"; case .kilometers: "km"
        case .inches: "in"; case .feet: "ft"; case .yards: "yd"; case .miles: "mi"; case .nauticalMiles: "nmi"
        }
    }
    var metersPerUnit: Double {
        switch self {
        case .automaticMetric, .automaticImperial: 1
        case .millimeters: 0.001; case .centimeters: 0.01; case .meters: 1; case .kilometers: 1000
        case .inches: 0.0254; case .feet: 0.3048; case .yards: 0.9144; case .miles: 1609.344; case .nauticalMiles: 1852
        }
    }
    func resolved(meters: Double) -> DistanceUnit {
        let magnitude = abs(meters)
        switch self {
        case .automaticMetric:
            if magnitude == 0 { return .meters }
            return magnitude < 0.01 ? .millimeters : magnitude < 1 ? .centimeters : magnitude < 1000 ? .meters : .kilometers
        case .automaticImperial:
            if magnitude == 0 { return .feet }
            return magnitude < 0.3048 ? .inches : magnitude < 1609.344 ? .feet : .miles
        default: return self
        }
    }
    func value(meters: Double) -> Double { meters / resolved(meters: meters).metersPerUnit }
}

enum AreaUnit: String, CaseIterable {
    case automaticMetric, automaticImperial, squareMillimeters, squareCentimeters, squareMeters, squareKilometers, squareInches, squareFeet, squareYards, squareMiles, squareNauticalMiles, acres, hectares
    var title: String {
        switch self {
        case .automaticMetric: "Automatic metric"
        case .automaticImperial: "Automatic imperial"
        case .squareMillimeters: "Square millimeters (mm²)"
        case .squareNauticalMiles: "Square nautical miles (nmi²)"
        case .squareCentimeters: "Square centimeters (cm²)"
        case .squareMeters: "Square meters (m²)"
        case .squareKilometers: "Square kilometers (km²)"
        case .squareInches: "Square inches (in²)"
        case .squareFeet: "Square feet (ft²)"
        case .squareYards: "Square yards (yd²)"
        case .squareMiles: "Square miles (mi²)"
        case .acres: "Acres (ac)"
        case .hectares: "Hectares (ha)"
        }
    }
    var symbol: String {
        switch self {
        case .automaticMetric, .automaticImperial: ""
        case .squareMillimeters: "mm²"; case .squareNauticalMiles: "nmi²"
        case .squareCentimeters: "cm²"; case .squareMeters: "m²"; case .squareKilometers: "km²"
        case .squareInches: "in²"; case .squareFeet: "ft²"; case .squareYards: "yd²"; case .squareMiles: "mi²"
        case .acres: "ac"; case .hectares: "ha"
        }
    }
    var squareMetersPerUnit: Double {
        switch self {
        case .automaticMetric, .automaticImperial: 1
        case .squareMillimeters: 0.000001; case .squareNauticalMiles: 3_429_904
        case .squareCentimeters: 0.0001; case .squareMeters: 1; case .squareKilometers: 1_000_000
        case .squareInches: 0.00064516; case .squareFeet: 0.09290304; case .squareYards: 0.83612736
        case .squareMiles: 2_589_988.110336; case .acres: 4046.8564224; case .hectares: 10_000
        }
    }
    func resolved(squareMeters: Double) -> AreaUnit {
        let magnitude = abs(squareMeters)
        switch self {
        case .automaticMetric:
            if magnitude == 0 { return .squareMeters }
            if magnitude < 0.0001 { return .squareMillimeters }
            if magnitude < 1 { return .squareCentimeters }
            return magnitude < 10_000 ? .squareMeters : magnitude < 1_000_000 ? .hectares : .squareKilometers
        case .automaticImperial:
            if magnitude == 0 { return .squareFeet }
            if magnitude < 0.09290304 { return .squareInches }
            return magnitude < 4046.8564224 ? .squareFeet : magnitude < 2_589_988.110336 ? .acres : .squareMiles
        default: return self
        }
    }
    func value(squareMeters: Double) -> Double { squareMeters / resolved(squareMeters: squareMeters).squareMetersPerUnit }
}

enum MeasurementText {
    static func format(_ value: Double, symbol: String, decimals: Int) -> String {
        guard value.isFinite else { return "—" }
        if decimals == -1 {
            return "\(value.formatted(.number.precision(.significantDigits(1...6)))) \(symbol)"
        }
        let precision = max(0, min(9, decimals))
        let number = value.formatted(.number.precision(.fractionLength(precision)))
        // Avoid showing a tiny, nonzero shape as a zero-sized measurement.
        if value > 0 && value < 0.5 * pow(10, -Double(precision)) {
            let threshold = pow(10, -Double(precision)).formatted(.number.precision(.fractionLength(precision)))
            return "< \(threshold) \(symbol)"
        }
        return "\(number) \(symbol)"
    }
}
