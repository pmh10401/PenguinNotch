import Darwin
import XCTest
@testable import PenguinNotch

final class StockCodexRunnerTests: XCTestCase {
    private let schema = Data(#"{"type":"object","properties":{"changePercent":{"type":"number"}},"required":["changePercent"],"additionalProperties":false}"#.utf8)
    private let prompt = "Public synthetic arithmetic: 151.45 to 144.07."

    func testLiveOfficialRunnerWithPublicArithmeticOnly() async throws {
        guard ProcessInfo.processInfo.environment["PENGUINNOTCH_LIVE_CODEX_TEST"] == "1" else {
            throw XCTSkip("Opt-in only: uses the signed-in Codex allowance for synthetic arithmetic.")
        }
        let output = try await StockCodexRunner.run(prompt: "Compute (144.07 / 151.45 - 1) * 100 and truncate toward zero to two decimal places. Return only the JSON object with changePercent. This is synthetic arithmetic; do not use tools or files.", schema: schema)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(object["changePercent"]), -4.87, accuracy: 0.00001)
        XCTAssertFalse(output.model.isEmpty)
        print("LIVE_CODEX_PUBLIC_ARITHMETIC model=\(output.model) changePercent=\(object["changePercent"]!)")
    }

    private final class Fixture {
        let root: URL
        let binary: URL
        var auth: URL { root.appendingPathComponent(".codex/auth.json") }
        init(_ mode: String = "success") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("stock-runner-test-\(UUID())")
            binary = root.appendingPathComponent("fake-codex")
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
            try Data("SYNTHETIC_AUTH_NOT_A_CREDENTIAL".utf8).write(to: auth)
            var source = Self.script.replacingOccurrences(of: "TEST_MODE", with: mode)
            if mode == "sibling-runtime" {
                source = source.replacingOccurrences(of: "#!/usr/bin/python3", with: "#!/usr/bin/env fake-codex-python")
                let runtime = root.appendingPathComponent("fake-codex-python")
                try Data("#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".utf8).write(to: runtime)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
            }
            try Data(source.utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func capture() -> [String: Any]? {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("capture.json")) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        // Synthetic subprocess only. It never opens auth.json or contacts a model.
        static let script = #"""
        #!/usr/bin/python3
        import json, os, signal, subprocess, sys, time
        from pathlib import Path
        mode = 'TEST_MODE'
        root = Path(__file__).parent
        home = Path(os.environ['CODEX_HOME'])
        capture = dict(args=sys.argv[1:], env=dict(os.environ), cwd=os.getcwd(), canonicalHome=os.path.realpath(home),
                       entries=os.listdir('.'), auth=os.readlink(home/'auth.json'), pid=os.getpid(), requests=[])
        def save():
            temporary = root/'capture.tmp'
            temporary.write_text(json.dumps(capture))
            temporary.replace(root/'capture.json')
        def receive(method):
            message=json.loads(sys.stdin.readline())
            assert message['method']==method
            capture['requests'].append(message)
            save()
            return message
        def emit(value):
            print(json.dumps(value), flush=True)
        def reply(request, result):
            emit(dict(id=request['id'], result=result))
        def event(method, **params):
            emit(dict(method=method, params=dict(threadId='thread-1', turnId='turn-1', **params)))
        save()
        request=receive('initialize')
        if mode in ['hang', 'cancel']:
            child=subprocess.Popen(['/bin/sleep', '30'])
            capture['child']=child.pid
            save()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(30)
            sys.exit(0)
        if mode == 'rpc-error':
            sys.stderr.write('SYNTHETIC_SECRET_IN_STDERR\n')
            emit(dict(id=request['id'], error=dict(message='SYNTHETIC_SECRET_IN_RPC_ERROR')))
            sys.exit(0)
        if mode == 'malformed':
            print('SYNTHETIC_SECRET_NON_JSON', flush=True)
            sys.exit(0)
        if mode == 'oversized':
            sys.stdout.write('x' * (2*1024*1024+1))
            sys.stdout.flush()
            time.sleep(30)
        if mode == 'exit': sys.exit(7)
        reply(request, {})
        receive('initialized')
        request=receive('model/list')
        if mode == 'pagination':
            reply(request, dict(data=[], nextCursor='page-2'))
            request=receive('model/list')
            assert request['params']['cursor']=='page-2'
        reply(request, dict(data=[dict(model='not-default', isDefault=False), dict(model='default-from-cli', isDefault=mode!='no-default')], nextCursor=None))
        if mode == 'no-default': time.sleep(30)
        request=receive('thread/start')
        result=dict(thread=dict(id='thread-1', ephemeral=mode!='persisted'), model='thread-resolved-model',
                    instructionSources=['unwanted-instructions'] if mode=='instructions' else [],
                    approvalPolicy='never', sandbox=dict(type='readOnly'))
        if mode=='missing-instructions': del result['instructionSources']
        reply(request, result)
        if mode == 'blocked-write': time.sleep(30)
        request=receive('turn/start')
        turn=dict(id='turn-1', status='inProgress', items=[])
        if mode=='embedded-tool': turn['items']=[dict(type='fileChange', id='tool')]
        reply(request, dict(turn=turn))
        if mode=='approval':
            emit(dict(id=900, method='item/commandExecution/requestApproval', params={}))
            time.sleep(30)
        event('item/started', item=dict(type='reasoning', id='reasoning-1'))
        if mode=='tool': event('item/started', item=dict(type='commandExecution', id='tool'))
        event('item/completed', item=dict(type='agentMessage', id='commentary', phase='commentary', text='Do not return this.'))
        if mode!='empty':
            event('item/completed', item=dict(type='agentMessage', id='answer', phase='final_answer', text='{"changePercent":-4.87}'))
        turn.update(status='failed' if mode=='turn-failed' else 'completed')
        if mode=='turn-failed': turn['error']=dict(message='SYNTHETIC_SECRET_TURN_ERROR')
        if mode=='completed-tool': turn['items']=[dict(type='webSearch', id='tool')]
        event('turn/completed', turn=turn)
        time.sleep(30)
        """#
    }

    private func run(_ fixture: Fixture, timeout: TimeInterval = 3, prompt: String? = nil) async throws -> StockCodexRunner.Output {
        try await StockCodexRunner.run(prompt: prompt ?? self.prompt, schema: schema, home: fixture.root,
            environment: ["HOME": fixture.root.path, "PATH": ".:relative:/usr/bin:/bin", "LANG": "en_US.UTF-8",
                          "OPENAI_API_KEY": "SYNTHETIC_KEY", "CODEX_HOME": "/never-use-this", "TOSS_SECRET": "SYNTHETIC_KEY"],
            timeout: timeout, binary: fixture.binary)
    }

    private func assertCleaned(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let captured = try XCTUnwrap(fixture.capture(), file: file, line: line)
        let env = try XCTUnwrap(captured["env"] as? [String: String], file: file, line: line)
        let temporary = try XCTUnwrap(env["CODEX_HOME"], file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary), file: file, line: line)
        XCTAssertEqual(try String(contentsOf: fixture.auth, encoding: .utf8), "SYNTHETIC_AUTH_NOT_A_CREDENTIAL", file: file, line: line)
        for name in ["pid", "child"] {
            if let pid = captured[name] as? Int32 {
                // An orphan child may take a moment to be reaped by launchd.
                for _ in 0..<50 where kill(pid, 0) == 0 { usleep(10_000) }
                XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
                XCTAssertEqual(errno, ESRCH, file: file, line: line)
            }
        }
    }

    func testProtocolUsesCLIDefaultResolvedModelAndIsolatedEnvironment() async throws {
        let fixture = try Fixture()
        let output = try await run(fixture)
        XCTAssertEqual(output.text, #"{"changePercent":-4.87}"#)
        XCTAssertEqual(output.model, "thread-resolved-model")
        let captured = try XCTUnwrap(fixture.capture())
        let env = try XCTUnwrap(captured["env"] as? [String: String])
        // /usr/bin/python3's macOS launcher adds these toolchain paths itself.
        XCTAssertTrue(Set(env.keys).isSubset(of: ["HOME", "PATH", "TMPDIR", "LANG", "CODEX_HOME", "__CF_USER_TEXT_ENCODING",
                                                "CPATH", "LIBRARY_PATH", "MANPATH", "SDKROOT"]),
                      "Unexpected environment keys: \(env.keys.sorted())")
        XCTAssertEqual(env["PATH"], fixture.root.path + ":/usr/bin:/bin")
        XCTAssertEqual(captured["auth"] as? String, fixture.auth.path)
        XCTAssertEqual(captured["entries"] as? [String], [])
        XCTAssertEqual(captured["cwd"] as? String, (captured["canonicalHome"] as? String).map { $0 + "/empty" })
        let args = try XCTUnwrap(captured["args"] as? [String])
        XCTAssertEqual(Array(args.prefix(2)), ["app-server", "--stdio"])
        for value in ["features.apps=false", "features.plugins=false", "features.remote_plugin=false", "features.multi_agent=false",
                      "features.shell_tool=false", "features.unified_exec=false", "features.memory_tool=false", "features.skill_search=false",
                      "features.skip_host_skill_discovery=true", "features.in_app_browser=false", "features.code_mode=false",
                      "skills.include_instructions=false", "skills.bundled.enabled=false", "memories.use_memories=false",
                      "memories.generate_memories=false", "project_doc_max_bytes=0", "web_search=\"disabled\"", "mcp_servers={}"] {
            XCTAssertTrue(args.contains(value), value)
        }
        let requests = try XCTUnwrap(captured["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialize", "initialized", "model/list", "thread/start", "turn/start"])
        let thread = try XCTUnwrap(requests[3]["params"] as? [String: Any])
        XCTAssertEqual(thread["model"] as? String, "default-from-cli")
        XCTAssertEqual(thread["cwd"] as? String, env["CODEX_HOME"].map { $0 + "/empty" })
        XCTAssertEqual(thread["ephemeral"] as? Bool, true)
        XCTAssertEqual(thread["sandbox"] as? String, "read-only")
        XCTAssertEqual(thread["approvalPolicy"] as? String, "never")
        for key in ["environments", "runtimeWorkspaceRoots", "selectedCapabilityRoots"] {
            XCTAssertEqual(thread[key] as? [String], [])
        }
        let turn = try XCTUnwrap(requests[4]["params"] as? [String: Any])
        XCTAssertEqual(turn["environments"] as? [String], [])
        XCTAssertEqual((turn["input"] as? [[String: String]])?.first?["text"], prompt)
        XCTAssertEqual(turn["outputSchema"] as? NSDictionary, try JSONSerialization.jsonObject(with: schema) as? NSDictionary)
        try assertCleaned(fixture)
    }

    func testModelListPagination() async throws {
        let fixture = try Fixture("pagination")
        let output = try await run(fixture)
        XCTAssertEqual(output.model, "thread-resolved-model")
        try assertCleaned(fixture)
    }

    func testSiblingRuntimeIsFoundWithMinimalFinderPath() async throws {
        let fixture = try Fixture("sibling-runtime")
        let output = try await run(fixture)
        XCTAssertEqual(output.text, #"{"changePercent":-4.87}"#)
        try assertCleaned(fixture)
    }

    func testUnsafeThreadsRequestsAndToolItemsFailClosed() async throws {
        for mode in ["persisted", "instructions", "missing-instructions", "approval", "tool", "embedded-tool", "completed-tool"] {
            let fixture = try Fixture(mode)
            do { _ = try await run(fixture); XCTFail(mode) }
            catch { XCTAssertEqual(error as? StockCodexRunner.Failure, .unsafeSession, mode) }
            try assertCleaned(fixture)
        }
    }

    func testErrorsAreBoundedSanitizedAndCleaned() async throws {
        for mode in ["rpc-error", "malformed", "oversized", "exit", "turn-failed", "empty", "no-default"] {
            let fixture = try Fixture(mode)
            do { _ = try await run(fixture); XCTFail(mode) }
            catch {
                XCTAssertNotNil(error as? StockCodexRunner.Failure, mode)
                XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_SECRET"), mode)
                if mode == "oversized" { XCTAssertEqual(error as? StockCodexRunner.Failure, .invalidResponse) }
            }
            try assertCleaned(fixture)
        }
    }

    func testMissingAuthRequiresCLILoginWithoutLaunching() async throws {
        let fixture = try Fixture()
        try FileManager.default.removeItem(at: fixture.auth)
        do { _ = try await run(fixture); XCTFail("Missing auth must fail") }
        catch { XCTAssertEqual(error as? StockCodexRunner.Failure, .loginNeeded) }
        XCTAssertNil(fixture.capture())
    }

    func testTimeoutKillsProcessGroupAndUnblocksWrites() async throws {
        for mode in ["hang", "blocked-write"] {
            let fixture = try Fixture(mode)
            let started = Date()
            do { _ = try await run(fixture, timeout: 0.6, prompt: String(repeating: "x", count: 256_000)); XCTFail(mode) }
            catch { XCTAssertEqual(error as? StockCodexRunner.Failure, .timedOut, mode) }
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
            try assertCleaned(fixture)
        }
    }

    func testCancellationKillsProcessGroupAndRejectsConcurrentCall() async throws {
        let fixture = try Fixture("cancel")
        let task = Task { try await run(fixture) }
        for _ in 0..<200 where fixture.capture()?["child"] == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(fixture.capture()?["child"])
        do { _ = try await run(fixture); XCTFail("Only one active invocation is allowed") }
        catch { XCTAssertEqual(error as? StockCodexRunner.Failure, .busy) }
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try assertCleaned(fixture)
    }
}
