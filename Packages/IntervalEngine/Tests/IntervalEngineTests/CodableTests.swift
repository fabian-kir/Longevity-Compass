import XCTest
@testable import IntervalEngine

/// The shared state and command payloads must survive JSON unchanged so either
/// device can become authority without reconstructing engine state heuristically.
final class CodableTests: XCTestCase {

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func testMidSessionOutputRoundTrips() throws {
        // Drive a real tick so the payload has representative, non-default values:
        // a high-intensity phase with an open target band and a below-band cue.
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        engine.feedConstantHR(120, from: 180, through: 260)
        let output = engine.tick(at: at(260)).output
        XCTAssertEqual(try roundTrip(output), output)
    }

    func testAllPhaseKindsRoundTrip() throws {
        let kinds: [PhaseKind] = [
            .warmUp, .highIntensity(round: 4), .activeRecovery(round: 2), .cooldown,
        ]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(PhaseKind.self, from: data), kind)
        }
    }

    func testNilTargetRoundTrips() throws {
        // Warm-up has no target/HR — the optionals must encode and decode as nil.
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        let output = engine.tick(at: at(1)).output
        XCTAssertNil(output.target)
        XCTAssertEqual(try roundTrip(output), output)
    }

    func testSessionMessagesRoundTrip() throws {
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let commandID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        engine.feedConstantHR(142, from: 170, through: 190)
        _ = engine.tick(at: at(150))
        let output = engine.tick(at: at(185)).output
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            createdAt: at(185),
            sequence: 42,
            authority: .watch,
            heartRateSource: .watch,
            heartRateSessionActive: true,
            acknowledgedCommandIDs: [commandID],
            output: output,
            checkpoint: engine.checkpoint()
        )
        let actions: [SessionCommand.Action] = [
            .setPaused(true), .setPaused(false), .skip, .stop, .requestSync,
        ]
        let messages: [SessionMessage] = [.snapshot(snapshot)] + actions.map {
            .command(SessionCommand(
                id: commandID,
                sessionID: sessionID,
                issuedAt: at(190),
                action: $0
            ))
        }

        for message in messages {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testCheckpointRoundTripsWithAllMutableState() throws {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        engine.feedConstantHR(140, from: 285, through: 300)
        _ = engine.tick(at: at(150))
        XCTAssertEqual(engine.tick(at: at(300)).haptics, [.phaseTransition, .goHarder])
        engine.pause(at: at(301))

        let checkpoint = engine.checkpoint()
        XCTAssertFalse(checkpoint.heartRateSamples.isEmpty)
        XCTAssertNotNil(checkpoint.lastGuidance)
        XCTAssertEqual(try roundTrip(checkpoint), checkpoint)
    }

    func testDeviceAndHeartRateSourceCasesRoundTrip() throws {
        for device in [SessionDevice.phone, .watch] {
            XCTAssertEqual(try roundTrip(device), device)
        }
        for source in [HeartRateSource.watch, .phoneExternal, .none] {
            XCTAssertEqual(try roundTrip(source), source)
        }
    }
}
