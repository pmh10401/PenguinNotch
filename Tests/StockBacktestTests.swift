import AppKit
import Foundation
import XCTest
import Darwin
@testable import PenguinNotch

final class StockBacktestTests: XCTestCase {
    @MainActor
    func testFinalShortCalendarIdentityPreservesFrozenDenominator() async throws {
        let f = BacktestPublicFixture(mode: "partial", dailyCount: 2)
        f.shortDay = "2026-09-24"
        let archive = StockBacktestArchive(directory: try temporaryArchive()), store = f.store(archive)
        try await store.start(symbols: [f.stock], sessions: 20)
        let m = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(m.cases.count, 20); XCTAssertEqual(m.status, .completed)
        let short = try XCTUnwrap(m.cases.first { $0.tradingDay == f.shortDay })
        XCTAssertEqual(short.status, .skipped); XCTAssertEqual(short.reason, "session_too_short")
        XCTAssertEqual(m.cases.first { $0.tradingDay == "2026-09-25" }?.status, .saved)
        XCTAssertFalse(f.calls.contains { if case .candles(_, _, let before, _, _) = $0.0 { return f.day(StockBacktestStore.timestamp(before)!) == f.shortDay }; return false })
        let receipt = try await store.loadReceipt(runID: m.runID, caseID: m.cases[0].caseID)
        let summary = try StockEvaluation.replaySummary(manifest: m, receipts: [receipt], selectedModels: Set(m.models))
        XCTAssertEqual(summary.requested, 20); XCTAssertEqual(summary.skipped, 1); XCTAssertEqual(summary.acquired, 19)
        XCTAssertEqual(summary.unavailable, 18)
        var reads = archive
        let counter = BacktestReadCounter()
        reads.fault = { phase in if phase.hasPrefix("read:"), phase.hasSuffix(".json"), phase != "read:manifest.json" { counter.increment() } }
        let viewer = f.store(reads)
        for _ in 0..<10_000 { if !viewer.runs.isEmpty { break }; await Task.yield() }
        XCTAssertEqual(viewer.runs.count, 1); counter.reset()
        let compact = try await viewer.loadReceipt(runID: m.runID, caseID: m.cases[0].caseID)
        XCTAssertEqual(counter.value, 3, "strict selected case/result binding reads only selected payloads")
        for _ in 0..<10 { _ = try StockEvaluation.replaySummary(manifest: m, receipts: [compact], selectedModels: Set(m.models)) }
        XCTAssertEqual(counter.value, 3, "collapsed summary redraw does not reopen raw evidence")
        let raw = try await viewer.loadCase(runID: m.runID, caseID: m.cases[0].caseID)
        XCTAssertFalse(raw.rawDetail.isEmpty); XCTAssertEqual(counter.value, 6, "explicit raw open performs selected reads")
        var unrelated = m; unrelated.runID = UUID()
        XCTAssertThrowsError(try StockEvaluation.replaySummary(manifest: unrelated, receipts: [compact], selectedModels: Set(m.models)))
    }
    @MainActor
    func testFinalWorkspaceSleepCancelsWaitAndDiscardsLateReply() async throws {
        for waiting in [true, false] {
            let f = BacktestPublicFixture(mode: "partial"), archive = StockBacktestArchive(directory: try temporaryArchive())
            var interrupted = false
            let store = StockBacktestStore(archive: archive, request: { request in
                let reply = try await f.request(request)
                if !waiting, case .candles = request, !interrupted {
                    interrupted = true
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
                }
                return reply
            }, now: { f.now }, sleep: { ms in
                f.clock += Int64(ms)
                if waiting, f.calls.contains(where: { if case .candles = $0.0 { return true }; return false }), !interrupted {
                    interrupted = true
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
                }
            }, provider: { .toss })
            do { try await store.start(symbols: [f.stock], sessions: 20); XCTFail("continued after suspend") } catch {}
            XCTAssertTrue(interrupted); XCTAssertEqual(store.errorMessage, "collection_cancelled")
            let m = try XCTUnwrap(store.runs.first); XCTAssertEqual(m.status, .paused)
            XCTAssertEqual(m.cases.count, 20); XCTAssertTrue(m.cases.allSatisfy { $0.status == .pending })
            XCTAssertEqual(f.calls.filter { if case .candles = $0.0 { return true }; return false }.count, 1)
            try await store.resume(runID: m.runID)
            XCTAssertEqual(store.runs.first?.status, .completed)
        }
    }

    @MainActor
    func testFinalShortResumeAndInvalidCalendarRemainFailClosed() async throws {
        let f = BacktestPublicFixture(mode: "partial", dailyCount: 2)
        var refuse = true
        let store = StockBacktestStore(archive: .init(directory: try temporaryArchive()), request: { r in
            if refuse, case .candles = r { throw TossInvestAPI.Failure.http(401) }
            return try await f.request(r)
        }, now: { f.now }, sleep: { f.clock += Int64($0) }, provider: { .toss })
        do { try await store.start(symbols: [f.stock], sessions: 20); XCTFail("auth accepted") } catch {}
        let m = try XCTUnwrap(store.runs.first); XCTAssertEqual(m.status, .paused)
        f.shortDay = "2026-09-24"; f.shortMinutes = 30; refuse = false
        try await store.resume(runID: m.runID)
        XCTAssertEqual(store.runs.first?.cases.count, 20)
        XCTAssertEqual(store.runs.first?.cases.first(where: { $0.tradingDay == f.shortDay })?.reason, "session_too_short")
        for minutes in [0.0, -1, 1440] {
            let malformed = BacktestPublicFixture(); malformed.shortDay = "2026-09-25"; malformed.shortMinutes = minutes
            let rejected = malformed.store(.init(directory: try temporaryArchive()))
            do { try await rejected.start(symbols: [malformed.stock], sessions: 20); XCTFail("invalid calendar accepted") } catch {}
            XCTAssertTrue(rejected.runs.isEmpty); XCTAssertEqual(rejected.errorMessage, "collection_failed")
        }
    }

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
    @MainActor
    func testCollectorPersistsResultsBeforeSaved() async throws {
        let f = BacktestPublicFixture(mode: "partial", dailyCount: 2)
        let archive = StockBacktestArchive(directory: try temporaryArchive()), store = f.store(archive)
        try await store.start(symbols: [f.stock], sessions: 20)
        let m = store.runs[0]
        for e in m.cases {
            XCTAssertNotNil(e.resultSHA256)
            let loaded = try await store.loadCase(runID: m.runID, caseID: e.caseID)
            let result = try XCTUnwrap(loaded.result)
            XCTAssertEqual(result.outcomes.filter { $0.status == .forecast }.count, 1)
            XCTAssertEqual(result.outcomes.filter { $0.status == .skipped }.count, 2)
            XCTAssertEqual(result.inputSHA256, e.inputSHA256)
            XCTAssertEqual(loaded.resultSHA256, e.resultSHA256)
            let rows = try StockEvaluation.replayRows(runID: m.runID, caseData: XCTUnwrap(loaded.caseData), result: result, inputSHA256: XCTUnwrap(loaded.inputSHA256))
            XCTAssertEqual(loaded.referenceID, rows[0].referenceID)
            let csv = StockEvaluation.csv(rows: rows, metrics: StockEvaluation.metrics(rows), details: [rows[0].referenceID: loaded.rawDetail])
            XCTAssertTrue(csv.contains("insufficient_daily_history")); XCTAssertTrue(csv.contains("insufficient_intraday_history"))
            XCTAssertTrue(csv.contains("\"outcome\""))
        }
    }

    @MainActor
    func testResultSaveCancellationOrphanReuseAndReadonlyCompletedLoader() async throws {
        let c = try samples()[0].caseData, body = try JSONEncoder().encode(c)
        let path = try temporaryArchive()
        var archive = StockBacktestArchive(directory: path), m = archiveManifest(c)
        m.models = Array(StockBacktestArchive.models.prefix(2))
        try archive.create(m); let hash = try archive.saveCase(runID: m.runID, body: body)
        let counter = BacktestReadCounter(), entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        archive.fault = { stage in
            XCTAssertFalse(Thread.isMainThread)
            if stage == "place" { counter.increment(); if counter.value == 2 { entered.signal(); _ = proceed.wait(timeout: .now() + 15) } }
        }
        let store = StockBacktestStore(archive: archive, request: { _ in XCTFail("frozen cases must not query"); throw CocoaError(.fileReadUnknown) }, provider: { .toss })
        let running = Task { try await store.resume(runID: m.runID) }
        let wait: @Sendable () -> Bool = { entered.wait(timeout: .now() + 15) == .success }
        let waiting = await Task.detached { wait() }.value
        XCTAssertTrue(waiting); store.cancel(); proceed.signal()
        do { try await running.value; XCTFail("cancelled result must not mark case saved") } catch is CancellationError { }
        archive.fault = nil
        let paused = try archive.loadManifest(runID: m.runID)
        XCTAssertEqual(paused.status, .paused); XCTAssertEqual(paused.cases[0].status, .pending)
        XCTAssertNil(paused.cases[0].resultSHA256)
        let original = try XCTUnwrap(archive.loadResult(runID: m.runID, caseID: c.input.caseID))
        XCTAssertEqual(try archive.loadCase(runID: m.runID, caseID: c.input.caseID).body, body)
        let pending = try await store.loadCase(runID: m.runID, caseID: c.input.caseID)
        XCTAssertNil(pending.result); XCTAssertNil(pending.caseData)
        let reopened = StockBacktestStore(archive: archive, request: { _ in XCTFail("orphan must not query"); throw CocoaError(.fileReadUnknown) }, provider: { .toss })
        try await reopened.resume(runID: m.runID)
        let loaded = try await reopened.loadCase(runID: m.runID, caseID: c.input.caseID)
        XCTAssertEqual(loaded.caseBody, body); XCTAssertEqual(loaded.inputSHA256, hash)
        XCTAssertEqual(loaded.resultBody, original); XCTAssertEqual(loaded.resultSHA256, StockBacktestArchive.hash(original))
        XCTAssertEqual(loaded.result?.outcomes.map(\.model), m.models)
        let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(loaded.rawDetail.utf8)) as? [String: Any])
        XCTAssertEqual(detail["caseBody"] as? String, String(decoding: body, as: UTF8.self))
        XCTAssertEqual(detail["resultBody"] as? String, String(decoding: original, as: UTF8.self))
        let frozen = try Data(contentsOf: path.appending(path: m.runID.uuidString.lowercased() + "/manifest.json"))
        try await reopened.resume(runID: m.runID)
        XCTAssertEqual(try Data(contentsOf: path.appending(path: m.runID.uuidString.lowercased() + "/manifest.json")), frozen)
        XCTAssertTrue(reopened.supportsReplay); XCTAssertTrue(reopened.watchedSymbols.isEmpty)

        // Completed source-only archives remain immutable and unavailable, even after explicit resume.
        let legacyArchive = StockBacktestArchive(directory: try temporaryArchive()), legacy = archiveManifest(c)
        try legacyArchive.create(legacy); let legacyHash = try legacyArchive.saveCase(runID: legacy.runID, body: body)
        var entries = legacy.cases; entries[0].status = .saved; entries[0].inputSHA256 = legacyHash
        try legacyArchive.updateProgress(runID: legacy.runID, entries: entries, status: .completed)
        let oldStore = StockBacktestStore(archive: legacyArchive, request: { _ in XCTFail("completed must not query"); throw CocoaError(.fileReadUnknown) }, provider: { .toss })
        let oldManifest = try legacyArchive.loadManifest(runID: legacy.runID)
        try await oldStore.resume(runID: legacy.runID)
        let old = try await oldStore.loadCase(runID: legacy.runID, caseID: c.input.caseID)
        XCTAssertNil(old.result); XCTAssertEqual(old.caseBody, body)
        XCTAssertEqual(try legacyArchive.loadManifest(runID: legacy.runID), oldManifest)
        XCTAssertNil(try legacyArchive.loadResult(runID: legacy.runID, caseID: c.input.caseID))
        let summary = try StockEvaluation.replaySummary(manifest: oldManifest, loaded: [old], selectedModels: Set(legacy.models))
        XCTAssertEqual(summary.unavailable, 1); XCTAssertEqual(summary.comparison.pairedCount, 0)
        XCTAssertTrue(summary.rows.isEmpty); XCTAssertNil(summary.models[0].metrics.mape)
    }

    @MainActor
    func testCancellationAfterCompletionKeepsImmutableAllSkippedResult() async throws {
        let c = try StockBacktest.decodeCase(wireBody), path = try temporaryArchive(), counter = BacktestReadCounter()
        var archive = StockBacktestArchive(directory: path)
        let m = archiveManifest(c)
        try archive.create(m); _ = try archive.saveCase(runID: m.runID, body: wireBody)
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        archive.fault = { stage in
            XCTAssertFalse(Thread.isMainThread)
            if stage == "place" { counter.increment(); if counter.value == 4 { entered.signal(); _ = proceed.wait(timeout: .now() + 15) } }
        }
        let store = StockBacktestStore(archive: archive, request: { _ in XCTFail("all-skipped frozen case must not query"); throw CocoaError(.fileReadUnknown) }, provider: { .toss })
        let running = Task { try await store.resume(runID: m.runID) }
        let wait: @Sendable () -> Bool = { entered.wait(timeout: .now() + 15) == .success }
        let waiting = await Task.detached { wait() }.value
        XCTAssertTrue(waiting); store.cancel(); proceed.signal()
        do { try await running.value; XCTFail("cancelled caller must observe cancellation") } catch is CancellationError { }
        archive.fault = nil
        XCTAssertEqual(store.errorMessage, "collection_cancelled"); XCTAssertNil(store.activeRunID)
        let completed = try archive.loadManifest(runID: m.runID)
        XCTAssertEqual(completed.status, .completed); XCTAssertEqual(store.runs[0], completed)
        let loaded = try await store.loadCase(runID: m.runID, caseID: c.input.caseID)
        XCTAssertEqual(loaded.caseBody, wireBody); XCTAssertEqual(loaded.inputSHA256, wireHash)
        XCTAssertEqual(loaded.result?.outcomes[0].status, .skipped)
        let summary = try StockEvaluation.replaySummary(manifest: completed, loaded: [loaded], selectedModels: Set(m.models))
        XCTAssertTrue(summary.rows.isEmpty); XCTAssertNil(summary.models[0].metrics.mape)
        XCTAssertEqual(summary.models[0].skipped, 1); XCTAssertEqual(summary.unavailable, 0)
        XCTAssertThrowsError(try archive.updateProgress(runID: m.runID, entries: completed.cases, status: .paused))
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

    private let wireBody = Data(#"{"version":1,"input":{"version":1,"caseID":"us_TEST_2026-09-25","stockID":"us:TEST","market":"us","currency":"USD","tradingDay":"2026-09-25","sessionStart":1790343000000,"sessionEnd":1790366400000,"cutoff":1790362800000,"inputBarEnd":1790362800000,"inputPrice":100.1,"previousClose":100,"priceBasis":"provider-adjusted-as-fetched","dailyCloses":[],"minutes":[{"end":1790362800000,"open":100.1,"high":100.3,"low":99.89999999999999,"close":100.1,"volume":0}]},"target":{"actualClose":101,"candleAt":1790308800000,"fetchedAt":1790366460000},"source":{"provider":"toss","calendarFetchedAt":1790366460000,"dailyFetchedAt":1790366460000,"minutePages":[{"before":"2026-09-25T19:00:00Z","nextBefore":null,"fetchedAt":1790366460000}]}}"#.utf8)
    private let wireHash = "b7a648b33e2d8b7fefa8d21668c29a70425477b8c2d7ddbdfacab73fcdfa406a"
    private func archiveManifest(_ sample: StockBacktestCase) -> StockBacktestManifest {
        StockBacktestManifest(version: 1, runID: UUID(), createdAt: sample.source.calendarFetchedAt,
            collectionStartedAt: sample.source.calendarFetchedAt, collectionCompletedAt: nil,
            protocolVersion: "replay-v1", codeVersion: "test-task3", priceBasis: StockBacktest.priceBasis,
            cutoffMinutes: 60, sessions: 20, symbols: [sample.input.stockID],
            models: ["GBM daily zero drift v1 / replay v1"], status: .ready,
            cases: [.init(caseID: sample.input.caseID, stockID: sample.input.stockID,
                tradingDay: sample.input.tradingDay, status: .pending, inputSHA256: nil, resultSHA256: nil, reason: nil)])
    }
    private func temporaryArchive() throws -> URL {
        let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let path = URL(fileURLWithPath: String(cString: canonical)).appending(path: "task3-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path.appending(path: "Forecasts/Backtests")
    }
    func testCrashAfterCaseSaveResumesWithoutOverwrite() throws {
        let sample = try samples()[0].caseData, body = try JSONEncoder().encode(sample)
        let path = try temporaryArchive(), manifest = archiveManifest(sample)
        let archive = StockBacktestArchive(directory: path)
        try archive.create(manifest)
        let hash = try archive.saveCase(runID: manifest.runID, body: body)
        let resumed = StockBacktestArchive(directory: path)
        XCTAssertEqual(try resumed.loadManifest(runID: manifest.runID).cases[0].status, .pending)
        let loaded = try resumed.loadCase(runID: manifest.runID, caseID: sample.input.caseID)
        XCTAssertEqual(loaded.body, body); XCTAssertEqual(loaded.sha256, hash)
        var entries = manifest.cases; entries[0].status = .saved; entries[0].inputSHA256 = hash
        try resumed.updateProgress(runID: manifest.runID, entries: entries, status: .paused)
        XCTAssertEqual(try resumed.saveCase(runID: manifest.runID, body: body), hash)
        XCTAssertThrowsError(try resumed.saveCase(runID: manifest.runID, body: body + Data(" ".utf8)))
        XCTAssertEqual(try resumed.loadCase(runID: manifest.runID, caseID: sample.input.caseID).body, body)
    }
    func testUnknownNestedFieldsAndTraversalRejectWithoutWriting() throws {
        let sample = try samples()[0].caseData, path = try temporaryArchive()
        let archive = StockBacktestArchive(directory: path), manifest = archiveManifest(sample)
        try archive.create(manifest)
        let original = try JSONEncoder().encode(sample)
        for field in ["token", "accountSeq", "quantity"] {
            for key in ["", "input", "target", "source"] {
                var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
                if key.isEmpty { object[field] = "fake" }
                else { var row = object[key] as! [String: Any]; row[field] = "fake"; object[key] = row }
                XCTAssertThrowsError(try archive.saveCase(runID: manifest.runID,
                    body: JSONSerialization.data(withJSONObject: object)))
            }
        }
        XCTAssertThrowsError(try archive.loadCase(runID: manifest.runID, caseID: "../history"))
        XCTAssertThrowsError(try archive.loadManifest(runID: UUID()))
        var unsupported = manifest; unsupported.version = 2
        XCTAssertThrowsError(try archive.create(unsupported))
        unsupported = manifest; unsupported.models = ["private-model"]
        XCTAssertThrowsError(try archive.create(unsupported))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:
            path.appending(path: manifest.runID.uuidString.lowercased() + "/cases").path), [])
    }

    private func resultBody(_ caseID: String, hash: String) throws -> Data {
        let r = StockBacktestResult(version: 1, caseID: caseID, inputSHA256: hash,
            calculationVersion: "replay-v1", computedAt: 1790366460000,
            outcomes: [.init(model: "GBM daily zero drift v1 / replay v1", status: .skipped,
                reason: "insufficient_daily_history", forecast: nil)])
        return try JSONEncoder().encode(r)
    }
    func testSharedWireHashConcurrentSavesAndSeparatePaginationSequences() throws {
        let sample = try StockBacktest.decodeCase(wireBody), manifest = archiveManifest(sample)
        let path = try temporaryArchive(), archive = StockBacktestArchive(directory: path)
        try archive.create(manifest)
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { let hash = try StockBacktestArchive(directory: path).saveCase(runID: manifest.runID, body: wireBody); XCTAssertEqual(hash, wireHash) }
            catch { XCTFail("Concurrent save failed: \(error)") }
        }
        XCTAssertEqual(try archive.loadCase(runID: manifest.runID, caseID: sample.input.caseID).body, wireBody)
        XCTAssertEqual(try archive.list().map(\.runID), [manifest.runID])
        var proof = sample
        proof.source.minutePages.append(.init(before: "2026-09-25T20:00:00Z", nextBefore: "2026-09-25T19:59:00Z", fetchedAt: sample.target.fetchedAt))
        _ = try StockBacktest.decodeCase(JSONEncoder().encode(proof))
        proof.source.minutePages = Array(repeating: proof.source.minutePages[0], count: 9)
        XCTAssertThrowsError(try StockBacktest.decodeCase(JSONEncoder().encode(proof)))
    }
    func testResultsHashesFrozenProgressAndLegacyFilesRemainUntouched() throws {
        let sample = try StockBacktest.decodeCase(wireBody), manifest = archiveManifest(sample)
        let path = try temporaryArchive(), archive = StockBacktestArchive(directory: path)
        let parent = path.deletingLastPathComponent().deletingLastPathComponent()
        let sentinel = Data("synthetic legacy sentinel".utf8)
        for file in ["Forecasts/history.json", "Forecasts/AIAnalyses/history.json", "Forecasts/CloseEstimates/public-test.json", "stock-history.sqlite3"] {
            let url = parent.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sentinel.write(to: url)
        }
        try archive.create(manifest)
        XCTAssertNil(try archive.loadResult(runID: manifest.runID, caseID: sample.input.caseID))
        XCTAssertThrowsError(try archive.saveResult(runID: manifest.runID, body: resultBody(sample.input.caseID, hash: wireHash)))
        XCTAssertEqual(try archive.saveCase(runID: manifest.runID, body: wireBody), wireHash)
        XCTAssertThrowsError(try archive.saveResult(runID: manifest.runID, body: resultBody(sample.input.caseID, hash: String(repeating: "0", count: 64))))
        let body = try resultBody(sample.input.caseID, hash: wireHash)
        let resultHash = try archive.saveResult(runID: manifest.runID, body: body)
        XCTAssertEqual(try archive.saveResult(runID: manifest.runID, body: body), resultHash)
        XCTAssertThrowsError(try archive.saveResult(runID: manifest.runID, body: body + Data(" ".utf8)))
        var entries = manifest.cases; entries[0].status = .saved
        entries[0].inputSHA256 = wireHash; entries[0].resultSHA256 = resultHash
        try archive.updateProgress(runID: manifest.runID, entries: entries, status: .completed)
        XCTAssertEqual(try archive.loadResult(runID: manifest.runID, caseID: sample.input.caseID), body)
        XCTAssertThrowsError(try archive.updateProgress(runID: manifest.runID, entries: manifest.cases, status: .paused))
        XCTAssertThrowsError(try archive.create(manifest))
        for file in ["Forecasts/history.json", "Forecasts/AIAnalyses/history.json", "Forecasts/CloseEstimates/public-test.json", "stock-history.sqlite3"] {
            XCTAssertEqual(try Data(contentsOf: parent.appending(path: file)), sentinel)
        }
    }
    func testWriteAndPlacementFailuresKeepManifestAndCaseBytes() throws {
        let sample = try StockBacktest.decodeCase(wireBody), manifest = archiveManifest(sample)
        let path = try temporaryArchive(), archive = StockBacktestArchive(directory: path)
        try archive.create(manifest)
        let run = path.appending(path: manifest.runID.uuidString.lowercased())
        let before = try Data(contentsOf: run.appending(path: "manifest.json"))
        for stage in ["write", "place"] {
            let failing = StockBacktestArchive(directory: path, fault: { at in
                if at == stage { throw CocoaError(.fileWriteUnknown) }
            })
            XCTAssertThrowsError(try failing.saveCase(runID: manifest.runID, body: wireBody))
            XCTAssertThrowsError(try failing.updateProgress(runID: manifest.runID, entries: manifest.cases, status: .paused))
            XCTAssertEqual(try Data(contentsOf: run.appending(path: "manifest.json")), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: run.appending(path: "cases").path), [])
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: run.path).contains(where: { $0.hasPrefix(".tmp-") }))
        }
        _ = try archive.saveCase(runID: manifest.runID, body: wireBody)
        try Data("preserved crash leftover".utf8).write(to: run.appending(path: ".tmp-interrupted-manifest"))
        XCTAssertEqual(try archive.loadManifest(runID: manifest.runID), manifest)
        XCTAssertEqual(try archive.loadCase(runID: manifest.runID, caseID: sample.input.caseID).body, wireBody)
    }
    func testCorruptionOversizeAndSymlinksBlockRunWithoutOverwrite() throws {
        let sample = try StockBacktest.decodeCase(wireBody)
        for kind in ["manifest", "case", "result", "directory-link", "file-link", "hash"] {
            let path = try temporaryArchive(), archive = StockBacktestArchive(directory: path), m = archiveManifest(sample)
            try archive.create(m); _ = try archive.saveCase(runID: m.runID, body: wireBody)
            let run = path.appending(path: m.runID.uuidString.lowercased())
            let caseURL = run.appending(path: "cases/" + sample.input.caseID + ".json")
            let manifestURL = run.appending(path: "manifest.json"), manifestBytes = try Data(contentsOf: manifestURL)
            var protectedURL = caseURL
            if kind == "manifest" {
                protectedURL = manifestURL; try Data("{broken".utf8).write(to: manifestURL)
            } else if kind == "case" { try Data("{broken".utf8).write(to: caseURL) }
            else if kind == "result" {
                protectedURL = run.appending(path: "results/" + sample.input.caseID + ".json")
                try Data("{broken".utf8).write(to: protectedURL)
            } else if kind == "hash" {
                var entries = m.cases; entries[0].status = .saved; entries[0].inputSHA256 = wireHash
                try archive.updateProgress(runID: m.runID, entries: entries, status: .paused)
                try (wireBody + Data(" ".utf8)).write(to: caseURL)
            } else {
                let outside = path.deletingLastPathComponent().deletingLastPathComponent().appending(path: "outside")
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
                let external = outside.appending(path: sample.input.caseID + ".json")
                try wireBody.write(to: external); protectedURL = external
                if kind == "file-link" {
                    try FileManager.default.removeItem(at: caseURL)
                    try FileManager.default.createSymbolicLink(at: caseURL, withDestinationURL: external)
                } else {
                    try FileManager.default.removeItem(at: run.appending(path: "cases"))
                    try FileManager.default.createSymbolicLink(at: run.appending(path: "cases"), withDestinationURL: outside)
                }
            }
            let protected = try Data(contentsOf: protectedURL)
            XCTAssertThrowsError(try archive.loadManifest(runID: m.runID), kind)
            XCTAssertThrowsError(try archive.saveCase(runID: m.runID, body: wireBody), kind)
            XCTAssertThrowsError(try archive.updateProgress(runID: m.runID, entries: m.cases, status: .running), kind)
            XCTAssertEqual(try Data(contentsOf: protectedURL), protected, kind)
            if kind != "manifest" && kind != "hash" { XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes) }
        }
        let path = try temporaryArchive(), archive = StockBacktestArchive(directory: path), m = archiveManifest(sample)
        try archive.create(m)
        XCTAssertThrowsError(try archive.saveCase(runID: m.runID, body: wireBody + Data(repeating: 32, count: 2*1024*1024)))
        XCTAssertThrowsError(try archive.saveCase(runID: m.runID, body: Data([0xff])))
        let link = path.deletingLastPathComponent().appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try StockBacktestArchive(directory: link).create(m))
    }
    func testAllNestedWireWhitelistsAndVersions() throws {
        let sample = try samples()[0].caseData, path = try temporaryArchive()
        let m = archiveManifest(sample), archive = StockBacktestArchive(directory: path)
        try archive.create(m)
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as! [String: Any]
        for field in ["accountSeq", "token", "quantity"] {
            for array in ["dailyCloses", "minutes"] {
                var c = base, i = c["input"] as! [String: Any], rows = i[array] as! [[String: Any]]
                rows[0][field] = 1; i[array] = rows; c["input"] = i
                XCTAssertThrowsError(try archive.saveCase(runID: m.runID, body: JSONSerialization.data(withJSONObject: c)))
            }
            var c = base, source = c["source"] as! [String: Any], pages = source["minutePages"] as! [[String: Any]]
            pages[0][field] = 1; source["minutePages"] = pages; c["source"] = source
            XCTAssertThrowsError(try archive.saveCase(runID: m.runID, body: JSONSerialization.data(withJSONObject: c)))
            let mb = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
            for nested in [false, true] {
                var object = mb
                if nested { var entries = object["cases"] as! [[String: Any]]; entries[0][field] = 1; object["cases"] = entries }
                else { object[field] = 1 }
                XCTAssertThrowsError(try StockBacktestArchive.decodeManifest(JSONSerialization.data(withJSONObject: object)))
            }
            let forecast = try XCTUnwrap(StockBacktest.predict(input: sample.input, interval: .day).forecast)
            let r = StockBacktestResult(version: 1, caseID: sample.input.caseID, inputSHA256: wireHash,
                calculationVersion: "replay-v1", computedAt: sample.target.fetchedAt,
                outcomes: [.init(model: m.models[0], status: .forecast, reason: nil, forecast: forecast)])
            let rb = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
            for level in 0...2 {
                var object = rb
                if level == 0 { object[field] = 1 }
                else {
                    var rows = object["outcomes"] as! [[String: Any]]
                    if level == 1 { rows[0][field] = 1 }
                    else { var f = rows[0]["forecast"] as! [String: Any]; f[field] = 1; rows[0]["forecast"] = f }
                    object["outcomes"] = rows
                }
                XCTAssertThrowsError(try archive.saveResult(runID: m.runID, body: JSONSerialization.data(withJSONObject: object)))
            }
        }
        for field in ["version", "runID", "models"] {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
            object[field] = field == "version" ? 2 : field == "runID" ? "../invalid" : ["unknown"] as Any
            XCTAssertThrowsError(try StockBacktestArchive.decodeManifest(JSONSerialization.data(withJSONObject: object)))
        }
        for path in ["../history", "/tmp/history", "us_TEST_2026-02-30", "us_TEST_2026-09-25\\foo"] {
            XCTAssertThrowsError(try archive.loadResult(runID: m.runID, caseID: path))
        }
    }

    func testKernelWriteAndRenameFailuresPreserveOriginalFiles() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission failure requires an unprivileged test user") }
        let sample = try StockBacktest.decodeCase(wireBody), m = archiveManifest(sample)
        let path = try temporaryArchive(), archive = StockBacktestArchive(directory: path)
        try archive.create(m)
        let run = path.appending(path: m.runID.uuidString.lowercased()), cases = run.appending(path: "cases")
        let original = try Data(contentsOf: run.appending(path: "manifest.json"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: run.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cases.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cases.path)
        XCTAssertThrowsError(try archive.saveCase(runID: m.runID, body: wireBody))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cases.path)
        _ = try archive.saveCase(runID: m.runID, body: wireBody)
        let failing = StockBacktestArchive(directory: path, fault: { stage in
            if stage == "place" { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: run.path) }
        })
        XCTAssertThrowsError(try failing.updateProgress(runID: m.runID, entries: m.cases, status: .paused))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: run.path)
        XCTAssertEqual(try Data(contentsOf: run.appending(path: "manifest.json")), original)
        XCTAssertEqual(try archive.loadCase(runID: m.runID, caseID: sample.input.caseID).body, wireBody)
    }

    private func duplicateJSON(_ body: Data, key: String, value: Any, first: Bool, escaped: Bool = false) throws -> Data {
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        let keyText = escaped ? "\"\\u" + String(format: "%04x", key.utf8.first!) + key.dropFirst() + "\""
            : try XCTUnwrap(String(data: JSONEncoder().encode(key), encoding: .utf8))
        let valueText = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8))
        let member = keyText + ":" + valueText
        return Data((first ? "{" + member + "," + text.dropFirst() : text.dropLast() + "," + member + "}").utf8)
    }
    func testDuplicateRawCaseAndResultKeysRejectWithoutWriting() throws {
        let c = try StockBacktest.decodeCase(wireBody), m = archiveManifest(c), path = try temporaryArchive()
        let archive = StockBacktestArchive(directory: path); try archive.create(m)
        let caseObject = try JSONSerialization.jsonObject(with: wireBody) as! [String: Any]
        let source = caseObject["source"] as! [String: Any]
        let rb = try resultBody(c.input.caseID, hash: wireHash)
        let resultObject = try JSONSerialization.jsonObject(with: rb) as! [String: Any]
        let run = path.appending(path: m.runID.uuidString.lowercased())
        let originalManifest = try Data(contentsOf: run.appending(path: "manifest.json"))
        for first in [false, true] {
            for escaped in [false, true] {
                for field in ["token", "accountSeq", "quantity"] {
                    var badSource = source; badSource[field] = "SYNTHETIC_ONLY"
                    let ambiguous = try duplicateJSON(wireBody, key: "source", value: badSource, first: first, escaped: escaped)
                    XCTAssertThrowsError(try archive.saveCase(runID: m.runID, body: ambiguous))
                    // A duplicate inside a nested page, without changing the surrounding dictionary.
                    let page = (source["minutePages"] as! [[String: Any]])[0]
                    let pageBody = try JSONSerialization.data(withJSONObject: page, options: [.sortedKeys])
                    let repeated = try duplicateJSON(pageBody, key: "before", value: page["before"]!, first: first, escaped: escaped)
                    let sourceBody = Data(("{\"provider\":\"toss\",\"calendarFetchedAt\":1790366460000,\"dailyFetchedAt\":1790366460000,\"minutePages\":[" + String(decoding: repeated, as: UTF8.self) + "]}").utf8)
                    var nested = caseObject; nested.removeValue(forKey: "source")
                    let withoutSource = try JSONSerialization.data(withJSONObject: nested)
                    let nestedBody = Data((String(decoding: withoutSource.dropLast(), as: UTF8.self) + ",\"source\":" + String(decoding: sourceBody, as: UTF8.self) + "}").utf8)
                    XCTAssertThrowsError(try archive.saveCase(runID: m.runID, body: nestedBody))
                }
                var badOutcome = (resultObject["outcomes"] as! [[String: Any]])[0]
                badOutcome["quantity"] = "SYNTHETIC_ONLY"
                let ambiguousResult = try duplicateJSON(rb, key: "outcomes", value: [badOutcome], first: first, escaped: escaped)
                // Case is absent during rejected case inputs, then present for actual result writes.
                _ = try archive.saveCase(runID: m.runID, body: wireBody)
                XCTAssertThrowsError(try archive.saveResult(runID: m.runID, body: ambiguousResult))
                let outcomeBody = try JSONSerialization.data(withJSONObject: (resultObject["outcomes"] as! [[String: Any]])[0])
                let repeatedOutcome = try duplicateJSON(outcomeBody, key: "model", value: m.models[0], first: first, escaped: escaped)
                var resultWithoutOutcomes = resultObject; resultWithoutOutcomes.removeValue(forKey: "outcomes")
                let resultPrefix = try JSONSerialization.data(withJSONObject: resultWithoutOutcomes)
                let nestedResult = Data((String(decoding: resultPrefix.dropLast(), as: UTF8.self) + ",\"outcomes\":[" + String(decoding: repeatedOutcome, as: UTF8.self) + "]}").utf8)
                XCTAssertThrowsError(try archive.saveResult(runID: m.runID, body: nestedResult))
            }
        }
        XCTAssertEqual(try Data(contentsOf: run.appending(path: "manifest.json")), originalManifest)
        XCTAssertEqual(try archive.loadCase(runID: m.runID, caseID: c.input.caseID).body, wireBody)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: run.appending(path: "results").path), [])
    }
    func testRawKeyScanUsesDecodedAliasesAndObjectScopes() throws {
        let valid = Data(#"{"a":"quote\" slash\\ } : [","rows":[{"same":1},{"same":2}],"pro\u0076ider":"toss"}"#.utf8)
        XCTAssertNoThrow(try StockBacktest.jsonObject(valid))
        let alias = Data("{\"provider\":1,\"pro\\u0076ider\" \n\t:2}".utf8)
        XCTAssertThrowsError(try StockBacktest.jsonObject(alias))
        XCTAssertThrowsError(try StockBacktest.jsonObject(Data(#"{"rows":[{"k":1,"k":2}]}"#.utf8)))
    }
    func testProgressAuditsPayloadsOnceAndRejectsSkippingOrphanEvidence() throws {
        let c = try StockBacktest.decodeCase(wireBody), path = try temporaryArchive()
        var archive = StockBacktestArchive(directory: path)
        let m = archiveManifest(c)
        try archive.create(m); _ = try archive.saveCase(runID: m.runID, body: wireBody)
        _ = try archive.saveResult(runID: m.runID, body: resultBody(c.input.caseID, hash: wireHash))
        let reads = BacktestReadCounter()
        archive.fault = { stage in if stage == "read:" + c.input.caseID + ".json" { reads.increment() } }
        try archive.updateProgress(runID: m.runID, entries: m.cases, status: .paused)
        XCTAssertEqual(reads.value, 2)
        let manifestURL = path.appending(path: m.runID.uuidString.lowercased()).appending(path: "manifest.json")
        let original = try Data(contentsOf: manifestURL)
        var skipped = m.cases; skipped[0].status = .skipped; skipped[0].reason = "synthetic"
        XCTAssertThrowsError(try archive.updateProgress(runID: m.runID, entries: skipped, status: .paused))
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
        var saved = m.cases; saved[0].status = .saved; saved[0].inputSHA256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try archive.updateProgress(runID: m.runID, entries: saved, status: .paused))
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
    }
    func testSelectedReadsValidateBindingWithoutAuditingUnrelatedPayloads() throws {
        let c = try StockBacktest.decodeCase(wireBody), path = try temporaryArchive()
        var archive = StockBacktestArchive(directory: path)
        let secondBody = Data(String(decoding: wireBody, as: UTF8.self).replacingOccurrences(of: "TEST", with: "TEST2").utf8)
        let second = try StockBacktest.decodeCase(secondBody)
        var m = archiveManifest(c); m.symbols.append(second.input.stockID)
        var entry = m.cases[0]; entry.caseID = second.input.caseID; entry.stockID = second.input.stockID
        m.cases.append(entry)
        try archive.create(m)
        _ = try archive.saveCase(runID: m.runID, body: wireBody)
        _ = try archive.saveCase(runID: m.runID, body: secondBody)
        let rb = try resultBody(c.input.caseID, hash: wireHash)
        _ = try archive.saveResult(runID: m.runID, body: rb)
        let run = path.appending(path: m.runID.uuidString.lowercased())
        try Data("{}".utf8).write(to: run.appending(path: "cases").appending(path: second.input.caseID + ".json"))
        let reads = BacktestReadCounter()
        archive.fault = { stage in if stage.hasPrefix("read:us_") { reads.increment() } }
        XCTAssertEqual(try archive.loadCase(runID: m.runID, caseID: c.input.caseID).body, wireBody)
        XCTAssertEqual(reads.value, 1); reads.reset()
        XCTAssertEqual(try archive.loadResult(runID: m.runID, caseID: c.input.caseID), rb)
        XCTAssertEqual(reads.value, 2)
        XCTAssertThrowsError(try archive.loadManifest(runID: m.runID))
        XCTAssertThrowsError(try archive.saveCase(runID: m.runID, body: wireBody))
        XCTAssertThrowsError(try archive.updateProgress(runID: m.runID, entries: m.cases, status: .paused))
        // Selected corruption and result binding still fail closed.
        try Data(String(decoding: rb, as: UTF8.self).replacingOccurrences(of: wireHash, with: String(repeating: "0", count: 64)).utf8)
            .write(to: run.appending(path: "results").appending(path: c.input.caseID + ".json"))
        XCTAssertThrowsError(try archive.loadResult(runID: m.runID, caseID: c.input.caseID))
        try Data("{}".utf8).write(to: run.appending(path: "cases").appending(path: c.input.caseID + ".json"))
        XCTAssertThrowsError(try archive.loadCase(runID: m.runID, caseID: c.input.caseID))
    }
    func testDuplicateRawManifestBlocksAllWritesAndPreservesOriginalBytes() throws {
        let c = try StockBacktest.decodeCase(wireBody)
        for first in [false, true] {
            for escaped in [false, true] {
                let path = try temporaryArchive(), archive = StockBacktestArchive(directory: path), m = archiveManifest(c)
                try archive.create(m)
                let run = path.appending(path: m.runID.uuidString.lowercased()), url = run.appending(path: "manifest.json")
                let original = try Data(contentsOf: url)
                var entry = (try JSONSerialization.jsonObject(with: original) as! [String: Any])["cases"] as! [[String: Any]]
                entry[0]["accountSeq"] = "SYNTHETIC_ONLY"
                let ambiguous = try duplicateJSON(original, key: "cases", value: entry, first: first, escaped: escaped)
                try ambiguous.write(to: url)
                XCTAssertThrowsError(try archive.loadManifest(runID: m.runID))
                XCTAssertThrowsError(try archive.list())
                XCTAssertThrowsError(try archive.saveCase(runID: m.runID, body: wireBody))
                XCTAssertThrowsError(try archive.updateProgress(runID: m.runID, entries: m.cases, status: .paused))
                XCTAssertEqual(try Data(contentsOf: url), ambiguous)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: run.appending(path: "cases").path), [])
            }
        }
    }


    func testManifestSessionLimitIsPerMarket() throws {
        var m = archiveManifest(try StockBacktest.decodeCase(wireBody))
        m.symbols = ["us:AAPL", "kr:005930"]; m.cases = []
        func entry(_ id: String, _ offset: Int) -> StockBacktestManifest.Entry {
            let date = String(format: "2026-09-%02d", offset + 1)
            return .init(caseID: id.replacingOccurrences(of: ":", with: "_") + "_" + date, stockID: id,
                tradingDay: date, status: .pending, inputSHA256: nil, resultSHA256: nil, reason: nil)
        }
        for n in 0..<20 { m.cases.append(entry("us:AAPL", n)); m.cases.append(entry("kr:005930", n + 1)) }
        XCTAssertEqual(Set(m.cases.map(\.tradingDay)).count, 21)
        XCTAssertEqual(m.cases.count, 40)
        let encoder = JSONEncoder()
        XCTAssertEqual(try StockBacktestArchive.decodeManifest(encoder.encode(m)), m)
        var sameMarket = m; sameMarket.symbols.append("us:MSFT"); sameMarket.cases.append(entry("us:MSFT", 20))
        XCTAssertLessThanOrEqual(sameMarket.cases.count, sameMarket.symbols.count * sameMarket.sessions)
        XCTAssertThrowsError(try StockBacktestArchive.decodeManifest(encoder.encode(sameMarket)))
        var totalInvalid = m; totalInvalid.cases.append(entry("us:AAPL", 20))
        XCTAssertGreaterThan(totalInvalid.cases.count, totalInvalid.symbols.count * totalInvalid.sessions)
        XCTAssertThrowsError(try StockBacktestArchive.decodeManifest(encoder.encode(totalInvalid)))
        var identityInvalid = m; identityInvalid.cases[0].stockID = "kr:005930"
        XCTAssertThrowsError(try StockBacktestArchive.decodeManifest(encoder.encode(identityInvalid)))
        var hashInvalid = m; hashInvalid.cases[0].status = .saved; hashInvalid.cases[0].inputSHA256 = "invalid"
        XCTAssertThrowsError(try StockBacktestArchive.decodeManifest(encoder.encode(hashInvalid)))
        var duplicate = m; duplicate.cases[1] = duplicate.cases[0]
        XCTAssertThrowsError(try StockBacktestArchive.decodeManifest(encoder.encode(duplicate)))
    }
    @MainActor
    func testCollectorFreezesDivergentMarketCalendars() async throws {
        let archive = StockBacktestArchive(directory: try temporaryArchive())
        let us = BacktestPublicFixture(market: .us, mode: "partial", dailyCount: 2)
        let kr = BacktestPublicFixture(market: .kr, mode: "partial", dailyCount: 2)
        var clock = StockBacktestStore.timestamp("2026-09-25T19:30:00Z")!, candleRequests = 0
        var store: StockBacktestStore!
        func dates(_ latest: String) -> [String] {
            var date = latest, result: [String] = []
            for _ in 0..<20 { result.append(date); date = us.previous(date) }; return result
        }
        let usDates = dates("2026-09-24"), krDates = dates("2026-09-25")
        store = StockBacktestStore(archive: archive, request: { request in
            let fixture: BacktestPublicFixture
            switch request {
            case .calendar(let market, _): fixture = market == .us ? us : kr
            case .candles(let stock, _, _, _, _):
                fixture = stock.market == .us ? us : kr; candleRequests += 1
                let m = try XCTUnwrap(store.runs.first)
                XCTAssertEqual(m.cases.filter { $0.stockID == us.stock.id }.map(\.tradingDay), usDates)
                XCTAssertEqual(m.cases.filter { $0.stockID == kr.stock.id }.map(\.tradingDay), krDates)
                XCTAssertEqual(Set(m.cases.map(\.tradingDay)).count, 21)
            }
            fixture.clock = clock; return try await fixture.request(request)
        }, now: { StockBacktest.date(clock) }, sleep: { clock += Int64($0) }, provider: { .toss })
        try await store.start(symbols: [us.stock, kr.stock], sessions: 20)
        let m = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(m.status, .completed); XCTAssertEqual(m.cases.count, 40)
        XCTAssertEqual(candleRequests, 120); XCTAssertTrue(m.cases.allSatisfy { $0.status == .saved })
        XCTAssertEqual(try archive.loadManifest(runID: m.runID).cases, m.cases)
    }

    @MainActor
    func testCollectorsUseOnlyFrozenPublicInputs() async throws {
        let path = try temporaryArchive(), fixture = BacktestPublicFixture()
        let archive = StockBacktestArchive(directory: path)
        let store = fixture.store(archive)
        XCTAssertEqual(fixture.calls.count, 0)
        try await store.start(symbols: [fixture.stock], sessions: 60)
        let m = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(m.status, .completed); XCTAssertEqual(m.cases.count, 60)
        XCTAssertTrue(m.cases.allSatisfy { $0.status == .saved })
        XCTAssertEqual(fixture.calls.filter { if case .calendar = $0.0 { return true }; return false }.count, 60)
        XCTAssertEqual(fixture.calls.filter { if case .candles(_, "1d", _, _, _) = $0.0 { return true }; return false }.count, 60)
        XCTAssertEqual(fixture.calls.count, 300)
        for (a, b) in zip(fixture.calls, fixture.calls.dropFirst()) { XCTAssertGreaterThanOrEqual(b.1 - a.1, 250) }
        var originals: [String: Data] = [:]
        for e in m.cases {
            let stored = try archive.loadCase(runID: m.runID, caseID: e.caseID), c = try StockBacktest.decodeCase(stored.body)
            originals[e.caseID] = stored.body
            XCTAssertEqual(c.source.minutePages.count, 3); XCTAssertEqual(c.input.minutes.count, 330)
            XCTAssertEqual(c.input.dailyCloses.count, 61); XCTAssertEqual(c.input.previousClose, Decimal(string: "100.01"))
            XCTAssertEqual(fixture.day(c.input.dailyCloses[0].date), fixture.previous(e.tradingDay))
            XCTAssertTrue(c.input.minutes.allSatisfy { $0.end <= c.input.cutoff })
            XCTAssertFalse(c.input.minutes.contains { $0.end == c.input.sessionEnd })
            XCTAssertEqual(c.target.actualClose, 100)
        }
        let count = fixture.calls.count
        try await store.resume(runID: m.runID)
        XCTAssertEqual(fixture.calls.count, count)
        for e in m.cases { XCTAssertEqual(try archive.loadCase(runID: m.runID, caseID: e.caseID).body, originals[e.caseID]) }
        XCTAssertEqual(store.progress, .init(completed: 60, total: 60)); XCTAssertNil(store.activeRunID)
    }
    @MainActor
    func testSessionMismatchIsSkipped() async throws {
        let f = BacktestPublicFixture(market: .kr, mode: "mismatch"), archive = StockBacktestArchive(directory: try temporaryArchive())
        let store = f.store(archive); try await store.start(symbols: [f.stock], sessions: 20)
        XCTAssertTrue(store.runs[0].cases.allSatisfy { $0.status == .skipped && $0.reason == "session_target_mismatch" && $0.inputSHA256 == nil })
        XCTAssertEqual(f.calls.filter { if case .candles(_, "1m", _, _, _) = $0.0 { return true }; return false }.count, 20)
    }
    @MainActor
    func testCollectorPreviousDayGapAndPartialModelShortage() async throws {
        let gap = BacktestPublicFixture(mode: "previous-gap"), store = gap.store(.init(directory: try temporaryArchive()))
        try await store.start(symbols: [gap.stock], sessions: 20)
        XCTAssertTrue(store.runs[0].cases.allSatisfy { $0.reason == "missing_previous_close" })
        XCTAssertEqual(gap.calls.count, 40)
        let f = BacktestPublicFixture(mode: "partial", dailyCount: 2), archive = StockBacktestArchive(directory: try temporaryArchive()), short = f.store(archive)
        try await short.start(symbols: [f.stock], sessions: 20)
        let m = short.runs[0], e = m.cases[0], c = try StockBacktest.decodeCase(archive.loadCase(runID: m.runID, caseID: e.caseID).body)
        XCTAssertEqual(e.status, .saved)
        XCTAssertEqual(StockBacktest.predict(input: c.input, interval: .day).reason, "insufficient_daily_history")
        XCTAssertEqual(StockBacktest.predict(input: c.input, interval: .minute).status, .forecast)
        XCTAssertEqual(StockBacktest.predict(input: c.input, interval: .tenMinutes).reason, "insufficient_intraday_history")
    }
    @MainActor
    func testCollectorCursorConflictsAndRawBounds() async throws {
        for (mode, reason) in [("cursor", "repeated_cursor"), ("conflict", "conflicting_duplicate")] {
            let f = BacktestPublicFixture(mode: mode), store = f.store(.init(directory: try temporaryArchive()))
            try await store.start(symbols: [f.stock], sessions: 20)
            XCTAssertTrue(store.runs[0].cases.allSatisfy { $0.reason == reason })
        }
        let f = BacktestPublicFixture(mode: "bounds"), archive = StockBacktestArchive(directory: try temporaryArchive()), store = f.store(archive)
        try await store.start(symbols: [f.stock], sessions: 20)
        let m = store.runs[0], c = try StockBacktest.decodeCase(archive.loadCase(runID: m.runID, caseID: m.cases[0].caseID).body)
        XCTAssertEqual(c.source.minutePages.count, 7); XCTAssertLessThanOrEqual(c.input.minutes.count, 1_400)
        XCTAssertEqual(f.calls.count, 20 * 9) // calendar, daily, seven minute pages = 1,400 raw rows, including proof.
    }
    @MainActor
    func testCollectorActiveFreezeCancelLateRepliesAndRevision() async throws {
        for changeRevision in [false, true] {
            let f = BacktestPublicFixture(), archive = StockBacktestArchive(directory: try temporaryArchive())
            var release: CheckedContinuation<Void, Never>?, entered = false, revision = 0
            let store = StockBacktestStore(archive: archive, request: { request in
                entered = true
                await withCheckedContinuation { release = $0 }
                return try await f.request(request)
            }, now: { f.now }, sleep: { f.clock += Int64($0) }, revision: { revision }, provider: { .toss })
            let active = Task { try await store.start(symbols: [f.stock], sessions: 60) }
            while !entered { await Task.yield() }
            XCTAssertNotNil(store.activeRunID); XCTAssertEqual(store.progress.total, 60)
            do { try await store.start(symbols: [f.stock], sessions: 20); XCTFail("double start accepted") } catch {}
            if changeRevision { revision += 1 } else { store.cancel() }
            release?.resume()
            do { try await active.value; XCTFail("late reply accepted") } catch {}
            XCTAssertEqual(store.errorMessage, "collection_cancelled"); XCTAssertNil(store.activeRunID)
            XCTAssertEqual(try archive.list(), [])
        }
    }
    @MainActor
    func testCollectorPausedAuthenticationAndOrphanResume() async throws {
        let f = BacktestPublicFixture(), archive = StockBacktestArchive(directory: try temporaryArchive())
        var attempts = 0
        let store = StockBacktestStore(archive: archive, request: { request in
            if case .candles = request { attempts += 1; throw TossInvestAPI.Failure.http(401) }
            return try await f.request(request)
        }, now: { f.now }, sleep: { f.clock += Int64($0) }, provider: { .toss })
        do { try await store.start(symbols: [f.stock], sessions: 20); XCTFail("auth accepted") } catch {}
        let m = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(m.status, .paused); XCTAssertEqual(attempts, 1); XCTAssertEqual(store.errorMessage, "authentication_paused")
        XCTAssertTrue(m.cases.allSatisfy { $0.status == .pending })
        // Place a valid synthetic orphan from the frozen entry. Resume must connect its exact bytes, without its calendar/candles.
        let e = m.cases[0], c = try f.caseData(e), encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let body = try encoder.encode(c); _ = try archive.saveCase(runID: m.runID, body: body)
        let resumed = f.store(archive), before = f.calls.count
        try await resumed.resume(runID: m.runID)
        XCTAssertEqual(f.calls.count - before, 19 * 5)
        XCTAssertTrue(f.calls.dropFirst(before).prefix(19).allSatisfy { if case .calendar = $0.0 { return true }; return false })
        XCTAssertEqual(try archive.loadCase(runID: m.runID, caseID: e.caseID).body, body)
        XCTAssertEqual(resumed.runs[0].cases[0].inputSHA256, StockBacktestArchive.hash(body))
    }
    @MainActor
    func testCollectorArchiveIOOffMainAndInitialListCannotOverwriteStart() async throws {
        let path = try temporaryArchive(), f = BacktestPublicFixture(mode: "partial")
        var archive = StockBacktestArchive(directory: path)
        archive.fault = { _ in XCTAssertFalse(Thread.isMainThread) }
        let store = f.store(archive)
        try await store.start(symbols: [f.stock], sessions: 20)
        await Task.yield()
        XCTAssertEqual(store.runs.count, 1); XCTAssertEqual(store.runs[0].status, .completed)
    }
    func testCollectorPublicPageOffsetEncodingStrictRowsAndDuplicates() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [BacktestPublicEndpoint.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        BacktestPublicEndpoint.reset()
        let stock = WatchedStock.parse("KR:005930")!, before = "2026-09-25T15:30:00+09:00"
        let reply = try await TossInvestAPI.backtestPage(token: "SYNTHETIC_PUBLIC", stock: stock, interval: "1m", before: before, session: session)
        guard case .candles(let values, let next, _) = reply else { return XCTFail("wrong reply") }
        XCTAssertEqual(values.count, 2); XCTAssertEqual(next, "2026-09-25T15:29:00+09:00")
        let request = try XCTUnwrap(BacktestPublicEndpoint.requests.first), url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/v1/candles"); XCTAssertTrue(url.absoluteString.contains("%2B09:00"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "before" }?.value, before)
        XCTAssertEqual(items.first { $0.name == "count" }?.value, "200"); XCTAssertEqual(items.first { $0.name == "adjusted" }?.value, "true")
        for mode in ["timestamp", "ohlc", "volume", "order", "oversize", "numeric", "boolean"] {
            BacktestPublicEndpoint.reset(mode: mode)
            do { _ = try await TossInvestAPI.backtestPage(token: "SYNTHETIC_PUBLIC", stock: stock, interval: "1d", before: before, session: session); XCTFail("invalid page accepted: " + mode) } catch {}
        }
        XCTAssertTrue(BacktestPublicEndpoint.requests.allSatisfy { $0.url?.path == "/api/v1/candles" })
    }
}

private final class BacktestReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
}

@MainActor
private final class BacktestPublicFixture {
    var clock: Int64 = 1_790_373_600_000 // 2026-09-25 22:00Z
    var now: Date { StockBacktest.date(clock) }
    let market: WatchedStock.Market
    let mode: String
    let dailyCount: Int
    var shortMinutes = 60.0
    var shortDay: String?
    var calls: [(StockBacktestRequest, Int64)] = []
    var stock: WatchedStock { WatchedStock.parse(market == .kr ? "KR:005930" : "AAPL")! }
    init(market: WatchedStock.Market = .us, mode: String = "", dailyCount: Int = 61) {
        self.market = market; self.mode = mode; self.dailyCount = dailyCount
    }
    func store(_ archive: StockBacktestArchive) -> StockBacktestStore {
        StockBacktestStore(archive: archive, request: { try await self.request($0) }, now: { self.now }, sleep: { self.clock += Int64($0) }, provider: { .toss })
    }
    func day(_ time: Int64) -> String {
        var c = Calendar(identifier: .gregorian); c.timeZone = StockQuoteCodec.timeZone(for: market)
        return StockBacktest.day(StockBacktest.date(time), calendar: c)
    }
    func midnight(_ day: String, market: WatchedStock.Market? = nil) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = StockQuoteCodec.timeZone(for: market ?? self.market); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)!
    }
    func previous(_ day: String) -> String {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        var d = ISO8601DateFormatter().date(from: day + "T12:00:00Z")!
        repeat { d = c.date(byAdding: .day, value: -1, to: d)! } while [1,7].contains(c.component(.weekday, from: d))
        return StockBacktest.day(d, calendar: c)
    }
    func trading(_ day: String, market: WatchedStock.Market? = nil) -> TradingSession {
        let m = market ?? self.market, at = midnight(day, market: m)
        return TradingSession(startTime: at.addingTimeInterval(m == .kr ? 9 * 3600 : 9.5 * 3600), endTime: at.addingTimeInterval(m == .kr ? 15.5 * 3600 : 16 * 3600))
    }
    func calendar(_ day: String, market: WatchedStock.Market) -> MarketSessions {
        func body(_ day: String) -> MarketSessionDay {
            var r = trading(day, market: market)
            if day == shortDay { r = TradingSession(startTime: r.startTime, endTime: r.startTime.addingTimeInterval(shortMinutes * 60)) }
            return MarketSessionDay(integrated: market == .kr ? IntegratedMarket(regularMarket: r) : nil,
                regularMarket: market == .us ? r : nil, dayMarket: nil, preMarket: nil, afterMarket: nil)
        }
        return MarketSessions(today: body(day), previousBusinessDay: body(previous(day)), nextBusinessDay: nil)
    }
    func bar(_ end: Date, _ price: Decimal) -> StockCandle { StockCandle(end: end, open: price, high: price + 1, low: price - 1, close: price, volume: 0) }
    func request(_ request: StockBacktestRequest) async throws -> StockBacktestReply {
        calls.append((request, clock))
        switch request {
        case .calendar(let market, let date): return .calendar(value: calendar(date, market: market), requestedAt: clock)
        case .candles(let stock, let interval, let before, let count, let adjusted):
            XCTAssertEqual(count, 200); XCTAssertTrue(adjusted); XCTAssertTrue(["1m", "1d"].contains(interval))
            let bound = StockBacktestStore.timestamp(before)!, date = day(bound), trading = trading(date)
            if interval == "1d" {
                var d = date, values = [bar(midnight(d), 100)]
                for n in 0..<dailyCount { d = previous(d); if mode != "previous-gap" || n != 0 { values.append(bar(midnight(d), 100 + Decimal(n+1)/100)) } }
                return .candles(values: values, nextBefore: nil, requestedAt: clock)
            }
            XCTAssertEqual(stock.market, market)
            let end = Int64(trading.endTime.timeIntervalSince1970 * 1000), start = Int64(trading.startTime.timeIntervalSince1970 * 1000)
            var values: [StockCandle] = [], time = bound
            let step: Int64 = mode == "bounds" ? 1_000 : 60_000
            while time >= start + 60_000 && values.count < 200 {
                values.append(bar(StockBacktest.date(time), 100 + Decimal(end-time)/60_000/1_000)); time -= step
            }
            if mode == "mismatch", bound == end { values[0] = bar(StockBacktest.date(bound), 101) }
            var next = Int64(values.last!.end.timeIntervalSince1970 * 1000) > start + 60_000 ? ISO8601DateFormatter().string(from: values.last!.end) : nil
            if mode == "cursor", bound == end - 3_600_000 { next = before }
            if mode == "conflict", bound != end, bound != end - 3_600_000 { values[0] = bar(StockBacktest.date(bound), 102) }
            if mode == "partial" { values = Array(values.prefix(11)); next = nil }
            return .candles(values: values, nextBefore: next, requestedAt: clock)
        }
    }
    func caseData(_ e: StockBacktestManifest.Entry) throws -> StockBacktestCase {
        let r = trading(e.tradingDay), start = Int64(r.startTime.timeIntervalSince1970 * 1000), end = Int64(r.endTime.timeIntervalSince1970 * 1000), cutoff = end - 3_600_000
        let minutes = (0..<330).map { n -> StockBacktestInput.Minute in
            let t = start + Int64(n+1)*60_000, p = 100 + Decimal(end-t)/60_000/1_000
            return .init(end: t, open: p, high: p+1, low: p-1, close: p, volume: 0)
        }
        let input = StockBacktestInput(version: 1, caseID: e.caseID, stockID: e.stockID, market: market.rawValue, currency: "USD", tradingDay: e.tradingDay,
            sessionStart: start, sessionEnd: end, cutoff: cutoff, inputBarEnd: cutoff, inputPrice: minutes.last!.close, previousClose: 100.01,
            priceBasis: StockBacktest.priceBasis, dailyCloses: [.init(date: Int64(midnight(previous(e.tradingDay)).timeIntervalSince1970*1000), price: 100.01)], minutes: minutes)
        return .init(version: 1, input: input, target: .init(actualClose: 100, candleAt: Int64(midnight(e.tradingDay).timeIntervalSince1970*1000), fetchedAt: clock),
            source: .init(provider: "toss", calendarFetchedAt: clock, dailyFetchedAt: clock, minutePages: [.init(before: ISO8601DateFormatter().string(from: r.endTime), nextBefore: nil, fetchedAt: clock)]))
    }
}
private final class BacktestPublicEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var mode = ""
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(mode: String = "") { lock.withLock { Self.mode = mode; recorded = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let mode = Self.lock.withLock { Self.recorded.append(request); return Self.mode }
        var row: [String: Any] = ["timestamp":"2026-09-25T15:30:00+09:00", "openPrice":"100", "highPrice":"101", "lowPrice":"99", "closePrice":"100", "volume":"0"]
        if mode == "timestamp" { row["timestamp"] = "2026-09-25" }
        if mode == "ohlc" { row["highPrice"] = "1" }
        if mode == "volume" { row["volume"] = "-1" }
        if mode == "numeric" { row["closePrice"] = "100garbage" }
        if mode == "boolean" { row["closePrice"] = true }
        var rows = [row, row]
        if mode == "oversize" { rows = Array(repeating: row, count: 201) }
        if mode == "order" {
            var older = row; older["timestamp"] = "2026-09-25T15:29:00+09:00"
            rows = [row, older, row]
        }
        let body = try! JSONSerialization.data(withJSONObject: ["result":["candles":rows,"nextBefore":"2026-09-25T15:29:00+09:00"]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
}
