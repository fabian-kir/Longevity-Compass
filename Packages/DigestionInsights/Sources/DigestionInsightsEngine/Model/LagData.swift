import Foundation

/// Absolute hour index (B9): floor(seconds since 1970 / 3600).
@inline(__always)
func absoluteHour(_ seconds: Double) -> Int {
    Int((seconds / 3600).rounded(.down))
}

/// Input turned into model rows: observed hours, outcome counts per kind,
/// exposures per feature and the distributed-lag cross-basis. Shared by the
/// full fit and both half fits. Public read-only for the simulation study
/// (unit 4: simulation-based calibration of `LagModel`).
public struct LagData: Sendable {
    public let kinds: [String]
    public let maxLagHours: Int
    public let lagBasis: BSplineBasis

    /// Observed absolute hours, ascending (hour h observed when its centre
    /// h + 0.5 lies inside a window).
    public let hours: [Int]
    public let rowOfHour: [Int: Int]
    /// Symptom onsets per row and kind, row-major hours × kinds.
    public let counts: [Double]
    /// Observed symptoms: onset seconds and kind index.
    public let observedSymptoms: [(time: Double, kind: Int)]

    /// Every feature with at least one positive exposure, sorted.
    public let allFeatures: [String]
    /// Exposure (seconds, value) per feature, ascending time, value > 0.
    public let exposures: [String: [(time: Double, value: Double)]]
    public let exposureCount: [String: Int]
    public let symptomsAfterCount: [String: Int]

    /// Features in the model (exposureCount ≥ minExposures), sorted.
    public let modelFeatures: [String]
    /// Cross-basis X[h, f, k], row-major rows × (modelFeatures.count · K).
    public let crossBasis: [Double]

    public var featureCount: Int { modelFeatures.count }
    public var basisCount: Int { lagBasis.count }
    public var kindCount: Int { kinds.count }

    public init(input: AnalysisInput) {
        let config = input.config
        var seenKinds = Set<String>()
        kinds = input.symptomKinds.filter { seenKinds.insert($0).inserted }
        maxLagHours = config.maxLagHours
        lagBasis = BSplineBasis(lower: 0, upper: Double(config.maxLagHours), interiorKnots: config.interiorKnots)

        // Observation hours.
        var hourSet = Set<Int>()
        for window in input.windows {
            let start = window.start.timeIntervalSince1970
            let end = window.end.timeIntervalSince1970
            guard end > start else { continue }
            var h = Int((start / 3600 - 0.5).rounded(.up))
            while (Double(h) + 0.5) * 3600 < end {
                if (Double(h) + 0.5) * 3600 >= start { hourSet.insert(h) }
                h += 1
            }
        }
        hours = hourSet.sorted()
        var rowOfHour = [Int: Int](minimumCapacity: hours.count)
        for (row, h) in hours.enumerated() { rowOfHour[h] = row }
        self.rowOfHour = rowOfHour

        // Outcomes.
        let kindIndex = Dictionary(uniqueKeysWithValues: kinds.enumerated().map { ($1, $0) })
        var counts = [Double](repeating: 0, count: hours.count * kinds.count)
        var observed: [(time: Double, kind: Int)] = []
        for symptom in input.symptoms {
            guard let s = kindIndex[symptom.kind] else { continue }
            let t = symptom.onset.timeIntervalSince1970
            guard let row = rowOfHour[absoluteHour(t)] else { continue }
            counts[row * kinds.count + s] += 1
            observed.append((t, s))
        }
        observed.sort { $0.time < $1.time || ($0.time == $1.time && $0.kind < $1.kind) }
        self.counts = counts
        observedSymptoms = observed

        // Exposures per feature.
        var byFeature: [String: [(time: Double, value: Double)]] = [:]
        for exposure in input.exposures where exposure.value > 0 && exposure.value.isFinite {
            byFeature[exposure.featureID, default: []].append((exposure.time.timeIntervalSince1970, exposure.value))
        }
        for key in byFeature.keys {
            byFeature[key]!.sort { $0.time < $1.time || ($0.time == $1.time && $0.value < $1.value) }
        }
        exposures = byFeature
        allFeatures = byFeature.keys.sorted()

        let windowRanges = input.windows
            .map { ($0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970) }
            .filter { $0.1 > $0.0 }
        let lagSeconds = Double(config.maxLagHours) * 3600
        let symptomTimes = observed.map(\.time)
        var exposureCount: [String: Int] = [:]
        var symptomsAfter: [String: Int] = [:]
        for feature in allFeatures {
            let events = byFeature[feature]!
            exposureCount[feature] = events.filter { event in
                windowRanges.contains { event.time >= $0.0 && event.time < $0.1 }
            }.count
            // Symptom counted once if some exposure lies in (onset − maxLag, onset].
            let times = events.map(\.time)
            symptomsAfter[feature] = symptomTimes.filter { onset in
                let i = Self.lastIndex(in: times, atMost: onset)
                return i >= 0 && onset - times[i] < lagSeconds
            }.count
        }
        self.exposureCount = exposureCount
        symptomsAfterCount = symptomsAfter

        modelFeatures = allFeatures.filter { exposureCount[$0]! >= config.minExposures }

        // Cross-basis: X[h, f, k] = Σ_e value(e) · B_k(lag), 0 ≤ lag < maxLag,
        // lag = hour centre − exposure time (hours).
        let lagBasis = self.lagBasis
        let k = lagBasis.count
        let width = modelFeatures.count * k
        var x = [Double](repeating: 0, count: hours.count * width)
        var basisValues = [Double](repeating: 0, count: k)
        for (f, feature) in modelFeatures.enumerated() {
            for event in byFeature[feature]! {
                let firstHour = Int((event.time / 3600 - 0.5).rounded(.up))
                for h in firstHour..<(firstHour + config.maxLagHours + 1) {
                    let lag = (Double(h) + 0.5) - event.time / 3600
                    guard lag >= 0, lag < Double(config.maxLagHours) else { continue }
                    guard let row = rowOfHour[h] else { continue }
                    basisValues.withUnsafeMutableBufferPointer { lagBasis.evaluate(at: lag, into: $0.baseAddress!) }
                    let base = row * width + f * k
                    for j in 0..<k { x[base + j] += event.value * basisValues[j] }
                }
            }
        }
        crossBasis = x
    }

    /// Index of the last element ≤ value in ascending `values`, or −1.
    static func lastIndex(in values: [Double], atMost value: Double) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    /// Symptom count per kind over the given rows.
    public func symptomCount(rows: [Int]) -> Int {
        var total = 0.0
        for row in rows {
            for s in 0..<kindCount { total += counts[row * kindCount + s] }
        }
        return Int(total)
    }

    /// Exposure–symptom pairs (any kind, observed symptoms) per lag hour.
    public func observedPairs(feature: String) -> [Int] {
        var pairs = [Int](repeating: 0, count: maxLagHours)
        guard let events = exposures[feature] else { return pairs }
        let lagSeconds = Double(maxLagHours) * 3600
        let times = events.map(\.time)
        for symptom in observedSymptoms {
            var i = Self.lastIndex(in: times, atMost: symptom.time)
            while i >= 0, symptom.time - times[i] < lagSeconds {
                let lagHour = Int(((symptom.time - times[i]) / 3600).rounded(.down))
                pairs[min(lagHour, maxLagHours - 1)] += 1
                i -= 1
            }
        }
        return pairs
    }

    /// Features whose hourly exposure series correlate with each feature at
    /// or above `threshold`, over all hours from the first exposure or window
    /// start to the last window end.
    func confounding(threshold: Double, windows: [ObservationWindow]) -> [String: [String]] {
        var series: [String: [Int: Double]] = [:]
        var minHour = Int.max, maxHour = Int.min
        for feature in allFeatures {
            var hourly: [Int: Double] = [:]
            for event in exposures[feature]! {
                let h = absoluteHour(event.time)
                hourly[h, default: 0] += event.value
                minHour = min(minHour, h)
                maxHour = max(maxHour, h)
            }
            series[feature] = hourly
        }
        for window in windows where window.end > window.start {
            minHour = min(minHour, absoluteHour(window.start.timeIntervalSince1970))
            maxHour = max(maxHour, absoluteHour(window.end.timeIntervalSince1970))
        }
        guard minHour <= maxHour else { return [:] }
        let n = Double(maxHour - minHour + 1)
        var sums: [String: (sum: Double, sumSquares: Double)] = [:]
        for (feature, hourly) in series {
            sums[feature] = (hourly.values.reduce(0, +), hourly.values.reduce(0) { $0 + $1 * $1 })
        }
        var result: [String: [String]] = [:]
        for (i, a) in allFeatures.enumerated() {
            for b in allFeatures[(i + 1)...] {
                let (small, large) = series[a]!.count <= series[b]!.count ? (series[a]!, series[b]!) : (series[b]!, series[a]!)
                var cross = 0.0
                for (h, v) in small {
                    if let w = large[h] { cross += v * w }
                }
                let sa = sums[a]!, sb = sums[b]!
                let covariance = cross - sa.sum * sb.sum / n
                let varianceA = sa.sumSquares - sa.sum * sa.sum / n
                let varianceB = sb.sumSquares - sb.sum * sb.sum / n
                guard varianceA > 0, varianceB > 0 else { continue }
                if covariance / (varianceA * varianceB).squareRoot() >= threshold {
                    result[a, default: []].append(b)
                    result[b, default: []].append(a)
                }
            }
        }
        return result.mapValues { $0.sorted() }
    }
}
