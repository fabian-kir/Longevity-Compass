import CoreTransferable
import DigestionInsightsEngine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shareable files (B15)

/// Doctor report, rendered to PDF only when the user shares it.
struct DigestionReportDocument: Transferable {
    let report: DigestionPresentation.Report

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { document in
            let url = try await MainActor.run { try DigestionReportRenderer.writePDF(document.report) }
            return SentTransferredFile(url)
        }
    }
}

/// Exact input and result of the last good run, as JSON.
struct DigestionAnalysisDataFile: Transferable {
    let export: DigestionAnalysisExport

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let data = try DigestionAnalysisService.encoder(pretty: true).encode(file.export)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("digestion-analysis-data.json")
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

// MARK: - PDF

enum DigestionReportRenderer {
    /// A4 in points.
    static let pageSize = CGSize(width: 595, height: 842)
    static let logLinesPerPage = 42

    static func writePDF(_ report: DigestionPresentation.Report) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("digestion-insights-report.pdf")
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let chunks = stride(from: 0, to: report.log.count, by: logLinesPerPage).map {
            Array(report.log[$0..<min($0 + logLinesPerPage, report.log.count)])
        }
        let pages: [AnyView] = [AnyView(DigestionReportSummaryPage(report: report))]
            + chunks.enumerated().map { index, lines in
                AnyView(DigestionReportLogPage(lines: lines, page: index + 1, pages: chunks.count, disclaimer: report.disclaimer))
            }
        for page in pages {
            let renderer = ImageRenderer(content: page.frame(width: pageSize.width, height: pageSize.height).environment(\.colorScheme, .light))
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return url
    }
}

// MARK: - Pages

private struct DigestionReportSummaryPage: View {
    let report: DigestionPresentation.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Digestion Insights — report").font(.title2.bold())
                Text("Generated \(report.generatedAt.formatted(date: .long, time: .shortened)) with Longevity Direction")
                    .font(.caption).foregroundStyle(.secondary)
            }

            block("Tracking") {
                ForEach(Array(report.periods.enumerated()), id: \.offset) { _, period in
                    Text("\(period.start.formatted(date: .abbreviated, time: .omitted)) – \(period.end?.formatted(date: .abbreviated, time: .omitted) ?? "today")")
                }
                Text("\(report.daysWithMeals) days with meals logged (days without meals are not analysed)")
                    .foregroundStyle(.secondary)
            }

            block("Symptoms logged") {
                if report.symptomCounts.isEmpty { Text("None").foregroundStyle(.secondary) }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                    ForEach(Array(report.symptomCounts.enumerated()), id: \.offset) { _, line in
                        GridRow {
                            Text(line.kind)
                            Text(line.level).foregroundStyle(.secondary)
                            Text("\(line.count)").monospacedDigit()
                        }
                    }
                }
            }

            block(report.resultDate.map { "Patterns (analysis of \($0.formatted(date: .abbreviated, time: .omitted)))" } ?? "Patterns") {
                if report.features.isEmpty {
                    Text("No analysis result with enough data yet.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        GridRow {
                            Text("Food"); Text("Result"); Text("Peak rate ratio (90 %)"); Text("Confidence"); Text("Delay"); Text("Meals")
                        }
                        .font(.caption2.bold())
                        ForEach(Array(report.features.prefix(24).enumerated()), id: \.offset) { _, line in
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(line.name)
                                    Text(line.kindLabel).font(.system(size: 7)).foregroundStyle(.secondary)
                                }
                                Text(line.level)
                                Text(line.peak).monospacedDigit()
                                Text(line.confidence).monospacedDigit()
                                Text(line.delay).monospacedDigit()
                                Text("\(line.exposures)").monospacedDigit()
                            }
                        }
                    }
                    .font(.caption2)
                    if report.features.count > 24 {
                        Text("\(report.features.count - 24) more in the app.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Confidence: estimated chance that symptoms become more frequent after this food. Rate ratio 1 = no change. Delay: median time from meal to the extra symptoms.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            Text(DigestionPresentation.doctorLine).font(.footnote.bold())
            Text(report.disclaimer).font(.caption2).foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white)
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }
}

private struct DigestionReportLogPage: View {
    let lines: [DigestionPresentation.Report.LogLine]
    let page: Int
    let pages: Int
    let disclaimer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Symptom log (\(page) of \(pages))").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    GridRow {
                        Text(line.onset.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                        Text(line.kind)
                        Text(line.level).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            Spacer(minLength: 0)
            Text(disclaimer).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white)
    }
}
