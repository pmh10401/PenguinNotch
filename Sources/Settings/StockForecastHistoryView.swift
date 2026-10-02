import SwiftUI
import Charts
import UniformTypeIdentifiers

struct StockForecastHistoryView: View {
    @ObservedObject var journal: StockForecastJournal
    @ObservedObject var analyses: StockCodexAnalysisStore
    @ObservedObject var backtests: StockBacktestStore
    @Environment(\.dismiss) private var dismiss
    @State private var replay = false
    @State private var stockID = ""
    @State private var day = ""
    @State private var model = ""
    @State private var capture = ""
    @State private var days = 30
    @State private var source: String
    @State private var exporting = false
    @State private var document = ForecastCSVDocument(text: "")
    @State private var exportError: String?

    init(journal: StockForecastJournal, analyses: StockCodexAnalysisStore, backtests: StockBacktestStore, initialCodexFilter: Bool = false) {
        self.journal = journal; self.analyses = analyses; self.backtests = backtests
        _source = State(initialValue: initialCodexFilter ? "codex" : "")
    }
    private var savedAnalyses: [StockCodexAnalysis] {
        Self.savedAnalyses(analyses.analyses, stockID: stockID, day: day, model: model, capture: capture).filter { $0.completedAt >= cutoff }
    }
    static func savedAnalyses(_ values: [StockCodexAnalysis], stockID: String = "", day: String = "", model: String = "", capture: String = "") -> [StockCodexAnalysis] {
        values.filter { a in
            (stockID.isEmpty || a.input.stockID == stockID) && (model.isEmpty || a.forecastModel == model || a.model == model)
                && (capture.isEmpty || capture == "manual")
                && (day.isEmpty || targetDay(a.input.sessionStart, stockID: a.input.stockID) == day)
        }
    }
    static func targetDay(_ date: Date, stockID: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = StockQuoteCodec.timeZone(for: WatchedStock.parse(stockID)?.market ?? .us)
        return StockBacktest.day(date, calendar: calendar)
    }
    private var cutoff: Date { days == 0 ? .distantPast : Date().addingTimeInterval(-Double(days) * 86400) }
    private var rows: [StockEvaluationRow] {
        let rows = StockEvaluation.filtered(StockEvaluation.rows(journal: journal.records.filter { $0.createdAt >= cutoff }, analyses: analyses.analyses.filter { $0.completedAt >= cutoff }),
            stockID: stockID.isEmpty ? nil : stockID, day: day.isEmpty ? nil : day, capture: capture.isEmpty ? nil : capture)
        return rows.filter { r in
            (model.isEmpty || r.model == model) && (source.isEmpty
                || source == "codex" && savedAnalyses.contains { a in a.forecastModel == r.model && r.references.contains { $0.referenceID == a.id.uuidString } }
                || source != "codex" && (r.source.rawValue == source || r.references.contains { $0.source.rawValue == source }))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("Forecast history and evaluation")).font(.title2.bold())
                Spacer()
                Button(L10n.t("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker(L10n.t("Forecast view"), selection: $replay) {
                Text(L10n.t("Saved predictions")).tag(false)
                Text(L10n.t("Historical replay")).tag(true)
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if replay { StockBacktestView(store: backtests) } else { savedHistory }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
        }.padding(16).frame(minWidth: 620, idealWidth: 820, minHeight: 480, idealHeight: 680)
        .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText,
                      defaultFilename: "PenguinNotch-evaluation") { if case .failure = $0 { exportError = L10n.t("Could not export forecast history.") } }
    }
    private var savedHistory: some View {
        let all = StockEvaluation.rows(journal: journal.records, analyses: analyses.analyses)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(L10n.t("Stock"), selection: $stockID) {
                    Text(L10n.t("All stocks")).tag("")
                    ForEach(Set(all.map(\.stockID) + analyses.analyses.map { $0.input.stockID }).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker(L10n.t("Target day"), selection: $day) {
                    Text(L10n.t("All")).tag("")
                    ForEach(Set(all.map { Self.targetDay(StockBacktest.date($0.sessionStart), stockID: $0.stockID) } + analyses.analyses.map { Self.targetDay($0.input.sessionStart, stockID: $0.input.stockID) }).sorted(), id: \.self) { Text($0).tag($0) }
                }
            }
            HStack {
                Picker(L10n.t("Model"), selection: $model) {
                    Text(L10n.t("All recorded models")).tag("")
                    ForEach(Set(all.map(\.model) + analyses.analyses.map(\.forecastModel)).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker(L10n.t("Prediction timing"), selection: $capture) {
                    Text(L10n.t("All")).tag("")
                    ForEach(ForecastCapture.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Picker(L10n.t("Period"), selection: $days) {
                Text(L10n.t("Last 30 days")).tag(30)
                Text(L10n.t("Last 90 days")).tag(90)
                Text(L10n.t("All time")).tag(0)
            }
            Picker(L10n.t("Source"), selection: $source) {
                Text(L10n.t("All")).tag("")
                Text(L10n.t("Saved records")).tag("recorded")
                Text(L10n.t("Saved Codex responses")).tag("codex")
                Text(L10n.t("Paired calculation (no Codex request)")).tag("pairedCalculation")
            }
            Text("\(L10n.t("Saved analysis requests/responses")): \(savedAnalyses.count) · \(L10n.t("Saved abstentions")): \(savedAnalyses.filter { $0.response.status == .abstain }.count)").font(.caption)
            Text(L10n.t("Failed or invalid CLI attempts are not archived. Paired calculation is not a Codex request. Codex execution is available on macOS only.")).font(.caption).foregroundStyle(.secondary)
            if let error = journal.errorMessage ?? analyses.errorMessage ?? exportError { Text(error).foregroundStyle(.orange).font(.caption) }
            if let message = journal.reconciliationMessage ?? analyses.reconciliationMessage { Text(message).font(.caption) }
            if rows.isEmpty { Text(L10n.t("No saved predictions in this filter")) }
            ForEach(EvaluationSummaryView.groups(rows), id: \.id) { own in EvaluationSummaryView(rows: own.rows) }
            // Comparisons keep recording times separate even when all timing filters are selected.
            ForEach(Set(rows.map(\.capture)).sorted(), id: \.self) { capture in
                let cohort = rows.filter { $0.capture == capture }
                EvaluationComparisonView(comparison: StockEvaluation.compare(cohort, selectedModels: Set(cohort.map(\.model))))
            }
            ForEach(EvaluationSummaryView.groups(rows), id: \.id) { group in
              ForEach(group.rows, id: \.referenceID) { row in
                DisclosureGroup("\(name(row)) · \(row.stockID) · \(row.model) · \(row.actualClose == nil ? L10n.t("Pending") : L10n.t("Evaluated"))") {
                    Text("\(L10n.t("Estimated close")): \(row.expectedClose.description) · \(L10n.t("Actual close")): \(row.actualClose?.description ?? L10n.t("Pending"))").font(.caption)
                    ForEach(row.references, id: \.self) { ref in
                        Text("\(L10n.t("Reference")): \(ref.referenceID) · \(ref.source.rawValue)").font(.caption).textSelection(.enabled)
                        if let record = journal.records.first(where: { $0.id == ref.referenceID }) { ForecastEvidenceView(record: record) }
                        if let analysis = analyses.analyses.first(where: { $0.id.uuidString == ref.referenceID }) {
                            Text(analysis.response.notes).textSelection(.enabled)
                            if let record = analysis.forecastRecord { ForecastEvidenceView(record: record) }
                        }
                    }
                }
            }
            }
            ForEach(savedAnalyses.filter { $0.response.status == .abstain }) { analysis in
                DisclosureGroup("\(analysis.input.stockID) · \(analysis.model) · \(L10n.t("Abstained"))") {
                    Text("\(L10n.t("Reference")): \(analysis.id.uuidString)")
                    Text(analysis.response.notes).textSelection(.enabled)
                }
            }
            Text(L10n.t("Saved inputs and predictions never change. Actual closes are checked on a later local date when stock estimates refresh. Abstentions are saved but not scored.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.t("Export evaluation CSV")) {
                    var details: [String: String] = [:]
                    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
                    let refs = Set(rows.flatMap { $0.references.map(\.referenceID) })
                    for record in journal.records where refs.contains(record.id) { if let data = try? encoder.encode(record) { details[record.id] = String(decoding: data, as: UTF8.self) } }
                    for analysis in savedAnalyses { if let data = try? encoder.encode(analysis) { details[analysis.id.uuidString] = String(decoding: data, as: UTF8.self) } }
                    document = ForecastCSVDocument(text: EvaluationSummaryView.csv(rows: rows, details: details)); exporting = true
                }
                Button(L10n.t("Export forecast CSV")) {
                    let refs = Set(rows.flatMap { $0.references.map(\.referenceID) })
                    document = ForecastCSVDocument(text: StockForecastJournal.csv(journal.records.filter { refs.contains($0.id) })); exporting = true
                }
            }
        }
    }
    private func name(_ row: StockEvaluationRow) -> String {
        journal.records.first { row.references.contains(.init(referenceID: $0.id, source: .recorded)) }?.name ?? row.stockID
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
            Text(L10n.t("GBM's expected close equals the input price, so its MAPE equals the price-hold baseline. Lower MAPE and Brier are better; these are prediction scores, not investment returns."))
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

struct ForecastCSVDocument: FileDocument {
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
