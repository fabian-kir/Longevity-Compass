import XCTest
@testable import IntervalEngine

/// `EngineOutput` is the primary→mirror wire payload (spec §5.2). It must survive
/// a JSON round-trip unchanged so a mirror device renders exactly what the primary
/// computed. These lock the `Codable` conformance in place.
final class CodableTests: XCTestCase {

    private func roundTrip(_ output: EngineOutput) throws -> EngineOutput {
        let data = try JSONEncoder().encode(output)
        return try JSONDecoder().decode(EngineOutput.self, from: data)
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
        let output = IntervalEngine(hrMax: 190, startedAt: t0).tick(at: at(1)).output
        let messages: [SessionMessage] = [.output(output), .stop]

        for message in messages {
            let data = try JSONEncoder().encode(message)
            XCTAssertEqual(try JSONDecoder().decode(SessionMessage.self, from: data), message)
        }
    }
}
