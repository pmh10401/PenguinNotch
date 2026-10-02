import Foundation
import XCTest
import Darwin
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

}
