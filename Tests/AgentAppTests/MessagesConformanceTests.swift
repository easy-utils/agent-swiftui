import XCTest
import Foundation
@testable import agent_app

// Behavioural conformance: replay the SHARED scenario manifest (vendored from
// easy-utils/agent-tools/conformance/scenarios.json) through the REAL
// MessagesController against a scripted fake AgentApi, then compare a
// normalized state snapshot. Proves the state machine behaves like the webui
// reference (abcp-sdk/webui/src/lib/messages.test.ts) — the string guards
// cannot. Every scenario id in the manifest appears below.
//
// Runs on Apple platforms (the app target imports SwiftUI); the controller,
// models and AgentApi facade are SwiftUI-free.
@MainActor
final class MessagesConformanceTests: XCTestCase {

    /// A faithful in-memory fake: the persisted chain + a push stream.
    ///
    /// All mutable state is under a lock: `push` comes from the test and
    /// `next` from the stream consumer, and without serialization the queue /
    /// waiter bookkeeping races — silently REORDERING or dropping events (the
    /// flake that made happy_path fail ~1 run in 5 on macOS). A lock (not
    /// @MainActor) because `FakeTransport` must satisfy the nonisolated
    /// `MessageTransport` requirements.
    private final class FakeServer: @unchecked Sendable {
        private let lock = NSLock()
        private var _chain: [Message] = []
        private var _promptErr: String?
        private var _status = "idle"
        private var _pushed = 0
        /// Continuations waiting for the next pushed event.
        private var waiters: [CheckedContinuation<StreamEvent?, Never>] = []
        private var queue: [StreamEvent] = []
        private var closed = false

        var chain: [Message] { lock.lock(); defer { lock.unlock() }; return _chain }
        var status: String { lock.lock(); defer { lock.unlock() }; return _status }
        var promptErr: String? { lock.lock(); defer { lock.unlock() }; return _promptErr }
        /// Events pushed (for `settle` to compare against `eventsApplied`).
        var pushed: Int { lock.lock(); defer { lock.unlock() }; return _pushed }

        func failPrompt(_ msg: String) { lock.lock(); _promptErr = msg; lock.unlock() }
        func clearPromptError() { lock.lock(); _promptErr = nil; lock.unlock() }
        func setStatus(_ s: String) { lock.lock(); _status = s; lock.unlock() }
        func persist(_ msgs: Message...) { lock.lock(); _chain.append(contentsOf: msgs); lock.unlock() }

        func push(_ ev: StreamEvent) {
            lock.lock()
            _pushed += 1
            if let w = waiters.first {
                waiters.removeFirst()
                lock.unlock()
                w.resume(returning: ev)
            } else {
                queue.append(ev)
                lock.unlock()
            }
        }

        func next() async -> StreamEvent? {
            lock.lock()
            if !queue.isEmpty {
                let ev = queue.removeFirst()
                lock.unlock()
                return ev
            }
            if closed {
                lock.unlock()
                return nil
            }
            lock.unlock()
            return await withCheckedContinuation { c in
                lock.lock()
                // Re-check under the lock: a push may have landed between the
                // unlock above and this registration.
                if !queue.isEmpty {
                    let ev = queue.removeFirst()
                    lock.unlock()
                    c.resume(returning: ev)
                } else if closed {
                    lock.unlock()
                    c.resume(returning: nil)
                } else {
                    waiters.append(c)
                    lock.unlock()
                }
            }
        }
    }

    /// The scripted fake transport (webui's FakeServer analog).
    private final class FakeTransport: MessageTransport {
        let server: FakeServer
        init(_ s: FakeServer) { server = s }

        func prompt(_ id: String, _ prompt: String, attachments: [String]) async throws -> String {
            if let e = server.promptErr { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
            return "accepted"
        }
        func messages(_ id: String, before: String?, limit: Int) async throws -> ([Message], Bool) {
            (server.chain, false)
        }
        func messagesAfter(_ id: String, after: String, limit: Int) async throws -> ([Message], Bool, String) {
            let tip = server.chain.last?.id ?? ""
            if after.isEmpty { return (server.chain, false, tip) }
            guard let i = server.chain.firstIndex(where: { $0.id == after }) else {
                return (server.chain, true, tip)
            }
            return (Array(server.chain[(i + 1)...]), false, tip)
        }
        func revert(_ id: String, messageId: String?) async throws {}
        func interrupt(_ id: String) async throws -> Bool { true }
        func state(_ id: String) async throws -> (String, [Any?]) { (server.status, []) }
        func streamEvents(_ sessionId: String, since: String) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    while let ev = await server.next() { continuation.yield(ev) }
                    continuation.finish()
                }
            }
        }
    }

    private func msg(_ id: String, _ role: String, _ prevId: String,
                     _ parts: [MessagePart]) -> Message {
        Message(id: id, role: role, parts: parts, createdAt: nil, prevId: prevId, source: "")
    }
    private func text(_ id: String, _ t: String) -> MessagePart {
        MessagePart(id: id, type: "text", text: t)
    }
    private func reasoning(_ id: String, _ t: String) -> MessagePart {
        MessagePart(id: id, type: "reasoning", text: t)
    }
    /// The domain part the real mapper produces from a persisted `tool_result`.
    private func tool(_ id: String, _ name: String) -> MessagePart {
        MessagePart(id: id, type: "tool", tool: name, toolCallId: nil,
                    state: ToolState(status: "complete", title: name))
    }

    private var eid = 0
    private func ev(_ event: String, _ params: [String: Any?],
                    eid: String? = nil) -> StreamEvent {
        defer { eidSeed += 1 }
        return StreamEvent(event: event, params: params,
                           eid: eid ?? "e\(eidSeed)", runId: "r1")
    }
    private var eidSeed = 0

    private let scenarioIds = [
        "boot_empty", "happy_path", "replay_reorder", "multi_step", "eid_dedup",
        "reconnect_persisted", "tool_error", "model_error", "send_failure", "error_transient",
    ]

    func testConformanceManifestPresent() throws {
        let url = Bundle.module.url(forResource: "scenarios", withExtension: "json")
        XCTAssertNotNil(url, "vendored conformance manifest missing")
        let body = try String(contentsOf: url!)
        for id in scenarioIds { XCTAssertTrue(body.contains(id), "manifest missing \(id)") }
    }

    func testBootEmpty() async { await replay("boot_empty") }
    func testHappyPath() async { await replay("happy_path") }
    func testReplayReorder() async { await replay("replay_reorder") }
    func testMultiStep() async { await replay("multi_step") }
    func testEidDedup() async { await replay("eid_dedup") }
    func testReconnectPersisted() async { await replay("reconnect_persisted") }
    func testToolError() async { await replay("tool_error") }
    func testModelError() async { await replay("model_error") }
    func testSendFailure() async { await replay("send_failure") }
    func testErrorTransient() async { await replay("error_transient") }

    /// Boot the real controller, drive one scenario, assert its snapshot.
    private func replay(_ id: String) async {
        let server = FakeServer()
        let ctrl = MessagesController(api: FakeTransport(server), getSessionId: { "s1" }, local: nil)
        ctrl.init_()
        // Boot (baseline fetch + recover) must FINISH before events are pushed:
        // the stream only connects at the end of boot, and a baseline landing
        // mid-stream would clobber an in-flight bubble.
        await ctrl.bootTask?.value
        await settle(ctrl, server)

        switch id {
        case "boot_empty":
            XCTAssertEqual(ctrl.messages.count, 0, id)
            XCTAssertFalse(ctrl.sending, id)

        case "happy_path":
            await ctrl.send("hi"); await settle(ctrl, server)
            server.push(ev("status", ["type": "busy"]))
            server.persist(msg("u1", "user", "", [text("p0", "hi")]))
            server.push(ev("message-added", ["message_id": "u1", "prev_id": "", "role": "user"]))
            server.push(ev("message-added", ["message_id": "a1", "prev_id": "u1", "role": "assistant", "streaming": true]))
            server.push(ev("text-start", ["id": "t0", "message_id": "a1"]))
            server.push(ev("text-delta", ["id": "t0", "text": "Hello"]))
            server.push(ev("text-delta", ["id": "t0", "text": " world"]))
            server.push(ev("tool-input-start", ["id": "tc1", "toolName": "web.search"]))
            server.push(ev("tool-input-delta", ["id": "tc1", "delta": "{\"q\":\"x\"}"]))
            server.push(ev("tool-call", ["toolCallId": "tc1", "toolName": "web.search", "input": ["q": "x"]]))
            server.push(ev("tool-result", ["toolCallId": "tc1", "output": "found 1"]))
            await settle(ctrl, server)
            XCTAssertEqual(ctrl.messages.map { $0.id }, ["u1", "a1"], id)
            let mid = ctrl.messages.first { $0.id == "a1" }!
            XCTAssertEqual(mid.status, "streaming", id)
            XCTAssertEqual(mid.parts.first { $0.type == "text" }!.text, "Hello world", id)
            let toolPart = mid.parts.first { $0.type == "tool" }!
            XCTAssertEqual(toolPart.state?.status, "complete", id)
            XCTAssertEqual(toolPart.state?.output, "found 1", id)
            XCTAssertTrue(ctrl.sending, id)

            server.persist(msg("a1", "assistant", "u1", [text("t0", "Hello world"), tool("tc1", "web.search")]))
            server.push(ev("turn-complete", ["reason": "stop"]))
            await settle(ctrl, server)
            XCTAssertFalse(ctrl.sending, id)
            XCTAssertEqual(ctrl.messages.map { $0.id }, ["u1", "a1"], id)
            let a1 = ctrl.messages.first { $0.id == "a1" }!
            XCTAssertEqual(a1.status, "complete", id)
            XCTAssertFalse(a1.isLocal, id)
            XCTAssertEqual(ctrl.messages.filter { $0.id == "a1" }.count, 1, id)

        case "replay_reorder":
            server.push(ev("text-delta", ["id": "t0", "text": "Hi", "message_id": "a1"]))
            await settle(ctrl, server)
            XCTAssertEqual(ctrl.messages.filter { $0.id == "a1" }.count, 1, id)
            server.push(ev("message-added", ["message_id": "a1", "prev_id": "", "role": "assistant", "streaming": true]))
            await settle(ctrl, server)
            let hits = ctrl.messages.filter { $0.id == "a1" }
            XCTAssertEqual(hits.count, 1, id)
            XCTAssertEqual(hits[0].parts.map { $0.text ?? "" }.joined(), "Hi", id)
            XCTAssertEqual(hits[0].status, "streaming", id)

        case "multi_step":
            server.push(ev("message-added", ["message_id": "a1", "prev_id": "", "role": "assistant", "streaming": true]))
            server.push(ev("text-delta", ["id": "t0", "text": "step one", "message_id": "a1"]))
            await settle(ctrl, server)
            XCTAssertEqual(ctrl.messages.first { $0.id == "a1" }!.status, "streaming", id)
            server.persist(msg("a1", "assistant", "", [text("t0", "step one")]))
            server.push(ev("message-added", ["message_id": "a2", "prev_id": "a1", "role": "assistant", "streaming": true]))
            server.push(ev("text-delta", ["id": "t1", "text": "step two", "message_id": "a2"]))
            await settle(ctrl, server)
            XCTAssertEqual(ctrl.messages.first { $0.id == "a1" }!.status, "complete", id)
            XCTAssertEqual(ctrl.messages.first { $0.id == "a2" }!.status, "streaming", id)
            server.persist(msg("a2", "assistant", "a1", [text("t1", "step two")]))
            server.push(ev("turn-complete", ["reason": "stop"]))
            await settle(ctrl, server)
            XCTAssertEqual(ctrl.messages.map { $0.id }, ["a1", "a2"], id)
            XCTAssertTrue(ctrl.messages.allSatisfy { $0.status == "complete" }, id)
            XCTAssertTrue(ctrl.messages.allSatisfy { !$0.isLocal }, id)

        case "eid_dedup":
            server.push(ev("message-added", ["message_id": "a1", "prev_id": "", "role": "assistant", "streaming": true]))
            server.push(ev("text-delta", ["id": "t0", "text": "Ha"], eid: "dup-eid"))
            server.push(ev("text-delta", ["id": "t0", "text": "Ha"], eid: "dup-eid"))
            server.push(ev("text-delta", ["id": "t0", "text": "Ha"], eid: "dup-eid"))
            await settle(ctrl, server)
            XCTAssertEqual(ctrl.messages.filter { $0.id == "a1" }.count, 1, id)
            XCTAssertEqual(ctrl.messages.first { $0.id == "a1" }!.parts.map { $0.text ?? "" }.joined(), "Ha", id)

        case "reconnect_persisted":
            server.push(ev("message-added", ["message_id": "a1", "prev_id": "", "role": "assistant", "streaming": true]))
            server.push(ev("text-delta", ["id": "t0", "text": "Hello", "message_id": "a1"]))
            server.push(ev("reasoning-delta", ["id": "r0", "text": "think", "message_id": "a1"]))
            await settle(ctrl, server)
            server.persist(msg("a1", "assistant", "", [text("srv-t0", "Hello"), reasoning("srv-r0", "think")]))
            server.push(ev("turn-complete", ["reason": "stop"]))
            await settle(ctrl, server)
            let before = ctrl.messages.first { $0.id == "a1" }!
            XCTAssertFalse(before.isLocal, id)
            XCTAssertEqual(before.parts.count, 2, id)
            server.push(ev("text-delta", ["id": "t0", "text": "Hello", "message_id": "a1"]))
            server.push(ev("reasoning-delta", ["id": "r0", "text": "think", "message_id": "a1"]))
            await settle(ctrl, server)
            let after = ctrl.messages.first { $0.id == "a1" }!
            XCTAssertEqual(after.parts.count, 2, id)
            XCTAssertEqual(after.parts.filter { $0.type == "reasoning" }.count, 1, id)
            XCTAssertEqual(after.parts.filter { $0.type == "text" }.map { $0.text ?? "" }.joined(), "Hello", id)

        case "tool_error":
            server.push(ev("message-added", ["message_id": "a1", "prev_id": "", "role": "assistant", "streaming": true]))
            server.push(ev("tool-call", ["toolCallId": "tc9", "toolName": "boom"]))
            server.push(ev("tool-error", ["toolCallId": "tc9", "error": ["message": "kaput"]]))
            await settle(ctrl, server)
            let toolPart = ctrl.messages.first { $0.id == "a1" }!.parts.first { $0.id == "tc9" }!
            XCTAssertEqual(toolPart.state?.status, "error", id)
            XCTAssertEqual(toolPart.state?.error, "kaput", id)

        case "model_error":
            server.push(ev("status", ["type": "busy"]))
            server.push(ev("message-added", ["message_id": "a1", "prev_id": "", "role": "assistant", "streaming": true]))
            await settle(ctrl, server)
            XCTAssertTrue(ctrl.sending, id)
            server.push(ev("error", ["error": ["message": "upstream 500"]]))
            await settle(ctrl, server)
            XCTAssertFalse(ctrl.sending, id)
            let err = ctrl.messages.first { $0.role == "error" }!
            XCTAssertEqual(err.status, "error", id)
            XCTAssertTrue(err.isLocal, id)
            XCTAssertEqual(err.errorKind, "model", id)
            XCTAssertTrue(err.parts.first!.text.contains("upstream 500"), id)

        case "send_failure":
            server.failPrompt("mailbox down")
            await ctrl.send("hi"); await settle(ctrl, server)
            XCTAssertFalse(ctrl.sending, id)
            let err = ctrl.messages.first { $0.role == "error" }!
            XCTAssertEqual(err.errorKind, "send", id)
            XCTAssertTrue(err.parts.first!.text.contains("mailbox down"), id)

        case "error_transient":
            server.failPrompt("mailbox down")
            await ctrl.send("hi"); await settle(ctrl, server)
            XCTAssertTrue(ctrl.messages.contains { $0.role == "error" }, id)
            server.clearPromptError()
            await ctrl.send("again"); await settle(ctrl, server)
            XCTAssertEqual(ctrl.messages.filter { $0.role == "error" }.count, 0, id)

        default:
            XCTFail("unknown scenario \(id)")
        }

        ctrl.dispose()
    }

    /// Let queued main-actor work settle: wait until the controller has
    /// APPLIED every pushed event, then yield for any follow-on work. Waiting
    /// on `eventsApplied` (not the stream pull) is what makes this
    /// deterministic — the async consumer pulls an event, then applies it a
    /// tick later, so a fixed yield count races.
    private func settle(_ ctrl: MessagesController, _ server: FakeServer) async {
        var spins = 0
        while ctrl.eventsApplied < server.pushed && spins < 20_000 {
            await Task.yield()
            spins += 1
        }
        for _ in 0..<50 { await Task.yield() }
    }
}
