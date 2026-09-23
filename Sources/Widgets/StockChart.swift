import Charts
import Combine
import SwiftUI

enum StockChartInterval: String, CaseIterable, Identifiable {
    case minute = "1m"
    case tenMinutes = "10m"
    case day = "1d"
    var id: String { rawValue }
}

struct StockChartData {
    let minutes: [StockCandle]
    let tenMinutes: [StockCandle]
    let days: [StockCandle]

    func candles(for interval: StockChartInterval) -> [StockCandle] {
        switch interval {
        case .minute: return minutes
        case .tenMinutes: return tenMinutes
        case .day: return days
        }
    }
}

@MainActor
final class StockChartStore: ObservableObject {
    struct Entry {
        let data: StockChartData
        let fetchedAt: Date
    }

    typealias Fetch = (WatchedStock) async throws -> StockChartData
    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var failed: Set<String> = []
    private var attemptedAt: [String: Date] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let fetch: Fetch

    init(fetch: @escaping Fetch = { stock in
        let credentials = TossCredentials.load()
        guard !credentials.clientID.isEmpty, !credentials.clientSecret.isEmpty else {
            throw TossInvestAPI.Failure.invalidResponse
        }
        let token = try await TossInvestAPI.accessToken(clientID: credentials.clientID,
                                                         clientSecret: credentials.clientSecret)
        return try await TossInvestAPI.chartCandles(token: token.value, stock: stock)
    }) {
        self.fetch = fetch
    }

    func load(stock: WatchedStock, now: Date = Date()) async {
        let id = stock.id
        if let task = tasks[id] { await task.value; return }
        if let attempted = attemptedAt[id], (0..<600).contains(now.timeIntervalSince(attempted)) { return }

        attemptedAt[id] = now
        loading.insert(id)
        failed.remove(id)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { loading.remove(id); tasks[id] = nil }
            do {
                let data = try await fetch(stock)
                entries[id] = Entry(data: data, fetchedAt: now)
            } catch {
                failed.insert(id)
            }
        }
        tasks[id] = task
        await task.value
    }
}

struct StockChartSection: View {
    @ObservedObject var store: StockChartStore
    @ObservedObject var preferences: Preferences
    let stock: WatchedStock
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private var candles: [StockCandle] {
        Array((store.entries[stock.id]?.data.candles(for: preferences.stockChartInterval) ?? [])
            .suffix(preferences.stockChartCount))
    }

    static func priceDomain(for candles: [StockCandle]) -> ClosedRange<Double> {
        let low = candles.map { NSDecimalNumber(decimal: $0.low).doubleValue }.min() ?? 0
        let high = candles.map { NSDecimalNumber(decimal: $0.high).doubleValue }.max() ?? 0
        let padding = max((high - low) * 0.08, max(abs(high) * 0.005, 0.00000001))
        return (low - padding)...(high + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.px(12)) {
            Rectangle().fill(Palette.textSecondary.opacity(0.35)).frame(height: NotchLayout.hairline)
            HStack {
                Text(L10n.t("Stock chart"))
                    .font(Typography.cardBody).fontWeight(.semibold)
                Spacer()
                Text("\(candles.count)/\(preferences.stockChartCount)")
                    .font(Typography.cardBody).foregroundStyle(secondaryInk)
            }
            Picker(L10n.t("Chart interval"), selection: $preferences.stockChartInterval) {
                ForEach(StockChartInterval.allCases) { interval in
                    Text(interval.rawValue).tag(interval)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                if candles.isEmpty {
                    Group {
                        if store.loading.contains(stock.id) { ProgressView().controlSize(.small) }
                        else { Text(L10n.t(store.failed.contains(stock.id) ? "Chart unavailable" : "No recent candles")) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(secondaryInk)
                } else {
                    Chart {
                        ForEach(candles.indices, id: \.self) { index in
                            let candle = candles[index]
                            let rising = candle.close >= candle.open
                            let color: Color = stock.market == .kr
                                ? (rising ? .red : .blue) : (rising ? .green : .red)
                            RuleMark(x: .value("Bar", index),
                                     yStart: .value("Low", NSDecimalNumber(decimal: candle.low).doubleValue),
                                     yEnd: .value("High", NSDecimalNumber(decimal: candle.high).doubleValue))
                                .foregroundStyle(color)
                            RectangleMark(x: .value("Bar", index),
                                          yStart: .value("Open", NSDecimalNumber(decimal: min(candle.open, candle.close)).doubleValue),
                                          yEnd: .value("Close", NSDecimalNumber(decimal: max(candle.open, candle.close)).doubleValue),
                                          width: .ratio(0.65))
                                .foregroundStyle(color)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: candles.count > 1 ? [0, candles.count - 1] : [0]) { axis in
                            AxisValueLabel {
                                if let index = axis.as(Int.self), candles.indices.contains(index) {
                                    Text(axisLabel(candles[index].end))
                                }
                            }
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                    .chartYScale(domain: Self.priceDomain(for: candles))
                }
            }
            .frame(height: NotchLayout.stockChartPlotHeight)
            Text(store.entries[stock.id].map {
                "\(L10n.t("Updated")) \($0.fetchedAt.formatted(date: .omitted, time: .shortened)) · \(L10n.t("Every 10 minutes"))"
            } ?? L10n.t("Each stock refreshes every 10 minutes"))
                .font(.system(size: 10)).foregroundStyle(secondaryInk).lineLimit(1)
        }
        .padding(.top, NotchLayout.blockSpacing)
        .frame(height: NotchLayout.stockChartSectionHeight, alignment: .top)
        .task(id: stock.id) {
            while !Task.isCancelled {
                await store.load(stock: stock)
                do { try await Task.sleep(for: .seconds(600)) }
                catch { return }
            }
        }
    }

    private func axisLabel(_ date: Date) -> String {
        if preferences.stockChartInterval == .day {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.hour().minute())
    }
}
