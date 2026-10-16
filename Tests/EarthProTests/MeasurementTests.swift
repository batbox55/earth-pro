import XCTest
@testable import EarthPro

final class MeasurementTests: XCTestCase {
    func testDistanceConversions() {
        XCTAssertEqual(DistanceUnit.feet.value(meters: 0.3048), 1, accuracy: 1e-10)
        XCTAssertEqual(DistanceUnit.inches.value(meters: 0.0254), 1, accuracy: 1e-10)
        XCTAssertEqual(DistanceUnit.yards.value(meters: 0.9144), 1, accuracy: 1e-10)
        XCTAssertEqual(DistanceUnit.miles.value(meters: 1609.344), 1, accuracy: 1e-10)
        XCTAssertEqual(DistanceUnit.nauticalMiles.value(meters: 1852), 1, accuracy: 1e-10)
        XCTAssertEqual(DistanceUnit.millimeters.value(meters: 1), 1000)
        XCTAssertEqual(DistanceUnit.centimeters.value(meters: 1), 100)
        XCTAssertEqual(DistanceUnit.kilometers.value(meters: 1000), 1)
    }
    func testAutomaticUnitThresholdsAndFormatting() {
        XCTAssertEqual(DistanceUnit.automaticMetric.resolved(meters: 0), .meters)
        XCTAssertEqual(DistanceUnit.automaticMetric.resolved(meters: 0.001), .millimeters)
        XCTAssertEqual(DistanceUnit.automaticMetric.resolved(meters: 0.1), .centimeters)
        XCTAssertEqual(DistanceUnit.automaticMetric.resolved(meters: 999), .meters)
        XCTAssertEqual(DistanceUnit.automaticMetric.resolved(meters: 1000), .kilometers)
        XCTAssertEqual(DistanceUnit.automaticImperial.resolved(meters: 0.0254), .inches)
        XCTAssertEqual(DistanceUnit.automaticImperial.resolved(meters: 0.3048), .feet)
        XCTAssertEqual(DistanceUnit.automaticImperial.resolved(meters: 1609.344), .miles)
        XCTAssertEqual(AreaUnit.automaticMetric.resolved(squareMeters: 0), .squareMeters)
        XCTAssertEqual(AreaUnit.automaticMetric.resolved(squareMeters: 0.000001), .squareMillimeters)
        XCTAssertEqual(AreaUnit.automaticMetric.resolved(squareMeters: 0.01), .squareCentimeters)
        XCTAssertEqual(AreaUnit.automaticMetric.resolved(squareMeters: 1), .squareMeters)
        XCTAssertEqual(AreaUnit.automaticMetric.resolved(squareMeters: 10_000), .hectares)
        XCTAssertEqual(AreaUnit.automaticMetric.resolved(squareMeters: 1_000_000), .squareKilometers)
        XCTAssertEqual(AreaUnit.automaticImperial.resolved(squareMeters: 0.01), .squareInches)
        XCTAssertEqual(AreaUnit.automaticImperial.resolved(squareMeters: 1), .squareFeet)
        XCTAssertEqual(AreaUnit.automaticImperial.resolved(squareMeters: 4046.8564224), .acres)
        XCTAssertEqual(AreaUnit.automaticImperial.resolved(squareMeters: 2_589_988.110336), .squareMiles)
        XCTAssertEqual(MeasurementText.format(1, symbol: "m", decimals: -1), "1 m")
        XCTAssertEqual(MeasurementText.format(1e-9, symbol: "m", decimals: 9), "\(Double(1e-9).formatted(.number.precision(.fractionLength(9)))) m")
    }
    func testAreaConversions() {
        XCTAssertEqual(AreaUnit.squareMillimeters.value(squareMeters: 1), 1_000_000)
        XCTAssertEqual(AreaUnit.squareNauticalMiles.value(squareMeters: 1852 * 1852), 1)
        XCTAssertEqual(AreaUnit.acres.value(squareMeters: 4046.8564224), 1, accuracy: 1e-10)
        XCTAssertEqual(AreaUnit.hectares.value(squareMeters: 10_000), 1)
        XCTAssertEqual(AreaUnit.squareFeet.value(squareMeters: 0.09290304), 1, accuracy: 1e-10)
        XCTAssertEqual(AreaUnit.squareInches.value(squareMeters: 0.00064516), 1, accuracy: 1e-10)
        XCTAssertEqual(AreaUnit.squareYards.value(squareMeters: 0.83612736), 1, accuracy: 1e-10)
        XCTAssertEqual(AreaUnit.squareMiles.value(squareMeters: 2_589_988.110336), 1, accuracy: 1e-10)
        XCTAssertEqual(AreaUnit.squareCentimeters.value(squareMeters: 1), 10_000)
        XCTAssertEqual(AreaUnit.squareKilometers.value(squareMeters: 1_000_000), 1)
    }
    @MainActor func testIndependentUnitsPrecisionAndUnchangedGeometry() {
        let store = EarthStore(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.begin(.polygon)
        store.vertices = [.init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.001), .init(latitude: 0.001, longitude: 0)]
        let points = store.vertices, distance = store.drawingDistance, area = GeoMath.area(points)
        store.measurementDistanceUnit = .feet; store.measurementAreaUnit = .acres; store.measurementDistanceDecimals = 6; store.measurementAreaDecimals = 6
        XCTAssertTrue(store.formatMeasurementDistance(0.3048).hasSuffix(" ft"))
        XCTAssertEqual(store.formatMeasurementDistance(0.3048), MeasurementText.format(1, symbol: "ft", decimals: 6))
        XCTAssertEqual(store.formatMeasurementArea(4046.8564224), MeasurementText.format(1, symbol: "ac", decimals: 6))
        store.measurementAreaUnit = .hectares; store.measurementAreaDecimals = 0
        XCTAssertEqual(store.measurementDistanceUnit, .feet)
        XCTAssertEqual(store.measurementDistanceDecimals, 6)
        XCTAssertEqual(store.vertices, points)
        XCTAssertEqual(store.drawingDistance, distance)
        XCTAssertEqual(GeoMath.area(store.vertices), area)
        XCTAssertTrue(MeasurementText.format(0.0001, symbol: "km²", decimals: 2).hasPrefix("< "))
        XCTAssertFalse(MeasurementText.format(0, symbol: "m²", decimals: 2).hasPrefix("< "))
        XCTAssertEqual(MeasurementText.format(.nan, symbol: "m", decimals: 2), "—")
    }
}
