import Foundation
import XCTest
@testable import PenguinNotch

final class StockForecastEvaluationTests: XCTestCase {
    private struct Fixture: Decodable {
        struct MetricCase: Decodable {
            let name: String
            let rows: [StockEvaluationRow]
            let expected: StockEvaluationMetrics
        }
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
