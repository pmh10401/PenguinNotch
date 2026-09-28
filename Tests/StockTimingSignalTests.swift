import Foundation
import XCTest
@testable import PenguinNotch

final class StockTimingSignalTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { start.addingTimeInterval(14400) }

    private func record(price: Decimal = 112, previous: Decimal = 100, evidence: StockForecastEvidence? = nil) -> StockForecastRecord {
        StockForecastRecord(stockID: "us:SOXL", name: "SOXL", currency: "USD",
            model: StockForecastRecord.modelVersion, capture: .manual, createdAt: now, quoteAt: now,
            sessionStart: start, sessionEnd: start.addingTimeInterval(23400), previousClose: previous,
            inputPrice: price, expectedClose: price, lowerClose: 80, upperClose: 120,
            riseProbability: 0.6, observations: 30, evidence: evidence)
    }

    private func bars(selling: Bool = false) -> [StockCandle] {
        (0..<20).map { i in
            let value = Decimal(selling ? 119 - i : 91 + i)
            return StockCandle(end: now.addingTimeInterval(Double(i - 19) * 60),
                open: value + (selling ? 0.5 : -0.5), high: value + 0.6, low: value - 0.6,
                close: value, volume: i == 19 ? 150 : 100)
        }
    }

    private func evaluate(_ bars: [StockCandle], price: Decimal = 112, at: Date? = nil) -> StockTimingSignal? {
        StockTimingSignal.evaluate(candles: bars, interval: .minute, market: .us, record: record(price: price),
                                   fetchedAt: now, now: at ?? now)
    }

    func testHistoricalPatternsOnlyBecomeLiveSignalsWhenTheCurrentPriceConfirms() throws {
        let buy = try XCTUnwrap(evaluate(bars()))
        XCTAssertEqual(buy.action, .buy)
        XCTAssertTrue(buy.isLiveConfirmed)
        XCTAssertEqual(buy.volumeRatio, 1.5, accuracy: 0.00001)
        XCTAssertEqual(buy.fastAverage, 108, accuracy: 0.00001)
        XCTAssertEqual(buy.slowAverage, 100.5, accuracy: 0.00001)
        XCTAssertEqual(buy.resistance, Decimal(string: "109.6"))
        XCTAssertEqual(try XCTUnwrap(evaluate(bars(selling: true), price: 99)).action, .sell)
        let unconfirmed = try XCTUnwrap(evaluate(bars(), price: 108))
        XCTAssertEqual(unconfirmed.action, .buy)
        XCTAssertFalse(unconfirmed.isLiveConfirmed)
        var weak = bars(); weak[19].volume = 149
        XCTAssertEqual(try XCTUnwrap(evaluate(weak)).action, .wait)
        var noBreakout = bars(); noBreakout[18].high = 200
        XCTAssertEqual(try XCTUnwrap(evaluate(noBreakout)).action, .wait)
        // A rising last ten bars cannot hide the higher prices still in the twenty-bar average.
        var longDowntrend = bars()
        for index in 0..<9 {
            longDowntrend[index].open = 200
            longDowntrend[index].close = 200
            longDowntrend[index].high = 201
            longDowntrend[index].low = 199
        }
        let waiting = try XCTUnwrap(evaluate(longDowntrend))
        XCTAssertLessThan(waiting.fastAverage, waiting.slowAverage)
        XCTAssertEqual(waiting.action, .wait)
    }

    func testInvalidStaleMissingAndPartialBarsCannotCreateSignals() throws {
        XCTAssertNil(evaluate(Array(bars().dropFirst())))
        XCTAssertFalse(try XCTUnwrap(evaluate(bars(), at: now.addingTimeInterval(121))).isLiveConfirmed)
        XCTAssertNil(evaluate(bars(), at: start.addingTimeInterval(23400)))
        XCTAssertNil(evaluate(bars() + [bars()[0]]))
        var missing = bars(); missing[5].end = missing[5].end.addingTimeInterval(-30)
        XCTAssertNil(evaluate(missing))
        var noVolume = bars(); for i in noVolume.indices { noVolume[i].volume = 0 }
        XCTAssertNil(evaluate(noVolume))
        var malformed = bars(); malformed[19].volume = -1
        XCTAssertNil(evaluate(malformed))
        malformed = bars(); malformed[19].high = 1
        XCTAssertNil(evaluate(malformed))
        var future = bars()[19]; future.end = now.addingTimeInterval(60); future.volume = 9999
        XCTAssertEqual(try XCTUnwrap(evaluate(bars() + [future])).volumeRatio, 1.5)
        XCTAssertNil(StockTimingSignal.evaluate(candles: bars(), interval: .minute, market: .us, record: record(),
                                                fetchedAt: now.addingTimeInterval(-181), now: now))
    }

    func testTenMinuteSignalNeedsAllConstituentMinutes() throws {
        let minutes = (1...200).map { index in
            let bucket = (index - 1) / 10
            let value = Decimal(91 + bucket)
            return StockCandle(end: start.addingTimeInterval(Double(index + 40) * 60),
                               open: value - 0.5, high: value + 0.6, low: value - 0.6,
                               close: value, volume: bucket == 19 ? 15 : 10)
        }
        let signal = try XCTUnwrap(StockTimingSignal.evaluate(candles: minutes, interval: .tenMinutes,
                                                             market: .us, record: record(), fetchedAt: now, now: now))
        XCTAssertEqual(signal.action, .buy)
        XCTAssertEqual(signal.volumeRatio, 1.5, accuracy: 0.00001)
        XCTAssertNil(StockTimingSignal.evaluate(candles: Array(minutes.dropLast()), interval: .tenMinutes,
                                                market: .us, record: record(), fetchedAt: now, now: now))
        var acrossDays = minutes
        for index in 0..<100 { acrossDays[index].end = acrossDays[index].end.addingTimeInterval(-3 * 86400) }
        let history = try XCTUnwrap(StockTimingSignal.evaluate(candles: acrossDays, interval: .tenMinutes,
            market: .us, fetchedAt: now, now: now))
        XCTAssertEqual(history.action, .buy)
        XCTAssertFalse(history.isLiveConfirmed)
    }

    func testPreviousTradingDayBarsWarmUpTheAnalysisAfterOpening() throws {
        var history = bars()
        for index in 0..<10 {
            history[index].end = history[index].end.addingTimeInterval(-3 * 86400)
        }
        let signal = try XCTUnwrap(evaluate(history))
        XCTAssertEqual(signal.action, .buy)
        XCTAssertEqual(signal.slowAverage, 100.5, accuracy: 0.00001)
        XCTAssertEqual(signal.volumeRatio, 1.5, accuracy: 0.00001)
        XCTAssertEqual(signal.firstCandleAt, history[0].end)
    }

    func testHistoricalAnalysisDoesNotRequireHoldingsOrAnOpenRegularSession() throws {
        let afterClose = start.addingTimeInterval(23400)
        for market in [WatchedStock.Market.kr, .us] {
            let analysis = try XCTUnwrap(StockTimingSignal.evaluate(candles: bars(), interval: .minute,
                market: market, fetchedAt: afterClose, now: afterClose))
            XCTAssertEqual(analysis.action, .buy)
            XCTAssertFalse(analysis.isLiveConfirmed)
            XCTAssertEqual(analysis.candleAt, bars().last?.end)
        }
        let closed = try XCTUnwrap(StockTimingSignal.evaluate(candles: bars(), interval: .minute,
            market: .us, record: record(), fetchedAt: afterClose, now: afterClose))
        XCTAssertFalse(closed.isLiveConfirmed)
        XCTAssertNil(StockTimingSignal.evaluate(candles: bars(), interval: .minute,
            market: .us, fetchedAt: now.addingTimeInterval(1), now: now))
    }

    func testDailyAnalysisExcludesTodayAndWorksWithoutForecastEvidence() throws {
        let calendar = record().marketCalendar
        let today = calendar.startOfDay(for: start)
        let evidence = StockForecastEvidence(closes: (0..<31).map { index in
            .init(date: today.addingTimeInterval(-Double(index + 1) * 86400), price: index == 0 ? 110 : 100)
        })
        let dailyRecord = record(previous: 110, evidence: evidence)
        XCTAssertTrue(dailyRecord.isValid)
        var days = bars().enumerated().map { index, bar in
            var result = bar
            result.end = today.addingTimeInterval(-Double(20 - index) * 86400)
            return result
        }
        let before = try XCTUnwrap(StockTimingSignal.evaluate(candles: days, interval: .day,
            market: .us, record: dailyRecord, fetchedAt: now, now: now))
        XCTAssertEqual(before.action, .buy)
        var todayBar = days[19]; todayBar.end = now; todayBar.volume = 9999
        days.append(todayBar)
        let after = try XCTUnwrap(StockTimingSignal.evaluate(candles: days, interval: .day,
            market: .us, record: dailyRecord, fetchedAt: now, now: now))
        XCTAssertEqual(before.volumeRatio, after.volumeRatio)
        XCTAssertEqual(before.candleAt, after.candleAt)
        XCTAssertNil(StockTimingSignal.evaluate(candles: Array(days.prefix(19)), interval: .day,
            market: .us, record: dailyRecord, fetchedAt: now, now: now))
        let withoutHoldings = try XCTUnwrap(StockTimingSignal.evaluate(candles: days, interval: .day,
            market: .us, fetchedAt: now, now: now))
        XCTAssertEqual(withoutHoldings.action, before.action)
        XCTAssertEqual(withoutHoldings.candleAt, before.candleAt)
        XCTAssertFalse(withoutHoldings.isLiveConfirmed)
    }

    @MainActor
    func testTimingVisibilityPersistsWithoutEnablingAccountAccess() throws {
        let name = "Timing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.portfolioForecastEnabled)
        XCTAssertTrue(preferences.showsStockTimingSignals)
        preferences.showsStockTimingSignals = false
        XCTAssertFalse(Preferences(defaults: defaults).showsStockTimingSignals)
    }
}
