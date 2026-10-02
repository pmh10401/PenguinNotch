import Foundation
import XCTest
@testable import PenguinNotch

final class StockBacktestTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Sample: Decodable {
            let name: String
            let caseData: StockBacktestCase
            let expected: [String: StockBacktestOutcome.Forecast]
        }
        let replayCases: [Sample]
    }
    private func samples() throws -> [Fixture.Sample] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/stock-forecast-evaluation-v1.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file)).replayCases
    }
    private func outcomes(_ input: StockBacktestInput) -> [StockBacktestOutcome] {
        StockChartInterval.allCases.map { StockBacktest.predict(input: input, interval: $0) }
    }
    func testTargetCannotChangePrediction() throws {
        var a = try samples()[0].caseData
        var b = a
        a.target.actualClose = 1
        b.target.actualClose = 1000
        XCTAssertTrue(a.isValid)
        XCTAssertTrue(b.isValid)
        XCTAssertEqual(outcomes(a.input), outcomes(b.input))
        let input = a.input
        var future = input.minutes.last!
        future.end = input.cutoff + 60_000
        future.open = 1_000_000_000; future.high = future.open
        future.low = future.open; future.close = future.open
        let filtered = StockQuoteCodec.completedRegularBars((input.minutes + [future]).map(\.candle),
            trading: input.trading, through: input.at, interval: .minute)
        XCTAssertEqual(filtered.count, input.minutes.count)
        var changed = input
        changed.minutes = filtered.map {
            StockBacktestInput.Minute(end: Int64(($0.end.timeIntervalSince1970 * 1000).rounded()),
                open: $0.open, high: $0.high, low: $0.low, close: $0.close, volume: $0.volume)
        }
        XCTAssertEqual(outcomes(changed), outcomes(input))
        changed.minutes = input.minutes + [future]
        XCTAssertFalse(changed.isValid)
        XCTAssertTrue(outcomes(changed).allSatisfy { $0.status == .skipped && $0.forecast == nil })
        let daily = try XCTUnwrap(StockBacktest.predict(input: input, interval: .day).forecast)
        XCTAssertEqual(daily.expectedClose, input.inputPrice)
        XCTAssertEqual(daily.observations, 60)
        XCTAssertEqual(input.cutoff, input.sessionEnd - 3_600_000)
    }
    func testPublicFixtureParityAndSessionTimes() throws {
        for sample in try samples() {
            XCTAssertTrue(sample.caseData.isValid, sample.name)
            for interval in StockChartInterval.allCases {
                let input = sample.caseData.input
                let outcome = StockBacktest.predict(input: input, interval: interval)
                XCTAssertEqual(outcome.status, .forecast)
                XCTAssertEqual(outcome.model, "GBM \(interval == .day ? "daily" : interval.rawValue) zero drift v1 / replay v1")
                let actual = try XCTUnwrap(outcome.forecast)
                let expected = sample.expected[interval.rawValue]!
                XCTAssertEqual(actual.expectedClose, input.inputPrice)
                XCTAssertEqual(actual.observations, expected.observations)
                for (a, e) in [(actual.lowerClose, expected.lowerClose), (actual.upperClose, expected.upperClose)] {
                    let value = NSDecimalNumber(decimal: e).doubleValue
                    XCTAssertEqual(NSDecimalNumber(decimal: a).doubleValue, value, accuracy: value * 1e-8)
                }
                XCTAssertEqual(actual.riseProbability, expected.riseProbability, accuracy: 1e-6)
            }
        }
    }
    func testConsecutiveSuffixShortageAndCutoffHorizon() throws {
        let base = try samples()[0].caseData.input
        var input = base
        input.minutes = Array(base.minutes.suffix(11))
        XCTAssertEqual(StockBacktest.predict(input: input, interval: .minute).forecast?.observations, 10)
        input.minutes = Array(base.minutes.suffix(10))
        XCTAssertEqual(StockBacktest.predict(input: input, interval: .minute).reason, "insufficient_intraday_history")
        input = base; input.minutes.remove(at: input.minutes.count - 6)
        XCTAssertEqual(StockBacktest.predict(input: input, interval: .minute).reason, "insufficient_intraday_history")
        XCTAssertEqual(StockBacktest.predict(input: base, interval: .minute).forecast?.observations, 329)
        input = base; input.dailyCloses.removeLast()
        XCTAssertEqual(StockBacktest.predict(input: input, interval: .day).reason, "insufficient_daily_history")
        for count in [2, 3] {
            input = base; input.minutes.removeLast(count)
            input.inputBarEnd = input.minutes.last!.end; input.inputPrice = input.minutes.last!.close
            XCTAssertEqual(input.isValid, count == 2)
            if count == 2 {
                let expected = try XCTUnwrap(StockForecast.estimate(price: input.inputPrice,
                    completedCloses: input.dailyCloses.map(\.price), trading: input.trading, now: input.at))
                XCTAssertEqual(StockBacktest.predict(input: input, interval: .day).forecast?.lowerClose, expected.lowerClose)
            }
        }
    }
    func testRejectInvalidInputAndUnknownCaseFields() throws {
        let base = try samples()[0].caseData
        var input = base.input
        input.inputPrice = .nan; XCTAssertFalse(input.isValid)
        input = base.input; input.minutes[0].high = 1; XCTAssertFalse(input.isValid)
        input = base.input; input.minutes[0].volume = -1; XCTAssertFalse(input.isValid)
        input = base.input; input.priceBasis = "unadjusted"; XCTAssertFalse(input.isValid)
        input = base.input; input.minutes.append(input.minutes[0]); XCTAssertFalse(input.isValid)
        input = base.input; input.dailyCloses[0].date = input.cutoff; XCTAssertFalse(input.isValid)
        input = base.input; input.caseID = "../TEST"; XCTAssertFalse(input.isValid)
        input = base.input; input.cutoff += 1; XCTAssertFalse(input.isValid)
        input = base.input; input.dailyCloses[1] = input.dailyCloses[0]; XCTAssertFalse(input.isValid)
        input = base.input; input.dailyCloses.append(input.dailyCloses.last!); XCTAssertFalse(input.isValid)
        input = base.input; input.sessionStart = Int64.max; XCTAssertFalse(input.isValid)
        input = base.input; input.minutes[0].close = .nan; XCTAssertFalse(input.isValid)
        input = base.input; input.minutes = (0..<1_401).map { n in
            var bar = base.input.minutes.last!; bar.end = base.input.cutoff - 1_400 + Int64(n); return bar
        }; XCTAssertFalse(input.isValid)
        let data = try JSONEncoder().encode(base)
        _ = try StockBacktest.decodeCase(data)
        for path in [[], ["input"], ["target"], ["source"]] {
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if let key = path.first {
                var nested = object[key] as! [String: Any]; nested["token"] = "fake"; object[key] = nested
            } else { object["token"] = "fake" }
            XCTAssertThrowsError(try StockBacktest.decodeCase(JSONSerialization.data(withJSONObject: object)))
        }
        for field in ["dailyCloses", "minutes"] {
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var input = object["input"] as! [String: Any]
            var rows = input[field] as! [[String: Any]]; rows[0]["priceBasis"] = "unadjusted"
            input[field] = rows; object["input"] = input
            XCTAssertThrowsError(try StockBacktest.decodeCase(JSONSerialization.data(withJSONObject: object)))
        }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var inputObject = object["input"] as! [String: Any]
        inputObject["cutoff"] = Double(base.input.cutoff) + 0.5; object["input"] = inputObject
        XCTAssertThrowsError(try StockBacktest.decodeCase(JSONSerialization.data(withJSONObject: object)))
        object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var source = object["source"] as! [String: Any]
        var pages = source["minutePages"] as! [[String: Any]]; pages[0]["token"] = "fake"
        source["minutePages"] = pages; object["source"] = source
        XCTAssertThrowsError(try StockBacktest.decodeCase(JSONSerialization.data(withJSONObject: object)))
    }
    func testExplicitNullsInReplayWireFormat() throws {
        let sample = try samples()[0].caseData
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as! [String: Any]
        let source = object["source"] as! [String: Any]
        let page = (source["minutePages"] as! [[String: Any]])[0]
        XCTAssertTrue(page["nextBefore"] is NSNull)
        for input in [sample.input, {
            var short = sample.input; short.dailyCloses.removeLast(); return short
        }()] {
            let outcome = StockBacktest.predict(input: input, interval: .day)
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(outcome)) as! [String: Any]
            XCTAssertEqual(Set(encoded.keys), ["model", "status", "reason", "forecast"])
            XCTAssertTrue(outcome.status == .forecast ? encoded["reason"] is NSNull : encoded["forecast"] is NSNull)
        }
        let entry = StockBacktestManifest.Entry(caseID: sample.input.caseID, stockID: sample.input.stockID,
            tradingDay: sample.input.tradingDay, status: .pending, inputSHA256: nil, resultSHA256: nil, reason: nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        XCTAssertTrue(["inputSHA256", "resultSHA256", "reason"].allSatisfy { encoded[$0] is NSNull })
    }
    func testTenMinuteCompletionGapAndVolumeAggregation() throws {
        let base = try samples()[0].caseData.input
        var input = base
        input.minutes = Array(base.minutes.suffix(110))
        XCTAssertEqual(StockBacktest.predict(input: input, interval: .tenMinutes).forecast?.observations, 10)
        input.minutes.removeFirst()
        XCTAssertEqual(StockBacktest.predict(input: input, interval: .tenMinutes).reason, "insufficient_intraday_history")
        input = base; input.minutes.remove(at: input.minutes.count - 16)
        XCTAssertEqual(StockBacktest.predict(input: input, interval: .tenMinutes).reason, "insufficient_intraday_history")
        var bars = Array(base.minutes.suffix(10)).map(\.candle)
        for n in bars.indices { bars[n].volume = Decimal(n + 1) }
        let complete = StockQuoteCodec.completedRegularBars(bars, trading: base.trading, through: base.at, interval: .tenMinutes)
        XCTAssertEqual(complete.count, 1)
        XCTAssertEqual(complete[0].volume, 55)
        XCTAssertEqual(complete[0].open, bars[0].open)
        XCTAssertEqual(complete[0].close, bars[9].close)
        XCTAssertEqual(StockQuoteCodec.completedRegularBars(Array(bars.dropLast()), trading: base.trading,
            through: base.at, interval: .tenMinutes).count, 0)
    }

}
