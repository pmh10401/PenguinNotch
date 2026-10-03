import Foundation
import Security

/// A person's permission for one keychain read to show the password dialogue.
///
/// Granted by "Allow access…" and by nothing else. Spent by the read it is
/// taken for, whatever that read's outcome — a Deny that left it standing would
/// hand the next poll a dialogue to show. And it lapses: the click is followed
/// by a refresh at once, but where that refresh never reached the keychain the
/// permission would otherwise sit there until some later poll spent it, and the
/// dialogue would appear on a timer after all.
final class PromptPermission: @unchecked Sendable {
    static let window: TimeInterval = 60

    private let now: () -> Date
    private var owedUntil: Date?
    private let lock = NSLock()

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func grant() {
        lock.lock()
        owedUntil = now().addingTimeInterval(Self.window)
        lock.unlock()
    }

    /// Whether a grant is standing, without spending it.
    var isOwed: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = owedUntil else { return false }
        return now() < until
    }

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = owedUntil else { return false }
        owedUntil = nil
        return now() < until
    }
}

/// A person's "Deny" to the dialogue they asked for, kept until they ask again.
///
/// Without it the answer was overruled within the hour (#98): the next
/// background read was refused, retried through `/usr/bin/security`, and
/// handed the secret back anyway — and the Claude CLI and Claude Desktop's
/// cache never asked at all. Kept in the app's preferences so a relaunch does
/// not quietly undo it; the designated initialisers take none, so a test never
/// writes into the installed app's settings.
final class KeychainRefusal: @unchecked Sendable {
    private let defaults: UserDefaults?
    private let key: String
    private var inMemory = false
    private let lock = NSLock()

    init(key: String, defaults: UserDefaults?) {
        self.key = "keychainRefused." + key
        self.defaults = defaults
    }

    var isRefused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return defaults?.bool(forKey: key) ?? inMemory
    }

    func set(_ refused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let defaults {
            if refused { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
        } else {
            inMemory = refused
        }
    }
}

/// Reading a borrowed keychain secret without ever raising the dialogue from a
/// background refresh.
///
/// Claude Code and Antigravity both file their items through `/usr/bin/security`.
/// An item created that way admits only Apple's own tools in its *partition
/// list*, which nothing in the GUI writes — so "Always Allow", which writes the
/// access list, buys exactly one read, and a poll raised the dialogue again.
enum KeychainSecret {
    /// Serialises the process-wide interaction switch. It is one switch for the
    /// whole app, so every reader that flips it must take this same lock: two
    /// readers interleaving their save and restore could otherwise leave
    /// interaction off for good, and "Allow access…" would never show its
    /// dialogue again.
    private static let interactionLock = NSLock()

    /// Runs `query` and returns its status and data.
    ///
    /// When not `interactive`, interaction is switched off for the read —
    /// `SecKeychainSetUserInteractionAllowed`, which legacy items honour, as well
    /// as `kSecUseAuthenticationUIFail`, which they may ignore. A refusal is
    /// returned unchanged: a child `security` process has its own interaction
    /// policy and could show the very password dialog this read suppressed.
    ///
    /// Readers that do not go through here (Cursor's, today) do not take the
    /// lock, so one of their reads landing inside the window is refused once
    /// without a prompt. Their caches retry after a backoff: a delayed prompt,
    /// never a lost one.
    static func read(query: [CFString: Any], interactive: Bool,
                     copyMatching: ([CFString: Any]) -> (OSStatus, Data?) = { query in
                         var item: CFTypeRef?
                         let status = SecItemCopyMatching(query as CFDictionary, &item)
                         return (status, item as? Data)
                     }) -> (status: OSStatus, data: Data?) {
        var query = query
        if !interactive { query[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail }
        return perform(interactive: interactive) { copyMatching(query) }
    }

    /// Writes during a background migration need the same process-wide
    /// interaction policy as reads. Explicit settings actions can opt in.
    static func perform<Value>(interactive: Bool, _ operation: () -> Value) -> Value {
        interactionLock.lock()
        defer { interactionLock.unlock() }

        var wasAllowed: DarwinBoolean = true
        if !interactive {
            SecKeychainGetUserInteractionAllowed(&wasAllowed)
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer { if !interactive { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) } }

        return operation()
    }
}
