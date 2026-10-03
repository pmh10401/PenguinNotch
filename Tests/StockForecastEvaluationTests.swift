import Foundation
import SwiftUI
import AppKit
import Vision
import XCTest
import Darwin
@testable import PenguinNotch

final class StockForecastEvaluationTests: XCTestCase {
    @MainActor
    func testFinalCompactReplayReceiptsAndComparisonControls() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/stock-forecast-evaluation-v1.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let cases = try XCTUnwrap(object["replayCases"] as? [[String: Any]])
        let body = try JSONSerialization.data(withJSONObject: cases[0]["caseData"]!)
        let c = try StockBacktest.decodeCase(body), hash = StockBacktestArchive.hash(body), runID = UUID()
        let r = StockBacktestResult(version: 1, caseID: c.input.caseID, inputSHA256: hash, calculationVersion: "replay-v1", computedAt: c.target.fetchedAt,
            outcomes: StockChartInterval.allCases.map { StockBacktest.predict(input: c.input, interval: $0) })
        let entry = StockBacktestManifest.Entry(caseID: c.input.caseID, stockID: c.input.stockID, tradingDay: c.input.tradingDay, status: .saved,
            inputSHA256: hash, resultSHA256: String(repeating: "b", count: 64), reason: nil)
        let loaded = StockBacktestLoadedCase(referenceID: runID.uuidString, entry: entry, caseData: c, result: r, inputSHA256: hash,
            resultSHA256: entry.resultSHA256, caseBody: body, resultBody: try JSONEncoder().encode(r), rawDetail: "ORIGINAL")
        let compact = try StockBacktestReceipt(runID: runID, loaded: loaded)
        XCTAssertEqual(compact.rows.count, 3); XCTAssertEqual(compact.outcomes?.count, 3)
        XCTAssertEqual(compact.inputSHA256, hash)
        let fields = Set(Mirror(reflecting: compact).children.compactMap(\.label))
        XCTAssertTrue(fields.isDisjoint(with: ["caseData", "caseBody", "resultBody", "rawDetail", "result"]))
        var rows = compact.rows; rows[2].actualClose = nil
        XCTAssertEqual(StockEvaluation.compare(rows, selectedModels: Set(rows.prefix(2).map(\.model))).pairedCount, 1)
        XCTAssertEqual(StockEvaluation.compare(rows, selectedModels: Set(rows.map(\.model))).pairedCount, 0)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let ui = try String(contentsOf: root.appending(path: "Sources/Settings/StockBacktestView.swift"), encoding: .utf8)
        XCTAssertTrue(ui.contains("LazyVStack")); XCTAssertTrue(ui.contains("store.loadReceipt(")); XCTAssertTrue(ui.contains(".task(id: rawCase)"))
        XCTAssertTrue(ui.contains("completeKey != loadKey"))
        XCTAssertTrue(ui.contains("@Binding var selectedModels: Set<String>?"))
    }

    func testTask6UnifiedHistoryContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appending(path: "Sources/Settings/StockSettings.swift"), encoding: .utf8)
        let history = try String(contentsOf: root.appending(path: "Sources/Settings/StockForecastHistoryView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("Forecast history and evaluation"))
        XCTAssertFalse(settings.contains("View Codex analysis history…"))
        XCTAssertTrue(history.contains("StockBacktestView(store: backtests)"))
        XCTAssertTrue(history.contains("StockEvaluation.rows(journal:"))
        XCTAssertTrue(history.contains("Saved analysis requests/responses"))
        let previousLocale = L10n.testLocale
        defer { L10n.testLocale = previousLocale }
        L10n.testLocale = Locale(identifier: "ko")
        XCTAssertEqual(L10n.t("Target day"), "목표 거래일")
        XCTAssertEqual(L10n.t("All"), "전체")
        XCTAssertEqual(L10n.t("Source"), "출처")
        XCTAssertEqual(L10n.t("Evaluated"), "평가 완료")
        XCTAssertEqual(L10n.t("Export forecast CSV"), "예측 CSV 내보내기")
    }
    @MainActor func testTask6SavedCohortsAndPublicRender() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "task6-public-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try fixture().records[0]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(base)) as? [String: Any])
        let malicious = "=TEST,\"quoted\"\nnext"
        json["name"] = malicious
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let sample = try decoder.decode(StockForecastRecord.self, from: JSONSerialization.data(withJSONObject: json))
        var scheduled = sample; scheduled.capture = .scheduled
        var pending = sample; pending.actualClose = nil; pending.evaluatedAt = nil
        let input = try StockCodexAnalysisInput(record: pending, now: pending.createdAt)
        let response = StockCodexAnalysisResponse(status: .forecast, expectedClose: 104, lowerClose: 100, upperClose: 106, riseProbability: 0.8, notes: "Public fixture response")
        let forecast = StockCodexAnalysis(id: UUID(), input: input, model: "public-mock", promptVersion: 1,
            createdAt: pending.createdAt, completedAt: pending.createdAt, response: response,
            resolution: .init(actualClose: 105, evaluatedAt: sample.evaluatedAt!))
        let abstain = StockCodexAnalysis(id: UUID(), input: input, model: "public-mock", promptVersion: 1,
            createdAt: pending.createdAt, completedAt: pending.createdAt,
            response: .init(status: .abstain, expectedClose: nil, lowerClose: nil, upperClose: nil, riseProbability: nil, notes: "Public fixture abstention"), resolution: nil)
        struct JournalFixture: Encodable { let version = 1; let records: [StockForecastRecord] }
        struct AnalysisFixture: Encodable { let version = 1; let analyses: [StockCodexAnalysis] }
        let journalURL = directory.appending(path: "history.json"), analysisURL = directory.appending(path: "analyses.json")
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(JournalFixture(records: [sample, scheduled])).write(to: journalURL)
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(AnalysisFixture(analyses: [forecast, abstain])).write(to: analysisURL)
        let journal = StockForecastJournal(url: journalURL)
        let analyses = StockCodexAnalysisStore(url: analysisURL, runner: { _, _ in XCTFail("No Codex execution in render"); throw CancellationError() })
        var requests = 0
        let backtests = StockBacktestStore(archive: StockBacktestArchive(directory: directory.appending(path: "Backtests")),
            request: { _ in requests += 1; XCTFail("No provider execution in render"); throw CancellationError() }, provider: { .toss })
        XCTAssertNil(journal.errorMessage); XCTAssertNil(analyses.errorMessage)
        XCTAssertEqual(journal.records.count, 2); XCTAssertEqual(analyses.analyses.count, 2)
        let saved = StockForecastHistoryView.savedAnalyses(analyses.analyses)
        XCTAssertEqual(saved.count, 2); XCTAssertEqual(saved.filter { $0.response.status == .abstain }.count, 1)
        XCTAssertEqual(StockForecastHistoryView.savedAnalyses(saved, capture: "scheduled").count, 0)
        XCTAssertEqual(StockForecastHistoryView.savedAnalyses(saved, stockID: "us:OTHER").count, 0)
        let rows = StockEvaluation.rows(journal: journal.records, analyses: analyses.analyses)
        let groups = EvaluationSummaryView.groups(rows)
        XCTAssertEqual(groups.count, 4, "Manual/scheduled GBM, Codex and paired GBM keep distinct cohorts")
        XCTAssertEqual(rows.count, 4, "Paired calculation adds a score, never a saved request")
        XCTAssertTrue(groups.allSatisfy { Set($0.rows.map(\.model)).count == 1 && Set($0.rows.map(\.capture)).count == 1 })
        XCTAssertTrue(groups.allSatisfy { StockEvaluation.calibration($0.rows).reduce(0) { $0 + $1.count } == 1 })
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        let raw = String(decoding: try encoder.encode(sample), as: UTF8.self)
        let csv = EvaluationSummaryView.csv(rows: rows, details: [sample.id: raw, abstain.id.uuidString: "Public fixture abstention"])
        let parsed = readCSV(csv), header = parsed[0]
        let exported = parsed.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
        XCTAssertTrue(exported.contains { $0["rawDetail"] == raw })
        XCTAssertTrue(exported.contains { $0["referenceID"] == abstain.id.uuidString })
        XCTAssertEqual(exported.filter { $0["type"] == "metrics" && $0["evaluated"] == "1" }.count, 4)
        let previousLocale = L10n.testLocale
        defer { L10n.testLocale = previousLocale }
        for language in ["en", "ko"] {
            L10n.testLocale = Locale(identifier: language)
            let views = [AnyView(StockForecastHistoryView(journal: journal, analyses: analyses, backtests: backtests)),
                         AnyView(StockBacktestView(store: backtests)),
                         AnyView(StockCodexHistoryView(store: analyses, journal: journal, backtests: backtests))]
            for (index, view) in views.enumerated() {
                // Native hosting is required for the ScrollView/segmented controls; ImageRenderer
                // flattened only the header. The window is never ordered on screen.
                let height = index == 1 ? 520.0 : 1100.0
                let content = view.padding(4).frame(width: 680, height: height)
                    .background(Color.white).environment(\.colorScheme, .light)
                let bitmap = try hostingSnapshot(content, height: height)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                var bodyInk = 0
                for y in stride(from: 100, to: bitmap.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        if let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.9,
                           max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) < 0.8 { bodyInk += 1 }
                    }
                }
                XCTAssertGreaterThan(bodyInk, 100, "Rendered body below header contains readable dark content, not just frame/PNG bytes")
                // An offscreen window has no published AX children. One local SDK recognition
                // request checks the actual bitmap labels and placement, not source strings.
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate; recognition.usesLanguageCorrection = false
                recognition.recognitionLanguages = language == "ko" ? ["ko-KR", "en-US"] : ["en-US"]
                try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([recognition])
                let labels = (recognition.results ?? []).compactMap { observation -> (text: String, frame: CGRect)? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return (text, observation.boundingBox)
                }
                func normalized(_ text: String) -> String { String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
                let text = normalized(labels.map(\.text).joined(separator: " "))
                if index != 1 {
                    XCTAssertTrue(text.contains(normalized(forecast.forecastModel)), "The rendered native body contains the injected Codex model")
                    if index == 0 { XCTAssertTrue(text.contains(normalized(forecast.pairedGBMRecord!.model)), "The rendered native body contains the paired GBM model") }
                    XCTAssertTrue(text.contains(normalized(L10n.t("Saved analysis requests/responses"))))
                    XCTAssertTrue(text.contains(normalized(L10n.t("MAPE minus baseline (percentage points)"))))
                    XCTAssertTrue(text.contains(normalized(L10n.t("Evaluation details"))))
                    XCTAssertFalse(text.contains(normalized(L10n.t("Price-hold baseline error"))), "Detailed metrics start collapsed")
                    XCTAssertFalse(text.contains(normalized(L10n.t("Probability check"))), "Calibration starts collapsed")
                    let summary = try XCTUnwrap(labels.first { normalized($0.text).contains(normalized(forecast.forecastModel)) })
                    XCTAssertLessThan(summary.frame.maxY, 0.85, "The actual Codex summary is below the header")
                    let detail = try XCTUnwrap(labels.filter { normalized($0.text).contains(normalized(L10n.t("Evaluation details"))) && $0.frame.maxY < summary.frame.minY }.max { $0.frame.maxY < $1.frame.maxY })
                    XCTAssertLessThan(detail.frame.maxY, summary.frame.minY, "Collapsed detail control follows its summary")
                } else {
                    XCTAssertTrue(text.contains(normalized(L10n.t("Start replay"))))
                    // Vision on CI consistently reads i as l in this caption. Canonicalize
                    // only that glyph pair in the English warning, never model identifiers.
                    let warning = normalized(L10n.t("Reconstructed from data fetched now; availability at the original time is not guaranteed."))
                    let warningText = language == "en" ? text.replacingOccurrences(of: "i", with: "l") : text
                    let expectedWarning = language == "en" ? warning.replacingOccurrences(of: "i", with: "l") : warning
                    XCTAssertTrue(warningText.contains(expectedWarning), "Replay disclaimer OCR (\(language), \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)): \(labels.map(\.text).joined(separator: " | "))")
                }
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "task6-public-\(language)-\(index)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(L10n.t("Reconstructed from data fetched now; availability at the original time is not guaranteed."),
            "현재 조회 자료로 재구성; 당시 정보만 사용한 검증을 보장하지 않음")
    }

    @MainActor private func hostingSnapshot<V: View>(_ content: V, height: Double) throws -> NSBitmapImageRep {
        let rect = NSRect(x: 0, y: 0, width: 680, height: height)
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: content); window.contentView = host
        host.frame = rect; defer { window.close() }
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private struct Fixture: Decodable {
        struct MetricCase: Decodable {
            let name: String
            let rows: [StockEvaluationRow]
            let expected: StockEvaluationMetrics
        }
        struct ReplaySample: Decodable {
            let caseData: StockBacktestCase
            let expected: [String: StockBacktestOutcome.Forecast]
        }
        let replayCases: [ReplaySample]
        let records: [StockForecastRecord]
        let rows: [StockEvaluationRow]
        let metricCases: [MetricCase]
    }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/stock-forecast-evaluation-v1.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Fixture.self, from: Data(contentsOf: url))
    }

    @MainActor
    func testIncompleteCohortNeverScoresAsZero() async throws {
        var cases = Array(try fixture().replayCases.prefix(2)).map(\.caseData)
        cases[1].input.dailyCloses = Array(cases[1].input.dailyCloses.prefix(2))
        let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let path = URL(fileURLWithPath: String(cString: canonical)).appending(path: "task5-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let archive = StockBacktestArchive(directory: path)
        let m = StockBacktestManifest(version: 1, runID: UUID(), createdAt: cases[0].target.fetchedAt,
            collectionStartedAt: cases[0].target.fetchedAt, collectionCompletedAt: nil, protocolVersion: "replay-v1",
            codeVersion: "task5-test", priceBasis: StockBacktest.priceBasis, cutoffMinutes: 60, sessions: 20,
            symbols: [cases[0].input.stockID], models: Array(StockBacktestArchive.models.prefix(2)), status: .ready,
            cases: cases.map { .init(caseID: $0.input.caseID, stockID: $0.input.stockID, tradingDay: $0.input.tradingDay,
                status: .pending, inputSHA256: nil, resultSHA256: nil, reason: nil) })
        try archive.create(m)
        for c in cases { _ = try archive.saveCase(runID: m.runID, body: JSONEncoder().encode(c)) }
        let store = StockBacktestStore(archive: archive, request: { _ in XCTFail("saved cases must not query"); throw CocoaError(.fileReadUnknown) }, provider: { .toss })
        try await store.resume(runID: m.runID)
        var loaded: [StockBacktestLoadedCase] = []
        for e in store.runs[0].cases {
            let c = try await store.loadCase(runID: m.runID, caseID: e.caseID)
            XCTAssertNotNil(c.result)
            loaded.append(c)
        }
        let summary = try StockEvaluation.replaySummary(manifest: store.runs[0], loaded: loaded, selectedModels: Set(m.models))
        XCTAssertEqual(summary.comparison.pairedCount, 1)
        for own in summary.models {
            XCTAssertEqual(own.success, own.model == m.models[0] ? 1 : 2)
            XCTAssertEqual(own.metrics.mape, own.metrics.baselineMAPE)
        }
        XCTAssertEqual(summary.requested, 2); XCTAssertEqual(summary.acquired, 2); XCTAssertEqual(summary.unavailable, 0)
        XCTAssertEqual(summary.stockCount, 1); XCTAssertEqual(summary.dayCount, 2)
        XCTAssertEqual(summary.models.first { $0.model == m.models[0] }?.skipped, 1)
        XCTAssertEqual(try StockEvaluation.replaySummary(manifest: store.runs[0], loaded: loaded, selectedModels: [m.models[1]]).comparison.pairedCount, 2)
        XCTAssertEqual(try StockEvaluation.replaySummary(manifest: store.runs[0], loaded: loaded, selectedModels: Set(m.models), day: cases[1].input.tradingDay).comparison.pairedCount, 0)
        let pair = summary.rows.filter { $0.inputKey == summary.rows[0].inputKey }
        XCTAssertEqual(pair.count, 2)
        for patch in 0..<4 {
            var other = pair[1]
            switch patch { case 0: other.actualClose = nil; case 1: other.actualClose = 1; case 2: other.inputKey = "other-hash"; default: other.capture = "manual" }
            XCTAssertEqual(StockEvaluation.compare([pair[0], other], selectedModels: Set(m.models)).pairedCount, 0)
        }
        var baseline = pair[0]; baseline.expectedClose = baseline.inputPrice
        baseline.lowerClose = nil; baseline.upperClose = nil; baseline.riseProbability = nil
        XCTAssertEqual(StockEvaluation.metrics([baseline]).mape, StockEvaluation.metrics([baseline]).baselineMAPE)
        XCTAssertNil(StockEvaluation.metrics([baseline]).brier); XCTAssertNil(StockEvaluation.metrics([baseline]).coverage)
        XCTAssertEqual(StockEvaluation.filtered(summary.rows, market: "kr").count, 0)
        XCTAssertEqual(StockEvaluation.filtered(summary.rows, stockID: cases[0].input.stockID, day: cases[0].input.tradingDay, capture: "replay", source: .replay).count, 2)
    }

    func testReplayBindingTargetOnlyScoresAndPublicFixtureParity() throws {
        for sample in try fixture().replayCases {
            let c = sample.caseData, hash = StockBacktestArchive.hash(try JSONEncoder().encode(c)), id = UUID()
            let r = StockBacktestResult(version: 1, caseID: c.input.caseID, inputSHA256: hash,
                calculationVersion: "replay-v1", computedAt: c.target.fetchedAt,
                outcomes: StockChartInterval.allCases.map { StockBacktest.predict(input: c.input, interval: $0) })
            let rows = try StockEvaluation.replayRows(runID: id, caseData: c, result: r, inputSHA256: hash)
            XCTAssertEqual(rows.count, 3)
            for row in rows {
                let interval = row.model.contains("daily") ? "1d" : row.model.contains("10m") ? "10m" : "1m"
                let expected = sample.expected[interval]!, m = StockEvaluation.metrics([row])
                XCTAssertEqual(row.expectedClose, c.input.inputPrice)
                for (actual, wanted) in [(row.lowerClose!, expected.lowerClose), (row.upperClose!, expected.upperClose)] {
                    let value = NSDecimalNumber(decimal: wanted).doubleValue
                    XCTAssertEqual(NSDecimalNumber(decimal: actual).doubleValue, value, accuracy: value * 1e-8)
                }
                XCTAssertEqual(row.riseProbability!, expected.riseProbability, accuracy: 1e-6)
                XCTAssertEqual(m.mape, m.baselineMAPE)
                XCTAssertEqual(m.brier!, pow(expected.riseProbability - (c.target.actualClose > c.input.previousClose ? 1 : 0), 2), accuracy: 1e-6)
                let width = NSDecimalNumber(decimal: (expected.upperClose - expected.lowerClose) / c.input.inputPrice * 100).doubleValue
                XCTAssertEqual(m.meanWidthPercent!, width, accuracy: 1e-6)
            }
            var changed = c; changed.target.actualClose = 1
            XCTAssertEqual(StockChartInterval.allCases.map { StockBacktest.predict(input: changed.input, interval: $0) }, r.outcomes)
            XCTAssertNotEqual(StockEvaluation.metrics(try StockEvaluation.replayRows(runID: id, caseData: changed, result: r, inputSHA256: hash)).mape,
                StockEvaluation.metrics(rows).mape)
            for patch in 0..<5 {
                var bad = r
                switch patch { case 0: bad.version = 2; case 1: bad.calculationVersion = "replay-v2"; case 2: bad.inputSHA256 = String(repeating: "0", count: 64)
                case 3: bad.caseID = "us_OTHER_2026-09-25"
                default: bad.outcomes = [.init(model: "unsupported", status: .skipped, reason: "insufficient_daily_history", forecast: nil)] }
                XCTAssertThrowsError(try StockEvaluation.replayRows(runID: id, caseData: c, result: bad, inputSHA256: hash))
            }
            changed.version = 2
            XCTAssertThrowsError(try StockEvaluation.replayRows(runID: id, caseData: changed, result: r, inputSHA256: hash))
        }
    }

    private func readCSV(_ body: String) -> [[String]] {
        let chars = Array(body), count = chars.count
        var rows: [[String]] = [], row: [String] = [], value = "", quoted = false, i = 0
        while i < count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < count && chars[i + 1] == "\"" { value.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if !quoted && c == "," { row.append(value); value = "" }
            else if !quoted && c == "\r\n" { row.append(value); rows.append(row); row = []; value = "" }
            else { value.append(c) }
            i += 1
        }
        XCTAssertFalse(quoted)
        return rows
    }

    func testReplayCalibrationMetricBoundsAndCSVOriginalDetailRoundtrip() throws {
        let base = try fixture().rows[0]
        var tie = base; tie.referenceID = " =PUBLIC(\"name\")"; tie.inputKey = "one"
        tie.riseProbability = 0.5; tie.actualClose = tie.previousClose; tie.lowerClose = tie.previousClose; tie.upperClose = tie.previousClose
        var high = base; high.inputKey = "two"; high.riseProbability = 1; high.actualClose = high.upperClose
        var low = base; low.inputKey = "three"; low.riseProbability = 0; low.lowerClose = low.previousClose - 1; low.actualClose = low.lowerClose
        var baseline = base; baseline.inputKey = "four"; baseline.riseProbability = nil; baseline.lowerClose = nil; baseline.upperClose = nil
        let rows = [tie, high, low, baseline], m = StockEvaluation.metrics(rows), bins = StockEvaluation.calibration(rows)
        XCTAssertEqual(m.evaluated, 4); XCTAssertEqual(m.directionCount, 2); XCTAssertEqual(m.coverage, 100)
        XCTAssertEqual(bins.reduce(0) { $0 + $1.count }, 3); XCTAssertEqual(bins.first { $0.id == 5 }?.rises, 0)
        for bin in bins {
            let existing = StockForecastCalibration(id: bin.id, count: bin.count, rises: bin.rises, meanProbability: bin.meanProbability)
            XCTAssertEqual(bin.interval, existing.interval); XCTAssertGreaterThanOrEqual(bin.interval.lowerBound, 0); XCTAssertLessThanOrEqual(bin.interval.upperBound, 1)
        }
        var huge = base; huge.inputPrice = 1; huge.expectedClose = 1000; huge.actualClose = 1; huge.lowerClose = 1; huge.upperClose = 1000
        XCTAssertEqual(StockEvaluation.metrics([huge]).mape, 99900); XCTAssertEqual(StockEvaluation.metrics([huge]).meanWidthPercent, 99900)
        XCTAssertTrue((0...1).contains(StockEvaluation.metrics([huge]).brier!))
        let raw = #"{"name":"=PUBLIC\nname", "precise":100.000000000000000000001,"reason":"insufficient_daily_history"}"# + "\n"
        tie.expectedClose = -5; tie.capture = "-manual"
        let csv = StockEvaluation.csv(rows: [tie, high, low, baseline], metrics: m,
            details: [tie.referenceID: raw, "skip-only": #"{"status":"skipped","reason":"missing_previous_close"}"#])
        let parsed = readCSV(csv), header = parsed[0]
        let records = parsed.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
        let forecast = try XCTUnwrap(records.first { $0["type"] == "forecast" })
        XCTAssertEqual(forecast["expectedClose"], "-5"); XCTAssertEqual(forecast["capture"], "'-manual")
        XCTAssertEqual(forecast["referenceID"], "' =PUBLIC(\"name\")"); XCTAssertEqual(forecast["rawDetail"], raw)
        XCTAssertEqual(forecast["source"], base.source.rawValue); XCTAssertEqual(forecast["inputKey"], "one")
        let totals = try XCTUnwrap(records.first { $0["type"] == "metrics" })
        XCTAssertEqual(totals["directionCount"], "2"); XCTAssertEqual(totals["probabilityCount"], "3"); XCTAssertEqual(totals["rangeCount"], "3")
        XCTAssertTrue(records.contains { $0["referenceID"] == "skip-only" && $0["rawDetail"]!.contains("missing_previous_close") })
    }

    func testSelectedModelsIgnoreUnselectedPendingModel() throws {
        let rows = StockEvaluation.rows(journal: try fixture().records, analyses: [])
        XCTAssertEqual(rows.count, 3)
        let comparison = StockEvaluation.compare(rows, selectedModels: ["A", "B"])
        XCTAssertEqual(comparison.pairedCount, 1)
        XCTAssertEqual(comparison.rows.map(\.model), ["A", "B"])
        XCTAssertTrue(comparison.rows.allSatisfy { $0.paired.evaluated == 1 })
        XCTAssertEqual(StockEvaluation.compare(rows, selectedModels: ["A", "B", "C"]).pairedCount, 0)
    }

    func testEquivalentPairedGBMCountsOnce() throws {
        let rows = try fixture().rows
        let comparison = StockEvaluation.compare(rows, selectedModels: ["A", "B"])
        XCTAssertEqual(comparison.pairedCount, 1)
        XCTAssertEqual(comparison.rows[0].available.evaluated, 1)
        XCTAssertEqual(StockEvaluation.metrics(Array(rows.prefix(2))).evaluated, 1)
        let sources = StockEvaluation.coalesced(rows).first!.references.map(\.source)
        XCTAssertEqual(Set(sources), [.recorded, .pairedCalculation])
        var conflict = rows[1]
        conflict.expectedClose = 103
        let excluded = StockEvaluation.compare([rows[0], conflict, rows[2]], selectedModels: ["A", "B"])
        XCTAssertEqual(excluded.pairedCount, 0)
        XCTAssertEqual(excluded.excludedConflicts, 1)
        conflict = rows[1]
        conflict.riseProbability = rows[1].riseProbability!.nextUp
        XCTAssertEqual(StockEvaluation.compare([rows[0], conflict, rows[2]], selectedModels: ["A", "B"]).pairedCount, 0)
        XCTAssertEqual(StockEvaluation.compare([rows[0], rows[0], rows[2]], selectedModels: ["A", "B"]).pairedCount, 0)
    }

    func testSharedMetricFixtureUnitsAndDenominators() throws {
        for sample in try fixture().metricCases {
            let result = StockEvaluation.metrics(sample.rows), expected = sample.expected
            XCTAssertEqual(result.total, expected.total, sample.name)
            XCTAssertEqual(result.evaluated, expected.evaluated, sample.name)
            XCTAssertEqual(result.directionCount, expected.directionCount, sample.name)
            XCTAssertEqual(result.directionHits, expected.directionHits, sample.name)
            for (actual, wanted) in [(result.mape, expected.mape), (result.baselineMAPE, expected.baselineMAPE),
                                     (result.brier, expected.brier), (result.coverage, expected.coverage),
                                     (result.meanWidthPercent, expected.meanWidthPercent)] {
                if let wanted { XCTAssertEqual(try XCTUnwrap(actual), wanted, accuracy: 1e-6, sample.name) }
                else { XCTAssertNil(actual, sample.name) }
            }
            XCTAssertEqual(Set(result.maeByCurrency.keys), Set(expected.maeByCurrency.keys))
            for (currency, wanted) in expected.maeByCurrency {
                XCTAssertEqual(try XCTUnwrap(result.maeByCurrency[currency]), wanted, accuracy: 1e-6)
            }
        }
    }

    func testDifferentTargetsInputsCapturesCurrenciesAndMissingEvidenceCannotPair() throws {
        let rows = try fixture().rows
        for patch in 0..<6 {
            var other = rows[2]
            switch patch {
            case 0: other.actualClose = 106
            case 1: other.inputKey = "different-evidence"
            case 2: other.capture = "scheduled"
            case 3: other.currency = "KRW"
            case 4: other.inputPrice = 103
            default: other.inputKey = nil
            }
            XCTAssertEqual(StockEvaluation.compare([rows[0], other], selectedModels: ["A", "B"]).pairedCount, 0)
        }
        var legacy = rows[0]
        legacy.inputKey = nil
        XCTAssertEqual(StockEvaluation.metrics([legacy]).evaluated, 1)
        XCTAssertEqual(StockEvaluation.compare([legacy], selectedModels: ["A"]).pairedCount, 1)
        XCTAssertEqual(StockEvaluation.compare([legacy, rows[2]], selectedModels: ["A", "B"]).excludedMissingEvidence, 1)
        XCTAssertEqual(StockEvaluation.compare(rows, selectedModels: []).pairedCount, 0)
        var replay = rows[2]
        replay.source = .replay
        XCTAssertEqual(StockEvaluation.compare([rows[0], replay], selectedModels: ["A", "B"]).pairedCount, 0)
        var differentInput = rows[1]
        differentInput.inputKey = "different-frozen-input"
        XCTAssertEqual(StockEvaluation.metrics([rows[0], differentInput]).evaluated, 2)
    }

    func testReadAdapterRejectsInvalidRecordsAndRetainsLegacyScores() throws {
        let record = try fixture().records[0]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        json["evidence"] = NSNull()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let legacy = try decoder.decode(StockForecastRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.isValid)
        let rows = StockEvaluation.rows(journal: [legacy], analyses: [])
        XCTAssertNil(rows.first?.inputKey)
        XCTAssertEqual(StockEvaluation.metrics(rows).evaluated, 1)
        json["currency"] = "KRW"
        let invalid = try decoder.decode(StockForecastRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(StockEvaluation.rows(journal: [invalid], analyses: []).isEmpty)
    }

    func testReadAdapterPreservesSubmillisecondQuoteDifferences() throws {
        let records = try fixture().records
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(records[1])) as? [String: Any])
        json["quoteAt"] = records[1].quoteAt.timeIntervalSince1970 * 1000 - 0.25
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let other = try decoder.decode(StockForecastRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(other.isValid)
        let rows = StockEvaluation.rows(journal: [records[0], other], analyses: [])
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].inputKey, rows[1].inputKey, "Different frozen quote times cannot be rounded into a pair")
        XCTAssertEqual(StockEvaluation.compare(rows, selectedModels: ["A", "B"]).pairedCount, 0)
    }

    func testFractionalSessionStartRetainsLegacyScoresAndExactFrozenIdentity() throws {
        let original = try fixture().records[0]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        let evidence = json["evidence"]!
        let start = original.sessionStart.timeIntervalSince1970 * 1000
        json["sessionStart"] = start + 0.25
        json["evidence"] = NSNull()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let legacy = try decoder.decode(StockForecastRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.isValid)
        let rows = StockEvaluation.rows(journal: [legacy], analyses: [])
        XCTAssertEqual(rows.count, 1)
        let score = StockForecastScore([legacy])
        XCTAssertEqual(score.total, 1)
        XCTAssertEqual(score.evaluated, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(try XCTUnwrap(score.meanError), 100.0 / 105, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(score.baselineError), 300.0 / 105, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(legacy.absolutePercentageError), 100.0 / 105, accuracy: 1e-10)
        XCTAssertEqual(row.sessionStart, Int64(start))
        XCTAssertNil(row.inputKey)

        json["evidence"] = evidence
        let first = try decoder.decode(StockForecastRecord.self, from: JSONSerialization.data(withJSONObject: json))
        json["model"] = "B"
        json["sessionStart"] = start + 0.75
        let second = try decoder.decode(StockForecastRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(first.isValid && second.isValid)
        let exact = StockEvaluation.rows(journal: [first, second], analyses: [])
        XCTAssertEqual(exact.count, 2)
        let firstRow = try XCTUnwrap(exact.first), secondRow = try XCTUnwrap(exact.last)
        XCTAssertEqual(firstRow.sessionStart, secondRow.sessionStart)
        XCTAssertNotEqual(firstRow.inputKey, secondRow.inputKey)
        XCTAssertEqual(StockEvaluation.compare(exact, selectedModels: ["A", "B"]).pairedCount, 0)
    }

    func testFrozenEvidenceAndNativeDateIdentityNeverCollapse() throws {
        let records = try fixture().records, b = records[1]
        func changed(quoteAt: Date, evidence: StockForecastEvidence) -> StockForecastRecord {
            StockForecastRecord(stockID: b.stockID, name: b.name, currency: b.currency, model: b.model,
                capture: b.capture, createdAt: b.createdAt, quoteAt: quoteAt, sessionStart: b.sessionStart,
                sessionEnd: b.sessionEnd, previousClose: b.previousClose, inputPrice: b.inputPrice,
                expectedClose: b.expectedClose, lowerClose: b.lowerClose, upperClose: b.upperClose,
                riseProbability: b.riseProbability, observations: b.observations, evidence: evidence,
                actualClose: b.actualClose, evaluatedAt: b.evaluatedAt)
        }
        let exactEarlier = Date(timeIntervalSinceReferenceDate: b.quoteAt.timeIntervalSinceReferenceDate.nextDown)
        XCTAssertNotEqual(exactEarlier, b.quoteAt)
        var closes = b.evidence!.closes
        closes[1] = .init(date: closes[1].date, price: Decimal(string: "101.00000000000000000001")!)
        for other in [changed(quoteAt: exactEarlier, evidence: b.evidence!),
                      changed(quoteAt: b.quoteAt, evidence: .init(closes: closes))] {
            XCTAssertTrue(other.isValid)
            let rows = StockEvaluation.rows(journal: [records[0], other], analyses: [])
            XCTAssertNotEqual(rows[0].inputKey, rows[1].inputKey)
            XCTAssertEqual(StockEvaluation.compare(rows, selectedModels: ["A", "B"]).pairedCount, 0)
        }
    }

    func testCodexAbstentionProducesNoInventedForecastOrPairedCalculation() throws {
        let record = try fixture().records[0]
        var pending = record
        pending.actualClose = nil
        pending.evaluatedAt = nil
        let input = try StockCodexAnalysisInput(record: pending, now: pending.createdAt)
        let analysis = StockCodexAnalysis(id: UUID(), input: input, model: "public-mock", promptVersion: 1,
            createdAt: pending.createdAt, completedAt: pending.createdAt,
            response: .init(status: .abstain, expectedClose: nil, lowerClose: nil, upperClose: nil,
                            riseProbability: nil, notes: "Public mock abstention"), resolution: nil)
        XCTAssertTrue(StockEvaluation.rows(journal: [], analyses: [analysis]).isEmpty)
        let forecast = StockCodexAnalysis(id: UUID(), input: input, model: "public-mock", promptVersion: 1,
            createdAt: pending.createdAt, completedAt: pending.createdAt,
            response: .init(status: .forecast, expectedClose: 104, lowerClose: 100, upperClose: 106,
                            riseProbability: 0.8, notes: "Public mock forecast"),
            resolution: .init(actualClose: 105, evaluatedAt: record.evaluatedAt!))
        let paired = try XCTUnwrap(forecast.pairedGBMRecord)
        let rows = StockEvaluation.rows(journal: [paired], analyses: [forecast])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.model == StockForecastRecord.modelVersion }?.references.count, 2)
        XCTAssertEqual(StockEvaluation.compare(rows, selectedModels: [paired.model, forecast.forecastModel]).pairedCount, 1)
    }

    func testOverflowIsUnavailableInsteadOfPerfectScoreAndBaselineHasNoProbability() throws {
        var row = try fixture().rows[0]
        row.expectedClose = Decimal(string: "1e127")!
        row.inputPrice = Decimal(string: "1e-127")!
        row.actualClose = row.inputPrice
        row.lowerClose = row.inputPrice
        row.upperClose = row.expectedClose
        let result = StockEvaluation.metrics([row])
        XCTAssertEqual(result.evaluated, 1)
        XCTAssertNil(result.mape)
        XCTAssertNil(result.meanWidthPercent)
        XCTAssertNil(StockEvaluation.metrics([row, try fixture().rows[0]]).mape,
                     "An overflow cannot disappear from an aggregate with a finite row")
        row.expectedClose = row.inputPrice
        row.lowerClose = nil
        row.upperClose = nil
        row.riseProbability = nil
        let baseline = StockEvaluation.metrics([row])
        XCTAssertEqual(baseline.mape, 0)
        XCTAssertNil(baseline.brier)
        XCTAssertNil(baseline.coverage)
    }
}
