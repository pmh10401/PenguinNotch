import SwiftUI
import Charts
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
    @State private var page = Page.history

    private enum Page: CaseIterable {
        case history, comparison, calibration
        var title: String {
            switch self {
            case .history: L10n.t("Saved predictions")
            case .comparison: L10n.t("Model comparison")
            case .calibration: L10n.t("Probability check")
            }
        }
    }

    private var cohort: [StockForecastRecord] {
        let cutoff = days == 0 ? Date.distantPast : Date().addingTimeInterval(-Double(days) * 86400)
        return journal.records.filter { $0.capture == capture
            && (stockID.isEmpty || $0.stockID == stockID) && $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private var filtered: [StockForecastRecord] { cohort.filter { $0.model == model } }
    private var exportRecords: [StockForecastRecord] { page == .comparison ? cohort : filtered }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("Forecast history")).font(.title2.bold())
                Spacer()
                Button(L10n.t("Export filtered CSV…")) {
                    document = ForecastCSVDocument(text: StockForecastJournal.csv(exportRecords))
                    exportsCSV = true
                }
                .disabled(exportRecords.isEmpty)
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
                if page == .comparison {
                    Text(L10n.t("All recorded models")).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker(L10n.t("Model"), selection: $model) {
                        ForEach(Set(journal.records.map(\.model) + [StockForecastRecord.modelVersion]).sorted(), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                Picker(L10n.t("Period"), selection: $days) {
                    Text(L10n.t("Last 30 days")).tag(30)
                    Text(L10n.t("Last 90 days")).tag(90)
                    Text(L10n.t("All time")).tag(0)
                }
            }
            Picker(L10n.t("Forecast view"), selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if let error = journal.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
            if let message = journal.reconciliationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let exportError { Text(exportError).foregroundStyle(.red).font(.caption) }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case .comparison:
                        ForecastComparisonView(records: cohort)
                    case .calibration:
                        ForecastCalibrationView(records: filtered)
                    case .history:
                        history
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            Text(L10n.t("Saved inputs are never replaced. CSV follows the current filters and includes all recorded models on the comparison tab. Missing daily closes remain pending."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 860, height: 700)
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

    private var history: some View {
        let score = StockForecastScore(filtered)
        return VStack(alignment: .leading, spacing: 16) {
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
            if filtered.isEmpty {
                ContentUnavailableView(L10n.t("No saved predictions in this filter"), systemImage: "chart.xyaxis.line",
                    description: Text(L10n.t("Enable automatic recording or save current predictions in Stocks settings. Only predictions made before the close can be recorded.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                  ForEach(filtered) { record in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(L10n.t("Model 80% range")): \(price(record.lowerClose, record)) – \(price(record.upperClose, record))")
                            Text("\(L10n.t("Rise")): \(percent(record.riseProbability * 100)) · n=\(record.observations)")
                            if let error = record.absolutePercentageError {
                                Text("\(L10n.t("Price error")): \(percent(error))")
                            }
                            Divider().padding(.vertical, 6)
                            ForecastEvidenceView(record: record)
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
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                  }
                }
            }
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

struct ForecastEvidenceView: View {
    let record: StockForecastRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.t("Prediction evidence"), systemImage: "doc.text.magnifyingglass").font(.headline)
            LabeledContent(L10n.t("Model"), value: record.model)
            LabeledContent(L10n.t("Input price"), value: price(record.inputPrice))
            LabeledContent(L10n.t("Previous close"), value: price(record.previousClose))
            LabeledContent(L10n.t("Quote time"), value: timestamp(record.quoteAt))
            LabeledContent(L10n.t("Prediction time"), value: timestamp(record.createdAt))
            LabeledContent(L10n.t("Target regular close"), value: timestamp(record.sessionEnd))
            if let evidence = record.evidence {
                Text(L10n.t("Source: Toss Securities · completed, adjusted daily closes"))
                    .foregroundStyle(.secondary)
                LabeledContent(L10n.t("Daily volatility"), value: percent(evidence.dailyVolatility))
                LabeledContent(L10n.t("Past 5-session return"), value: percent(evidence.historicalReturn(sessions: 5)))
                LabeledContent(L10n.t("Past 20-session return"), value: percent(evidence.historicalReturn(sessions: 20)))
                DisclosureGroup(String(format: L10n.t("Completed daily closes (%d)"), evidence.closes.count)) {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                        ForEach(evidence.closes, id: \.date) { close in
                            GridRow {
                                Text(timestamp(close.date, dateOnly: true))
                                Text(price(close.price)).monospacedDigit().gridColumnAlignment(.trailing)
                            }
                        }
                    }.padding(.top, 6)
                }
            } else {
                Text(L10n.t("This older record has no saved daily-candle evidence. Its original prices and result are retained."))
                    .foregroundStyle(.secondary)
            }
            if record.model == StockForecastRecord.modelVersion {
                Text(L10n.t("GBM assumes zero expected return from the input price to the close. Daily volatility sizes the price range; historical returns are context, not a trend prediction. No news or AI API is used."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private func price(_ value: Decimal) -> String {
        StockQuoteCodec.format(price: value, currency: record.currency, locale: .current)
    }
    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.2f%%", $0 * 100) } ?? "—"
    }
    private func timestamp(_ date: Date, dateOnly: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = record.marketCalendar.timeZone
        formatter.dateFormat = dateOnly ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss z"
        return formatter.string(from: date)
    }
}

struct ForecastComparisonView: View {
    let records: [StockForecastRecord]

    var body: some View {
        let comparison = StockForecastComparison(records)
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Compare identical prediction inputs")).font(.headline)
            Text(L10n.t("Only completed records shared by every listed model are compared. Stock, quote time, input prices, daily candles, regular session, and recording mode must match. Unpaired records are excluded from both error columns."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if comparison.rows.isEmpty {
                ContentUnavailableView(L10n.t("No saved predictions in this filter"), systemImage: "chart.bar.xaxis")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                    GridRow {
                        Text(L10n.t("Model"))
                        Text(L10n.t("Saved / pending"))
                        Text(L10n.t("Paired samples"))
                        Text("MAPE")
                        Text("Brier")
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(comparison.rows) { row in
                        GridRow {
                            Text(row.model).font(.headline)
                            Text("\(row.available.total) / \(row.available.total - row.available.evaluated)")
                            Text("\(row.paired.evaluated)")
                            Text(row.paired.meanError.map { String(format: "%.2f%%", $0) } ?? "—")
                            Text(row.paired.brier.map { String(format: "%.3f", $0) } ?? "—")
                        }.monospacedDigit()
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                LabeledContent(L10n.t("Price-hold baseline error"),
                    value: comparison.baselineError.map { String(format: "%.2f%% · n=%d", $0, comparison.pairedCount) } ?? "—")
                if comparison.pairedCount == 0 {
                    Text(L10n.t("No completed records with matching inputs yet. Missing evidence or a pending close cannot be treated as a match."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(L10n.t("This version records local GBM predictions. Laya and Jev are not connected. GBM's expected close equals the input price, so its MAPE equals the price-hold baseline. Lower MAPE and Brier are better; these are not investment returns."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ForecastCalibrationView: View {
    let records: [StockForecastRecord]

    var body: some View {
        let bins = StockForecastCalibration.bins(records)
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Do predicted probabilities match observed rises?")).font(.headline)
            Text(L10n.t("For example, predictions near 70% should rise about 7 times out of 10. This chart checks saved probabilities; it does not change or train the model."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if bins.isEmpty {
                ContentUnavailableView(L10n.t("Waiting for evaluated predictions"), systemImage: "chart.xyaxis.line",
                    description: Text(L10n.t("Probability checks appear after the matching daily closes are available.")))
            } else {
                Chart {
                    ForEach([0.0, 1.0], id: \.self) { value in
                        LineMark(x: .value(L10n.t("Mean predicted rise"), value),
                                 y: .value(L10n.t("Observed rise rate"), value))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .accessibilityLabel(L10n.t("Perfect calibration reference"))
                    }
                    ForEach(bins) { bin in
                        RuleMark(x: .value(L10n.t("Mean predicted rise"), bin.meanProbability),
                                 yStart: .value(L10n.t("95% interval lower bound"), bin.interval.lowerBound),
                                 yEnd: .value(L10n.t("95% interval upper bound"), bin.interval.upperBound))
                            .foregroundStyle(.blue.opacity(0.45))
                        PointMark(x: .value(L10n.t("Mean predicted rise"), bin.meanProbability),
                                  y: .value(L10n.t("Observed rise rate"), bin.observedRate))
                            .foregroundStyle(.blue).symbolSize(65)
                            .accessibilityLabel(bin.label)
                            .accessibilityValue(String(format: L10n.t("%d rises in %d evaluated predictions"), bin.rises, bin.count))
                    }
                }
                .chartXScale(domain: 0...1).chartYScale(domain: 0...1)
                .chartXAxis { AxisMarks(values: [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]) {
                    AxisGridLine()
                    AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent())
                } }
                .chartYAxis { AxisMarks(values: [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]) {
                    AxisGridLine()
                    AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent())
                } }
                .chartXAxisLabel(L10n.t("Mean predicted rise"))
                .chartYAxisLabel(L10n.t("Observed rise rate"))
                .frame(height: 230)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                    GridRow {
                        Text(L10n.t("Probability band"))
                        Text(L10n.t("Mean predicted rise"))
                        Text(L10n.t("Observed rise rate"))
                        Text(L10n.t("Rises / evaluated"))
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(bins) { bin in
                        GridRow {
                            Text(bin.label)
                            Text(bin.meanProbability, format: .percent.precision(.fractionLength(1)))
                            Text(bin.observedRate, format: .percent.precision(.fractionLength(1)))
                            Text("\(bin.rises) / \(bin.count)")
                        }.monospacedDigit()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.t("Only evaluated predictions are counted. An unchanged close counts as not rising; 50% predictions are included. Empty bands are omitted. Bars show descriptive 95% Wilson intervals; related stocks and dates can make uncertainty larger."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
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
