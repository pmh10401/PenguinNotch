import AppKit
import SwiftUI
import XCTest
@testable import PenguinNotch

final class TossAccountTests: XCTestCase {
    private func fixture() -> Data { Data(Self.sample.utf8) }

    func testOfficialAmountsCurrenciesAndFractionalQuantity() throws {
        let result = try TossAccountPortfolio.decode(fixture())
        XCTAssertEqual(result.totalPurchaseAmount.krw.value, 6500000)
        XCTAssertEqual(result.totalPurchaseAmount.usd?.value, 1553)
        XCTAssertEqual(result.items[1].quantity.value, Decimal(string: "1.25"))
        XCTAssertEqual(result.items[1].profitLoss.rate.value, Decimal(string: "0.1494"))
        XCTAssertTrue(TossAccountDisplay.percent(result.items[1].profitLoss.rate, locale: Locale(identifier: "en_US_POSIX")).contains("14.94"))
        XCTAssertEqual(TossAccountDisplay.quantity(result.items[1].quantity, locale: Locale(identifier: "en_US_POSIX")), "1.25")
    }

    func testAccountPercentRoundingMatchesWindowsAndUsesTheRequestedLocale() throws {
        let up = try JSONDecoder().decode(TossAccountDecimal.self, from: Data(#""0.10005""#.utf8))
        let down = try JSONDecoder().decode(TossAccountDecimal.self, from: Data(#""-0.10005""#.utf8))
        XCTAssertEqual(TossAccountDisplay.percent(up, locale: Locale(identifier: "en_US")), "10.01%")
        XCTAssertEqual(TossAccountDisplay.percent(down, locale: Locale(identifier: "en_US")), "-10.01%")
        XCTAssertTrue(TossAccountDisplay.percent(up, locale: Locale(identifier: "de_DE")).contains("10,01"))
    }

    func testNullCurrencyAndTaxRemainUnavailable() throws {
        var object = try JSONSerialization.jsonObject(with: fixture()) as! [String: Any]
        var result = object["result"] as! [String: Any]
        result["totalPurchaseAmount"] = ["krw": "0", "usd": NSNull()]
        var items = result["items"] as! [[String: Any]]
        items[1]["cost"] = ["commission": "3.57", "tax": NSNull()]
        result["items"] = items; object["result"] = result
        let parsed = try TossAccountPortfolio.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(parsed.totalPurchaseAmount.usd)
        XCTAssertNil(parsed.items[1].cost.tax)
        XCTAssertEqual(TossAccountDisplay.money(parsed.totalPurchaseAmount.usd, currency: "USD"), "—")
    }

    func testInvalidAmountsAndCurrencyRejectEntireSnapshot() throws {
        let original = try JSONSerialization.jsonObject(with: fixture()) as! [String: Any]
        for value: Any in ["NaN", "Infinity", "1e5", "1junk", "1\n", "-1", String(repeating: "9", count: 31), 1, NSNull()] {
            var object = original, result = object["result"] as! [String: Any]
            var items = result["items"] as! [[String: Any]]
            items[0]["quantity"] = value; result["items"] = items; object["result"] = result
            XCTAssertThrowsError(try TossAccountPortfolio.decode(JSONSerialization.data(withJSONObject: object)))
        }
        var object = original, result = object["result"] as! [String: Any]
        var items = result["items"] as! [[String: Any]]
        items[1]["currency"] = "KRW"; result["items"] = items; object["result"] = result
        XCTAssertThrowsError(try TossAccountPortfolio.decode(JSONSerialization.data(withJSONObject: object)))
        result["items"] = [items[0], items[0]]; object["result"] = result
        XCTAssertThrowsError(try TossAccountPortfolio.decode(JSONSerialization.data(withJSONObject: object)))
    }

    @MainActor
    func testExplicitAccountViewerNeedsNoForecastOrSavedSelectionAndNeverAutoSelects() async throws {
        let (session, id) = AccountEndpoint.install { _ in (200, Self.sample, 0) }
        defer { session.invalidateAndCancel(); AccountEndpoint.remove(id) }
        let store = TossAccountStore(session: session, credentials: { (id, "synthetic-secret") })
        XCTAssertTrue(AccountEndpoint.requests(id).isEmpty)
        await store.startLoadingAccounts().value
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertEqual(store.selectedAccount, 0)
        XCTAssertNil(store.portfolio)
        XCTAssertEqual(store.accounts[0].maskedNumber, "•••• 8901")
        XCTAssertFalse(AccountEndpoint.requests(id).contains { $0.url?.path == "/api/v1/holdings" })
        await store.startSelecting(7).value
        XCTAssertNotNil(store.portfolio)
        XCTAssertNotNil(store.updatedAt)
        let requests = AccountEndpoint.requests(id)
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/v1/holdings" }.count, 1)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "X-Tossinvest-Account"), "7")
        XCTAssertTrue(requests.allSatisfy { ["/oauth2/token", "/api/v1/accounts", "/api/v1/holdings"].contains($0.url?.path) })
        await store.startSelecting(999).value
        XCTAssertEqual(store.selectedAccount, 0)
        XCTAssertNil(store.portfolio)
        XCTAssertEqual(AccountEndpoint.requests(id).count, requests.count)
    }

    @MainActor
    func testHideAndSwitchRejectPendingSnapshots() async throws {
        let (session, id) = AccountEndpoint.install { request in
            let account = request.value(forHTTPHeaderField: "X-Tossinvest-Account")
            return (200, Self.sample.replacingOccurrences(of: "Apple Inc.", with: account == "8" ? "Second account" : "First account"), account == "7" ? 0.12 : 0)
        }
        defer { session.invalidateAndCancel(); AccountEndpoint.remove(id) }
        let store = TossAccountStore(session: session, credentials: { (id, "synthetic-secret") })
        await store.startLoadingAccounts().value
        let first = store.startSelecting(7)
        while !AccountEndpoint.requests(id).contains(where: { $0.value(forHTTPHeaderField: "X-Tossinvest-Account") == "7" }) { await Task.yield() }
        await store.startSelecting(8).value
        await first.value
        XCTAssertEqual(store.selectedAccount, 8)
        XCTAssertEqual(store.portfolio?.items[1].name, "Second account")
        let pending = store.startSelecting(7)
        while AccountEndpoint.requests(id).filter({ $0.value(forHTTPHeaderField: "X-Tossinvest-Account") == "7" }).count < 2 { await Task.yield() }
        store.hide()
        await pending.value
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(store.selectedAccount, 0)
        XCTAssertNil(store.portfolio)
        XCTAssertNil(store.updatedAt)
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.message)
    }

    @MainActor
    func testFailedRefreshClearsFinancialSnapshot() async throws {
        let state = AccountTestStatus()
        let (session, id) = AccountEndpoint.install { _ in (state.value, Self.sample, 0) }
        defer { session.invalidateAndCancel(); AccountEndpoint.remove(id) }
        let store = TossAccountStore(session: session, credentials: { (id, "synthetic-secret") })
        await store.startLoadingAccounts().value; await store.startSelecting(7).value
        XCTAssertNotNil(store.portfolio)
        state.set(403)
        await store.startSelecting(7).value
        XCTAssertNil(store.portfolio)
        XCTAssertNil(store.updatedAt)
        XCTAssertNotNil(store.message)
    }

    @MainActor
    func testQueuedViewActionsCannotUndoHide() async {
        let (session, id) = AccountEndpoint.install { _ in (200, Self.sample, 0) }
        defer { session.invalidateAndCancel(); AccountEndpoint.remove(id) }
        let store = TossAccountStore(session: session, credentials: { (id, "synthetic-secret") })
        let load = store.startLoadingAccounts()
        store.hide()
        await load.value
        XCTAssertTrue(AccountEndpoint.requests(id).isEmpty)
        await store.startLoadingAccounts().value
        let prior = AccountEndpoint.requests(id).count
        let select = store.startSelecting(7)
        store.hide()
        await select.value
        XCTAssertEqual(AccountEndpoint.requests(id).count, prior)
        XCTAssertNil(store.portfolio)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testFutureEnumsKeepLiteralCurrencyAndErrorEnvelopeIsRejected() throws {
        var object = try JSONSerialization.jsonObject(with: fixture()) as! [String: Any]
        var result = object["result"] as! [String: Any]
        var items = result["items"] as! [[String: Any]]
        items[1]["marketCountry"] = "JP"; items[1]["currency"] = "JPY"
        result["items"] = items; object["result"] = result
        let decoded = try TossAccountPortfolio.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.items[1].currency, "JPY")
        XCTAssertTrue(TossAccountDisplay.money(decoded.items[1].lastPrice, currency: "JPY").hasPrefix("JPY "))
        items[1]["currency"] = "KRW\n"; result["items"] = items; object["result"] = result
        XCTAssertThrowsError(try TossAccountPortfolio.decode(JSONSerialization.data(withJSONObject: object)))
        object["error"] = ["code": "denied"]
        XCTAssertThrowsError(try TossAccountPortfolio.decode(JSONSerialization.data(withJSONObject: object)))
    }

    @MainActor
    func testAccountSummaryRendersEnglishAndKorean() throws {
        let portfolio = try TossAccountPortfolio.decode(fixture())
        let previous = L10n.testLocale
        defer { L10n.testLocale = previous }
        for language in [AppLanguage.english, .korean] {
            L10n.testLocale = language.locale
            let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 14) {
                TossAccountSummaryView(portfolio: portfolio)
                TossAccountPositionView(position: portfolio.items[1])
            }.padding().frame(width: 600).background(Color.black).foregroundStyle(Color.white))
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertGreaterThan(image.height, 300)
            XCTAssertLessThan(image.height, 500, "The default summary keeps investment and total-return details collapsed")
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: "/tmp/PenguinNotch-account-\(language.rawValue).png"))
        }
    }

    @MainActor
    func testAccountNotchUsesAPIDailyReturnAndSeparateCurrencyValues() throws {
        let portfolio = try TossAccountPortfolio.decode(fixture())
        let snapshot = TossAccountStore.snapshot(portfolio: portfolio, updatedAt: Date(), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(snapshot.id, "widget-account")
        XCTAssertEqual(snapshot.headlineText, "+1.41%")
        XCTAssertEqual(snapshot.bandOverride, .ample)
        XCTAssertEqual(snapshot.ringFraction!, 0.0141 / 0.30, accuracy: 1e-12)
        XCTAssertEqual(snapshot.windows.first { $0.id == "value-usd" }?.detail, "$1,785.00")
        XCTAssertFalse(snapshot.windows.contains { $0.detail?.contains("12345678901") == true || $0.detail?.contains("Apple") == true })
        for (text, band): (String, UsageBand?) in [("-0.0141", .critical), ("0", nil)] {
            let data = Data(Self.sample.replacingOccurrences(of: #""rate":"0.0141""#, with: #""rate":""# + text + #"""#).utf8)
            let changed = TossAccountStore.snapshot(portfolio: try TossAccountPortfolio.decode(data))
            XCTAssertEqual(changed.bandOverride, band)
            XCTAssertEqual(changed.headline?.prefersUsedText, true)
        }
    }

    @MainActor
    func testNotchOptInSharesFreshViewerAndStopsPrivateReadsOnDisable() async throws {
        let (session, id) = AccountEndpoint.install { _ in (200, Self.sample, 0) }
        defer { session.invalidateAndCancel(); AccountEndpoint.remove(id) }
        let store = TossAccountStore(session: session, credentials: { (id, "synthetic-secret") }, refreshInterval: .milliseconds(20))
        store.configureNotch(enabled: false, account: 7, source: .toss, revision: 0)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(AccountEndpoint.requests(id).isEmpty)
        await store.startLoadingAccounts().value
        await store.startSelecting(7).value
        let before = AccountEndpoint.requests(id).count
        store.configureNotch(enabled: true, account: 7, source: .toss, revision: 0)
        store.hideViewer()
        try await Task.sleep(for: .milliseconds(55))
        XCTAssertEqual(AccountEndpoint.requests(id).count, before, "Enabling and closing Settings reuse the fresh snapshot")
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertNotNil(store.portfolio)
        store.configureNotch(enabled: false, account: 7, source: .toss, revision: 0)
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(store.portfolio)
        XCTAssertEqual(AccountEndpoint.requests(id).count, before)
    }

    @MainActor
    func testNotchResumesOnlySelectedAccountAndCancelsLateResultsOnProviderChange() async throws {
        let (session, id) = AccountEndpoint.install { _ in (200, Self.sample, 0.08) }
        defer { session.invalidateAndCancel(); AccountEndpoint.remove(id) }
        let store = TossAccountStore(session: session, credentials: { (id, "synthetic-secret") })
        store.configureNotch(enabled: true, account: 8, source: .toss, revision: 0)
        try await Task.sleep(for: .milliseconds(30))
        let holdings = AccountEndpoint.requests(id).filter { $0.url?.path == "/api/v1/holdings" }
        XCTAssertEqual(holdings.map { $0.value(forHTTPHeaderField: "X-Tossinvest-Account") }, ["8"])
        store.configureNotch(enabled: true, account: 8, source: .finnhub, revision: 1)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(store.portfolio)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    @MainActor
    func testAccountRefreshDoesNotFlickerOrOverlapAndFailureClearsAmounts() async throws {
        let status = AccountTestStatus()
        let (session, id) = AccountEndpoint.install { _ in (status.value, Self.sample, 0.05) }
        defer { session.invalidateAndCancel(); AccountEndpoint.remove(id) }
        let store = TossAccountStore(session: session, credentials: { (id, "synthetic-secret") })
        store.configureNotch(enabled: false, account: 7, source: .toss, revision: 0)
        await store.startLoadingAccounts().value; await store.startSelecting(7).value
        store.configureNotch(enabled: true, account: 7, source: .toss, revision: 0)
        status.set(403)
        let before = AccountEndpoint.requests(id).filter { $0.url?.path == "/api/v1/holdings" }.count
        let refresh = Task { await store.refreshNotch() }
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertNotNil(store.portfolio, "Same-account reads retain the previous snapshot until completion")
        await store.refreshNotch()
        await refresh.value
        XCTAssertEqual(AccountEndpoint.requests(id).filter { $0.url?.path == "/api/v1/holdings" }.count, before + 1)
        XCTAssertNil(store.portfolio)
        XCTAssertNil(store.updatedAt)
        XCTAssertEqual(store.snapshots.first?.headlineText, "—")
        store.hide()
    }

    @MainActor
    func testScheduledRefreshUsesOneDiscoveryAndOneReadPerMinute() async throws {
        let (session, id) = AccountEndpoint.install { _ in (200, Self.sample, 0) }
        defer { session.invalidateAndCancel(); AccountEndpoint.remove(id) }
        var now = Date()
        let store = TossAccountStore(session: session, credentials: { (id, "synthetic-secret") },
                                     refreshInterval: .milliseconds(20), clock: { now })
        store.configureNotch(enabled: true, account: 7, source: .toss, revision: 0)
        try await Task.sleep(for: .milliseconds(55))
        XCTAssertNotNil(store.portfolio)
        now = now.addingTimeInterval(59)
        try await Task.sleep(for: .milliseconds(45))
        XCTAssertEqual(AccountEndpoint.requests(id).filter { $0.url?.path == "/api/v1/holdings" }.count, 1)
        now = now.addingTimeInterval(2)
        try await Task.sleep(for: .milliseconds(55))
        XCTAssertEqual(AccountEndpoint.requests(id).filter { $0.url?.path == "/api/v1/accounts" }.count, 1)
        XCTAssertEqual(AccountEndpoint.requests(id).filter { $0.url?.path == "/api/v1/holdings" }.count, 2)
        store.hide()
    }

    @MainActor
    func testAccountNotchPreferencesDefaultOffAndNeverPersistFinancialValues() async throws {
        let suite = "AccountNotchTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.accountNotchEnabled)
        XCTAssertEqual(preferences.accountNotchSeq, 0)
        preferences.tossAccountSeq = 7
        XCTAssertFalse(preferences.accountNotchEnabled, "Forecast opt-in must not grant private notch polling")
        let (session, id) = AccountEndpoint.install { _ in (200, Self.sample, 0) }
        defer { session.invalidateAndCancel(); AccountEndpoint.remove(id) }
        let store = TossAccountStore(session: session, credentials: { (id, "synthetic-secret") })
        store.start(preferences: preferences)
        preferences.accountNotchSeq = 8
        preferences.accountNotchEnabled = true
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(store.selectedAccount, 8)
        XCTAssertNotNil(store.portfolio)
        XCTAssertEqual(preferences.tossAccountSeq, 7)
        XCTAssertEqual(defaults.integer(forKey: "accountNotchSeq"), 8)
        let saved = String(describing: defaults.persistentDomain(forName: suite) ?? [:])
        XCTAssertFalse(saved.contains("12345678901") || saved.contains("7200000") || saved.contains("Apple Inc."))
        preferences.setNotchItemVisible(false, id: "widget-account")
        XCTAssertFalse(preferences.accountNotchEnabled)
        XCTAssertNil(store.portfolio)
        XCTAssertTrue(store.snapshots.isEmpty)
        preferences.accountNotchSeq = -1
        XCTAssertEqual(preferences.accountNotchSeq, 0)
    }

    @MainActor
    func testAccountNotchRendersBothMetersAndHoverDirectionsInEnglishAndKorean() throws {
        let prior = L10n.testLocale
        defer { L10n.testLocale = prior }
        for language in [AppLanguage.english, .korean] {
            L10n.testLocale = Locale(identifier: language.rawValue)
            let snapshot = TossAccountStore.snapshot(portfolio: try TossAccountPortfolio.decode(fixture()), updatedAt: Date())
            XCTAssertEqual(ProviderReading(snapshot: snapshot).text, snapshot.headlineText)
            let view = VStack(spacing: 16) {
                HStack {
                    ProviderCell(snapshot: snapshot, meterStyle: .ring)
                    ProviderCell(snapshot: snapshot, meterStyle: .bar)
                    ProviderReading(snapshot: snapshot, across: 130)
                }
                HStack(alignment: .top) {
                    TooltipCard(snapshot: snapshot, now: Date(), direction: .leading)
                    TooltipCard(snapshot: snapshot, now: Date(), direction: .trailing)
                }
                HStack(alignment: .top) {
                    TooltipCard(snapshot: snapshot, now: Date(), direction: .up)
                    TooltipCard(snapshot: snapshot, now: Date(), direction: .down)
                }
            }.padding().background(Color.black).environment(\.colorScheme, .dark).transaction { $0.animation = nil }
            let renderer = ImageRenderer(content: view)
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertGreaterThan(image.height, 400)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: "/tmp/PenguinNotch-account-notch-\(language.rawValue).png"))
        }
    }

    @MainActor
    func testUnifiedAccountChoicePreservesOptInsUntilExplicitSelection() async throws {
        let (session, id) = AccountEndpoint.install { _ in (200, Self.sample, 0) }
        defer { session.invalidateAndCancel(); AccountEndpoint.remove(id) }
        let store = TossAccountStore(session: session, credentials: { (id, "synthetic-secret") })
        let suite = "StockSettingsUX-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.tossAccountSeq = 8
        preferences.accountNotchSeq = 7
        preferences.accountNotchEnabled = true
        let view = TossAccountView(preferences: preferences, account: store)
        XCTAssertEqual(preferences.tossAccountSeq, 8)
        XCTAssertEqual(preferences.accountNotchSeq, 7)
        XCTAssertTrue(AccountEndpoint.requests(id).isEmpty)
        view.includeHoldings(false)
        XCTAssertEqual(preferences.tossAccountSeq, 0)
        XCTAssertTrue(preferences.accountNotchEnabled)
        view.includeHoldings(true)
        XCTAssertEqual(preferences.tossAccountSeq, 0, "Loading and choosing an account is required")
        await store.startLoadingAccounts().value
        XCTAssertEqual(store.selectedAccount, 0)
        XCTAssertEqual(preferences.accountNotchSeq, 7)
        preferences.accountNotchEnabled = false
        await view.selectAccount(7)?.value
        view.includeHoldings(true)
        XCTAssertEqual(preferences.tossAccountSeq, 7)
        XCTAssertFalse(preferences.portfolioForecastEnabled, "Including holdings does not enable forecasts")
        await view.selectAccount(8)?.value
        XCTAssertEqual(preferences.tossAccountSeq, 8)
        XCTAssertEqual(store.selectedAccount, 8)
        preferences.accountNotchEnabled = true
        view.selectAccount(7)
        XCTAssertEqual(preferences.tossAccountSeq, 7)
        XCTAssertEqual(preferences.accountNotchSeq, 7)
        view.selectAccount(999)
        XCTAssertEqual(preferences.tossAccountSeq, 7)
        view.selectAccount(0)
        XCTAssertEqual(preferences.tossAccountSeq, 0)
        XCTAssertFalse(preferences.accountNotchEnabled)
        XCTAssertEqual(preferences.accountNotchSeq, 0)
        store.hide()
    }

    @MainActor
    func testStockSettingsPagesRenderWithoutReadingAccountsOrChangingSavedChoices() async throws {
        let (session, id) = AccountEndpoint.install { _ in (200, Self.sample, 0) }
        defer { session.invalidateAndCancel(); AccountEndpoint.remove(id) }
        let account = TossAccountStore(session: session, credentials: { (id, "synthetic-secret") })
        let suite = "StockSettingsUX-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.tossAccountSeq = 8
        preferences.accountNotchSeq = 7
        preferences.accountNotchEnabled = true
        _ = preferences.addStockSymbol("us:AAPL")
        _ = preferences.addStockSymbol("kr:005930")
        let portfolio = StockForecastStore(journal: StockForecastJournal())
        let previous = L10n.testLocale
        defer { L10n.testLocale = previous }
        XCTAssertEqual(StockSettingsPage.allCases.count, 4)
        for language in [AppLanguage.english, .korean] {
            L10n.testLocale = language.locale
            for (index, page) in StockSettingsPage.allCases.enumerated() {
                let view = NSHostingView(rootView: StockSettings(preferences: preferences,
                    portfolio: portfolio, account: account, page: page).environment(\.colorScheme, .dark))
                view.appearance = NSAppearance(named: .darkAqua)
                view.frame = NSRect(x: 0, y: 0, width: 680, height: 640)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = view
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                window.orderFront(nil)
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
                let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                XCTAssertEqual(view.bounds.size, NSSize(width: 680, height: 640))
                XCTAssertEqual(image.pixelsWide, Int(680 * window.backingScaleFactor))
                XCTAssertEqual(image.pixelsHigh, Int(640 * window.backingScaleFactor))
                try image.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: "/tmp/PenguinNotch-stock-settings-mac-\(language.rawValue)-\(index).png"))
                window.orderOut(nil)
                window.contentView = nil
            }
        }
        XCTAssertTrue(AccountEndpoint.requests(id).isEmpty, "Local navigation cannot discover or load an account")
        XCTAssertEqual(preferences.tossAccountSeq, 8)
        XCTAssertEqual(preferences.accountNotchSeq, 7)
        XCTAssertTrue(preferences.accountNotchEnabled)
        XCTAssertTrue(portfolio.journal.records.isEmpty)
    }

    private static let sample = #"{"result":{"totalPurchaseAmount":{"krw":"6500000","usd":"1553"},"marketValue":{"amount":{"krw":"7200000","usd":"1785"},"amountAfterCost":{"krw":"7050000","usd":"1771.43"}},"profitLoss":{"amount":{"krw":"700000","usd":"232"},"amountAfterCost":{"krw":"550000","usd":"218.43"},"rate":"0.1179","rateAfterCost":"0.0983"},"dailyProfitLoss":{"amount":{"krw":"100000","usd":"25"},"rate":"0.0141"},"items":[{"symbol":"005930","name":"삼성전자","marketCountry":"KR","currency":"KRW","quantity":"100","lastPrice":"72000","averagePurchasePrice":"65000","marketValue":{"purchaseAmount":"6500000","amount":"7200000","amountAfterCost":"7050000"},"profitLoss":{"amount":"700000","amountAfterCost":"550000","rate":"0.1077","rateAfterCost":"0.0846"},"dailyProfitLoss":{"amount":"100000","rate":"0.0141"},"cost":{"commission":"14400","tax":"135600"}},{"symbol":"AAPL","name":"Apple Inc.","marketCountry":"US","currency":"USD","quantity":"1.25","lastPrice":"178.5","averagePurchasePrice":"155.3","marketValue":{"purchaseAmount":"1553","amount":"1785","amountAfterCost":"1771.43"},"profitLoss":{"amount":"232","amountAfterCost":"218.43","rate":"0.1494","rateAfterCost":"0.1406"},"dailyProfitLoss":{"amount":"25","rate":"0.0142"},"cost":{"commission":"3.57","tax":"10"}}]}}"#
}

private final class AccountTestStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    var value: Int { lock.withLock { status } }
    func set(_ value: Int) { lock.withLock { status = value } }
}

private final class AccountEndpoint: URLProtocol, @unchecked Sendable {
    typealias Response = @Sendable (URLRequest) -> (Int, String, TimeInterval)
    private static let lock = NSLock()
    private static var handlers: [String: Response] = [:]
    private static var recorded: [String: [URLRequest]] = [:]
    private let stateLock = NSLock()
    private var stopped = false
    static func install(_ handler: @escaping Response) -> (URLSession, String) {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler; recorded[id] = [] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountEndpoint.self]
        config.httpAdditionalHeaders = ["X-Account-Test-Fixture": id]
        return (URLSession(configuration: config), id)
    }
    static func remove(_ id: String) { lock.withLock { handlers[id] = nil; recorded[id] = nil } }
    static func requests(_ id: String) -> [URLRequest] { lock.withLock { recorded[id] ?? [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stateLock.withLock { stopped = true } }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Account-Test-Fixture"),
              let handler = Self.lock.withLock({ () -> Response? in
                  Self.recorded[id, default: []].append(request); return Self.handlers[id]
              }) else { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        let result: (Int, String, TimeInterval)
        switch request.url?.path {
        case "/oauth2/token": result = (200, #"{"access_token":"synthetic-account-token","expires_in":3600}"#, 0)
        case "/api/v1/accounts": result = (200, #"{"result":[{"accountNo":"12345678901","accountSeq":7,"accountType":"BROKERAGE"},{"accountNo":"23456789012","accountSeq":8,"accountType":"BROKERAGE"}]}"#, 0)
        case "/api/v1/holdings": result = handler(request)
        default: client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let send = { [self] in
            guard !stateLock.withLock({ stopped }) else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(result.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + result.2, execute: send)
    }
}
