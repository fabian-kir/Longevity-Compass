import Foundation

/// SplitMix64 (Steele, Lea & Flood 2014). Used only to expand a 64-bit seed
/// into the 256-bit xoshiro state, as recommended by the xoshiro authors.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// xoshiro256** 1.0 (Blackman & Vigna 2018): 256-bit state, period 2^256 − 1.
///
/// Every sampler chain gets its own stream: the generator seeded from `seed`
/// is advanced by `jump()` (2^128 steps) once per stream index, so streams are
/// non-overlapping for any realistic run length and depend only on
/// `(seed, stream)`, never on scheduling.
public struct Xoshiro256StarStar: RandomNumberGenerator, Sendable, Equatable {
    private var s0: UInt64
    private var s1: UInt64
    private var s2: UInt64
    private var s3: UInt64
    /// Second Box–Muller variate, kept so normals come in pairs.
    private var spareNormal: Double?

    public init(seed: UInt64) {
        var mixer = SplitMix64(seed: seed)
        s0 = mixer.next()
        s1 = mixer.next()
        s2 = mixer.next()
        s3 = mixer.next()
        spareNormal = nil
    }

    /// Independent stream `stream` of the generator seeded with `seed`.
    public init(seed: UInt64, stream: Int) {
        precondition(stream >= 0, "stream index must be non-negative")
        self.init(seed: seed)
        for _ in 0..<stream { jump() }
    }

    /// Raw state constructor, used to check the reference output sequence.
    init(state: (UInt64, UInt64, UInt64, UInt64)) {
        precondition(state != (0, 0, 0, 0), "xoshiro state must not be all zero")
        (s0, s1, s2, s3) = state
        spareNormal = nil
    }

    @inline(__always)
    private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }

    public mutating func next() -> UInt64 {
        let result = Self.rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = Self.rotl(s3, 45)
        return result
    }

    /// Advance by 2^128 steps (reference jump polynomial).
    public mutating func jump() {
        let polynomial: [UInt64] = [
            0x180E_C6D3_3CFD_0ABA, 0xD5A6_1266_F0C9_392C,
            0xA958_2618_E03F_C9AA, 0x39AB_DC45_29B1_661C,
        ]
        var t0: UInt64 = 0, t1: UInt64 = 0, t2: UInt64 = 0, t3: UInt64 = 0
        for word in polynomial {
            for bit in 0..<64 {
                if word & (UInt64(1) << UInt64(bit)) != 0 {
                    t0 ^= s0
                    t1 ^= s1
                    t2 ^= s2
                    t3 ^= s3
                }
                _ = next()
            }
        }
        (s0, s1, s2, s3) = (t0, t1, t2, t3)
        spareNormal = nil
    }

    /// Uniform on [0, 1) with 53 random bits.
    @inline(__always)
    public mutating func uniform() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// Uniform on [lower, upper).
    public mutating func uniform(in lower: Double, _ upper: Double) -> Double {
        lower + (upper - lower) * uniform()
    }

    /// Standard normal by the Box–Muller transform; values come in pairs.
    public mutating func standardNormal() -> Double {
        if let spare = spareNormal {
            spareNormal = nil
            return spare
        }
        // 1 − U lies in (0, 1], so the logarithm is finite.
        let u1 = 1.0 - uniform()
        let u2 = uniform()
        let radius = (-2.0 * log(u1)).squareRoot()
        let angle = 2.0 * Double.pi * u2
        spareNormal = radius * sin(angle)
        return radius * cos(angle)
    }
}
