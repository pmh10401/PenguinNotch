import XCTest
import Security
@testable import PenguinNotch

/// Where the Apify token comes from, and which account the settings row
/// names for it. Every keychain is stood in for by a closure: there is no
/// keychain to point a unit test at, and a real read could put a prompt in
/// front of whoever is running the suite.
final class ApifyCredentialsTests: XCTestCase {
    private var directory: URL!
    private var authURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("apify-credentials-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        authURL = directory.appendingPathComponent("auth.json")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// The CLI's file with the token still in it — an older CLI, or one run
    /// with `APIFY_DISABLE_KEYRING=1`.
    private let fileLogin = #"{"token":"apify_api_fixture","id":"abc123","username":"fixture","email":"fixture@example.invalid","plan":{"id":"SCALE","description":"Scale plan"},"secretsBackend":"file"}"#
    /// The current CLI's file: the secret moved to the keyring, the account
    /// metadata stayed behind.
    private let keyringLogin = #"{"id":"abc123","username":"fixture","email":"fixture@example.invalid","plan":{"id":"SCALE"},"secretsBackend":"keyring"}"#

    private func sources(environment: [String: String] = [:],
                         settings: String? = nil,
                         cliKeychain: @escaping () throws -> String = { throw UsageProviderError.needsAuth },
                         cliKeychainPresent: Bool = false) -> ApifyCredentialSources {
        ApifyCredentialSources(
            environment: environment,
            settingsToken: { settings },
            settingsPresent: { settings != nil },
            deleteSettingsToken: {},
            authURL: authURL,
            cliKeychain: cliKeychain,
            cliKeychainPresent: { cliKeychainPresent },
            forgetCached: {},
            askAgain: {}
        )
    }

    // MARK: - Which token is used

    func testTheEnvironmentWinsOverEverythingElse() throws {
        try fileLogin.write(to: authURL, atomically: true, encoding: .utf8)
        let credential = try ApifyCredentials.load(
            sources(environment: [ApifyCredentials.environmentKey: " env_token "], settings: "pasted")
        )
        XCTAssertEqual(credential, ApifyCredentials.Credential(token: "env_token", source: .environment),
                       "trimmed, and ahead of both the pasted and the borrowed token")
    }

    func testABlankEnvironmentTokenIsNoToken() throws {
        try fileLogin.write(to: authURL, atomically: true, encoding: .utf8)
        let credential = try ApifyCredentials.load(
            sources(environment: [ApifyCredentials.environmentKey: "  \n"], settings: "pasted")
        )
        XCTAssertEqual(credential.source, .settings)
    }

    func testAPastedTokenWinsOverTheCLILogin() throws {
        try fileLogin.write(to: authURL, atomically: true, encoding: .utf8)
        var asked = 0
        let credential = try ApifyCredentials.load(
            sources(settings: "pasted", cliKeychain: { asked += 1; return "ring" }, cliKeychainPresent: true)
        )
        XCTAssertEqual(credential, ApifyCredentials.Credential(token: "pasted", source: .settings))
        XCTAssertEqual(asked, 0, "an explicit token means the CLI's keychain item is never asked for")
    }

    func testTheCLIFileTokenIsUsedWhenTheFileStillHoldsOne() throws {
        try fileLogin.write(to: authURL, atomically: true, encoding: .utf8)
        var asked = 0
        let credential = try ApifyCredentials.load(sources(cliKeychain: { asked += 1; return "ring" }))
        XCTAssertEqual(credential, ApifyCredentials.Credential(token: "apify_api_fixture", source: .cliFile))
        XCTAssertEqual(asked, 0)
    }

    func testAKeyringLoginFallsThroughToTheCLIKeychain() throws {
        try keyringLogin.write(to: authURL, atomically: true, encoding: .utf8)
        var asked = 0
        let credential = try ApifyCredentials.load(sources(cliKeychain: { asked += 1; return " ring " }))
        XCTAssertEqual(credential, ApifyCredentials.Credential(token: "ring", source: .cliKeychain))
        XCTAssertEqual(asked, 1)
    }

    func testWithoutALoginFileTheCLIKeychainIsNeverAsked() {
        var asked = 0
        XCTAssertThrowsError(try ApifyCredentials.load(
            sources(cliKeychain: { asked += 1; return "ring" }, cliKeychainPresent: true)
        )) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
        XCTAssertEqual(asked, 0, "no `apify login` on this Mac means nothing to borrow — and no dialogue")
    }

    func testARefusedKeychainReadIsReportedAsARefusal() throws {
        try keyringLogin.write(to: authURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ApifyCredentials.load(
            sources(cliKeychain: { throw UsageProviderError.accessDenied })
        )) { error in
            guard case UsageProviderError.accessDenied = error else {
                return XCTFail("expected accessDenied, got \(error)")
            }
        }
    }

    func testAnEmptyFileTokenCountsAsAbsent() throws {
        try #"{"token":"","username":"fixture"}"#.write(to: authURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ApifyCredentials.load(sources())) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testAnUnreadableLoginFileIsAnErrorRatherThanALogout() throws {
        try "{not json".write(to: authURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ApifyCredentials.load(sources())) { error in
            guard case UsageProviderError.apiError(let why) = error else {
                return XCTFail("expected apiError, got \(error)")
            }
            XCTAssertTrue(why.contains("auth.json"), why)
        }
    }

    // MARK: - Whose readings these are

    func testTheAccountNamesTheLoginTheTokenCameFrom() throws {
        try fileLogin.write(to: authURL, atomically: true, encoding: .utf8)
        let account = try XCTUnwrap(ApifyCredentials.account(sources()))
        XCTAssertEqual(account.label, "fixture@example.invalid")
        XCTAssertEqual(account.plan, "Scale", "Apify's plan ids are shouted; the card and the row are not")
        XCTAssertEqual(account.source, "Apify CLI")
        XCTAssertEqual(account.manageURL?.absoluteString, "https://console.apify.com/billing")
        XCTAssertEqual(account.summary, "fixture@example.invalid · Scale · via Apify CLI")
    }

    func testTheUsernameStandsInWhenTheLoginCarriesNoEmail() throws {
        try #"{"token":"apify_api_fixture","id":"abc123","username":"fixture"}"#
            .write(to: authURL, atomically: true, encoding: .utf8)
        let account = try XCTUnwrap(ApifyCredentials.account(sources()))
        XCTAssertEqual(account.label, "fixture")
        XCTAssertNil(account.plan)
    }

    func testAKeyringLoginIsAnAccountOnlyWhileItsItemExists() throws {
        try keyringLogin.write(to: authURL, atomically: true, encoding: .utf8)
        XCTAssertNil(ApifyCredentials.account(sources(cliKeychainPresent: false)),
                     "the file alone is a login that has been logged out of")
        let account = try XCTUnwrap(ApifyCredentials.account(sources(cliKeychainPresent: true)))
        XCTAssertEqual(account.label, "fixture@example.invalid")
        XCTAssertEqual(account.source, "Apify CLI")
    }

    func testAPastedOrExportedTokenIsAnAccountOfItsOwn() throws {
        // The reading is whatever account that token belongs to, which the
        // CLI's file cannot say — so the file's address must not be borrowed.
        try fileLogin.write(to: authURL, atomically: true, encoding: .utf8)
        for account in [ApifyCredentials.account(sources(settings: "pasted")),
                        ApifyCredentials.account(sources(environment: [ApifyCredentials.environmentKey: "env"]))] {
            let account = try XCTUnwrap(account)
            XCTAssertNil(account.label)
            XCTAssertNil(account.plan)
            XCTAssertEqual(account.source, "Apify")
        }
    }

    func testNothingOnThisMacIsNoAccount() {
        XCTAssertNil(ApifyCredentials.account(sources()))
    }
}

final class ApifyKeychainTests: XCTestCase {
    func testBackgroundReadsAndCacheInvalidationNeverGrantPromptPermission() throws {
        var interactive: [Bool] = []
        let keychain = ApifyCLIKeychain(itemModifiedAt: { nil }) { flag in
            interactive.append(flag)
            return "fixture"
        }
        XCTAssertEqual(try keychain.load(), "fixture")
        keychain.forgetCached()
        XCTAssertEqual(try keychain.load(), "fixture")
        XCTAssertEqual(interactive, [false, false])
    }

    func testAllowAccessPermitsOneReadAndUnspentGrantsExpire() throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var interactive: [Bool] = []
        let keychain = ApifyCLIKeychain(now: { now }, itemModifiedAt: { nil }) { flag in
            interactive.append(flag)
            return "fixture"
        }
        keychain.askAgain()
        _ = try keychain.load()
        keychain.forgetCached()
        _ = try keychain.load()
        keychain.askAgain()
        now = now.addingTimeInterval(PromptPermission.window + 1)
        _ = try keychain.load()
        XCTAssertEqual(interactive, [true, false, false])
    }

    func testExplicitDenialSurvivesRotationAndRelaunchUntilAllowAccess() throws {
        let suite = "ApifyKeychainTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var modified = Date(timeIntervalSince1970: 1_800_000_000)
        var interactive: [Bool] = []
        let keychain = ApifyCLIKeychain(refusals: defaults, itemModifiedAt: { modified }) { flag in
            interactive.append(flag)
            throw UsageProviderError.accessDenied
        }
        keychain.askAgain()
        XCTAssertThrowsError(try keychain.load())
        keychain.forgetCached()
        modified = modified.addingTimeInterval(60)
        XCTAssertThrowsError(try keychain.load())

        let relaunched = ApifyCLIKeychain(refusals: defaults, itemModifiedAt: { modified }) { flag in
            interactive.append(flag)
            return "allowed_fixture"
        }
        XCTAssertThrowsError(try relaunched.load())
        XCTAssertEqual(interactive, [true], "neither rotation nor relaunch overrides Deny")
        relaunched.askAgain()
        XCTAssertEqual(try relaunched.load(), "allowed_fixture")
        relaunched.forgetCached()
        XCTAssertEqual(try relaunched.load(), "allowed_fixture")
        XCTAssertEqual(interactive, [true, true, false])
    }

    func testSecretReadIsNoninteractiveAndDoesNotBypassRefusals() {
        let item = KeychainItem.Match(modifiedAt: nil, persistentRef: Data("fixture".utf8),
                                      service: ApifyCLIKeychain.service)
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
            var reads = 0
            XCTAssertThrowsError(try ApifyCLIKeychain.read(newest: { item }, copyMatching: { query in
                reads += 1
                XCTAssertEqual(query[kSecValuePersistentRef] as? Data, item.persistentRef)
                XCTAssertEqual(query[kSecUseAuthenticationUI] as? String, kSecUseAuthenticationUIFail as String)
                var allowed: DarwinBoolean = true
                SecKeychainGetUserInteractionAllowed(&allowed)
                XCTAssertFalse(allowed.boolValue)
                return (status, nil)
            })) { error in
                guard case UsageProviderError.accessDenied = error else {
                    return XCTFail("expected accessDenied, got \(error)")
                }
            }
            XCTAssertEqual(reads, 1, "a refusal must not fall through to another secret reader")
        }
    }
}
