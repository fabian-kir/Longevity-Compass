import XCTest
@testable import IntervalEngine

final class FailoverTests: XCTestCase {

    func testMirrorPromotesAfterTimeout() {
        let c = FailoverController(role: .mirror, referenceStart: t0, promotionTimeout: 4.5)
        XCTAssertFalse(c.evaluate(at: at(4)))   // within window
        XCTAssertFalse(c.evaluate(at: at(4.5))) // exactly at threshold (needs to exceed)
        XCTAssertTrue(c.evaluate(at: at(4.6)))  // exceeded → promote
        XCTAssertEqual(c.role, .primary)
    }

    func testLiveTicksKeepMirrorFromPromoting() {
        let c = FailoverController(role: .mirror, referenceStart: t0, promotionTimeout: 4.5)
        c.receivedPrimaryTick(at: at(3))
        XCTAssertFalse(c.evaluate(at: at(6)))   // 3s since last tick
        c.receivedPrimaryTick(at: at(6))
        XCTAssertFalse(c.evaluate(at: at(9)))   // 3s since last tick
        XCTAssertEqual(c.role, .mirror)
    }

    func testNoAutoReclaimOncePromoted() {
        let c = FailoverController(role: .mirror, referenceStart: t0, promotionTimeout: 4.5)
        XCTAssertTrue(c.evaluate(at: at(10)))   // promote
        // A late tick from the (recovered) original primary must NOT demote us.
        c.receivedPrimaryTick(at: at(11))
        XCTAssertFalse(c.evaluate(at: at(20)))
        XCTAssertEqual(c.role, .primary)
    }

    func testPrimaryNeverPromotes() {
        let c = FailoverController(role: .primary, referenceStart: t0)
        XCTAssertFalse(c.evaluate(at: at(100)))
        XCTAssertEqual(c.role, .primary)
    }

    func testPromotionFiresExactlyOnce() {
        let c = FailoverController(role: .mirror, referenceStart: t0, promotionTimeout: 4.5)
        XCTAssertTrue(c.evaluate(at: at(10)))
        XCTAssertFalse(c.evaluate(at: at(11))) // already primary → no repeat event
    }
}
