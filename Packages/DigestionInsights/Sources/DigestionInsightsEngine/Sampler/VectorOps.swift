import Accelerate

/// Fixed-size heap vector. Hot sampler loops go through vDSP so debug builds
/// stay within a small factor of release builds.
final class Vector {
    let pointer: UnsafeMutablePointer<Double>
    let count: Int

    init(_ count: Int) {
        self.count = count
        pointer = .allocate(capacity: max(count, 1))
        pointer.initialize(repeating: 0, count: max(count, 1))
    }

    deinit {
        pointer.deallocate()
    }

    @inline(__always) var p: UnsafeMutablePointer<Double> { pointer }

    func copy(from other: Vector) {
        pointer.update(from: other.pointer, count: count)
    }

    func copy(from source: UnsafePointer<Double>) {
        pointer.update(from: source, count: count)
    }

    func zero() {
        pointer.update(repeating: 0, count: count)
    }

    var array: [Double] { Array(UnsafeBufferPointer(start: pointer, count: count)) }
}

enum VectorOps {
    /// y += a · x
    @inline(__always)
    static func axpy(_ a: Double, _ x: UnsafePointer<Double>, _ y: UnsafeMutablePointer<Double>, _ n: Int) {
        var scale = a
        vDSP_vsmaD(x, 1, &scale, y, 1, y, 1, vDSP_Length(n))
    }

    /// z = x ⊙ y
    @inline(__always)
    static func multiply(_ x: UnsafePointer<Double>, _ y: UnsafePointer<Double>, _ z: UnsafeMutablePointer<Double>, _ n: Int) {
        vDSP_vmulD(x, 1, y, 1, z, 1, vDSP_Length(n))
    }

    /// z = x + y
    @inline(__always)
    static func add(_ x: UnsafePointer<Double>, _ y: UnsafePointer<Double>, _ z: UnsafeMutablePointer<Double>, _ n: Int) {
        vDSP_vaddD(x, 1, y, 1, z, 1, vDSP_Length(n))
    }

    @inline(__always)
    static func dot(_ x: UnsafePointer<Double>, _ y: UnsafePointer<Double>, _ n: Int) -> Double {
        var result = 0.0
        vDSP_dotprD(x, 1, y, 1, &result, vDSP_Length(n))
        return result
    }

    static func allFinite(_ x: UnsafePointer<Double>, _ n: Int) -> Bool {
        var sum = 0.0
        vDSP_sveD(x, 1, &sum, vDSP_Length(n))
        if sum.isFinite { return true }
        for i in 0..<n where !x[i].isFinite { return false }
        return true
    }
}

@inline(__always)
func logSumExp(_ a: Double, _ b: Double) -> Double {
    if a == -.infinity { return b }
    if b == -.infinity { return a }
    return a > b ? a + log1p(exp(b - a)) : b + log1p(exp(a - b))
}
