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
    @ObservedObject var store: StockCodexAnalysisStore
    @ObservedObject var journal: StockForecastJournal
    @ObservedObject var backtests: StockBacktestStore
    var body: some View {
        StockForecastHistoryView(journal: journal, analyses: store,
            backtests: backtests, initialCodexFilter: true)
    }
}
