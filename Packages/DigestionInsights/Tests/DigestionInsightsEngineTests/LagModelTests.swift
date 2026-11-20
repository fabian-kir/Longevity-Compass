import XCTest
@testable import DigestionInsightsEngine

/// Lag basis, penalty, observation rule and cross-basis on cases small enough
/// to check by hand (B9 design).
final class LagModelTests: XCTestCase {

    let lagBasis = BSplineBasis(lower: 0, upper: 96, interiorKnots: [3, 8, 24, 48])

    /// Plain recursive Cox–de Boor, independent of the production algorithm.
    private func naiveBasis(_ i: Int, _ p: Int, _ x: Double, _ t: [Double]) -> Double {
        if p == 0 {
            if t[i] <= x && x < t[i + 1] { return 1 }
            // Close the last non-empty interval at the upper boundary.
            if x == t.last!, t[i] < t[i + 1], t[i + 1] == t.last! { return 1 }
            return 0
        }
        var value = 0.0
        if t[i + p] > t[i] { value += (x - t[i]) / (t[i + p] - t[i]) * naiveBasis(i, p - 1, x, t) }
        if t[i + p + 1] > t[i + 1] { value += (t[i + p + 1] - x) / (t[i + p + 1] - t[i + 1]) * naiveBasis(i + 1, p - 1, x, t) }
        return value
    }

    func testLagBasisShapeAndPartitionOfUnity() {
        XCTAssertEqual(lagBasis.count, 8, "B9: K = 8")
        for step in 0...960 {
            let x = Double(step) / 10
            let values = lagBasis.evaluate(at: x)
            XCTAssertEqual(values.reduce(0, +), 1, accuracy: 1e-12, "partition of unity at \(x)")
            XCTAssertTrue(values.allSatisfy { $0 >= -1e-15 })
            for k in 0..<8 {
                XCTAssertEqual(values[k], naiveBasis(k, 3, x, lagBasis.knots), accuracy: 1e-12, "B_\(k)(\(x))")
            }
        }
        XCTAssertEqual(lagBasis.evaluate(at: 0), [1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(lagBasis.evaluate(at: 96), [0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(lagBasis.evaluate(at: 96.5), [Double](repeating: 0, count: 8))
        XCTAssertEqual(lagBasis.evaluate(at: -0.1), [Double](repeating: 0, count: 8))
    }

    func testPenaltyAnnihilatesLinearCoefficients() {
        let k = 8
        let p = BSplineBasis.secondDifferencePenalty(size: k)
        for vector in [[Double](repeating: 1, count: k), (0..<k).map(Double.init)] {
            for row in 0..<k {
                let value = (0..<k).reduce(0) { $0 + p[row * k + $1] * vector[$1] }
                XCTAssertEqual(value, 0, accuracy: 1e-12)
            }
        }
    }

    func testPriorFactorReproducesCovariance() {
        // C Cᵀ (ωP + diag κ) = I.
        let k = 8
        let ridge = (0..<k).map { 1 + Double($0) }
        let c = BSplineBasis.priorFactor(size: k, ridge: ridge, smoothing: 0.7)
        let p = BSplineBasis.secondDifferencePenalty(size: k)
        for i in 0..<k {
            for j in 0..<k {
                var value = 0.0
                for m in 0..<k {
                    let covariance = (0..<k).reduce(0) { $0 + c[i * k + $1] * c[m * k + $1] }
                    let precision = 0.7 * p[m * k + j] + (m == j ? ridge[m] : 0)
                    value += covariance * precision
                }
                XCTAssertEqual(value, i == j ? 1 : 0, accuracy: 1e-10)
            }
            for j in (i + 1)..<k { XCTAssertEqual(c[i * k + j], 0, "lower triangular") }
        }
    }

    private func input(
        exposures: [ExposureEvent] = [],
        symptoms: [SymptomEvent] = [],
        windows: [ObservationWindow],
        kinds: [String] = ["pain", "gas"]
    ) -> AnalysisInput {
        AnalysisInput(exposures: exposures, symptoms: symptoms, windows: windows, symptomKinds: kinds, config: fastConfig())
    }

    func testObservationHoursFollowHourCentres() {
        let day = LagData(input: input(windows: [ObservationWindow(start: day0, end: hoursAfterDay0(24))]))
        XCTAssertEqual(day.hours.count, 24)
        XCTAssertEqual(day.hours.first, absoluteHour(day0.timeIntervalSince1970))
        // [00:20, 01:40): centres 00:30 and 01:30 inside.
        let partial = LagData(input: input(windows: [ObservationWindow(start: hoursAfterDay0(1.0 / 3), end: hoursAfterDay0(5.0 / 3))]))
        XCTAssertEqual(partial.hours.count, 2)
        // Overlapping windows count each hour once; empty windows ignored.
        let union = LagData(input: input(windows: [
            ObservationWindow(start: day0, end: hoursAfterDay0(10)),
            ObservationWindow(start: hoursAfterDay0(5), end: hoursAfterDay0(15)),
            ObservationWindow(start: hoursAfterDay0(30), end: hoursAfterDay0(30)),
        ]))
        XCTAssertEqual(union.hours.count, 15)
    }

    func testCrossBasisHandCases() {
        let firstHour = absoluteHour(day0.timeIntervalSince1970)
        // Exposure exactly at the centre of hour 10 (lag 0 there), value 0.5,
        // and a second exposure 2 h later, value 1.
        let data = LagData(input: AnalysisInput(
            exposures: (0..<5).map { ExposureEvent(featureID: "f", time: hoursAfterDay0(10.5 + 200 * Double($0)), value: 0.5) }
                + [ExposureEvent(featureID: "f", time: hoursAfterDay0(12.5), value: 1)],
            symptoms: [],
            windows: [ObservationWindow(start: day0, end: hoursAfterDay0(24 * 50))],
            symptomKinds: ["pain"],
            config: fastConfig()
        ))
        XCTAssertEqual(data.modelFeatures, ["f"])
        func row(_ hoursAfterStart: Int) -> [Double] {
            let r = data.rowOfHour[firstHour + hoursAfterStart]!
            return Array(data.crossBasis[(r * 8)..<(r * 8 + 8)])
        }
        XCTAssertEqual(row(9), [Double](repeating: 0, count: 8), "before exposure")
        XCTAssertEqual(row(10), lagBasis.evaluate(at: 0).map { 0.5 * $0 })
        XCTAssertEqual(row(11), lagBasis.evaluate(at: 1).map { 0.5 * $0 })
        let expected13 = zip(lagBasis.evaluate(at: 3), lagBasis.evaluate(at: 1)).map { 0.5 * $0 + $1 }
        for (a, b) in zip(row(13), expected13) { XCTAssertEqual(a, b, accuracy: 1e-15) }
        // Lag 95 still counts, lag 96 does not.
        let r105 = row(105)
        let expected105 = zip(lagBasis.evaluate(at: 95), lagBasis.evaluate(at: 93)).map { 0.5 * $0 + $1 }
        for (a, b) in zip(r105, expected105) { XCTAssertEqual(a, b, accuracy: 1e-15) }
        let r106 = row(106)
        for (a, b) in zip(r106, lagBasis.evaluate(at: 94)) { XCTAssertEqual(a, b, accuracy: 1e-15) }
        XCTAssertEqual(row(109), [Double](repeating: 0, count: 8), "both exposures past 96 h")
    }

    func testHistoryExposureFeedsEarlyRowsButNotExposureCount() {
        // Six exposures 10 h before the window opens (B3: history only) and
        // five inside it.
        let history = (0..<6).map { ExposureEvent(featureID: "f", time: hoursAfterDay0(-10 - Double($0) * 0.01), value: 1) }
        let inside = (0..<5).map { ExposureEvent(featureID: "f", time: hoursAfterDay0(30 + 24 * Double($0)), value: 1) }
        let data = LagData(input: input(exposures: history + inside, windows: [ObservationWindow(start: day0, end: hoursAfterDay0(24 * 10))]))
        XCTAssertEqual(data.exposureCount["f"], 5)
        let firstRow = Array(data.crossBasis[0..<8])
        XCTAssertGreaterThan(firstRow.reduce(0, +), 5.9, "history exposures contribute at lag ~10 h")
    }

    func testOutcomesDropUnobservedAndUnknownSymptoms() {
        let symptoms = [
            SymptomEvent(kind: "pain", onset: hoursAfterDay0(1.2), levelRank: 0, isTopLevel: false),
            SymptomEvent(kind: "pain", onset: hoursAfterDay0(1.7), levelRank: 1, isTopLevel: true),
            SymptomEvent(kind: "gas", onset: hoursAfterDay0(3.1), levelRank: 0, isTopLevel: true),
            SymptomEvent(kind: "gas", onset: hoursAfterDay0(30), levelRank: 0, isTopLevel: true),     // outside window
            SymptomEvent(kind: "nausea", onset: hoursAfterDay0(2), levelRank: 0, isTopLevel: true),   // unknown kind
        ]
        let data = LagData(input: input(symptoms: symptoms, windows: [ObservationWindow(start: day0, end: hoursAfterDay0(24))]))
        XCTAssertEqual(data.observedSymptoms.count, 3)
        XCTAssertEqual(data.counts[1 * 2 + 0], 2, "two pain onsets in hour 1")
        XCTAssertEqual(data.counts[3 * 2 + 1], 1, "gas in hour 3")
        XCTAssertEqual(data.counts.reduce(0, +), 3)
    }

    func testSymptomsAfterAndObservedPairs() {
        let exposures = [
            ExposureEvent(featureID: "f", time: hoursAfterDay0(10), value: 1),
            ExposureEvent(featureID: "f", time: hoursAfterDay0(12), value: 0.5),
        ]
        let symptoms = [
            SymptomEvent(kind: "pain", onset: hoursAfterDay0(9), levelRank: 0, isTopLevel: false),    // before both
            SymptomEvent(kind: "pain", onset: hoursAfterDay0(15.5), levelRank: 0, isTopLevel: false), // lags 5.5 and 3.5
            SymptomEvent(kind: "gas", onset: hoursAfterDay0(107), levelRank: 0, isTopLevel: false),   // lag 97 and 95
        ]
        let data = LagData(input: input(exposures: exposures, symptoms: symptoms, windows: [ObservationWindow(start: day0, end: hoursAfterDay0(24 * 6))]))
        XCTAssertEqual(data.symptomsAfterCount["f"], 2)
        let pairs = data.observedPairs(feature: "f")
        XCTAssertEqual(pairs[5], 1)
        XCTAssertEqual(pairs[3], 1)
        XCTAssertEqual(pairs[95], 1)
        XCTAssertEqual(pairs.reduce(0, +), 3)
    }

    func testConfoundingFindsFoodsEatenTogether() {
        var exposures: [ExposureEvent] = []
        var rng = Xoshiro256StarStar(seed: 1)
        for day in 0..<30 {
            let time = hoursAfterDay0(Double(day) * 24 + 12)
            if rng.uniform() < 0.5 {
                exposures.append(ExposureEvent(featureID: "garlic", time: time, value: 1))
                exposures.append(ExposureEvent(featureID: "onion", time: time, value: 0.85))
            }
            if rng.uniform() < 0.5 {
                exposures.append(ExposureEvent(featureID: "rice", time: time.addingTimeInterval(7 * 3600), value: 1))
            }
        }
        let data = LagData(input: input(exposures: exposures, windows: [ObservationWindow(start: day0, end: hoursAfterDay0(24 * 30))]))
        let confounded = data.confounding(threshold: 0.9, windows: [ObservationWindow(start: day0, end: hoursAfterDay0(24 * 30))])
        XCTAssertEqual(confounded["garlic"], ["onion"])
        XCTAssertEqual(confounded["onion"], ["garlic"])
        XCTAssertNil(confounded["rice"])
    }
}
