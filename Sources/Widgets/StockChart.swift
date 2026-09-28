import Charts
import Combine
import SwiftUI

enum StockChartInterval: String, CaseIterable, Identifiable {
    case minute = "1m"
    case tenMinutes = "10m"
    case day = "1d"
    var id: String { rawValue }

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
        let interval: StockChartInterval

        init(stock: WatchedStock, interval: StockChartInterval) {
            stockID = stock.id
            self.interval = interval
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
    private var settingsRevision = 0
    private var quoteSource: StockQuoteSource = .toss

    init(fetch: Fetch? = nil) {
        fetchOverride = fetch
    }

    private func fetchLive(_ stock: WatchedStock, _ interval: StockChartInterval) async throws -> [StockCandle] {
        let credentials = TossCredentials.load()
        guard !credentials.clientID.isEmpty, !credentials.clientSecret.isEmpty else {
            throw TossInvestAPI.Failure.invalidResponse
        }
        let token = try await TossInvestAPI.accessToken(clientID: credentials.clientID,
                                                         clientSecret: credentials.clientSecret)
        try Task.checkCancellation()
        do {
            return try await TossInvestAPI.chartCandles(token: token.value, stock: stock, interval: interval)
        } catch TossInvestAPI.Failure.http(401) {
            let renewed = try await TossInvestAPI.accessToken(clientID: credentials.clientID,
                                                               clientSecret: credentials.clientSecret)
            try Task.checkCancellation()
            return try await TossInvestAPI.chartCandles(token: renewed.value, stock: stock, interval: interval)
        }
    }

    func secondsUntilRefresh(stock: WatchedStock, interval: StockChartInterval, now: Date = Date()) -> TimeInterval {
        let key = Key(stock: stock, interval: interval)
        guard let attempted = attemptedAt[key] else { return 0 }
        let elapsed = now.timeIntervalSince(attempted)
        guard elapsed >= 0 else { return 0 }
        let refreshSeconds = failed.contains(key) ? min(interval.refreshSeconds, 600) : interval.refreshSeconds
        return max(0, refreshSeconds - elapsed)
    }

    func configure(source: StockQuoteSource, settingsRevision revision: Int) {
        if revision != settingsRevision || source != quoteSource {
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            entries.removeAll()
            loading.removeAll()
            failed.removeAll()
            attemptedAt.removeAll()
            settingsRevision = revision
            quoteSource = source
        }
    }

    func load(stock: WatchedStock, interval: StockChartInterval, now: Date = Date(),
              settingsRevision revision: Int = 0, source: StockQuoteSource = .toss) async {
        configure(source: source, settingsRevision: revision)
        guard source == .toss else { return }
        let key = Key(stock: stock, interval: interval)
        if let task = tasks[key] { await task.value; return }
        if secondsUntilRefresh(stock: stock, interval: interval, now: now) > 0 { return }

        attemptedAt[key] = now
        loading.insert(key)
        failed.remove(key)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if settingsRevision == revision, !Task.isCancelled {
                    loading.remove(key)
                    tasks[key] = nil
                }
            }
            do {
                let candles: [StockCandle]
                if let fetchOverride {
                    candles = try await fetchOverride(stock, key.interval)
                } else {
                    candles = try await fetchLive(stock, key.interval)
                }
                if settingsRevision == revision, !Task.isCancelled { entries[key] = Entry(candles: candles, fetchedAt: now) }
            } catch {
                if settingsRevision == revision, !Task.isCancelled { failed.insert(key) }
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
    @ObservedObject var portfolio: StockForecastStore = .shared
    @State private var forecastObserver = UUID()
    @State private var showsCodexAnalysis = false
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private var key: StockChartStore.Key {
        StockChartStore.Key(stock: stock, interval: preferences.stockChartInterval)
    }

    private var history: [StockCandle] {
        let source = store.entries[key]?.candles ?? []
        return preferences.stockChartInterval == .tenMinutes
            ? StockQuoteCodec.tenMinuteCandles(from: source) : source
    }

    private var chartsAvailable: Bool { preferences.stockQuoteSource == .toss }

    static func priceDomain(for candles: [StockCandle]) -> ClosedRange<Double> {
        let prices = candles.flatMap { [NSDecimalNumber(decimal: $0.low).doubleValue,
                                       NSDecimalNumber(decimal: $0.high).doubleValue] }
            .filter { $0.isFinite && $0 > 0 }
        guard let low = prices.min(), let high = prices.max() else { return 0...1 }
        // A price-relative margin overwhelms quiet minute bars. Use it only for a flat range.
        let padding = high > low ? max((high - low) * 0.08, high.ulp * 8)
            : max(high * 0.0005, 0.00000001)
        return max(0, low - padding)...(high + padding)
    }

    var body: some View {
        let history = history
        let candles = Array(history.suffix(preferences.stockChartCount))
        let averages = Dictionary(uniqueKeysWithValues: preferences.stockMovingAveragePeriods.map { period in
            (period, Array(StockQuoteCodec.movingAverages(for: history, period: period).suffix(candles.count)))
        })
        VStack(alignment: .leading, spacing: Design.px(12)) {
            Rectangle().fill(Palette.textSecondary.opacity(0.35)).frame(height: NotchLayout.hairline)
            HStack {
                Text(L10n.t("Stock chart"))
                    .font(Typography.cardBody).fontWeight(.semibold)
                Spacer()
                Text(chartsAvailable ? "\(candles.count)/\(preferences.stockChartCount)" : "—")
                    .font(Typography.cardBody).foregroundStyle(secondaryInk)
            }
            Picker(L10n.t("Chart interval"), selection: $preferences.stockChartInterval) {
                ForEach(StockChartInterval.allCases) { interval in
                    Text(interval.rawValue).tag(interval)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!chartsAvailable)
            HStack(spacing: 8) {
                Text("SMA").foregroundStyle(secondaryInk)
                ForEach(preferences.stockMovingAveragePeriods, id: \.self) { period in
                    let available = averages[period]?.last.flatMap { $0 } != nil
                    Text("\(period)\(available ? "" : " —")")
                        .foregroundStyle(Self.averageColor(period))
                        .help(L10n.t(available
                            ? "The price axis fits visible candles. Moving averages outside this range are clipped."
                            : "A dash means there are not enough candles for this moving average."))
                }
                if preferences.stockMovingAveragePeriods.isEmpty {
                    Text(L10n.t("Off")).foregroundStyle(secondaryInk)
                }
            }
            .font(.system(size: 10, weight: .medium))
            Group {
                if !chartsAvailable {
                    Text(L10n.t("Candlestick charts are not available with Finnhub."))
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
                                .lineStyle(StrokeStyle(lineWidth: 1))
                            if candle.open == candle.close {
                                PointMark(x: .value("Bar", index),
                                          y: .value("Price", NSDecimalNumber(decimal: candle.close).doubleValue))
                                    .symbol { Rectangle().fill(color).frame(width: 5, height: 1) }
                            } else {
                                // A ratio width collapses on this continuous, unbinned X axis.
                                RectangleMark(x: .value("Bar", index),
                                              yStart: .value("Open", NSDecimalNumber(decimal: min(candle.open, candle.close)).doubleValue),
                                              yEnd: .value("Close", NSDecimalNumber(decimal: max(candle.open, candle.close)).doubleValue),
                                              width: .fixed(5))
                                    .foregroundStyle(color)
                            }
                        }
                        ForEach(preferences.stockMovingAveragePeriods, id: \.self) { period in
                            ForEach(candles.indices, id: \.self) { index in
                                if let value = averages[period]?[index] {
                                    LineMark(x: .value("Bar", index), y: .value("SMA", value),
                                             series: .value("Period", period))
                                        .foregroundStyle(Self.averageColor(period))
                                        .lineStyle(StrokeStyle(lineWidth: 1.3))
                                        .symbol(.circle).symbolSize(3)
                                        .accessibilityLabel("SMA \(period)")
                                        .accessibilityValue(value.formatted(.number.precision(.fractionLength(2))))
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: candles.count > 1 ? [0, candles.count - 1] : [0]) { axis in
                            AxisValueLabel(anchor: axis.as(Int.self) == 0 ? .topLeading : .topTrailing) {
                                if let index = axis.as(Int.self), candles.indices.contains(index) {
                                    Text(axisLabel(candles[index].end))
                                }
                            }
                        }
                    }
                    .chartXScale(domain: -0.5...(Double(candles.count) - 0.5))
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                    .chartYScale(domain: Self.priceDomain(for: candles))
                    .chartPlotStyle { plot in plot.clipped() }
                }
            }
            .frame(height: NotchLayout.stockChartPlotHeight)
            Text(!chartsAvailable ? "" : store.entries[key].map {
                "\(L10n.t("Updated")) \($0.fetchedAt.formatted(date: .omitted, time: .shortened)) · \(preferences.stockChartInterval.refreshLabel)"
            } ?? preferences.stockChartInterval.refreshLabel)
                .font(.system(size: 10)).foregroundStyle(secondaryInk).lineLimit(1)
        }
        .padding(.top, NotchLayout.blockSpacing)
        .frame(height: NotchLayout.stockChartSectionHeight, alignment: .top)
        .task(id: "\(stock.id):\(preferences.stockChartInterval.rawValue):\(preferences.stockSettingsRevision)") {
            while !Task.isCancelled {
                let interval = preferences.stockChartInterval
                await store.load(stock: stock, interval: interval,
                                 settingsRevision: preferences.stockSettingsRevision, source: preferences.stockQuoteSource)
                guard chartsAvailable else { return }
                let wait = store.secondsUntilRefresh(stock: stock, interval: interval)
                do { try await Task.sleep(for: .seconds(max(wait, 1))) }
                catch { return }
            }
        }
        if preferences.portfolioForecastEnabled || preferences.showsStockTimingSignals {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    if preferences.portfolioForecastEnabled {
                        forecastSection(now: context.date)
                            .frame(height: NotchLayout.stockForecastSectionHeight, alignment: .top)
                    }
                    if preferences.showsStockTimingSignals {
                        timingSection(now: context.date)
                            .frame(height: NotchLayout.stockTimingSectionHeight, alignment: .top)
                    }
                }
            }
            .onAppear { portfolio.setChartVisible(true, observer: forecastObserver) }
            .onDisappear { portfolio.setChartVisible(false, observer: forecastObserver) }
        }

    }

    @ViewBuilder
    func forecastSection(now: Date) -> some View {
        let record = preferences.stockQuoteSource == .toss
            ? portfolio.candidates.first { $0.stockID == stock.id } : nil
        let estimate = record.flatMap {
            StockForecast.chartEstimate(record: $0, minutes: store.entries[key]?.candles ?? [],
                                        interval: preferences.stockChartInterval, now: now)
        }
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            HStack {
                Text(showsCodexAnalysis ? L10n.t("Codex · daily inputs")
                     : "\(L10n.t("Today's regular close")) · \(preferences.stockChartInterval.rawValue)")
                    .font(Typography.cardBody).fontWeight(.semibold)
                Spacer(minLength: 2)
                Button(showsCodexAnalysis ? "GBM" : "Codex") { showsCodexAnalysis.toggle() }
                    .controlSize(.mini)
                    .accessibilityLabel(L10n.t(showsCodexAnalysis ? "Show GBM estimate" : "Show Codex analysis"))
            }
            if showsCodexAnalysis {
                ScrollView {
                    StockCodexAnalysisView(stockID: stock.id, input: record, compact: true)
                }
            } else if let estimate, let record {
                Text("\(L10n.t("Estimated close")): \(StockQuoteCodec.format(price: estimate.expectedClose, currency: record.currency, locale: .current))")
                    .font(Typography.cardBody)
                Text("\(L10n.t("Rise")) ≈\(Int((estimate.riseProbability * 100).rounded()))% · \(L10n.t("Fall")) ≈\(Int(((1 - estimate.riseProbability) * 100).rounded()))%")
                    .font(Typography.cardBody)
                Text("\(L10n.t("Model 80% range")): \(StockQuoteCodec.format(price: estimate.lowerClose, currency: record.currency, locale: .current)) – \(StockQuoteCodec.format(price: estimate.upperClose, currency: record.currency, locale: .current))")
                    .font(.system(size: 10))
                Text("\(record.sessionEnd.formatted(date: .omitted, time: .shortened)) \(TimeZone.current.abbreviation(for: record.sessionEnd) ?? "") · \(estimate.observations) \(L10n.t("Returns used"))")
                    .font(.system(size: 10))
                Text(L10n.t("Uncalibrated GBM: expected close equals the quote; odds are versus the previous close."))
                    .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(forecastReason(record: record, now: now))
                    .font(Typography.cardBody).fixedSize(horizontal: false, vertical: true)
            }
            if !showsCodexAnalysis { closeHistoryChart(now: now) }
        }
        .foregroundStyle(secondaryInk)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    func closeHistoryChart(now: Date) -> some View {
        let points = portfolio.closeHistory(for: stock, now: now)
        var segments: [Date] = []
        var segment = points.first?.createdAt ?? now
        for index in points.indices {
            if index > 0, points[index].createdAt.timeIntervalSince(points[index - 1].createdAt) > 180 {
                segment = points[index].createdAt
            }
            segments.append(segment)
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("Close estimate history · daily GBM")).font(.system(size: 10, weight: .semibold))
            if points.isEmpty {
                Text(L10n.t("Waiting for today's first estimate. Past values are not reconstructed."))
                    .font(.system(size: 10)).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            } else {
                Chart {
                    ForEach(points.indices, id: \.self) { index in
                        let point = points[index]
                        let price = NSDecimalNumber(decimal: point.expectedClose).doubleValue
                        LineMark(x: .value("Time", point.createdAt), y: .value("Estimated close", price),
                                 series: .value("Observed segment", segments[index]))
                            .foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth: 1.5))
                        PointMark(x: .value("Time", point.createdAt), y: .value("Estimated close", price))
                            .foregroundStyle(.cyan).symbolSize(10)
                            .accessibilityLabel(point.createdAt.formatted(date: .omitted, time: .shortened))
                            .accessibilityValue(StockQuoteCodec.format(price: point.expectedClose, currency: point.currency, locale: .current))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) {
                    AxisValueLabel(format: .dateTime.hour().minute())
                } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 70)
            }
            Text(portfolio.closeHistoryError
                 ?? L10n.t("Saved locally · today's minute samples · GBM estimate equals the quote"))
                .foregroundStyle(portfolio.closeHistoryError == nil ? secondaryInk : .orange)
                .font(.system(size: 9)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(secondaryInk)
    }

    @ViewBuilder
    func timingSection(now: Date) -> some View {
        let record = portfolio.candidates.first { $0.stockID == stock.id }
        let signal = store.entries[key].flatMap { entry in
            StockTimingSignal.evaluate(candles: entry.candles, interval: preferences.stockChartInterval,
                                       market: stock.market, record: record, fetchedAt: entry.fetchedAt, now: now)
        }
        let currency = stock.market == .kr ? "KRW" : "USD"
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text("\(L10n.t("Technical analysis")) · \(preferences.stockChartInterval.rawValue)")
                .font(Typography.cardBody).fontWeight(.semibold)
            if let signal {
                Text(L10n.t(signal.action == .buy
                    ? (signal.isLiveConfirmed ? "Consider buying" : "Bullish pattern · completed bars")
                    : signal.action == .sell
                    ? (signal.isLiveConfirmed ? "Consider selling" : "Bearish pattern · completed bars")
                    : "Wait · conditions do not agree"))
                    .font(Typography.cardBody).fontWeight(.semibold)
                    .foregroundStyle(signal.action == .buy ? Color.green : signal.action == .sell ? Color.orange : secondaryInk)
                Text("\(L10n.t("Volume / prior 10 bars")): \(signal.volumeRatio.formatted(.number.precision(.fractionLength(2))))× · SMA5 \(signal.fastAverage > signal.slowAverage ? ">" : signal.fastAverage < signal.slowAverage ? "<" : "=") SMA20")
                Text("SMA 5 / 20: \(StockQuoteCodec.format(price: Decimal(signal.fastAverage), currency: currency, locale: .current)) / \(StockQuoteCodec.format(price: Decimal(signal.slowAverage), currency: currency, locale: .current))")
                Text("\(L10n.t("Prior 10-bar high / low")): \(StockQuoteCodec.format(price: signal.resistance, currency: currency, locale: .current)) / \(StockQuoteCodec.format(price: signal.support, currency: currency, locale: .current))")
                Text("\(L10n.t("20-bar window")): \(signal.firstCandleAt.formatted(date: .abbreviated, time: .omitted)) – \(signal.candleAt.formatted(date: .abbreviated, time: .shortened))")
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t(signal.isLiveConfirmed
                    ? "Current regular-session price confirms the pattern. Not backtested."
                    : "Completed-bar analysis; no live price confirmation. Not backtested."))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.t(store.loading.contains(key) ? "Loading chart history…"
                    : "Analysis needs a fresh chart download and 20 complete bars with valid volume. Gaps within a trading day break the window."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 10)).foregroundStyle(secondaryInk)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    private func forecastReason(record: StockForecastRecord?, now: Date) -> String {
        if preferences.stockQuoteSource != .toss { return L10n.t("Close estimates require Toss Securities market data.") }
        if portfolio.loading && record == nil { return L10n.t("Loading estimates…") }
        if let message = portfolio.message { return message }
        if let reason = portfolio.reasons[stock.id] { return reason }
        guard let record else { return L10n.t("Add this stock to your watchlist to view estimates.") }
        if now >= record.sessionEnd { return L10n.t("Close estimates run during the regular session only. Extended-hours trading is separate.") }
        if now.timeIntervalSince(record.quoteAt) > 120 { return L10n.t("No recent trade price is available.") }
        return L10n.t("Waiting for at least 10 complete, consecutive regular-session bar returns and fresh candles.")
    }

    static func averageColor(_ period: Int) -> Color {
        switch period {
        case 5: return .yellow
        case 20: return .cyan
        case 60: return .purple
        default: return .orange
        }
    }

    private func axisLabel(_ date: Date) -> String {
        if preferences.stockChartInterval == .day {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.hour().minute())
    }
}
