import XCTest
@testable import Longevity_Compass

final class LiveBarcodeStabilizerTests: XCTestCase {
    func testRequiresSeveralMatchingFramesBeforeDelivery() {
        var stabilizer = LiveBarcodeStabilizer(matchesRequired: 3)

        XCTAssertNil(stabilizer.observe("4006381333931"))
        XCTAssertNil(stabilizer.observe("4006381333931"))
        XCTAssertEqual(stabilizer.observe("4006381333931"), "4006381333931")
    }

    func testDoesNotRepeatUntilBarcodeLeavesFrame() {
        var stabilizer = LiveBarcodeStabilizer(
            matchesRequired: 2,
            missesRequiredToReset: 3
        )

        XCTAssertNil(stabilizer.observe("4006381333931"))
        XCTAssertEqual(stabilizer.observe("4006381333931"), "4006381333931")
        XCTAssertNil(stabilizer.observe("4006381333931"))
        XCTAssertNil(stabilizer.observe("4006381333931"))

        XCTAssertNil(stabilizer.observe(nil))
        XCTAssertNil(stabilizer.observe(nil))
        XCTAssertNil(stabilizer.observe(nil))

        XCTAssertNil(stabilizer.observe("4006381333931"))
        XCTAssertEqual(stabilizer.observe("4006381333931"), "4006381333931")
    }

    func testAlternatingCodesNeverBecomeStable() {
        var stabilizer = LiveBarcodeStabilizer(matchesRequired: 3)

        XCTAssertNil(stabilizer.observe("111"))
        XCTAssertNil(stabilizer.observe("222"))
        XCTAssertNil(stabilizer.observe("111"))
        XCTAssertNil(stabilizer.observe("222"))
    }
}
