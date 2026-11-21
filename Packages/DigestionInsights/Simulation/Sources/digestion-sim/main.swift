import DigestionSimulation
import Foundation

// Package root from this file's location: Simulation/Sources/digestion-sim/main.swift.
let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let paths = SimulationPaths(packageRoot: packageRoot)

let log: @Sendable (String) -> Void = { line in
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

do {
    switch try SimulationCommand.parse(Array(CommandLine.arguments.dropFirst())) {
    case .sbc(let plan):
        try await SBC.run(plan: plan, output: paths.sbcRecords, log: log)
    case .recovery(let plan, let limit):
        try await RecoveryStudy.run(plan: plan, output: paths.recoveryRecords, limit: limit, log: log)
    case .calibrate:
        try Calibration.run(paths: paths, log: log)
    case .report(let checkOnly):
        try Report.run(paths: paths, checkOnly: checkOnly, log: log)
    }
} catch let error as SimulationCommand.ParseError {
    log(error.description)
    exit(64)
} catch {
    log("digestion-sim: \(error)")
    exit(1)
}
