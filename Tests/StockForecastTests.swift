import AppKit
import SwiftUI
import Foundation
import XCTest
@testable import PenguinNotch

final class StockForecastTests: XCTestCase {
    @MainActor
    func testCloseHistoryKeepsOnlyObservedMinuteSamplesForOneTargetSession() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-28T00:00:00Z"))
        func record(_ minute: Double, price: Decimal = 104, day: Double = 0,
                    model: String = StockForecastRecord.modelVersion) -> StockForecastRecord {
            let session = start.addingTimeInterval(day * 86400)
            let time = session.addingTimeInterval(minute * 60)
            return StockForecastRecord(stockID: "kr:000660", name: "SK hynix", currency: "KRW",
                model: model, capture: .manual, createdAt: time, quoteAt: time,
                sessionStart: session, sessionEnd: session.addingTimeInterval(23400), previousClose: 100,
                inputPrice: price, expectedClose: price, lowerClose: 90, upperClose: 120,
                riseProbability: 0.6, observations: 30, evidence: nil)
        }
        let store = StockForecastStore()
        let stock = WatchedStock(symbol: "000660", market: .kr)
        store.retainCloseHistory([record(1), record(2, price: 105), record(2.5, price: 999), record(1.5, price: 888)],
                                 now: record(2.5).createdAt)
        var points = store.closeHistory(for: stock, now: start.addingTimeInterval(3600))
        XCTAssertEqual(points.map(\.expectedClose), [104, 105])
        XCTAssertEqual(points.map(\.createdAt), [record(1).createdAt, record(2).createdAt])
        XCTAssertTrue(store.journal.records.isEmpty, "Display samples must not become scored predictions")
        XCTAssertTrue(store.closeHistory(for: stock, now: start.addingTimeInterval(86400)).isEmpty)
        store.retainCloseHistory([record(6, price: 103), record(10, price: .nan)], now: record(6).createdAt)
        points = store.closeHistory(for: stock, now: start.addingTimeInterval(3600))
        XCTAssertEqual(points.count, 3, "No backfill or invalid samples")

        let domain = "CloseTrend.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preview = StockChartSection(store: StockChartStore(fetch: { _, _ in [] }),
            preferences: Preferences(defaults: defaults), stock: stock, portfolio: store)
            .closeHistoryChart(now: start.addingTimeInterval(3600))
            .frame(width: 200).padding(10).background(.black).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertLessThanOrEqual(CGFloat(image.height), 280)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/PenguinNotch-close-history-preview.png"))

        store.retainCloseHistory([record(1, price: 106, day: 1), record(5, day: 0)], now: record(1, day: 1).createdAt)
        XCTAssertEqual(store.closeHistory[stock.id]?.map(\.expectedClose), [106])
        store.retainCloseHistory([record(2, price: 107, day: 1, model: "Other model")], now: record(2, day: 1).createdAt)
        XCTAssertEqual(store.closeHistory[stock.id]?.map(\.expectedClose), [106, 107])
        XCTAssertEqual(store.closeHistory(for: stock, now: record(2, day: 1).createdAt).map(\.expectedClose), [107])
        store.clearSelection()
        XCTAssertEqual(store.closeHistory[stock.id]?.map(\.expectedClose), [106, 107])
    }

    private func historyRecord(minute: Double = 1, day: Int = 0, market: WatchedStock.Market = .kr,
                               price: Decimal = 104, model: String = StockForecastRecord.modelVersion,
                               quoteAt: Date? = nil) -> StockForecastRecord {
        let start = ISO8601DateFormatter().date(from: market == .kr
            ? "2026-09-28T00:00:00Z" : "2026-09-28T13:30:00Z")!.addingTimeInterval(Double(day) * 86400)
        let created = start.addingTimeInterval(minute * 60)
        let evidence = StockForecastEvidence(closes: (1...31).map {
            .init(date: start.addingTimeInterval(-Double($0) * 86400), price: $0.isMultiple(of: 2) ? 101 : 100)
        })
        return StockForecastRecord(stockID: market == .kr ? "kr:000660" : "us:SOXL",
            name: "private-account-name", currency: market == .kr ? "KRW" : "USD", model: model,
            capture: .manual, createdAt: created, quoteAt: quoteAt ?? created, sessionStart: start,
            sessionEnd: start.addingTimeInterval(23400), previousClose: 100, inputPrice: price,
            expectedClose: price, lowerClose: 90, upperClose: 120, riseProbability: 0.6,
            observations: 30, evidence: evidence)
    }

    @MainActor
    func testCloseHistoryRoundTripsCompactPointsWithoutScoredOrPrivateData() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = historyRecord(minute: 1.125)
        let second = historyRecord(minute: 7, price: 105)
        let store = StockForecastStore(closeHistoryDirectory: folder, now: first.createdAt)
        store.retainCloseHistory([first], now: first.createdAt)
        store.retainCloseHistory([second], now: second.createdAt)
        let file = folder.appending(path: "2026-09-28/kr-000660.json")
        let saved = try Data(contentsOf: file)
        let json = String(decoding: saved, as: UTF8.self)
        for forbidden in ["private-account-name", "accountNo", "accountSeq", "quantity", "balance",
                          "clientSecret", "access_token", "evidence", "closes", "actualClose", "inputPrice"] {
            XCTAssertFalse(json.contains(forbidden), forbidden)
        }
        XCTAssertLessThan(saved.count, 2000, "Daily OHLC evidence must not be repeated for display points")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dayAttributes = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual((dayAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let loaded = StockForecastStore(closeHistoryDirectory: folder, now: second.createdAt)
        XCTAssertNil(loaded.closeHistoryError)
        XCTAssertEqual(loaded.closeHistory, store.closeHistory)
        XCTAssertEqual(loaded.closeHistory[first.stockID]?.map(\.createdAt), [first.createdAt, second.createdAt])
        XCTAssertEqual(loaded.closeHistory[first.stockID]?.map(\.expectedClose), [104, 105])
        loaded.retainCloseHistory([historyRecord(minute: 7.5, price: 999)], now: historyRecord(minute: 7.5).createdAt)
        loaded.retainCloseHistory([historyRecord(minute: 8, quoteAt: second.quoteAt)], now: historyRecord(minute: 8).createdAt)
        XCTAssertEqual(try Data(contentsOf: file), saved, "Restart must preserve first observation per minute and quote")
        loaded.retainCloseHistory([historyRecord(minute: 10)], now: historyRecord(minute: 10).createdAt)
        XCTAssertEqual(loaded.closeHistory[first.stockID]?.count, 3, "Gaps must remain gaps")
        XCTAssertTrue(loaded.candidates.isEmpty)
        XCTAssertEqual(loaded.saveCurrent(now: second.createdAt), 0)
        XCTAssertTrue(store.journal.records.isEmpty)
        XCTAssertTrue(loaded.journal.records.isEmpty)
    }

    @MainActor
    func testCloseHistorySurvivesClearDisableProviderAndAccountChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let domain = "CloseHistoryReset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: domain) }
        let record = historyRecord()
        let store = StockForecastStore(closeHistoryDirectory: folder, now: record.createdAt)
        store.retainCloseHistory([record], now: record.createdAt)
        let expected = store.closeHistory
        let file = folder.appending(path: "2026-09-28/kr-000660.json")
        let saved = try Data(contentsOf: file)
        store.clearSelection()
        XCTAssertEqual(store.closeHistory, expected)
        store.clear()
        XCTAssertEqual(store.closeHistory, expected)
        store.stop()
        XCTAssertEqual(store.closeHistory, expected)
        let preferences = Preferences(defaults: defaults)
        preferences.portfolioForecastEnabled = false
        await store.refresh(preferences: preferences, now: record.createdAt)
        XCTAssertEqual(store.closeHistory, expected)
        preferences.portfolioForecastEnabled = true
        preferences.stockQuoteSource = .finnhub
        await store.refresh(preferences: preferences, now: record.createdAt)
        XCTAssertEqual(store.closeHistory, expected)
        preferences.stockQuoteSource = .toss
        preferences.tossAccountSeq = 99
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForecastEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        await store.refresh(preferences: preferences, session: session, now: record.createdAt,
                            credentials: ("history-reset-\(UUID().uuidString)", "fake-secret"))
        XCTAssertTrue(store.holdings.isEmpty)
        XCTAssertEqual(store.closeHistory, expected)
        XCTAssertEqual(try Data(contentsOf: file), saved)
        XCTAssertEqual(StockForecastStore(closeHistoryDirectory: folder, now: record.createdAt).closeHistory, expected)
    }

    @MainActor
    func testCloseHistoryKeepsOldDayAndModelArchivesWithMarketLocalDates() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = historyRecord()
        let store = StockForecastStore(closeHistoryDirectory: folder, now: first.createdAt)
        store.retainCloseHistory([first], now: first.createdAt)
        let changed = historyRecord(minute: 2, model: "Other model")
        store.retainCloseHistory([changed], now: changed.createdAt)
        let oldFile = folder.appending(path: "2026-09-28/kr-000660.json")
        let saved = try Data(contentsOf: oldFile)
        let next = historyRecord(day: 1, price: 106)
        store.retainCloseHistory([next], now: next.createdAt)
        store.retainCloseHistory([first], now: first.createdAt) // A delayed earlier refresh cannot reset the curve.
        let loaded = StockForecastStore(closeHistoryDirectory: folder, now: next.createdAt)
        let stock = try XCTUnwrap(next.stock)
        XCTAssertEqual(loaded.closeHistory(for: stock, now: next.createdAt).map(\.expectedClose), [106])
        XCTAssertEqual(store.closeHistory, loaded.closeHistory)
        XCTAssertTrue(loaded.closeHistory(for: stock, now: historyRecord(day: 2).createdAt).isEmpty)
        XCTAssertTrue(StockForecastStore(closeHistoryDirectory: folder, now: historyRecord(day: 2).createdAt).closeHistory.isEmpty)
        XCTAssertEqual(try Data(contentsOf: oldFile), saved)
        let oldDay = StockForecastStore(closeHistoryDirectory: folder, now: changed.createdAt)
        XCTAssertEqual(oldDay.closeHistory[first.stockID]?.map(\.model), [first.model, changed.model])
        XCTAssertEqual(oldDay.closeHistory(for: stock, now: changed.createdAt).map(\.model), [changed.model])

        let us = historyRecord(minute: 150, market: .us) // Sep 29 in Seoul, still Sep 28 in New York.
        let usStore = StockForecastStore(closeHistoryDirectory: folder, now: us.createdAt)
        usStore.retainCloseHistory([us], now: us.createdAt)
        let usLoaded = StockForecastStore(closeHistoryDirectory: folder, now: us.createdAt)
        XCTAssertEqual(usLoaded.closeHistory(for: try XCTUnwrap(us.stock), now: us.createdAt).map(\.expectedClose), [104])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "2026-09-28/us-SOXL.json").path))
        XCTAssertEqual(try Data(contentsOf: oldFile), saved)
    }

    @MainActor
    func testCloseHistoryRejectsFutureStaleAndUnobservedSamples() {
        let store = StockForecastStore()
        let live = historyRecord(minute: 10)
        store.retainCloseHistory([historyRecord(minute: 1), historyRecord(minute: 11),
            historyRecord(minute: 10, price: .nan), historyRecord(minute: 10, quoteAt: historyRecord(minute: 7).quoteAt)],
            now: live.createdAt)
        XCTAssertTrue(store.closeHistory.isEmpty)
        store.retainCloseHistory([live], now: live.createdAt)
        store.retainCloseHistory([historyRecord(minute: 10.9), historyRecord(minute: 9)], now: historyRecord(minute: 11).createdAt)
        XCTAssertEqual(store.closeHistory[live.stockID]?.map(\.createdAt), [live.createdAt])
    }

    @MainActor
    func testCloseHistoryCorruptUnsupportedOrInvalidArchivesAreNeverOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = historyRecord()
        let now = historyRecord(minute: 10).createdAt
        let store = StockForecastStore(closeHistoryDirectory: folder, now: now)
        store.retainCloseHistory([first], now: first.createdAt)
        let file = folder.appending(path: "2026-09-28/kr-000660.json")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let point = try XCTUnwrap((original["points"] as? [[String: Any]])?.first)
        var invalid = [Data("{not an archive}".utf8)]
        var version = original
        version["version"] = 2
        invalid.append(try JSONSerialization.data(withJSONObject: version))
        for (key, value): (String, Any) in [
            ("stockID", "kr:../../escape"), ("currency", "USD"), ("expectedClose", 0),
            ("model", ""), ("createdAt", now.addingTimeInterval(60).timeIntervalSince1970 * 1000),
            ("quoteAt", first.createdAt.addingTimeInterval(1).timeIntervalSince1970 * 1000),
            ("sessionStart", -1), ("sessionEnd", first.sessionEnd.addingTimeInterval(86400).timeIntervalSince1970 * 1000)
        ] {
            var changed = point
            changed[key] = value
            var archive = original
            archive["points"] = [changed]
            invalid.append(try JSONSerialization.data(withJSONObject: archive))
        }
        var duplicate = original
        duplicate["points"] = [point, point]
        invalid.append(try JSONSerialization.data(withJSONObject: duplicate))
        var oversized = original
        oversized["points"] = Array(repeating: point, count: 1441)
        invalid.append(try JSONSerialization.data(withJSONObject: oversized))
        invalid.append(Data(repeating: 32, count: 2 * 1024 * 1024 + 1))
        for broken in invalid {
            try broken.write(to: file)
            let loaded = StockForecastStore(closeHistoryDirectory: folder, now: now)
            XCTAssertNotNil(loaded.closeHistoryError)
            XCTAssertTrue(loaded.closeHistory.isEmpty)
            loaded.retainCloseHistory([historyRecord(minute: 10)], now: now)
            loaded.clearSelection()
            loaded.clear()
            XCTAssertNotNil(loaded.closeHistoryError)
            XCTAssertEqual(try Data(contentsOf: file), broken)
        }
        // A file replaced after launch also blocks writing, and retains already loaded points.
        try JSONSerialization.data(withJSONObject: original).write(to: file)
        let loaded = StockForecastStore(closeHistoryDirectory: folder, now: now)
        let unsupported = invalid[1]
        try unsupported.write(to: file)
        loaded.retainCloseHistory([historyRecord(minute: 10)], now: now)
        XCTAssertNotNil(loaded.closeHistoryError)
        XCTAssertEqual(loaded.closeHistory[first.stockID]?.count, 1)
        let us = historyRecord(market: .us)
        loaded.retainCloseHistory([us], now: us.createdAt)
        XCTAssertEqual(loaded.closeHistory[us.stockID]?.count, 1)
        XCTAssertNotNil(loaded.closeHistoryError, "A healthy file must not hide another file's read failure")
        XCTAssertEqual(try Data(contentsOf: file), unsupported)
    }

    @MainActor
    func testCloseHistoryWriteFailureRetainsSavedPointsAndCanRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let dayFolder = folder.appending(path: "2026-09-28")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dayFolder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let first = historyRecord()
        let next = historyRecord(minute: 2)
        let store = StockForecastStore(closeHistoryDirectory: folder, now: first.createdAt)
        store.retainCloseHistory([first], now: first.createdAt)
        let file = dayFolder.appending(path: "kr-000660.json")
        let saved = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dayFolder.path)
        store.retainCloseHistory([next], now: next.createdAt)
        XCTAssertNotNil(store.closeHistoryError)
        XCTAssertEqual(store.closeHistory[first.stockID]?.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), saved)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dayFolder.path)
        store.retainCloseHistory([next], now: next.createdAt)
        XCTAssertNil(store.closeHistoryError)
        XCTAssertEqual(StockForecastStore(closeHistoryDirectory: folder, now: next.createdAt).closeHistory[first.stockID]?.count, 2)
    }

    func testZeroDriftModelNeedsLiveSessionAndEnoughVariableHistory() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trading = TradingSession(startTime: start, endTime: start.addingTimeInterval(3600))
        let closes = (0..<61).map { Decimal($0.isMultiple(of: 2) ? 100 : 101) }
        let midpoint = start.addingTimeInterval(1800)
        let flat = try XCTUnwrap(StockForecast.estimate(price: 100, completedCloses: closes,
                                                         trading: trading, now: midpoint))
        XCTAssertEqual(flat.expectedClose, 100)
        XCTAssertEqual(flat.observations, 60)
        XCTAssertLessThan(flat.lowerClose, flat.expectedClose)
        XCTAssertGreaterThan(flat.upperClose, flat.expectedClose)
        let nearClose = try XCTUnwrap(StockForecast.estimate(price: 100, completedCloses: closes,
                                                            trading: trading, now: start.addingTimeInterval(3500)))
        XCTAssertLessThan(nearClose.upperClose - nearClose.lowerClose, flat.upperClose - flat.lowerClose)
        XCTAssertTrue((0.45...0.55).contains(flat.riseProbability))
        let higher = try XCTUnwrap(StockForecast.estimate(price: 102, completedCloses: closes,
                                                           trading: trading, now: midpoint))
        XCTAssertGreaterThan(higher.riseProbability, flat.riseProbability)
        XCTAssertNil(StockForecast.estimate(price: 100, completedCloses: Array(closes.prefix(20)),
                                             trading: trading, now: midpoint))
        XCTAssertNil(StockForecast.estimate(price: 100, completedCloses: closes,
                                             trading: trading, now: trading.endTime))
        XCTAssertNil(StockForecast.estimate(price: 100, completedCloses: Array(repeating: 100, count: 30),
                                             trading: trading, now: midpoint))
    }

    func testChartIntervalsUseCompletedSessionBarsAndKeepTodaysCloseTarget() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let now = start.addingTimeInterval(7200)
        let trading = TradingSession(startTime: start, endTime: start.addingTimeInterval(23400))
        let closes = (0..<31).map { index in
            StockForecastEvidence.Close(date: start.addingTimeInterval(-Double(index + 1) * 86400),
                                        price: index.isMultiple(of: 2) ? 100 : 101)
        }
        let record = StockForecastRecord(stockID: "us:SOXL", name: "SOXL", currency: "USD",
            model: StockForecastRecord.modelVersion, capture: .manual, createdAt: now, quoteAt: now,
            sessionStart: start, sessionEnd: trading.endTime, previousClose: 100, inputPrice: 105,
            expectedClose: 105, lowerClose: 90, upperClose: 120, riseProbability: 0.6,
            observations: 30, evidence: StockForecastEvidence(closes: closes))
        XCTAssertTrue(record.isValid)
        let minutes = (1...120).map { index in
            let price = Decimal(100 + sin(Double(index) / 7) + Double(index) / 100)
            return StockCandle(end: start.addingTimeInterval(Double(index) * 60),
                               open: price, high: price, low: price, close: price, volume: 1)
        }
        let minute = try XCTUnwrap(StockForecast.chartEstimate(record: record, minutes: minutes,
                                                               interval: .minute, now: now))
        let ten = try XCTUnwrap(StockForecast.chartEstimate(record: record, minutes: minutes,
                                                            interval: .tenMinutes, now: now))
        let day = try XCTUnwrap(StockForecast.chartEstimate(record: record, minutes: [], interval: .day, now: now))
        let original = try XCTUnwrap(StockForecast.estimate(price: 105, completedCloses: closes.map(\.price),
                                                           trading: trading, now: now))
        XCTAssertEqual(minute.expectedClose, 105)
        XCTAssertEqual(ten.expectedClose, 105)
        XCTAssertEqual(day.lowerClose, original.lowerClose)
        XCTAssertEqual(day.riseProbability, original.riseProbability)
        XCTAssertEqual(minute.observations, 119)
        XCTAssertEqual(ten.observations, 11)
        XCTAssertNotEqual(minute.lowerClose, ten.lowerClose)
        XCTAssertNil(StockForecast.chartEstimate(record: record, minutes: minutes, interval: .minute,
                                                now: now.addingTimeInterval(121)))
        XCTAssertNil(StockForecast.chartEstimate(record: record, minutes: minutes, interval: .day,
                                                now: trading.endTime))
        XCTAssertNil(StockForecast.chartEstimate(record: record, minutes: minutes + [minutes[0]],
                                                interval: .minute, now: now))
        // A missing minute near the tail prevents bridging the gap as a one-minute return.
        var missing = minutes
        missing.remove(at: 110)
        XCTAssertNil(StockForecast.chartEstimate(record: record, minutes: missing, interval: .minute, now: now))
        let incomplete = try XCTUnwrap(StockForecast.chartEstimate(record: record,
            minutes: Array(minutes.dropLast()), interval: .tenMinutes, now: now))
        XCTAssertEqual(incomplete.observations, 10) // Partial last ten-minute bucket is excluded.
        let future = StockCandle(end: now.addingTimeInterval(60), open: 1, high: 1000, low: 1,
                                 close: 1000, volume: 1)
        let filtered = try XCTUnwrap(StockForecast.chartEstimate(record: record, minutes: minutes + [future],
                                                                interval: .minute, now: now))
        XCTAssertEqual(filtered.lowerClose, minute.lowerClose)
        XCTAssertNil(StockForecast.chartEstimate(record: record, minutes: Array(minutes.prefix(80)),
                                                interval: .minute, now: now))
    }

    @MainActor
    func testActualAccountHoldingsProduceEstimatesWithoutPersistingPositions() async throws {
        let name = "Forecast.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let historyFolder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: historyFolder) }
        let preferences = Preferences(defaults: defaults)
        preferences.stockQuoteSource = .toss
        preferences.portfolioForecastEnabled = true
        preferences.tossAccountSeq = 7 // Explicit account opt-in; never selected by refresh.
        let store = StockForecastStore(closeHistoryDirectory: historyFolder)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ForecastEndpoint.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ForecastEndpoint.reset()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T01:00:00Z"))

        let credentials = (clientID: "forecast-\(UUID().uuidString)", clientSecret: "fake-secret")
        await store.refresh(preferences: preferences, session: session, now: now,
                            credentials: credentials)

        XCTAssertNil(store.message)
        XCTAssertEqual(preferences.tossAccountSeq, 7)
        XCTAssertEqual(store.accounts.first?.maskedNumber, "•••• 8901")
        XCTAssertEqual(store.holdings.map(\.id), ["KR:005930"])
        XCTAssertNotNil(store.forecasts["kr:005930"])
        XCTAssertEqual(store.forecasts["kr:005930"]?.expectedClose, 100)
        let candidate = try XCTUnwrap(store.candidates.first)
        XCTAssertTrue(candidate.isValid)
        XCTAssertEqual(candidate.evidence?.closes.count, 30)
        XCTAssertEqual(candidate.evidence?.closes.first?.price, candidate.previousClose)
        XCTAssertTrue(candidate.evidence?.closes.allSatisfy { $0.date < candidate.sessionStart } == true)
        preferences.stockChartInterval = .day
        let preview = StockChartSection(store: StockChartStore(fetch: { _, _ in [] }),
            preferences: preferences, stock: WatchedStock(symbol: "005930", market: .kr), portfolio: store)
            .forecastSection(now: now).frame(width: 220)
        let renderer = ImageRenderer(content: preview)
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertLessThanOrEqual(CGFloat(image.height), NotchLayout.stockForecastSectionHeight)
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/PenguinNotch-chart-forecast-preview.png"))
        let timingStore = StockChartStore(fetch: { _, _ in
            let day = candidate.marketCalendar.startOfDay(for: now)
            return (0..<20).map { index in
                let price = Decimal(81 + index)
                return StockCandle(end: day.addingTimeInterval(-Double(20 - index) * 86400),
                    open: price - 0.5, high: price + 0.6, low: price - 0.6, close: price,
                    volume: index == 19 ? 150 : 100)
            }
        })
        let timingStock = WatchedStock(symbol: "005930", market: .kr)
        await timingStore.load(stock: timingStock, interval: .day, now: now)
        let timingBars = try XCTUnwrap(timingStore.entries[.init(stock: timingStock, interval: .day)])
        XCTAssertEqual(StockTimingSignal.evaluate(candles: timingBars.candles, interval: .day,
                         market: .kr, record: candidate, fetchedAt: now, now: now)?.action, .buy)
        let timingPreview = StockChartSection(store: timingStore, preferences: preferences,
                                              stock: timingStock, portfolio: store)
            .timingSection(now: now).frame(width: 200)
        let timingImage = try XCTUnwrap(ImageRenderer(content: timingPreview).cgImage)
        XCTAssertLessThanOrEqual(CGFloat(timingImage.height), NotchLayout.stockTimingSectionHeight)
        try NSBitmapImageRep(cgImage: timingImage).representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/PenguinNotch-technical-analysis-preview.png"))
        XCTAssertNil(defaults.object(forKey: "holdings"))
        XCTAssertEqual(defaults.integer(forKey: "tossAccountSeq"), 7)
        let requests = ForecastEndpoint.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/v1/holdings" }.count, 1)
        XCTAssertEqual(requests.first(where: { $0.url?.path == "/api/v1/holdings" })?
            .value(forHTTPHeaderField: "X-Tossinvest-Account"), "7")
        XCTAssertTrue(requests.filter { $0.url?.path != "/api/v1/holdings" }
            .allSatisfy { $0.value(forHTTPHeaderField: "X-Tossinvest-Account") == nil })
        XCTAssertTrue(requests.filter { $0.url?.path != "/oauth2/token" }
            .allSatisfy { $0.httpMethod == "GET" })
        let historyURL = try XCTUnwrap(requests.first { $0.url?.path == "/api/v1/candles" }?.url)
        XCTAssertEqual(URLComponents(url: historyURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "adjusted" }?.value, "true")

        await store.refresh(preferences: preferences, session: session, now: now.addingTimeInterval(60),
                            credentials: credentials)
        XCTAssertEqual(store.closeHistory["kr:005930"]?.count, 1, "An unchanged trade timestamp is not a new observation")
        // A second refresh reuses the in-memory history and stays below account limits.
        XCTAssertEqual(ForecastEndpoint.requests.filter { $0.url?.path == "/api/v1/holdings" }.count, 1)
        XCTAssertEqual(ForecastEndpoint.requests.filter { $0.url?.path == "/api/v1/candles" }.count, 1)
        XCTAssertEqual(StockForecastStore(closeHistoryDirectory: historyFolder, now: now.addingTimeInterval(60)).closeHistory,
                       store.closeHistory, "The real refresh path must persist observed points")

        try Data("{broken}".utf8).write(to: historyFolder.appending(path: "2026-09-25/kr-005930.json"))
        store.retainCloseHistory(store.candidates, now: now.addingTimeInterval(60))
        XCTAssertNotNil(store.closeHistoryError)
        let errorPreview = StockChartSection(store: StockChartStore(fetch: { _, _ in [] }),
            preferences: preferences, stock: WatchedStock(symbol: "005930", market: .kr), portfolio: store)
            .forecastSection(now: now.addingTimeInterval(60)).frame(width: 200)
        let errorImage = try XCTUnwrap(ImageRenderer(content: errorPreview).cgImage)
        XCTAssertLessThanOrEqual(CGFloat(errorImage.height), NotchLayout.stockForecastSectionHeight,
                                 "Persistence errors must fit inside the visible hover section")
        try NSBitmapImageRep(cgImage: errorImage).representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/PenguinNotch-close-history-error-preview.png"))

        preferences.portfolioForecastEnabled = false
        store.clear()
        XCTAssertTrue(store.holdings.isEmpty)
        XCTAssertTrue(store.forecasts.isEmpty)
    }

    func testMissingQuoteTimestampCannotBecomeAForecastInput() {
        let body = Data(#"{"result":[{"symbol":"005930","lastPrice":"100","currency":"KRW","timestamp":null}]}"#.utf8)
        XCTAssertNotNil(StockQuoteCodec.prices(from: body)["kr:005930"])
        XCTAssertNil(StockQuoteCodec.prices(from: body, requireTimestamp: true)["kr:005930"])
    }

    @MainActor
    func testScheduledAndManualSnapshotsAreSavedOnceAndKeepOriginalInputs() async throws {
        let suite = "ForecastCapture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.recordsStockForecasts)
        preferences.portfolioForecastEnabled = true
        preferences.recordsStockForecasts = true
        preferences.stockSymbols = ["kr:005930"]
        let store = StockForecastStore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForecastEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ForecastEndpoint.reset(priceTime: "2026-09-25T14:30:00+09:00")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T05:30:00Z"))
        let credentials = (clientID: "capture-\(UUID().uuidString)", clientSecret: "fake-secret")
        await store.refresh(preferences: preferences, session: session, now: now, credentials: credentials)
        XCTAssertEqual(store.journal.records.count, 1)
        XCTAssertEqual(store.journal.records.first?.capture, .scheduled)
        XCTAssertEqual(store.saveCurrent(now: now), 1)
        XCTAssertEqual(store.saveCurrent(now: now), 0)
        await store.refresh(preferences: preferences, session: session, now: now.addingTimeInterval(60), credentials: credentials)
        XCTAssertEqual(store.journal.records.count, 2)
        XCTAssertTrue(store.journal.records.allSatisfy { $0.createdAt == now && $0.inputPrice == 100 })
        XCTAssertEqual(store.saveCurrent(now: now.addingTimeInterval(240)), 0)
        XCTAssertFalse(ForecastEndpoint.requests.contains { ["/api/v1/accounts", "/api/v1/holdings"].contains($0.url?.path) })
        store.stop()
        XCTAssertTrue(store.candidates.isEmpty)
        XCTAssertEqual(store.journal.records.count, 2)
    }

    @MainActor
    func testWatchlistOnlyUsesPublicDataAndRetainsHistoryAfterRemovalAndRestart() async throws {
        let suite = "WatchlistForecast.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let preferences = Preferences(defaults: defaults)
        preferences.portfolioForecastEnabled = true
        preferences.stockSymbols = [" KR:005930 ", "000660", "kr:005930"]
        let store = StockForecastStore(closeHistoryDirectory: folder)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ForecastEndpoint.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ForecastEndpoint.reset()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T01:00:00Z"))
        let credentials = (clientID: "watchlist-\(UUID().uuidString)", clientSecret: "fake-secret")
        await store.refresh(preferences: preferences, session: session, now: now, credentials: credentials)

        XCTAssertNil(store.message)
        XCTAssertEqual(preferences.tossAccountSeq, 0)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.holdings.isEmpty, "A watchlist stock is not a position")
        XCTAssertEqual(store.candidates.map(\.stockID), ["kr:005930", "kr:000660"])
        XCTAssertEqual(store.candidates.map(\.name), ["삼성전자", "SK하이닉스"])
        XCTAssertEqual(store.candidates.map(\.currency), ["KRW", "KRW"])
        XCTAssertTrue(store.candidates.allSatisfy { $0.isValid && $0.createdAt == now && $0.observations == 29 })
        XCTAssertEqual(store.forecasts["kr:000660"]?.expectedClose, 110)
        let saved = store.closeHistory
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(store.journal.records.isEmpty, "Display history is never pooled into scored forecasts")
        XCTAssertFalse(ForecastEndpoint.requests.contains { ["/api/v1/accounts", "/api/v1/holdings"].contains($0.url?.path) })
        XCTAssertTrue(ForecastEndpoint.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Tossinvest-Account") == nil })

        preferences.stockSymbols = ["kr:000660"]
        await store.refresh(preferences: preferences, session: session, now: now.addingTimeInterval(60), credentials: credentials)
        XCTAssertEqual(store.candidates.map(\.stockID), ["kr:000660"])
        XCTAssertEqual(store.closeHistory, saved)
        XCTAssertEqual(StockForecastStore(closeHistoryDirectory: folder, now: now.addingTimeInterval(60)).closeHistory, saved)
        preferences.stockSymbols = []
        await store.refresh(preferences: preferences, session: session, now: now.addingTimeInterval(60), credentials: credentials)
        XCTAssertTrue(store.candidates.isEmpty)
        XCTAssertNotNil(store.message)
        XCTAssertEqual(store.closeHistory, saved)
        let requestsBeforeFinnhub = ForecastEndpoint.requests.count
        preferences.stockQuoteSource = .finnhub
        await store.refresh(preferences: preferences, session: session, now: now, credentials: credentials)
        await store.loadAccounts(preferences: preferences, session: session, credentials: credentials)
        XCTAssertEqual(ForecastEndpoint.requests.count, requestsBeforeFinnhub)
        XCTAssertTrue(store.candidates.isEmpty)
        XCTAssertEqual(store.closeHistory, saved)
    }

    @MainActor
    func testExplicitAccountLoadingNeverSelectsAndOptionalHoldingsMergeOnce() async throws {
        let suite = "WatchlistAccount.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.portfolioForecastEnabled = true
        preferences.stockSymbols = ["kr:005930", "kr:000660"]
        let store = StockForecastStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ForecastEndpoint.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ForecastEndpoint.reset()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T01:00:00Z"))
        let credentials = (clientID: "optional-\(UUID().uuidString)", clientSecret: "fake-secret")

        await store.loadAccounts(preferences: preferences, session: session, credentials: credentials)
        XCTAssertFalse(store.loadingAccounts)
        XCTAssertNil(store.accountMessage)
        XCTAssertEqual(store.accounts.map(\.accountSeq), [7])
        XCTAssertEqual(preferences.tossAccountSeq, 0, "Even a single account requires explicit selection")
        XCTAssertTrue(store.holdings.isEmpty)
        XCTAssertFalse(ForecastEndpoint.requests.contains { $0.url?.path == "/api/v1/holdings" })
        await store.refresh(preferences: preferences, session: session, now: now, credentials: credentials)
        XCTAssertFalse(ForecastEndpoint.requests.contains { $0.url?.path == "/api/v1/holdings" })
        XCTAssertEqual(ForecastEndpoint.requests.filter { $0.url?.path == "/api/v1/accounts" }.count, 1)

        preferences.tossAccountSeq = 7
        await store.refresh(preferences: preferences, session: session, now: now, credentials: credentials)
        XCTAssertEqual(store.holdings.map(\.id), ["KR:005930"])
        XCTAssertEqual(store.candidates.map(\.stockID), ["kr:005930", "kr:000660"], "Watched and held stocks share one canonical target")
        XCTAssertEqual(store.targets(for: preferences).map(\.id), ["kr:005930", "kr:000660"])
        let saved = store.closeHistory
        preferences.stockSymbols = ["kr:000660"]
        await store.refresh(preferences: preferences, session: session, now: now, credentials: credentials)
        XCTAssertEqual(store.candidates.map(\.stockID), ["kr:000660", "kr:005930"], "Optional holdings extend the watchlist")
        let accountRequests = ForecastEndpoint.requests.filter { ["/api/v1/accounts", "/api/v1/holdings"].contains($0.url?.path) }.count
        preferences.tossAccountSeq = 0
        await store.refresh(preferences: preferences, session: session, now: now.addingTimeInterval(60), credentials: credentials)
        XCTAssertTrue(store.holdings.isEmpty)
        XCTAssertEqual(store.candidates.map(\.stockID), ["kr:000660"])
        XCTAssertNil(store.accountMessage)
        XCTAssertEqual(store.closeHistory, saved)
        XCTAssertEqual(ForecastEndpoint.requests.filter { ["/api/v1/accounts", "/api/v1/holdings"].contains($0.url?.path) }.count, accountRequests)
    }

    @MainActor
    func testUnavailableOptionalAccountOrHoldingsDoesNotBlockWatchlistEstimates() async throws {
        for (accountsStatus, holdingsStatus, emptyHoldings) in [(403, 200, false), (200, 403, false), (200, 200, true)] {
            let suite = "WatchlistFallback.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = Preferences(defaults: defaults)
            preferences.portfolioForecastEnabled = true
            preferences.tossAccountSeq = 7
            preferences.stockSymbols = ["kr:000660"]
            let store = StockForecastStore()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ForecastEndpoint.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            ForecastEndpoint.reset(accountsStatus: accountsStatus, holdingsStatus: holdingsStatus, emptyHoldings: emptyHoldings)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T01:00:00Z"))
            await store.refresh(preferences: preferences, session: session, now: now,
                                credentials: ("fallback-\(UUID().uuidString)", "fake-secret"))
            XCTAssertNil(store.message)
            XCTAssertNotNil(store.accountMessage, "Optional account errors must remain visible")
            XCTAssertTrue(store.holdings.isEmpty)
            XCTAssertEqual(preferences.tossAccountSeq, 7, "A transient error must not change the user's choice")
            XCTAssertEqual(store.candidates.map(\.stockID), ["kr:000660"])
            XCTAssertTrue(store.candidates.allSatisfy(\.isValid))
            XCTAssertEqual(store.closeHistory["kr:000660"]?.count, 1)
        }
    }

    @MainActor
    func testFutureAndAgedQuotesNeverBecomeCandidatesOrAutomaticRecords() async throws {
        let suite = "ForecastQuoteClock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.portfolioForecastEnabled = true
        preferences.recordsStockForecasts = true
        preferences.stockSymbols = ["kr:000660"]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ForecastEndpoint.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-09-25T05:30:00Z")) // Automatic capture window.
        for age in [-60.0, -1.0, 121.0, 600.0, 120.0, 0.0] {
            let quoteAt = now.addingTimeInterval(-age)
            ForecastEndpoint.reset(priceTime: formatter.string(from: quoteAt))
            let store = StockForecastStore()
            await store.refresh(preferences: preferences, session: session, now: now,
                                credentials: ("quote-clock-\(UUID().uuidString)", "fake-secret"))
            XCTAssertNil(store.message)
            if (0...120).contains(age) {
                let candidate = try XCTUnwrap(store.candidates.first)
                XCTAssertTrue(candidate.isValid)
                XCTAssertEqual(candidate.createdAt, now, "Never advance the actual capture clock")
                XCTAssertEqual(candidate.quoteAt, quoteAt)
                let expected = try XCTUnwrap(StockForecast.estimate(price: 110,
                    completedCloses: try XCTUnwrap(candidate.evidence).closes.map(\.price),
                    trading: TradingSession(startTime: candidate.sessionStart, endTime: candidate.sessionEnd), now: quoteAt))
                XCTAssertEqual(candidate.lowerClose, expected.lowerClose, "Variance horizon must still use quote time")
                XCTAssertEqual(store.journal.records.count, 1)
                XCTAssertEqual(store.closeHistory["kr:000660"]?.count, 1)
            } else {
                XCTAssertTrue(store.forecasts.isEmpty, "Quote age \(age)")
                XCTAssertTrue(store.candidates.isEmpty, "Quote age \(age)")
                XCTAssertNotNil(store.reasons["kr:000660"])
                XCTAssertTrue(store.journal.records.isEmpty)
                XCTAssertTrue(store.closeHistory.isEmpty)
                XCTAssertEqual(store.saveCurrent(now: now), 0)
            }
        }
    }

    func testUSRegularSessionContinuesPastKoreanMidnight() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ForecastEndpoint.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let formatter = ISO8601DateFormatter()
        let overnight = try XCTUnwrap(formatter.date(from: "2026-09-25T17:00:00Z"))
        let closed = try XCTUnwrap(formatter.date(from: "2026-09-26T01:00:00Z"))

        let activeSession = try await TossInvestAPI.regularSession(token: "test", market: .us,
                                                                   at: overnight, session: session)
        let closedSession = try await TossInvestAPI.regularSession(token: "test", market: .us,
                                                                   at: closed, session: session)
        XCTAssertNotNil(activeSession)
        XCTAssertNil(closedSession)
    }
}

private final class ForecastEndpoint: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var priceTime = "2026-09-25T10:00:00+09:00"
    private static var accountsStatus = 200
    private static var holdingsStatus = 200
    private static var emptyHoldings = false
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(priceTime: String = "2026-09-25T10:00:00+09:00", accountsStatus: Int = 200,
                      holdingsStatus: Int = 200, emptyHoldings: Bool = false) {
        lock.withLock {
            recorded = []
            Self.priceTime = priceTime
            Self.accountsStatus = accountsStatus
            Self.holdingsStatus = holdingsStatus
            Self.emptyHoldings = emptyHoldings
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let fixture = Self.lock.withLock {
            Self.recorded.append(request)
            return (priceTime: Self.priceTime, accountsStatus: Self.accountsStatus,
                    holdingsStatus: Self.holdingsStatus, emptyHoldings: Self.emptyHoldings)
        }
        let body: Data
        var status = 200
        switch request.url?.path {
        case "/oauth2/token":
            body = Data(#"{"access_token":"forecast-test-token","expires_in":3600}"#.utf8)
        case "/api/v1/accounts":
            status = fixture.accountsStatus
            body = Data(#"{"result":[{"accountNo":"12345678901","accountSeq":7,"accountType":"BROKERAGE"}]}"#.utf8)
        case "/api/v1/holdings":
            status = fixture.holdingsStatus
            body = fixture.emptyHoldings ? Data(#"{"result":{"items":[]}}"#.utf8)
                : Data(#"{"result":{"items":[{"symbol":"005930","name":"삼성전자","marketCountry":"KR","currency":"KRW"}]}}"#.utf8)
        case "/api/v1/market-calendar/KR":
            body = Data(#"{"result":{"today":{"integrated":{"regularMarket":{"startTime":"2026-09-25T09:00:00+09:00","endTime":"2026-09-25T15:30:00+09:00"}}},"previousBusinessDay":{"integrated":null}}}"#.utf8)
        case "/api/v1/market-calendar/US":
            body = Data(#"{"result":{"today":{"regularMarket":null},"previousBusinessDay":{"regularMarket":{"startTime":"2026-09-25T22:30:00+09:00","endTime":"2026-09-26T05:00:00+09:00"}}}}"#.utf8)
        case "/api/v1/prices":
            let symbols = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "symbols" }?.value?.split(separator: ",").map(String.init) ?? []
            let prices = symbols.map { symbol in
                ["symbol": symbol, "lastPrice": symbol == "005930" ? "100" : "110",
                 "currency": WatchedStock.parse(symbol)?.market == .kr ? "KRW" : "USD", "timestamp": fixture.priceTime]
            }
            body = try! JSONSerialization.data(withJSONObject: ["result": prices])
        case "/api/v1/candles":
            let formatter = ISO8601DateFormatter()
            let base = formatter.date(from: "2026-09-24T00:00:00Z")!
            let candles: [[String: String]] = (0..<30).map { index in
                ["timestamp": formatter.string(from: base.addingTimeInterval(Double(-index * 86_400))),
                 "closePrice": index.isMultiple(of: 2) ? "100" : "101"]
            }
            body = try! JSONSerialization.data(withJSONObject: ["result": ["candles": candles]])
        default:
            XCTFail("Unexpected forecast request: \(request.url?.path ?? "nil")")
            body = Data()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
