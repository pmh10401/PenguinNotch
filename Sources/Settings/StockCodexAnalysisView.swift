import SwiftUI

/// Both surfaces use the same manual action; merely opening a view never calls Codex.
struct StockCodexAnalysisView: View {
    let stockID: String
    let input: StockForecastRecord?
    var compact = false
    @ObservedObject var store: StockCodexAnalysisStore = .shared

    var body: some View {
        let latest = store.latest(stockID: stockID)
        let savedForSession = input.map { candidate in
            store.records.contains { $0.stockID == stockID && $0.sessionStart == candidate.sessionStart }
        } ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(L10n.t("Analyze with Codex")) {
                    guard let input else { return }
                    store.startAnalysis(input: input)
                }
                .disabled(input == nil || store.loadingStockID != nil || savedForSession)
                if store.loadingStockID == stockID {
                    ProgressView().controlSize(.small)
                    Button(L10n.t("Cancel")) { store.cancelAnalysis() }
                }
            }
            if let latest {
                Text("\(latest.model) · \(latest.completedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).lineLimit(compact ? 1 : nil)
                if let record = latest.forecastRecord {
                    Text("\(L10n.t("Estimated close")): \(price(record.expectedClose, record.currency)) · \(L10n.t("Rise")) ≈\(Int((record.riseProbability * 100).rounded()))%")
                        .font(.caption).monospacedDigit()
                    Text("\(L10n.t("Model 80% range")): \(price(record.lowerClose, record.currency)) – \(price(record.upperClose, record.currency))")
                        .font(.caption2).monospacedDigit()
                } else {
                    Text(L10n.t("Codex abstained from predicting.")).font(.caption)
                }
                Text(latest.response.notes).font(.caption2).lineLimit(compact ? 3 : nil)
            } else {
                Text(L10n.t("Manual analysis sends this symbol, quote and completed daily closes to Codex. It uses your signed-in Codex allowance."))
                    .font(.caption2).fixedSize(horizontal: false, vertical: true)
            }
            if savedForSession {
                Text(L10n.t("Saved for this trading day. The original prediction will not be replaced."))
                    .font(.caption2)
            } else if input == nil, store.loadingStockID != stockID {
                Text(L10n.t("A fresh regular-session quote and daily history are required."))
                    .font(.caption2)
            }
            if let message = store.errorMessage {
                Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(compact ? 3 : nil)
            }
        }
        .controlSize(compact ? .mini : .small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func price(_ value: Decimal, _ currency: String) -> String {
        StockQuoteCodec.format(price: value, currency: currency, locale: .current)
    }
}

struct StockCodexHistoryView: View {
    @ObservedObject var store: StockCodexAnalysisStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var model = ""

    private var analyses: [StockCodexAnalysis] {
        store.analyses.filter { model.isEmpty || $0.model == model }.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("Codex analysis history")).font(.title2.bold())
                Spacer()
                Button(L10n.t("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker(L10n.t("Model"), selection: $model) {
                Text(L10n.t("All recorded models")).tag("")
                ForEach(Set(store.analyses.map(\.model)).sorted(), id: \.self) { Text($0).tag($0) }
            }
            Text(L10n.t("Saved inputs and predictions never change. Actual closes are checked on a later local date when stock estimates refresh. Abstentions are saved but not scored."))
                .font(.caption).foregroundStyle(.secondary)
            if let message = store.errorMessage ?? store.reconciliationMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForecastComparisonView(records: analyses.flatMap {
                        [$0.forecastRecord, $0.pairedGBMRecord].compactMap { $0 }
                    })
                    ForEach(analyses) { analysis in
                        DisclosureGroup {
                            Text(analysis.response.notes).textSelection(.enabled)
                            if let record = analysis.forecastRecord {
                                LabeledContent(L10n.t("Estimated close"), value: price(record.expectedClose, record.currency))
                                LabeledContent(L10n.t("Actual close"), value: record.actualClose.map {
                                    price($0, record.currency)
                                } ?? L10n.t("Pending daily close"))
                                LabeledContent(L10n.t("Direction"), value: record.directionHit.map {
                                    L10n.t($0 ? "Direction matched" : "Direction missed")
                                } ?? L10n.t("No direction score"))
                                ForecastEvidenceView(record: record)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(analysis.input.stockID) · \(analysis.model)").font(.headline)
                                Text("\(analysis.completedAt.formatted(date: .abbreviated, time: .shortened)) · \(L10n.t(analysis.response.status == .abstain ? "Abstained" : "Saved manually"))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(20).frame(minWidth: 740, idealWidth: 840, minHeight: 560)
    }

    private func price(_ value: Decimal, _ currency: String) -> String {
        StockQuoteCodec.format(price: value, currency: currency, locale: .current)
    }
}
