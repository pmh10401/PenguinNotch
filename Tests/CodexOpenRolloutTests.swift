import XCTest
@testable import PenguinNotch

@MainActor
final class CodexOpenRolloutTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexOpenRolloutTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testQuietOpenConversationStaysBusyUntilTaskComplete() throws {
        let rollout = try makeRollout(events: ["task_started"])
        let conversations = CodexActivityMonitor.liveConversations(
            [thread(rollout)], staleAfter: 8, now: now, openRollouts: [rollout.path]
        )

        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.state, .busy)
        XCTAssertTrue(conversations.first?.isOpen == true)
    }

    func testOpenCompletedConversationIsNotBusy() throws {
        let rollout = try makeRollout(events: ["task_started", "task_complete"])
        XCTAssertTrue(CodexActivityMonitor.liveConversations(
            [thread(rollout)], staleAfter: 8, now: now, openRollouts: [rollout.path]
        ).isEmpty)
    }

    func testCompletedHelperDoesNotHideConversationCompletion() throws {
        let root = try makeRollout(id: "root", written: 1, events: ["task_started", "task_complete"])
        let helper = try makeRollout(id: "helper", written: 1, events: ["task_started", "task_complete"])
        let conversations = CodexActivityMonitor.liveConversations(
            [thread(root, id: "root"), thread(helper, id: "helper", parentID: "root")],
            staleAfter: 8, now: now
        )
        XCTAssertEqual(conversations.count, 1)
        let conversation = try XCTUnwrap(conversations.first)
        XCTAssertEqual(conversation.state, .success)

        var watcher = SessionCompletionWatcher()
        let busy = AgentSession(id: "root", name: "Conversation", detail: "", state: .busy,
                                waitingFor: nil, since: now.addingTimeInterval(-2))
        XCTAssertTrue(watcher.absorb(["codex": [busy]]).isEmpty)
        let completed = try XCTUnwrap(CodexActivityMonitor.session(
            id: "root", name: "Conversation", modified: conversation.at, state: conversation.state,
            staleAfter: 8, now: now
        ))
        let events = watcher.absorb(["codex": [completed]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .finished)
        XCTAssertTrue(watcher.absorb(["codex": [completed]]).isEmpty)
    }

    func testBusyOpenHelperKeepsCompletedParentBusy() throws {
        let root = try makeRollout(id: "root", written: 1, events: ["task_complete"])
        let helper = try makeRollout(id: "helper", events: ["task_started"])
        let conversations = CodexActivityMonitor.liveConversations(
            [thread(root, id: "root"), thread(helper, id: "helper", parentID: "root")],
            staleAfter: 8, now: now, openRollouts: [helper.path]
        )
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.state, .busy)
        XCTAssertTrue(conversations.first?.isOpen == true)
    }

    func testCompletedHelperDoesNotCompleteAStaleParent() throws {
        let root = try makeRollout(id: "root", events: ["task_started"])
        let helper = try makeRollout(id: "helper", written: 1, events: ["task_complete"])
        let conversations = CodexActivityMonitor.liveConversations(
            [thread(root, id: "root"), thread(helper, id: "helper", parentID: "root")],
            staleAfter: 8, now: now
        )
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.state, .busy)
    }

    func testFindsARolloutHeldOpenByAProcess() throws {
        let sessions = directory.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout.jsonl")
        try Data().write(to: rollout)
        let handle = try FileHandle(forWritingTo: rollout)
        defer { try? handle.close() }

        XCTAssertTrue(CodexOpenRollouts.paths(under: sessions, pids: [getpid()]).contains(rollout.path))
    }

    private func makeRollout(id: String = "rollout", written: TimeInterval = 60,
                             events: [String]) throws -> URL {
        let rollout = directory.appendingPathComponent("\(id).jsonl")
        let lines = events.map { #"{"type":"event_msg","payload":{"type":"\#($0)"}}"# }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rollout)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-written)],
            ofItemAtPath: rollout.path
        )
        return rollout
    }

    private func thread(_ rollout: URL, id: String = "thread", parentID: String? = nil) -> CodexThread {
        CodexThread(
            id: id,
            rollout: rollout,
            name: "Long-running command",
            preview: nil,
            cwd: nil,
            parentID: parentID,
            isHelper: parentID != nil
        )
    }
}
