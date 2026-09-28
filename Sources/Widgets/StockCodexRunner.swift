import Darwin
import Foundation

/// One public-market-data request through the user's official Codex CLI login.
enum StockCodexRunner {
    struct Output: Sendable {
        let text: String
        let model: String
    }

    enum Failure: String, Error, LocalizedError {
        case loginNeeded = "Log in with the Codex CLI first. File-based CLI login is required."
        case notInstalled = "Install the official Codex CLI to run stock analysis."
        case busy = "A Codex stock analysis is already running."
        case timedOut = "Codex stock analysis timed out."
        case unsafeSession = "Codex could not start an isolated, tool-free analysis."
        case invalidResponse = "Codex returned an invalid or oversized analysis response."
        case failed = "Codex CLI analysis failed. Check CLI login and model access."
        var errorDescription: String? {
            switch self {
            case .loginNeeded: return L10n.t("Log in with the Codex CLI first. File-based CLI login is required.")
            case .notInstalled: return L10n.t("Install the official Codex CLI to run stock analysis.")
            case .busy: return L10n.t("A Codex stock analysis is already running.")
            case .timedOut: return L10n.t("Codex stock analysis timed out.")
            case .unsafeSession: return L10n.t("Codex could not start an isolated, tool-free analysis.")
            case .invalidResponse: return L10n.t("Codex returned an invalid or oversized analysis response.")
            case .failed: return L10n.t("Codex CLI analysis failed. Check CLI login and model access.")
            }
        }
    }

    private static let gate = DispatchSemaphore(value: 1)
    private static func begin() -> Bool { gate.wait(timeout: .now()) == .success }
    private static let byteLimit = 2 * 1024 * 1024
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }

    static func run(prompt: String, schema: Data) async throws -> Output {
        try await run(prompt: prompt, schema: schema, home: FileManager.default.homeDirectoryForCurrentUser,
                      environment: ProcessInfo.processInfo.environment)
    }

    // Explicit home/environment injection keeps process tests off real credentials.
    static func run(prompt: String, schema: Data, home: URL,
                    environment: [String: String], timeout: TimeInterval = 120, binary: URL? = nil) async throws -> Output {
        try Task.checkCancellation()
        guard begin() else { throw Failure.busy }
        defer { gate.signal() }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            let result: Output = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try execute(prompt: prompt, schema: schema, home: home,
                            environment: environment, timeout: timeout, binary: binary, cancellation: cancellation))
                    } catch is CancellationError { continuation.resume(throwing: CancellationError()) }
                    catch { continuation.resume(throwing: (error as? Failure) ?? Failure.failed) }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }

    static func executable(home: URL, path: String) -> URL? {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          home.appendingPathComponent(".local/bin/codex").path]
            + path.split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
        return candidates.first { path in
            var directory: ObjCBool = false
            return !path.contains("\0") && FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        }.map { URL(fileURLWithPath: $0) }
    }

    private static func execute(prompt: String, schema: Data, home: URL, environment: [String: String],
                                timeout: TimeInterval, binary: URL?, cancellation: Cancellation) throws -> Output {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func check() throws {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timedOut }
        }
        try check()
        guard schema.count + prompt.utf8.count <= byteLimit,
              let schemaObject = try JSONSerialization.jsonObject(with: schema) as? [String: Any]
        else { throw Failure.invalidResponse }
        let fm = FileManager.default
        let auth = home.appendingPathComponent(".codex/auth.json")
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: auth.path, isDirectory: &directory), !directory.boolValue
        else { throw Failure.loginNeeded } // Keychain-only CLI credentials are not supported yet.
        guard let binary = binary ?? executable(home: home, path: environment["PATH"] ?? "") else { throw Failure.notInstalled }
        var template = Array(fm.temporaryDirectory.appendingPathComponent("penguin-stock-codex-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw Failure.failed }
        let temporary = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        defer { try? fm.removeItem(at: temporary) } // Only the directory exclusively created above.
        let cwd = temporary.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: temporary.appendingPathComponent("auth.json"), withDestinationURL: auth)

        let process = Process(), input = Pipe(), output = Pipe()
        let overrides = [
            "features.apps=false", "features.plugins=false", "features.remote_plugin=false",
            "features.multi_agent=false", "features.shell_tool=false", "features.unified_exec=false",
            "features.memory_tool=false", "features.skill_search=false", "features.skip_host_skill_discovery=true",
            "features.in_app_browser=false", "features.code_mode=false", "skills.include_instructions=false",
            "skills.bundled.enabled=false", "memories.use_memories=false", "memories.generate_memories=false",
            "project_doc_max_bytes=0", "web_search=\"disabled\"", "mcp_servers={}"
        ]
        process.executableURL = binary
        process.arguments = ["app-server", "--stdio"] + overrides.flatMap { ["-c", $0] }
        var childEnvironment = environment.filter { ["HOME", "PATH", "TMPDIR", "LANG"].contains($0.key) }
        childEnvironment["HOME"] = home.path
        // Finder/Xcode omit Homebrew from PATH. npm's codex launcher needs the
        // sibling node executable even though codex itself was found absolutely.
        childEnvironment["PATH"] = ([binary.deletingLastPathComponent().path]
            + (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
                .filter { $0.hasPrefix("/") }.map(String.init)).joined(separator: ":")
        childEnvironment["CODEX_HOME"] = temporary.path
        process.environment = childEnvironment
        process.currentDirectoryURL = cwd
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer {
            for handle in [input.fileHandleForWriting, input.fileHandleForReading,
                           output.fileHandleForReading, output.fileHandleForWriting] { try? handle.close() }
        }
        try check()
        try process.run()
        let pid = process.processIdentifier
        let grouped = getpgid(pid) == pid || setpgid(pid, pid) == 0
        defer {
            if grouped { _ = killpg(pid, SIGKILL) }
            if process.isRunning { _ = kill(pid, SIGKILL) }
            process.waitUntilExit()
        }
        guard grouped else { throw Failure.unsafeSession }
        let readFD = output.fileHandleForReading.fileDescriptor, writeFD = input.fileHandleForWriting.fileDescriptor
        for fd in [readFD, writeFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure.failed }
        }
        guard fcntl(writeFD, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.failed }
        func send(_ method: String, _ params: [String: Any], id: Int? = nil) throws {
            var message: [String: Any] = ["method": method, "params": params]
            if let id { message["id"] = id }
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try check()
                    let count = Darwin.write(writeFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if errno == EAGAIN || errno == EINTR {
                        var descriptor = pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&descriptor, 1, 50)
                    } else { throw Failure.failed }
                }
            }
        }
        try send("initialize", ["clientInfo": ["name": "penguinnotch_stocks", "version": "1"],
                                "capabilities": ["experimentalApi": true]], id: 1)
        var expectedID = 1, threadID = "", turnID = "", model = "", answer = ""
        func items(_ values: [[String: Any]], completed: Bool) throws {
            for item in values {
                guard let type = item["type"] as? String, ["userMessage", "reasoning", "agentMessage"].contains(type)
                else { throw Failure.unsafeSession }
                if completed, type == "agentMessage", item["phase"] as? String != "commentary",
                   let text = item["text"] as? String { answer = text }
            }
        }
        var pending = Data(), received = 0, buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try check()
            var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            let count = Darwin.read(readFD, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw Failure.failed }
            received += count
            guard received <= byteLimit else { throw Failure.invalidResponse }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                try check()
                let line = pending.prefix(upTo: newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { throw Failure.invalidResponse }
                pending.removeSubrange(...newline)
                guard message["error"] == nil else { throw Failure.failed }
                let params = message["params"] as? [String: Any] ?? [:]
                if let method = message["method"] as? String {
                    guard message["id"] == nil else { throw Failure.unsafeSession } // Never fulfill server requests.
                    if method == "error" { throw Failure.failed }
                    if method == "item/started" || method == "item/completed" {
                        guard params["threadId"] as? String == threadID,
                              let item = params["item"] as? [String: Any] else { throw Failure.invalidResponse }
                        try items([item], completed: method == "item/completed")
                    } else if method == "turn/started" || method == "turn/completed" {
                        guard params["threadId"] as? String == threadID,
                              let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String,
                              turnID.isEmpty || turnID == id, let values = turn["items"] as? [[String: Any]]
                        else { throw Failure.invalidResponse }
                        turnID = id
                        try items(values, completed: method == "turn/completed")
                        if method == "turn/completed" {
                            guard expectedID == 0, turn["status"] as? String == "completed",
                                  turn["error"] == nil || turn["error"] is NSNull,
                                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            else { throw Failure.failed }
                            return Output(text: answer, model: model)
                        }
                    }
                    continue
                }
                guard message["id"] as? Int == expectedID, let result = message["result"] as? [String: Any]
                else { throw Failure.invalidResponse }
                switch expectedID {
                case 1:
                    try send("initialized", [:])
                    expectedID = 4
                    try send("model/list", [:], id: expectedID)
                case 4:
                    guard let models = result["data"] as? [[String: Any]] else { throw Failure.invalidResponse }
                    guard let selected = models.first(where: { $0["isDefault"] as? Bool == true })?["model"] as? String,
                          !selected.isEmpty else {
                        guard let cursor = result["nextCursor"] as? String else { throw Failure.failed }
                        try send("model/list", ["cursor": cursor], id: expectedID)
                        continue
                    }
                    expectedID = 2
                    // Empty environments disables environment access (app-server 0.153.4 schema).
                    try send("thread/start", ["model": selected, "cwd": cwd.path, "ephemeral": true,
                        "environments": [], "runtimeWorkspaceRoots": [], "selectedCapabilityRoots": [],
                        "approvalPolicy": "never", "sandbox": "read-only"], id: expectedID)
                case 2:
                    guard let thread = result["thread"] as? [String: Any], thread["ephemeral"] as? Bool == true,
                          let sources = result["instructionSources"] as? [String], sources.isEmpty,
                          result["approvalPolicy"] as? String == "never",
                          (result["sandbox"] as? [String: Any])?["type"] as? String == "readOnly",
                          let id = thread["id"] as? String, !id.isEmpty,
                          let resolved = result["model"] as? String, !resolved.isEmpty
                    else { throw Failure.unsafeSession }
                    threadID = id
                    model = resolved
                    expectedID = 3
                    try send("turn/start", ["threadId": id, "environments": [], "effort": "low",
                        "input": [["type": "text", "text": prompt]], "outputSchema": schemaObject], id: expectedID)
                case 3:
                    guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String,
                          turnID.isEmpty || turnID == id, let values = turn["items"] as? [[String: Any]]
                    else { throw Failure.invalidResponse }
                    turnID = id
                    try items(values, completed: false)
                    expectedID = 0
                default: throw Failure.invalidResponse
                }
            }
        }
    }
}
