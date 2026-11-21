import XCTest
@testable import DigestionInsightsEngine

/// The generator is the root of bitwise determinism: same (seed, stream) must
/// give the same sequence on every run, and streams must not repeat each other.
final class RandomTests: XCTestCase {

    func testXoshiroMatchesReferenceSequence() {
        // Reference outputs of xoshiro256** 1.0 from state {1, 2, 3, 4}.
        var rng = Xoshiro256StarStar(state: (1, 2, 3, 4))
        XCTAssertEqual(rng.next(), 11520)
        XCTAssertEqual(rng.next(), 0)
        XCTAssertEqual(rng.next(), 1_509_978_240)
        XCTAssertEqual(rng.next(), 1_215_971_899_390_074_240)
    }

    func testSplitMixMatchesReferenceSequence() {
        var mixer = SplitMix64(seed: 0)
        XCTAssertEqual(mixer.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(mixer.next(), 0x6E78_9E6A_A1B9_65F4)
    }

    func testSameSeedAndStreamReproduce() {
        var a = Xoshiro256StarStar(seed: 42, stream: 3)
        var b = Xoshiro256StarStar(seed: 42, stream: 3)
        for _ in 0..<1000 {
            XCTAssertEqual(a.next(), b.next())
        }
        XCTAssertEqual(a.standardNormal(), b.standardNormal())
    }

    func testStreamsAndSeedsDiffer() {
        var first = Xoshiro256StarStar(seed: 42, stream: 0)
        var second = Xoshiro256StarStar(seed: 42, stream: 1)
        var otherSeed = Xoshiro256StarStar(seed: 43, stream: 0)
        let a = (0..<16).map { _ in first.next() }
        let b = (0..<16).map { _ in second.next() }
        let c = (0..<16).map { _ in otherSeed.next() }
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(Set(a).isDisjoint(with: Set(b)))
    }

    func testUniformMoments() {
        var rng = Xoshiro256StarStar(seed: 7)
        let n = 200_000
        var sum = 0.0, sumSquares = 0.0
        for _ in 0..<n {
            let u = rng.uniform()
            XCTAssertTrue(u >= 0 && u < 1)
            sum += u
            sumSquares += u * u
        }
        let mean = sum / Double(n)
        let variance = sumSquares / Double(n) - mean * mean
        // SE of mean = √(1/12 / n) ≈ 6.5e-4; 5 SE tolerance.
        XCTAssertEqual(mean, 0.5, accuracy: 3.3e-3)
        XCTAssertEqual(variance, 1.0 / 12, accuracy: 2e-3)
    }

    func testStandardNormalMoments() {
        var rng = Xoshiro256StarStar(seed: 11)
        let n = 200_000
        var m1 = 0.0, m2 = 0.0, m3 = 0.0, m4 = 0.0
        for _ in 0..<n {
            let x = rng.standardNormal()
            m1 += x
            m2 += x * x
            m3 += x * x * x
            m4 += x * x * x * x
        }
        m1 /= Double(n); m2 /= Double(n); m3 /= Double(n); m4 /= Double(n)
        // SEs: mean 2.2e-3, E[x²] 3.2e-3, E[x³] 8.7e-3, E[x⁴] 2.2e-2; 5 SE.
        XCTAssertEqual(m1, 0, accuracy: 0.011)
        XCTAssertEqual(m2, 1, accuracy: 0.016)
        XCTAssertEqual(m3, 0, accuracy: 0.044)
        XCTAssertEqual(m4, 3, accuracy: 0.11)
    }
}
