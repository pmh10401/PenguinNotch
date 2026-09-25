import Charts
import Combine
import SwiftUI

enum StockChartInterval: String, CaseIterable, Identifiable {
    case minute = "1m"
    case tenMinutes = "10m"
    case day = "1d"
    var id: String { rawValue }

    var source: StockChartInterval {
        self == .tenMinutes ? .minute : self
    }

    var refreshSeconds: TimeInterval {
        switch self {
        case .minute: return 60
        case .tenMinutes: return 600
        case .day: return 86_400
        }
    }

    var refreshLabel: String {
        switch self {
        case .minute: return L10n.t("Every minute")
        case .tenMinutes: return L10n.t("Every 10 minutes")
        case .day: return L10n.t("Every day")
        }
    }
}

@MainActor
final class StockChartStore: ObservableObject {
    struct Key: Hashable {
        let stockID: String
        let source: StockChartInterval

        init(stock: WatchedStock, interval: StockChartInterval) {
            stockID = stock.id
            source = interval.source
        }
    }

    struct Entry {
        let candles: [StockCandle]
        let fetchedAt: Date
    }

    typealias Fetch = (WatchedStock, StockChartInterval) async throws -> [StockCandle]
    @Published private(set) var entries: [Key: Entry] = [:]
    @Published private(set) var loading: Set<Key> = []
    @Published private(set) var failed: Set<Key> = []
    private var attemptedAt: [Key: Date] = [:]
    private var tasks: [Key: Task<Void, Never>] = [:]
    private let fetchOverride: Fetch?
    private var token: TossInvestAPI.AccessToken?
    private var tokenTask: Task<TossInvestAPI.AccessToken, Error>?
    private var settingsRevision = 0

    init(fetch: Fetch? = nil) {
        fetchOverride = fetch
    }

    private func fetchLive(_ stock: WatchedStock, _ interval: StockChartInterval) async throws -> [StockCandle] {
        let token = try await accessToken()
        try Task.checkCancellation()
        return try await TossInvestAPI.chartCandles(token: token.value, stock: stock, interval: interval)
    }

    private func accessToken() async throws -> TossInvestAPI.AccessToken {
        if let token, token.expiresAt > Date() { return token }
        if let tokenTask { return try await tokenTask.value }
        let credentials = TossCredentials.load()
        guard !credentials.clientID.isEmpty, !credentials.clientSecret.isEmpty else {
            throw TossInvestAPI.Failure.invalidResponse
        }
        let revision = settingsRevision
        let task = Task {
            try await TossInvestAPI.accessToken(clientID: credentials.clientID,
                                                clientSecret: credentials.clientSecret)
        }
        tokenTask = task
        defer { if settingsRevision == revision { tokenTask = nil } }
        let token = try await task.value
        if settingsRevision == revision { self.token = token }
        return token
    }

    func secondsUntilRefresh(stock: WatchedStock, interval: StockChartInterval, now: Date = Date()) -> TimeInterval {
        let key = Key(stock: stock, interval: interval)
        guard let attempted = attemptedAt[key] else { return 0 }
        let elapsed = now.timeIntervalSince(attempted)
        guard elapsed >= 0 else { return 0 }
        let refreshSeconds = failed.contains(key) ? min(interval.refreshSeconds, 600) : interval.refreshSeconds
        return max(0, refreshSeconds - elapsed)
    }

    func load(stock: WatchedStock, interval: StockChartInterval, now: Date = Date(),
              settingsRevision revision: Int = 0) async {
        if revision != settingsRevision {
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            entries.removeAll()
            loading.removeAll()
            failed.removeAll()
            attemptedAt.removeAll()
            token = nil
            tokenTask?.cancel()
            tokenTask = nil
            settingsRevision = revision
        }
        let key = Key(stock: stock, interval: interval)
        if let task = tasks[key] { await task.value; return }
        if secondsUntilRefresh(stock: stock, interval: interval, now: now) > 0 { return }

        attemptedAt[key] = now
        loading.insert(key)
        failed.remove(key)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if settingsRevision == revision {
                    loading.remove(key)
                    tasks[key] = nil
                }
            }
            do {
                let candles: [StockCandle]
                if let fetchOverride {
                    candles = try await fetchOverride(stock, key.source)
                } else {
                    candles = try await fetchLive(stock, key.source)
                }
                if settingsRevision == revision { entries[key] = Entry(candles: candles, fetchedAt: now) }
            } catch {
                if settingsRevision == revision { failed.insert(key) }
            }
        }
        tasks[key] = task
        await task.value
    }
}

struct StockChartSection: View {
    @ObservedObject var store: StockChartStore
    @ObservedObject var preferences: Preferences
    let stock: WatchedStock
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private var key: StockChartStore.Key {
        StockChartStore.Key(stock: stock, interval: preferences.stockChartInterval)
    }

    private var candles: [StockCandle] {
        let source = store.entries[key]?.candles ?? []
        let displayed = preferences.stockChartInterval == .tenMinutes
            ? StockQuoteCodec.tenMinuteCandles(from: source) : source
        return Array(displayed.suffix(preferences.stockChartCount))
    }

    private var needsTossKeys: Bool {
        guard stock.market == .us, preferences.usStockSource == .finnhub else { return false }
        let credentials = TossCredentials.load()
        return credentials.clientID.isEmpty || credentials.clientSecret.isEmpty
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
                if needsTossKeys {
                    Text(L10n.t("Candlestick charts require Toss Securities API keys."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(secondaryInk)
                } else if candles.isEmpty {
                    Group {
                        if store.loading.contains(key) { ProgressView().controlSize(.small) }
                        else {
                            let unavailable = store.failed.contains(key)
                            Text(L10n.t(unavailable ? "Chart unavailable" : "No recent candles"))
                        }
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
            Text(store.entries[key].map {
                "\(L10n.t("Updated")) \($0.fetchedAt.formatted(date: .omitted, time: .shortened)) · \(preferences.stockChartInterval.refreshLabel)"
            } ?? preferences.stockChartInterval.refreshLabel)
                .font(.system(size: 10)).foregroundStyle(secondaryInk).lineLimit(1)
        }
        .padding(.top, NotchLayout.blockSpacing)
        .frame(height: NotchLayout.stockChartSectionHeight, alignment: .top)
        .task(id: "\(stock.id):\(preferences.stockChartInterval.rawValue):\(preferences.stockSettingsRevision)") {
            if needsTossKeys { return }
            while !Task.isCancelled {
                let interval = preferences.stockChartInterval
                await store.load(stock: stock, interval: interval,
                                 settingsRevision: preferences.stockSettingsRevision)
                let wait = store.secondsUntilRefresh(stock: stock, interval: interval)
                do { try await Task.sleep(for: .seconds(max(wait, 1))) }
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
