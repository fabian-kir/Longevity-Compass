import XCTest
@testable import IntervalEngine

final class SessionReconciliationTests: XCTestCase {
    private let earlierID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let laterID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func snapshot(
        id: UUID,
        createdAt: Date,
        sequence: UInt64 = 0,
        authority: SessionDevice
    ) -> SessionSnapshot {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        let output = engine.tick(at: t0).output
        return SessionSnapshot(
            sessionID: id,
            createdAt: createdAt,
            sequence: sequence,
            authority: authority,
            heartRateSource: authority == .watch ? .watch : .phoneExternal,
            output: output,
            checkpoint: engine.checkpoint()
        )
    }

    func testMissingLocalSnapshotAlwaysAdoptsRemote() {
        let remote = snapshot(id: earlierID, createdAt: at(10), authority: .phone)
        XCTAssertTrue(SessionReconciliation.shouldAdopt(
            remote: remote,
            over: nil,
            localDevice: .watch
        ))
    }

    func testEarlierDifferentSessionWinsRegardlessOfAuthorityOrSequence() {
        let older = snapshot(
            id: earlierID,
            createdAt: at(10),
            sequence: 1,
            authority: .phone
        )
        let newer = snapshot(
            id: laterID,
            createdAt: at(20),
            sequence: 999,
            authority: .watch
        )

        XCTAssertTrue(SessionReconciliation.shouldAdopt(
            remote: older,
            over: newer,
            localDevice: .watch
        ))
        XCTAssertFalse(SessionReconciliation.shouldAdopt(
            remote: newer,
            over: older,
            localDevice: .phone
        ))
    }

    func testDifferentSessionCreationTieUsesAscendingUUID() {
        let lower = snapshot(id: earlierID, createdAt: at(10), authority: .phone)
        let higher = snapshot(id: laterID, createdAt: at(10), authority: .watch)

        XCTAssertTrue(SessionReconciliation.shouldAdopt(
            remote: lower,
            over: higher,
            localDevice: .watch
        ))
        XCTAssertFalse(SessionReconciliation.shouldAdopt(
            remote: higher,
            over: lower,
            localDevice: .phone
        ))
    }

    func testWatchAuthorityWinsSameSessionEvenWithLowerSequence() {
        let phone = snapshot(
            id: earlierID,
            createdAt: at(10),
            sequence: 100,
            authority: .phone
        )
        let watch = snapshot(
            id: earlierID,
            createdAt: at(10),
            sequence: 1,
            authority: .watch
        )

        XCTAssertTrue(SessionReconciliation.shouldAdopt(
            remote: watch,
            over: phone,
            localDevice: .phone
        ))
        XCTAssertFalse(SessionReconciliation.shouldAdopt(
            remote: phone,
            over: watch,
            localDevice: .watch
        ))
    }

    func testSameAuthorityUsesOnlyGreaterSequence() {
        let old = snapshot(
            id: earlierID,
            createdAt: at(10),
            sequence: 4,
            authority: .watch
        )
        let new = snapshot(
            id: earlierID,
            createdAt: at(50),
            sequence: 5,
            authority: .watch
        )

        for device in [SessionDevice.phone, .watch] {
            XCTAssertTrue(SessionReconciliation.shouldAdopt(
                remote: new,
                over: old,
                localDevice: device
            ))
            XCTAssertFalse(SessionReconciliation.shouldAdopt(
                remote: old,
                over: new,
                localDevice: device
            ))
            XCTAssertFalse(SessionReconciliation.shouldAdopt(
                remote: old,
                over: old,
                localDevice: device
            ))
        }
    }
}
