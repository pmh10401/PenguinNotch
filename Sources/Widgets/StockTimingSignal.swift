import Foundation

/// A fixed, unvalidated confirmation rule. These labels are not probabilities or orders.
struct StockTimingSignal {
    enum Action: Equatable { case buy, sell, wait }
    let action: Action
    let volumeRatio: Double
    let fastAverage: Double
    let slowAverage: Double
    let resistance: Decimal
    let support: Decimal
    let firstCandleAt: Date
    let candleAt: Date
    let isLiveConfirmed: Bool

    static func evaluate(candles: [StockCandle], interval: StockChartInterval,
                         market: WatchedStock.Market, record: StockForecastRecord? = nil,
                         fetchedAt: Date, now: Date) -> Self? {
        guard fetchedAt <= now, now.timeIntervalSince(fetchedAt) <= interval.refreshSeconds + 120,
              !candles.isEmpty,
              candles.allSatisfy({ bar in
                  [bar.open, bar.high, bar.low, bar.close, bar.volume].allSatisfy {
                      NSDecimalNumber(decimal: $0).doubleValue.isFinite
                  } && bar.end.timeIntervalSince1970.isFinite && bar.low > 0 && bar.volume >= 0
                      && bar.high >= max(bar.open, bar.close) && bar.low <= min(bar.open, bar.close)
              }), Set(candles.map(\.end)).count == candles.count else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = StockQuoteCodec.timeZone(for: market)
        var bars: [StockCandle]
        if interval == .day {
            // A daily candle carries its local trading date, not its closing time.
            let today = calendar.startOfDay(for: min(now, fetchedAt))
            bars = candles.filter { calendar.startOfDay(for: $0.end) < today }.sorted { $0.end < $1.end }
        } else {
            bars = StockQuoteCodec.completedIntradayBars(candles, through: min(now, fetchedAt), interval: interval)
            let seconds: TimeInterval = interval == .minute ? 60 : 600
            // Count observed bars across trading days, without inventing overnight/weekend bars.
            // Missing bars within one local date still break the analysis window.
            if bars.count > 1, let gap = (1..<bars.count).last(where: {
                calendar.isDate(bars[$0].end, inSameDayAs: bars[$0 - 1].end)
                    && abs(bars[$0].end.timeIntervalSince(bars[$0 - 1].end) - seconds) > 0.01
            }) { bars = Array(bars[gap...]) }
        }
        guard bars.count >= 20, let last = bars.last else { return nil }
        bars = Array(bars.suffix(20))
        let prior = Array(bars.dropLast().suffix(10))
        let averageVolume = prior.reduce(0.0) { $0 + NSDecimalNumber(decimal: $1.volume).doubleValue } / 10
        guard averageVolume.isFinite, averageVolume > 0 else { return nil }
        let ratio = NSDecimalNumber(decimal: last.volume).doubleValue / averageVolume
        guard let fast = StockQuoteCodec.movingAverages(for: bars, period: 5).last.flatMap({ $0 }),
              let slow = StockQuoteCodec.movingAverages(for: bars, period: 20).last.flatMap({ $0 }),
              ratio.isFinite,
              let high = prior.map(\.high).max(), let low = prior.map(\.low).min() else { return nil }
        let action: Action
        if ratio >= 1.5 && fast > slow && last.close > high && last.close > last.open {
            action = .buy
        } else if ratio >= 1.5 && fast < slow && last.close < low && last.close < last.open {
            action = .sell
        } else {
            action = .wait
        }
        var confirmed = false
        if let record, record.isValid, record.createdAt <= now,
           WatchedStock.parse(record.stockID)?.market == market,
           TradingSession(startTime: record.sessionStart, endTime: record.sessionEnd).contains(now),
           now.timeIntervalSince(record.quoteAt) <= 120 {
            let recent: Bool
            if interval == .day {
                recent = record.evidence?.closes.first.map { calendar.isDate(last.end, inSameDayAs: $0.date) } ?? false
            } else {
                let age = record.quoteAt.timeIntervalSince(last.end)
                recent = age >= 0 && age <= (interval == .minute ? 60 : 600) + 120
                    && last.end > record.sessionStart
            }
            confirmed = recent && ((action == .buy && record.inputPrice > high)
                || (action == .sell && record.inputPrice < low))
        }
        return Self(action: action, volumeRatio: ratio, fastAverage: fast, slowAverage: slow,
                    resistance: high, support: low, firstCandleAt: bars[0].end,
                    candleAt: last.end, isLiveConfirmed: confirmed)
    }
}
