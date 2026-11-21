import Foundation

/// `digestion-sim` command line, parsed without dependencies.
///
///     digestion-sim sbc [--replications N] [--warmup N] [--samples N] [--concurrency N]
///     digestion-sim recovery [--users-per-cell N] [--nulls N] [--horizons 14,30,...] [--diligences typical,...] [--effects 2,...]
///                            [--warmup N] [--samples N] [--concurrency N] [--limit N]
///     digestion-sim calibrate
///     digestion-sim report [--check]
///
/// Raw output goes to `build/digestion-sim/` at the repository root (git-ignored);
/// `calibrate` writes `Simulation/results.json`, `report` renders `results.md`
/// from it and checks that `Thresholds.default` matches the calibrated values.
public enum SimulationCommand: Equatable {
    case sbc(SBCPlan)
    case recovery(RecoveryPlan, limit: Int?)
    case calibrate
    case report(checkOnly: Bool)

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public static let usage = """
    usage: digestion-sim <sbc|recovery|calibrate|report> [options]
      sbc        --replications N --warmup N --samples N --concurrency N
      recovery   --users-per-cell N --nulls N --horizons 14,30,60 --diligences typical --effects 2 --warmup N --samples N
                 --concurrency N --limit N
      calibrate  (reads build/digestion-sim/*.jsonl, writes Simulation/results.json)
      report     [--check]  (renders Simulation/results.md from results.json)
    """

    public static func parse(_ arguments: [String]) throws -> SimulationCommand {
        guard let name = arguments.first else { throw ParseError(description: usage) }
        var options: [String: String] = [:]
        var flags = Set<String>()
        var rest = arguments.dropFirst()
        while let argument = rest.popFirst() {
            guard argument.hasPrefix("--") else { throw ParseError(description: "unexpected argument \(argument)") }
            let key = String(argument.dropFirst(2))
            if key == "check" {
                flags.insert(key)
                continue
            }
            guard let value = rest.popFirst() else { throw ParseError(description: "missing value for \(argument)") }
            options[key] = value
        }

        func int(_ key: String) throws -> Int? {
            guard let raw = options.removeValue(forKey: key) else { return nil }
            guard let value = Int(raw), value >= 0 else { throw ParseError(description: "--\(key) needs a non-negative integer, got \(raw)") }
            return value
        }
        func finish() throws {
            if let unknown = options.keys.sorted().first { throw ParseError(description: "unknown option --\(unknown) for \(name)") }
        }

        switch name {
        case "sbc":
            var plan = SBCPlan()
            if let v = try int("replications") { plan.replications = v }
            if let v = try int("warmup") { plan.warmup = v }
            if let v = try int("samples") { plan.samples = v }
            if let v = try int("concurrency") { plan.concurrency = v }
            try finish()
            return .sbc(plan)
        case "recovery":
            var plan = RecoveryPlan()
            if let v = try int("users-per-cell") { plan.usersPerCell = v }
            if let v = try int("nulls") { plan.nullUsers = v }
            if let v = try int("warmup") { plan.warmup = v }
            if let v = try int("samples") { plan.samples = v }
            if let v = try int("concurrency") { plan.concurrency = v }
            if let raw = options.removeValue(forKey: "diligences") {
                let values = raw.split(separator: ",").map { LoggingDiligence(rawValue: String($0)) }
                guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else {
                    throw ParseError(description: "--diligences needs careful, typical or sloppy separated by commas, got \(raw)")
                }
                plan.diligences = values.map { $0! }
            }
            if let raw = options.removeValue(forKey: "horizons") {
                let values = raw.split(separator: ",").map { Int($0) }
                guard !values.isEmpty, values.allSatisfy({ ($0 ?? 0) > 0 }) else {
                    throw ParseError(description: "--horizons needs positive integers separated by commas, got \(raw)")
                }
                plan.horizons = values.map { $0! }
            }
            if let raw = options.removeValue(forKey: "effects") {
                let values = raw.split(separator: ",").map { Double($0) }
                guard !values.isEmpty, values.allSatisfy({ [1.5, 2, 4, 10].contains($0 ?? 0) }) else {
                    throw ParseError(description: "--effects needs 1.5, 2, 4 or 10 separated by commas, got \(raw)")
                }
                plan.effects = values.map { $0! }
            }
            let limit = try int("limit")
            try finish()
            return .recovery(plan, limit: limit)
        case "calibrate":
            try finish()
            return .calibrate
        case "report":
            try finish()
            return .report(checkOnly: flags.contains("check"))
        default:
            throw ParseError(description: "unknown command \(name)\n\(usage)")
        }
    }
}
