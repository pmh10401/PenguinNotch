import SwiftUI

struct StockBacktestView: View {
    @ObservedObject var store: StockBacktestStore
    @State private var sessions = 60
    @State private var selected: UUID?
    @State private var market = ""
    @State private var stockID = ""
    @State private var day = ""
    @State private var model = ""
    @State private var loaded: [StockBacktestLoadedCase] = []
    @State private var receipts: [String: StockBacktestLoadedCase] = [:]
    @State private var loading = false
    @State private var launching = false
    @State private var message: String?
    @State private var exporting = false
    @State private var document = ForecastCSVDocument(text: "")

    private var run: StockBacktestManifest? { store.runs.first { $0.runID == selected } }
    private var active: Bool { launching || store.activeRunID != nil }
    private var loadKey: String { "\(selected?.uuidString ?? ""):\(run?.cases.description ?? "")" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Historical replay")).font(.headline)
            Text(L10n.t("Reconstructed from data fetched now; availability at the original time is not guaranteed."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.t("Adjusted inputs and target; regular close minus 60 minutes. GBM expected close equals the input price. No Codex requests are made."))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker(L10n.t("Completed trading days"), selection: $sessions) {
                    ForEach([20, 60, 120], id: \.self) { Text(String($0)).tag($0) }
                }.disabled(active)
                Button(L10n.t("Start replay")) { execute { try await store.start(symbols: store.watchedSymbols, sessions: sessions) } }
                    .disabled(active || !store.supportsReplay || store.watchedSymbols.isEmpty || store.watchedSymbols.count > 30 || store.errorMessage == "archive_unavailable")
                Button(L10n.t("Cancel")) { store.cancel() }.disabled(!active)
            }
            Text("\(L10n.t("Watched symbols (including hidden)")): \(store.watchedSymbols.count)/30 · \(store.watchedSymbols.map(\.id).joined(separator: ", "))")
                .font(.caption).textSelection(.enabled)
            if !store.supportsReplay { Text(L10n.t("Historical replay requires Toss Securities.")) }
            if store.watchedSymbols.isEmpty { Text(L10n.t("Add watched symbols before starting replay.")) }
            Text("\(L10n.t(active ? "Running" : "Idle")) · \(store.progress.completed)/\(store.progress.total)").monospacedDigit()
            if let error = message ?? store.errorMessage { Text(replayMessage(error)).foregroundStyle(.orange).font(.caption) }
            Picker(L10n.t("Replay run"), selection: $selected) {
                Text(L10n.t("Select a run")).tag(Optional<UUID>.none)
                ForEach(store.runs, id: \.runID) { run in
                    Text("\(run.runID.uuidString) · \(replayMessage(run.status.rawValue))").tag(Optional(run.runID))
                }
            }
            if let run {
                if run.status != .completed {
                    Button(L10n.t("Resume replay")) { execute { try await store.resume(runID: run.runID) } }
                        .disabled(active || !store.supportsReplay || store.errorMessage == "archive_unavailable")
                }
                HStack {
                    Picker(L10n.t("Market"), selection: $market) {
                        Text(L10n.t("All")).tag(""); Text("US").tag("us"); Text("KR").tag("kr")
                    }
                    Picker(L10n.t("Stock"), selection: $stockID) {
                        Text(L10n.t("All stocks")).tag("")
                        ForEach(run.symbols, id: \.self) { Text($0).tag($0) }
                    }
                }
                HStack {
                    Picker(L10n.t("Target day"), selection: $day) {
                        Text(L10n.t("All")).tag("")
                        ForEach(Set(run.cases.map(\.tradingDay)).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Picker(L10n.t("Model"), selection: $model) {
                        Text(L10n.t("All recorded models")).tag("")
                        ForEach(run.models, id: \.self) { Text($0).tag($0) }
                    }
                }
                if loading { ProgressView(L10n.t("Loading saved results…")) }
                results(run)
            } else { Text(L10n.t("No historical replay runs.")) }
        }
        .task(id: loadKey) {
            loaded = []; message = nil
            guard let run else { return }
            loading = true
            defer { loading = false }
            for entry in run.cases {
                guard !Task.isCancelled else { return }
                do {
                    let receipt: StockBacktestLoadedCase
                    if let cached = receipts[entry.caseID], cached.entry == entry { receipt = cached }
                    else { receipt = try await store.loadCase(runID: run.runID, caseID: entry.caseID) }
                    guard !Task.isCancelled else { return }; receipts[entry.caseID] = receipt; loaded.append(receipt)
                } catch { if !Task.isCancelled { message = "archive_unavailable" } }
            }
        }
        .onChange(of: selected) { _, _ in receipts = [:]; market = ""; stockID = ""; day = ""; model = "" }
        .onChange(of: store.runs.count) { _, _ in if selected == nil { selected = store.runs.last?.runID } }
        .onAppear { if selected == nil { selected = store.runs.last?.runID } }
        .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText,
                      defaultFilename: "PenguinNotch-replay-evaluation") { if case .failure = $0 { message = "Could not export forecast history." } }
    }

    @ViewBuilder private func results(_ run: StockBacktestManifest) -> some View {
        let models = model.isEmpty ? Set(run.models) : [model]
        if let summary = try? StockEvaluation.replaySummary(manifest: run, loaded: loaded, selectedModels: models,
            market: market.isEmpty ? nil : market, stockID: stockID.isEmpty ? nil : stockID, day: day.isEmpty ? nil : day) {
            Text("\(L10n.t("Acquired / requested")): \(summary.acquired)/\(summary.requested) · \(L10n.t("Pending")): \(summary.pending) · \(L10n.t("Skipped")): \(summary.skipped) · \(L10n.t("Unavailable")): \(summary.unavailable)")
                .font(.caption)
            ForEach(summary.models, id: \.model) { model in
                EvaluationSummaryView(rows: summary.rows.filter { $0.model == model.model })
                Text("\(model.model) · \(L10n.t("Evaluated")): \(model.success) · \(L10n.t("Skipped")): \(model.skipped) · \(L10n.t("Unavailable")): \(model.unavailable)").font(.caption)
            }
            EvaluationComparisonView(comparison: summary.comparison)
            let entries = run.cases.filter { (market.isEmpty || WatchedStock.parse($0.stockID)?.market.rawValue == market)
                && (stockID.isEmpty || $0.stockID == stockID) && (day.isEmpty || $0.tradingDay == day) }
            ForEach(entries, id: \.caseID) { entry in
                DisclosureGroup("\(entry.stockID) · \(entry.tradingDay) · \(replayMessage(entry.status.rawValue))\(entry.reason.map { " · " + replayMessage($0) } ?? "")") {
                    if let c = loaded.first(where: { $0.entry.caseID == entry.caseID }) {
                        Text("\(L10n.t("Reference")): \(c.referenceID)").font(.caption)
                        Text(c.rawDetail).font(.caption.monospaced()).textSelection(.enabled)
                    } else { Text(L10n.t("Unavailable")) }
                }
            }
            Button(L10n.t("Export evaluation CSV")) {
                let details = Dictionary(uniqueKeysWithValues: loaded.filter { c in entries.contains { $0.caseID == c.entry.caseID } }.map { ($0.referenceID, $0.rawDetail) })
                document = ForecastCSVDocument(text: EvaluationSummaryView.csv(rows: summary.rows, details: details)); exporting = true
            }.disabled(loading)
        } else { Text(replayMessage("archive_unavailable")).foregroundStyle(.orange) }
    }
    private func execute(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !active else { return }; message = nil; launching = true
        Task { defer { launching = false }; do { try await operation() } catch { message = store.errorMessage ?? "collection_failed" } }
    }
}

func replayMessage(_ key: String) -> String {
    switch key {
    case "archive_unavailable": L10n.t("History could not be read. Original records are preserved; writes are blocked.")
    case "collection_cancelled": L10n.t("Replay paused. Resume is explicit.")
    case "authentication_paused": L10n.t("Replay paused. Check the selected provider credentials.")
    case "collection_failed": L10n.t("Replay failed. Saved cases are retained.")
    case "completed": L10n.t("Completed")
    case "running": L10n.t("Running")
    case "paused": L10n.t("Paused")
    case "pending": L10n.t("Pending")
    case "saved": L10n.t("Saved")
    case "skipped": L10n.t("Skipped")
    default: key
    }
}

/// Each summary has one model, capture and logical source cohort; comparison is separate.
struct EvaluationSummaryView: View {
    let rows: [StockEvaluationRow]
    struct Cohort: Identifiable { let id: String; let rows: [StockEvaluationRow] }
    static func groups(_ rows: [StockEvaluationRow]) -> [Cohort] {
        let groups = Dictionary(grouping: rows) { "\($0.model)\u{1F}\($0.capture)\u{1F}\($0.source == .replay ? "replay" : "saved")" }
        return groups.keys.sorted().map { Cohort(id: $0, rows: groups[$0]!) }
    }
    static func csv(rows: [StockEvaluationRow], details: [String: String]) -> String {
        let groups = groups(rows)
        guard !groups.isEmpty else { return StockEvaluation.csv(rows: [], metrics: StockEvaluation.metrics([]), details: details) }
        let refs = Set(rows.flatMap { [$0.referenceID] + $0.references.map(\.referenceID) })
        var bodies = groups.map { group in
            let own = group.rows
            let ids = Set(own.flatMap { [$0.referenceID] + $0.references.map(\.referenceID) })
            return StockEvaluation.csv(rows: own, metrics: StockEvaluation.metrics(own), details: details.filter { ids.contains($0.key) })
        }
        let orphan = details.filter { !refs.contains($0.key) }
        if !orphan.isEmpty { bodies.append(StockEvaluation.csv(rows: [], metrics: StockEvaluation.metrics([]), details: orphan)) }
        return bodies.enumerated().map { index, body in index == 0 ? body : String(body.dropFirst((body.firstIndex(of: "\r\n").map { body.distance(from: body.startIndex, to: $0) } ?? 0) + 1)) }.joined()
    }
    var body: some View {
        if let row = rows.first {
            let m = StockEvaluation.metrics(rows)
            VStack(alignment: .leading, spacing: 8) {
                Text("\(row.model) · \(row.capture) · \(L10n.t(row.source == .replay ? "Historical replay" : "Saved predictions"))").font(.headline)
                Text("\(L10n.t("Evaluated / pending")): \(m.evaluated)/\(m.total - m.evaluated) · \(L10n.t("MAPE minus baseline (percentage points)")): \(number(m.mape.flatMap { error in m.baselineMAPE.map { error - $0 } })) · Brier: \(number(m.brier))").font(.caption).monospacedDigit()
                DisclosureGroup(L10n.t("Evaluation details")) {
                    LabeledContent("MAPE", value: percent(m.mape))
                    LabeledContent(L10n.t("Price-hold baseline error"), value: percent(m.baselineMAPE))
                    LabeledContent(L10n.t("Direction hit rate"), value: "\(m.directionHits)/\(m.directionCount)")
                    LabeledContent(L10n.t("80% range coverage"), value: percent(m.coverage))
                    LabeledContent(L10n.t("Mean range width"), value: percent(m.meanWidthPercent))
                    ForEach(m.maeByCurrency.keys.sorted(), id: \.self) { currency in LabeledContent("MAE \(currency)", value: number(m.maeByCurrency[currency])) }
                    Text(L10n.t("Direction excludes unchanged closes and 50% probabilities. Scores are not investment returns.")).font(.caption)
                    Text(L10n.t("Probability check")).font(.headline)
                    ForEach(StockEvaluation.calibration(rows)) { bin in
                        Text("\(bin.label): \(percent(bin.meanProbability * 100)) → \(percent(bin.observedRate * 100)) · \(bin.rises)/\(bin.count) · 95% Wilson \(percent(bin.interval.lowerBound * 100))–\(percent(bin.interval.upperBound * 100))").font(.caption)
                    }
                    Text(L10n.t("Calibration is descriptive; related stocks and dates can increase uncertainty. Ties count as not rising; 50% calls remain in calibration.")).font(.caption)
                }
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "—" }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
}

struct EvaluationComparisonView: View {
    let comparison: StockEvaluationComparison
    var body: some View {
        DisclosureGroup(L10n.t("Compare identical prediction inputs")) {
            Text("\(L10n.t("Paired samples")): \(comparison.pairedCount)")
            Text("\(L10n.t("Excluded conflicts / missing evidence")): \(comparison.excludedConflicts)/\(comparison.excludedMissingEvidence)")
            ForEach(comparison.rows, id: \.model) { row in
                Text("\(row.model) · n=\(row.paired.evaluated) · MAPE \(row.paired.mape.map { String(format: "%.2f%%", $0) } ?? "—") · Brier \(row.paired.brier.map { String(format: "%.3f", $0) } ?? "—")")
            }
            Text(L10n.t("GBM's expected close equals the input price, so its MAPE equals the price-hold baseline. Lower MAPE and Brier are better; these are prediction scores, not investment returns.")).font(.caption)
        }.font(.caption)
    }
}
