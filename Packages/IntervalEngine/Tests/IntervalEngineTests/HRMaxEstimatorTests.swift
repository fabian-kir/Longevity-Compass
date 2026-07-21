import XCTest
@testable import IntervalEngine

final class HRMaxEstimatorTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 0)
    private func dob(yearsAgo years: Double) -> Date {
        now.addingTimeInterval(-years * 365.25 * 24 * 60 * 60)
    }

    func testTanakaFormula() {
        XCTAssertEqual(HRMaxEstimator.tanaka(age: 40), 180, accuracy: 0.001)   // 208 − 28
        XCTAssertEqual(HRMaxEstimator.tanaka(age: 30), 187, accuracy: 0.001)
    }

    func testObservedMaxWinsWhenHigher() {
        // 40yo → Tanaka 180; observed 192 is a personal ceiling and should win.
        let est = HRMaxEstimator.estimate(dateOfBirth: dob(yearsAgo: 40), now: now, observedMaxLast90d: 192)
        XCTAssertEqual(est!, 192, accuracy: 0.001)
    }

    func testFormulaWinsWhenObservedIsLower() {
        let est = HRMaxEstimator.estimate(dateOfBirth: dob(yearsAgo: 40), now: now, observedMaxLast90d: 150)
        XCTAssertEqual(est!, 180, accuracy: 0.001)
    }

    func testFormulaFloorWhenNoObserved() {
        let est = HRMaxEstimator.estimate(dateOfBirth: dob(yearsAgo: 40), now: now, observedMaxLast90d: nil)
        XCTAssertEqual(est!, 180, accuracy: 0.001)
    }

    func testObservedOnlyWhenNoDOB() {
        let est = HRMaxEstimator.estimate(dateOfBirth: nil, now: now, observedMaxLast90d: 178)
        XCTAssertEqual(est!, 178, accuracy: 0.001)
    }

    func testNilWhenNeitherInputAvailable() {
        XCTAssertNil(HRMaxEstimator.estimate(dateOfBirth: nil, now: now, observedMaxLast90d: nil))
    }
}
