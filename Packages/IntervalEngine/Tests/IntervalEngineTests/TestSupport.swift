import Foundation
@testable import IntervalEngine

/// Fixed session origin so every test speaks in "seconds since start".
let t0 = Date(timeIntervalSinceReferenceDate: 0)
func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

extension IntervalEngine {
    /// Ingest a constant HR once per second across `[from, through]` (inclusive),
    /// so the 10s trailing average is well-defined at any tick in that range.
    func feedConstantHR(_ bpm: Double, from: TimeInterval, through: TimeInterval) {
        var s = from
        while s <= through {
            ingest(hrSample: bpm, at: at(s))
            s += 1
        }
    }
}
