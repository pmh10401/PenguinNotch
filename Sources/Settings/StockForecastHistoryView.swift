import SwiftUI
import UniformTypeIdentifiers

struct StockForecastHistoryView: View {
    @ObservedObject var journal: StockForecastJournal
    @Environment(\.dismiss) private var dismiss
    @State private var capture: ForecastCapture = .scheduled
    @State private var stockID = ""
    @State private var model = StockForecastRecord.modelVersion
    @State private var days = 30
    @State private var exportsCSV = false
    @State private var document = ForecastCSVDocument(text: "")
    @State private var exportError: String?

    private var filtered: [StockForecastRecord] {
        let cutoff = days == 0 ? Date.distantPast : Date().addingTimeInterval(-Double(days) * 86400)
        return journal.records.filter { $0.capture == capture && $0.model == model
            && (stockID.isEmpty || $0.stockID == stockID) && $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("Forecast history")).font(.title2.bold())
                Spacer()
                Button(L10n.t("Export filtered CSV…")) {
                    document = ForecastCSVDocument(text: StockForecastJournal.csv(filtered))
                    exportsCSV = true
                }
                .disabled(filtered.isEmpty)
                Button(L10n.t("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker(L10n.t("Prediction timing"), selection: $capture) {
                    ForEach(ForecastCapture.allCases) { Text($0.title).tag($0) }
                }
                Picker(L10n.t("Stock"), selection: $stockID) {
                    Text(L10n.t("All stocks")).tag("")
                    ForEach(Set(journal.records.map(\.stockID)).sorted(), id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
            }
            HStack {
                Picker(L10n.t("Model"), selection: $model) {
                    ForEach(Set(journal.records.map(\.model) + [StockForecastRecord.modelVersion]).sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Picker(L10n.t("Period"), selection: $days) {
                    Text(L10n.t("Last 30 days")).tag(30)
                    Text(L10n.t("Last 90 days")).tag(90)
                    Text(L10n.t("All time")).tag(0)
                }
            }
            let score = StockForecastScore(filtered)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    metric("Direction hit rate", score.directionCount == 0 ? "—"
                        : "\(percent(Double(score.directionHits) / Double(score.directionCount) * 100)) · \(score.directionHits)/\(score.directionCount)")
                    metric("Mean price error (MAPE)", percent(score.meanError))
                    metric("Price-hold baseline error", percent(score.baselineError))
                }
                GridRow {
                    metric("80% range coverage", percent(score.rangeCoverage))
                    metric("Up-probability error (Brier)", score.brier.map { String(format: "%.3f", $0) } ?? "—")
                    metric("Evaluated / pending", "\(score.evaluated) / \(score.total - score.evaluated)")
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            Text(L10n.t("Direction compares with the previous close, not your purchase price. Ties and 50% calls are excluded from direction hits. Lower MAPE and Brier are better; Brier treats an unchanged close as not rising. GBM's central price equals its price-hold baseline. Sample counts matter; this is not investment performance."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = journal.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
            if let message = journal.reconciliationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let exportError { Text(exportError).foregroundStyle(.red).font(.caption) }
            if filtered.isEmpty {
                ContentUnavailableView(L10n.t("No saved predictions in this filter"), systemImage: "chart.xyaxis.line",
                    description: Text(L10n.t("Enable automatic recording or save current predictions in Stocks settings. Only predictions made before the close can be recorded.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { record in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(L10n.t("Model 80% range")): \(price(record.lowerClose, record)) – \(price(record.upperClose, record))")
                            Text("\(L10n.t("Previous close")): \(price(record.previousClose, record)) · \(L10n.t("Input price")): \(price(record.inputPrice, record))")
                            Text("\(L10n.t("Rise")): \(percent(record.riseProbability * 100)) · n=\(record.observations)")
                            Text("\(L10n.t("Prediction time")): \(record.createdAt.formatted(date: .abbreviated, time: .standard))")
                            Text("\(L10n.t("Quote time")): \(record.quoteAt.formatted(date: .abbreviated, time: .standard))")
                            Text("\(L10n.t("Minutes before close")): \(Int(record.sessionEnd.timeIntervalSince(record.createdAt) / 60))")
                            if let error = record.absolutePercentageError {
                                Text("\(L10n.t("Price error")): \(percent(error))")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.name.isEmpty ? record.stockID : record.name).font(.headline)
                                Text("\(record.stockID) · \(tradingDay(record))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("\(L10n.t("Estimated close")): \(price(record.expectedClose, record))")
                                Text(record.actualClose.map { "\(L10n.t("Actual daily close")): \(price($0, record))" }
                                     ?? L10n.t("Pending daily close"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(record.directionHit.map { L10n.t($0 ? "Direction matched" : "Direction missed") }
                                 ?? L10n.t(record.actualClose == nil ? "Pending" : "No direction score"))
                                .font(.caption).frame(width: 100)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Text(L10n.t("Saved predictions are never replaced. Missing closes stay pending. Daily-close checks resume when Toss holdings estimates are enabled and the app is running; with automatic recording off, open Stocks settings to resume checks. Export includes only the selected filters."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 780, height: 660)
        .onAppear {
            if !journal.records.contains(where: { $0.capture == .scheduled }),
               journal.records.contains(where: { $0.capture == .manual }) { capture = .manual }
        }
        .fileExporter(isPresented: $exportsCSV, document: document, contentType: .commaSeparatedText,
                      defaultFilename: "PenguinNotch-forecasts") { result in
            if case .failure = result { exportError = L10n.t("Could not export forecast history.") }
            else { exportError = nil }
        }
    }

    private func metric(_ title: String.LocalizationValue, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    private func price(_ value: Decimal, _ record: StockForecastRecord) -> String {
        StockQuoteCodec.format(price: value, currency: record.currency, locale: .current)
    }
    private func tradingDay(_ record: StockForecastRecord) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = record.marketCalendar.timeZone
        return formatter.string(from: record.sessionStart)
    }
}

private struct ForecastCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(("\u{FEFF}" + text).utf8))
    }
}
