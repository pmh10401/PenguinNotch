import XCTest
import Security
@testable import PenguinNotch

final class TossCredentialsTests: XCTestCase {
    private let bundle = "{\"version\":1,\"clientID\":\"example-id\",\"clientSecret\":\"example-secret\"}"

    func testCombinedItemNeedsOnlyOneReadAndNeverTouchesLegacyKeys() throws {
        let keychain = Fixture()
        keychain.put("current", "credentials", bundle)
        let store = keychain.store()
        for _ in 0..<4 {
            let saved = try store.load()
            XCTAssertEqual(saved.clientID, "example-id")
            XCTAssertEqual(saved.clientSecret, "example-secret")
        }
        XCTAssertEqual(keychain.reads.map(\.account), ["credentials"])
        XCTAssertTrue(keychain.reads.allSatisfy { !$0.interactive })
    }

    func testSavingWritesTheWholePairAtomically() throws {
        let keychain = Fixture()
        XCTAssertTrue(keychain.store().save(clientID: " example-id ", clientSecret: " example-secret "))
        XCTAssertEqual(keychain.writes.count, 1)
        XCTAssertEqual(keychain.writes.first?.account, "credentials")
        let data = try XCTUnwrap(keychain.items["current/credentials"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["clientID"] as? String, "example-id")
        XCTAssertEqual(json["clientSecret"] as? String, "example-secret")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(Set(json.keys), ["version", "clientID", "clientSecret"])
    }

    func testLegacyMigrationPreservesOriginalItemsAndNeverPromptsInBackground() throws {
        let keychain = Fixture()
        keychain.put("old", "client-id", "example-id")
        keychain.put("old", "client-secret", "example-secret")
        let originals = keychain.items
        let saved = try keychain.store().load()
        XCTAssertEqual(saved.clientID, "example-id")
        XCTAssertEqual(saved.clientSecret, "example-secret")
        XCTAssertNotNil(keychain.items["current/credentials"])
        for (key, value) in originals { XCTAssertEqual(keychain.items[key], value) }
        XCTAssertTrue(keychain.removals.isEmpty)
        XCTAssertTrue(keychain.reads.allSatisfy { !$0.interactive })
        XCTAssertTrue(keychain.writes.allSatisfy { !$0.interactive })
        XCTAssertEqual(try keychain.store().load().clientSecret, "example-secret")
    }

    func testDeniedCombinedItemDoesNotFallBackToOlderSecrets() {
        let keychain = Fixture()
        keychain.denied["current/credentials"] = errSecAuthFailed
        keychain.put("old", "client-id", "old-id")
        keychain.put("old", "client-secret", "old-secret")
        let store = keychain.store()
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(keychain.reads.map(\.account), ["credentials"])
        XCTAssertTrue(keychain.writes.isEmpty)
    }

    func testDeniedLegacyItemStopsMigrationWithoutReadingAnotherCopy() {
        let keychain = Fixture()
        keychain.denied["current/client-id"] = errSecUserCanceled
        keychain.put("old", "client-id", "old-id")
        keychain.put("old", "client-secret", "old-secret")
        let original = keychain.items
        XCTAssertThrowsError(try keychain.store().load())
        XCTAssertEqual(keychain.reads.map { $0.service + "/" + $0.account },
                       ["current/credentials", "current/client-id"])
        XCTAssertEqual(keychain.items, original)
        XCTAssertTrue(keychain.writes.isEmpty)
    }

    func testMalformedOrUnknownBundleIsPreservedAndCannotBeOverwrittenWithABlankSecret() {
        for value in ["not-json", "{\"version\":2,\"clientID\":\"x\",\"clientSecret\":\"y\"}",
                      "{\"version\":1,\"clientID\":\"x\",\"clientSecret\":\"\"}",
                      "{\"version\":1,\"clientID\":\"x\",\"clientSecret\":\"y\",\"unknown\":true}"] {
            let keychain = Fixture()
            keychain.put("current", "credentials", value)
            let store = keychain.store()
            XCTAssertThrowsError(try store.load())
            XCTAssertFalse(store.save(clientID: "replacement", clientSecret: ""))
            XCTAssertEqual(keychain.items["current/credentials"], Data(value.utf8))
            XCTAssertTrue(keychain.writes.isEmpty)
        }
    }

    func testFailedMigrationWriteLeavesTheLegacyPairIntact() {
        let keychain = Fixture()
        keychain.put("current", "client-id", "example-id")
        keychain.put("current", "client-secret", "example-secret")
        keychain.failWrites = true
        let original = keychain.items
        XCTAssertThrowsError(try keychain.store().load())
        XCTAssertEqual(keychain.items, original)
        XCTAssertTrue(keychain.removals.isEmpty)
    }

    func testBlankSecretPreservesReadableSavedSecretOrFailsWithoutChangingAnything() throws {
        let keychain = Fixture()
        keychain.put("current", "credentials", bundle)
        XCTAssertTrue(keychain.store().save(clientID: "new-id", clientSecret: "  "))
        XCTAssertEqual(try keychain.store().load().clientSecret, "example-secret")
        XCTAssertEqual(try keychain.store().load().clientID, "new-id")

        keychain.denied["current/credentials"] = errSecInteractionNotAllowed
        let original = keychain.items
        XCTAssertFalse(keychain.store().save(clientID: "other-id", clientSecret: ""))
        XCTAssertEqual(keychain.items, original)
    }

    func testExplicitUnlockPromptsOnceThenBackgroundReadsUseTheCache() throws {
        let keychain = Fixture()
        keychain.put("current", "credentials", bundle)
        keychain.requiresInteraction = true
        let store = keychain.store()
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try store.authorize().clientID, "example-id")
        for _ in 0..<10 { XCTAssertEqual(try store.load().clientSecret, "example-secret") }
        XCTAssertEqual(keychain.reads.map(\.interactive), [false, true])
        XCTAssertEqual(keychain.reads.map(\.account), ["credentials", "credentials"])
    }

    func testRemovalFailureKeepsTheCombinedCredential() {
        let keychain = Fixture()
        keychain.put("current", "credentials", bundle)
        keychain.failRemoval = "old/client-secret"
        XCTAssertFalse(keychain.store().clear())
        XCTAssertEqual(keychain.items["current/credentials"], Data(bundle.utf8))
    }

    // Only the native Keychain operations are substituted; the credential
    // parser, cache, migration, save and removal paths above are production.
    private final class Fixture {
        struct Call { let service: String; let account: String; let interactive: Bool }
        var items: [String: Data] = [:]
        var denied: [String: OSStatus] = [:]
        var reads: [Call] = []
        var writes: [Call] = []
        var removals: [Call] = []
        var failWrites = false
        var failRemoval: String?
        var requiresInteraction = false
        func put(_ service: String, _ account: String, _ value: String) {
            items[service + "/" + account] = Data(value.utf8)
        }
        func store() -> TossCredentialStore {
            TossCredentialStore(service: "current", previousService: "old", read: { [self] service, account, interactive in
                reads.append(Call(service: service, account: account, interactive: interactive))
                let key = service + "/" + account
                if let status = denied[key] { return (status, nil) }
                if requiresInteraction && !interactive { return (errSecInteractionNotAllowed, nil) }
                guard let data = items[key] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            }, write: { [self] service, account, value, interactive in
                writes.append(Call(service: service, account: account, interactive: interactive))
                guard !failWrites else { return false }
                put(service, account, value)
                return true
            }, remove: { [self] service, account, interactive in
                removals.append(Call(service: service, account: account, interactive: interactive))
                let key = service + "/" + account
                guard key != failRemoval else { return false }
                items.removeValue(forKey: key)
                return true
            })
        }
    }
}
