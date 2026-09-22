import Foundation
import Observation

// MessagesController — port of flutter messages.dart.

@Observable
@MainActor
final class MessagesController {
    private let api: AgentApi
    private let getSessionId: () -> String
    private let local: LocalStore?
    private let sendFailed: (Error) -> String

    var messages: [ChatMessage] = []
    var sending = false
    var loading = false
    var hasMore = false
    var revision = 0

    private var syncedTipId = ""
    private var syncedOldestId = ""

    private var streamTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var subSid: String?
    private var streamingId: String?
    private var nextSeq = 1_000_000
    private var reconnectAttempt = 0

    private var seenEids = Set<String>()
    private var activeRunId: String?
    private var awaitingRun = false

    private var idleProbeTask: Task<Void, Never>?
    private var lastActivity = Date.distantPast

    init(api: AgentApi, getSessionId: @escaping () -> String, local: LocalStore?, sendFailed: @escaping (Error) -> String) {
        self.api = api
        self.getSessionId = getSessionId
        self.local = local
        self.sendFailed = sendFailed
    }

    var sorted: [ChatMessage] {
        messages.sorted {
            let a = $0.seq ?? Int.max
            let b = $1.seq ?? Int.max
            if a != b { return a < b }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }

    func init_() {
        let sid = getSessionId()
        guard !sid.isEmpty else { return }
        Task { await boot(sid) }
    }

    private func boot(_ sid: String) async {
        await hydrateFromLocal(sid)
        await sync(sid)
        await recover()
        connect(sid)
    }

    private func hydrateFromLocal(_ sid: String) async {
        guard let l = local else { return }
        guard let cached = try? await l.loadMessages(sid), !cached.isEmpty else { return }
        messages = cached + inFlightLocal()
        renumber()
        syncedTipId = (try? await l.serverTipId(sid)) ?? ""
        syncedOldestId = (try? await l.oldestCachedId(sid)) ?? ""
        revision += 1
    }

    private func sync(_ sid: String) async {
        loading = messages.isEmpty
        revision += 1
        defer {
            loading = false
            revision += 1
        }
        do {
            var cacheConsistent = messages.isEmpty
            if !syncedTipId.isEmpty && !syncedOldestId.isEmpty {
                let oldest = (try? await local?.oldestCachedId(sid)) ?? ""
                cacheConsistent = cacheConsistent || oldest == syncedOldestId
            }
            if let l = local, !syncedTipId.isEmpty, cacheConsistent {
                let (msgs, resync, tipId) = try await api.messagesAfter(sid, after: syncedTipId)
                if resync {
                    await baseline(sid)
                } else if msgs.isEmpty && messages.isEmpty {
                    await baseline(sid)
                } else {
                    mergeServer(msgs, tipId: tipId)
                    try? await l.persistMessages(sid, messages, tipId: tipId)
                }
            } else {
                await baseline(sid)
            }
        } catch {
            // offline: keep the local cache
        }
    }

    private func baseline(_ sid: String) async {
        do {
            let (msgs, more) = try await api.messages(sid, limit: 50)
            let chat = mapMessagesToChat(msgs)
            messages = inFlightLocal() + chat
            renumber()
            hasMore = more
            if let l = local {
                syncedTipId = chat.last?.id ?? ""
                try? await l.applyServerMessages(sid, msgs, replace: true, tipId: syncedTipId)
                syncedOldestId = (try? await l.oldestCachedId(sid)) ?? ""
            }
        } catch {
            // keep the cache
        }
    }

    private func mergeServer(_ msgs: [Message], tipId: String) {
        let hasServer = !msgs.isEmpty
        let chat = mapMessagesToChat(msgs)
        var byId: [String: ChatMessage] = [:]
        var order: [String] = []
        for m in messages {
            let key = m.isLocal ? "local:\(m.id)" : m.id
            if !m.isLocal {
                byId[key] = m; order.append(key); continue
            }
            let inFlight = m.status == "streaming" || m.status == "pending"
            if !hasServer || inFlight {
                if byId[key] == nil { byId[key] = m; order.append(key) }
            }
        }
        for m in chat {
            if byId[m.id] == nil { order.append(m.id) }
            byId[m.id] = m
        }
        messages = order.compactMap { byId[$0] }
        renumber()
        syncedTipId = tipId
    }

    private func renumber() {
        // Stable sort by createdAt, keeping the CURRENT array order on ties.
        // Ties must not be broken by id: a locally-appended user bubble and the
        // assistant streaming placeholder created right after it share a
        // millisecond, and "m…" sorts before "u…" — which would draw the
        // assistant reply ABOVE its user message.
        let ordered = messages.enumerated()
            .sorted { a, b in
                if a.element.createdAt != b.element.createdAt {
                    return a.element.createdAt < b.element.createdAt
                }
                return a.offset < b.offset
            }
            .map { $0.element }
        messages = ordered.enumerated().map { i, m in
            var mm = m; mm.seq = i; return mm
        }
        nextSeq = (messages.map { $0.seq ?? -1 }.max() ?? -1) + 1
    }

    private func fetchMessages(before: String? = nil) async {
        loading = true
        revision += 1
        defer {
            loading = false
            revision += 1
        }
        do {
            let sid = getSessionId()
            let (msgs, more) = try await api.messages(sid, before: before, limit: 50)
            let chat = mapMessagesToChat(msgs)
            if let before {
                let existing = Set(messages.map { $0.id })
                messages = chat.filter { !existing.contains($0.id) } + messages
            } else {
                messages = inFlightLocal() + chat
            }
            renumber()
            hasMore = more
        } catch {
            // keep view
        }
        if let l = local {
            try? await l.persistMessages(getSessionId(), messages, tipId: syncedTipId)
            syncedOldestId = (try? await l.oldestCachedId(getSessionId())) ?? ""
        }
    }

    private func recover() async {
        do {
            let (status, _) = try await api.state(getSessionId())
            if status == "busy" || status == "running" {
                sending = true
                if !messages.contains(where: { $0.status == "streaming" }) {
                    streamingId = "recover-\(Int(Date().timeIntervalSince1970 * 1000))"
                    messages.append(
                        ChatMessage(
                            id: streamingId!, role: "assistant", status: "streaming",
                            parts: [], createdAt: nowIso(), seq: allocSeq(), isLocal: true
                        )
                    )
                }
                revision += 1
            }
        } catch {}
    }

    private func connect(_ sid: String) {
        reconnectTask?.cancel()
        streamTask?.cancel()
        subSid = sid
        reconnectAttempt = 0
        lastActivity = Date()
        idleProbeTask?.cancel()
        seenEids.removeAll()
        activeRunId = nil
        awaitingRun = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await ev in self.api.streamEvents(sid, since: self.syncedTipId) {
                    self.handleEvent(ev)
                }
                self.onStreamClosed(sid)
            } catch {
                self.onStreamClosed(sid)
            }
        }
        startIdleProbe()
    }

    private func clearStreaming() {
        streamingId = nil
        activeRunId = nil
        messages.removeAll { $0.status == "streaming" }
    }

    private func onStreamClosed(_ sid: String) {
        if let s = subSid, s != sid { return }
        syncIdle()
        guard sid == getSessionId(), reconnectAttempt < 10 else { return }
        let delayMs = min(30_000, 1_000 << reconnectAttempt)
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            self?.connect(sid)
        }
    }

    private func startIdleProbe() {
        idleProbeTask?.cancel()
        idleProbeTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard Date().timeIntervalSince(self.lastActivity) >= 30 else { continue }
                do {
                    let (st, _) = try await self.api.state(self.getSessionId())
                    if st == "busy" || st == "running" {
                        if !self.sending { self.sending = true; self.revision += 1 }
                    } else {
                        self.syncIdle()
                    }
                } catch {}
            }
        }
    }

    private func syncIdle() {
        guard sending else { return }
        finishStreaming()
    }

    private func handleEvent(_ ev: StreamEvent) {
        lastActivity = Date()
        if !ev.eid.isEmpty {
            guard seenEids.insert(ev.eid).inserted else { return }
            if seenEids.count > 20_000 { seenEids.removeAll() }
        }
        if awaitingRun {
            awaitingRun = false
            clearStreaming()
        }
        let run = ev.runId
        if !run.isEmpty && run != activeRunId {
            if activeRunId != nil { clearStreaming() }
            activeRunId = run
        }
        let params = ev.params
        let event = ev.event
        switch event {
        case "message-added":
            // The server AUTHORED this message's id and chain anchor. This is
            // the ONLY place user bubbles are created (no client-optimistic
            // row). `streaming:true` opens the assistant step's bubble.
            let addedId = params["message_id"] as? String ?? ""
            let prevId = params["prev_id"] as? String ?? ""
            let role = params["role"] as? String ?? "assistant"
            let streaming = params["streaming"] as? Bool ?? false
            let src = params["source"] as? String ?? ""
            if !addedId.isEmpty {
                if streaming && role == "assistant" {
                    if let prevStream = streamingId, prevStream != addedId {
                        for i in messages.indices where messages[i].id == prevStream && messages[i].status == "streaming" {
                            messages[i].status = "complete"
                        }
                    }
                    streamingId = addedId
                    ensureStreamingMsgAt(addedId, prevId)
                } else if role == "user" {
                    upsertServerMessage(addedId, prevId, role: "user", source: src)
                }
                revision += 1
            }
        case "start-step", "text-start", "reasoning-start", "tool-input-start":
            let current = streamingId.flatMap { id in messages.first { $0.id == id } }
            let hasToolPart = current?.parts.contains { $0.type == "tool" } ?? false
            let sid = ensureStreamingMsg(forceNew: event == "start-step" || (event == "text-start" && hasToolPart))
            if event == "text-start", let pid = params["id"] as? String {
                ensurePart(sid, pid, "text")
            } else if event == "reasoning-start", let pid = params["id"] as? String {
                ensurePart(sid, "r\(pid)", "reasoning")
            } else if event == "tool-input-start", let pid = params["id"] as? String {
                startToolPart(sid, pid,
                              (params["toolName"] ?? params["name"] ?? "tool") as? String ?? "tool")
            }
        case "tool-input-delta":
            if let pid = params["id"] as? String, let delta = params["delta"] as? String {
                appendToolInput(pid, delta)
            }
        case "text-delta":
            if let pid = params["id"] as? String, let text = params["text"] as? String {
                appendDelta(ensureStreamingMsg(forceNew: false), pid, text, reasoning: false)
            }
        case "reasoning-delta":
            if let pid = params["id"] as? String, let text = params["text"] as? String {
                appendDelta(ensureStreamingMsg(forceNew: false), "r\(pid)", text, reasoning: true)
            }
        case "tool-call":
            let sid = ensureStreamingMsg(forceNew: false)
            if let tcId = (params["toolCallId"] ?? params["id"]) as? String {
                addToolPart(sid, tcId,
                            (params["toolName"] ?? params["name"] ?? "tool") as? String ?? "tool",
                            params["input"] as? [String: Any?])
            }
        case "tool-result":
            guard let tcId = (params["toolCallId"] ?? params["id"]) as? String else { return }
            updateToolResult(
                tcId, params["formatted"] ?? params["output"] ?? params["result"],
                errorMsg: nil,
                changeId: params["change_id"] as? String,
                diff: params["diff"] as? String,
                additions: (params["additions"] as? NSNumber)?.intValue,
                deletions: (params["deletions"] as? NSNumber)?.intValue,
                data: params["data"] as? [String: Any?]
            )
        case "tool-error":
            guard let tcId = (params["toolCallId"] ?? params["id"]) as? String else { return }
            let errObj = params["error"]
            let errMsg: String
            if let s = errObj as? String { errMsg = s }
            else if let m = errObj as? [String: Any?], let msg = (m["message"] ?? params["message"]) {
                errMsg = String(describing: msg)
            } else {
                errMsg = (params["message"].map { String(describing: $0) }) ?? "tool error"
            }
            updateToolResult(tcId, nil, errorMsg: errMsg)
        case "tool-output-denied":
            guard let tcId = (params["toolCallId"] ?? params["id"]) as? String else { return }
            updateToolResult(tcId, nil, errorMsg: "denied")
        case "file", "reasoning-file":
            // A streamed media part the agent has already offloaded to the blob
            // store; `code` is the file code. Render it as a file part (same
            // path as a persisted file part) on the streaming bubble.
            guard let code = params["code"] as? String, !code.isEmpty else { return }
            let sid = ensureStreamingMsg(forceNew: false)
            let partId = "f\(code)"
            if messages.first(where: { $0.id == sid })?.parts.contains(where: { $0.id == partId }) == true { return }
            setMsg(sid) { m in
                m.parts.append(ChatPart(
                    id: partId, type: "file", code: code,
                    name: params["name"] as? String,
                    mime: (params["mediaType"] ?? params["mime"]) as? String,
                    size: nil
                ))
            }
        case "turn-complete":
            finishStreaming()
        case "chain-changed":
            clearStreaming()
            sending = false
            revision += 1
            Task { await fetchMessages() }
        case "status":
            let stype = params["type"] as? String
            if stype == "busy" || stype == "running" {
                sending = true
                revision += 1
            } else {
                finishStreaming()
            }
        case "error", "provider-error":
            let errObj = params["error"]
            let content: String
            if let s = errObj as? String { content = s }
            else if let m = errObj as? [String: Any?], let msg = (m["message"] ?? params["message"]) {
                content = String(describing: msg)
            } else {
                content = (params["message"].map { String(describing: $0) }) ?? "Unknown error"
            }
            addError(content)
            sending = false
            revision += 1
        default:
            break
        }
    }

    /// Allocate the next optimistic seq. MUST advance nextSeq (the other
    /// three clients do): a non-mutating alloc would hand the same seq to a
    /// later bubble, and `sorted`'s id tie-break ("m…" < "u…") could then
    /// reorder a retry's streaming card above its user message.
    private func allocSeq() -> Int {
        nextSeq += 1
        return nextSeq - 1
    }

    private func inFlightLocal() -> [ChatMessage] {
        messages.filter { $0.isLocal && ($0.status == "streaming" || $0.status == "pending") }
    }

    private func nowIso() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func ensureStreamingMsg(forceNew: Bool) -> String {
        if let id = streamingId, let existing = messages.first(where: { $0.id == id }) {
            if !forceNew || existing.parts.isEmpty { return id }
        }
        let id = "m\(Int(Date().timeIntervalSince1970 * 1000))"
        streamingId = id
        messages.append(
            ChatMessage(id: id, role: "assistant", status: "streaming", parts: [],
                        createdAt: nowIso(), seq: nextSeq, isLocal: true)
        )
        nextSeq += 1
        return id
    }

    /// Open (or reuse) the server-authored streaming assistant bubble for the
    /// id announced by `message-added{streaming:true}`. No id is minted here.
    private func ensureStreamingMsgAt(_ id: String, _ prevId: String) {
        if messages.contains(where: { $0.id == id }) {
            streamingId = id
            return
        }
        messages.append(
            ChatMessage(id: id, role: "assistant", status: "streaming", parts: [],
                        createdAt: nowIso(), seq: nextSeq, prevId: prevId, isLocal: true)
        )
        nextSeq += 1
        revision += 1
    }

    /// Render a persisted row announced via `message-added` with the
    /// server-authored id/position — the user prompt in particular.
    private func upsertServerMessage(_ id: String, _ prevId: String, role: String, source: String) {
        if messages.contains(where: { $0.id == id }) { return }
        messages.append(
            ChatMessage(id: id, role: role, status: "complete", parts: [],
                        createdAt: nowIso(), seq: nextSeq, prevId: prevId,
                        isLocal: false, source: source)
        )
        nextSeq += 1
        revision += 1
    }

    private func setMsg(_ id: String, _ fn: (inout ChatMessage) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        fn(&messages[idx])
        revision += 1
    }

    private func ensurePart(_ msgId: String, _ partId: String, _ type: String) {
        setMsg(msgId) { m in
            guard !m.parts.contains(where: { $0.id == partId }) else { return }
            m.parts.append(ChatPart(id: partId, type: type))
        }
    }

    private func appendDelta(_ msgId: String, _ partId: String, _ delta: String, reasoning: Bool) {
        setMsg(msgId) { m in
            if let idx = m.parts.firstIndex(where: { $0.id == partId }) {
                m.parts[idx].text += delta
            } else {
                m.parts.append(ChatPart(id: partId, type: reasoning ? "reasoning" : "text", text: delta))
            }
        }
    }

    /// Create the tool part as soon as argument streaming begins.
    private func startToolPart(_ msgId: String, _ partId: String, _ name: String) {
        setMsg(msgId) { m in
            if m.parts.contains(where: { $0.id == partId }) { return }
            m.parts.append(ChatPart(id: partId, type: "tool", tool: name,
                                    state: ToolState(status: "running", title: name, inputText: "")))
        }
    }

    /// Accumulate streamed tool-argument JSON for the live preview.
    private func appendToolInput(_ partId: String, _ delta: String) {
        guard let sid = streamingId else { return }
        setMsg(sid) { m in
            for i in m.parts.indices where m.parts[i].id == partId {
                var st = m.parts[i].state ?? ToolState()
                st.inputText = (st.inputText ?? "") + delta
                m.parts[i].state = st
            }
        }
    }

    private func addToolPart(_ msgId: String, _ partId: String, _ name: String, _ input: [String: Any?]?) {
        setMsg(msgId) { m in
            let part = ChatPart(id: partId, type: "tool", tool: name,
                                state: ToolState(status: "running", title: name, input: input))
            if let idx = m.parts.firstIndex(where: { $0.id == partId }) {
                m.parts[idx] = part
            } else {
                m.parts.append(part)
            }
        }
    }

    private func updateToolResult(
        _ partId: String, _ result: Any?,
        errorMsg: String?, changeId: String? = nil, diff: String? = nil,
        additions: Int? = nil, deletions: Int? = nil, data: [String: Any?]? = nil
    ) {
        guard let sid = streamingId else { return }
        setMsg(sid) { m in
            for i in m.parts.indices where m.parts[i].id == partId {
                let old = m.parts[i].state ?? ToolState()
                let output: String?
                if let r = result as? String { output = r }
                else if result == nil { output = old.output }
                else { output = prettyAny(result!) }
                m.parts[i].state = ToolState(
                    status: errorMsg != nil ? "error" : "complete",
                    title: old.title,
                    input: old.input,
                    output: output,
                    error: errorMsg ?? old.error,
                    data: data ?? old.data,
                    changeId: changeId ?? old.changeId,
                    diff: diff ?? old.diff,
                    additions: additions ?? old.additions,
                    deletions: deletions ?? old.deletions
                )
            }
        }
    }

    private func finishStreaming() {
        for i in messages.indices where messages[i].status == "streaming" {
            messages[i].status = "complete"
        }
        streamingId = nil
        activeRunId = nil
        sending = false
        revision += 1
        Task { await reconcile() }
    }

    private func reconcile() async {
        guard let l = local else { return }
        let sid = getSessionId()
        do {
            if syncedTipId.isEmpty {
                await baseline(sid)
                return
            }
            let (msgs, resync, tipId) = try await api.messagesAfter(sid, after: syncedTipId)
            if resync {
                await baseline(sid)
                return
            }
            mergeServer(msgs, tipId: tipId)
            revision += 1
            try? await l.persistMessages(sid, messages, tipId: syncedTipId)
            syncedOldestId = (try? await l.oldestCachedId(sid)) ?? ""
        } catch {}
    }

    private func addError(_ text: String) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        messages.removeAll { $0.status == "streaming" }
        messages.append(
            ChatMessage(
                id: "err\(now)", role: "error", status: "error",
                parts: [ChatPart(id: "p\(now)", type: "text", text: text)],
                createdAt: nowIso(), seq: nextSeq, isLocal: true
            )
        )
        nextSeq += 1
        streamingId = nil
    }

    func send(_ text: String, attachments: [UploadedFile] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard !sending else { return }
        sending = true
        let codes = attachments.map { $0.code }
        // No client-optimistic user bubble: the server AUTHORS the message id
        // and chain position and announces it via `message-added{role:user}`
        // once the running turn drains the mailbox. We only show the composer
        // spinner until the send RPC is accepted.
        revision += 1
        do {
            _ = try await api.prompt(getSessionId(), trimmed, attachments: codes)
        } catch {
            addError(sendFailed(error))
            Task { @MainActor in AuthGate.notify(error) }
            sending = false
            revision += 1
        }
    }

    func stop() {
        Task {
            _ = try? await api.interrupt(getSessionId())
            finishStreaming()
        }
    }

    func revert(_ messageId: String) async {
        if sending { _ = try? await api.interrupt(getSessionId()) }
        try? await api.revert(getSessionId(), messageId: messageId)
        clearStreaming()
        sending = false
        await fetchMessages()
    }

    func resendFrom(_ msg: ChatMessage, _ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if sending { _ = try? await api.interrupt(getSessionId()) }
        let codes = msg.parts.filter { $0.type == "file" }.compactMap { $0.code }.filter { !$0.isEmpty }
        try? await api.revert(getSessionId(), messageId: msg.id)
        clearStreaming()
        sending = false
        await fetchMessages()
        await send(trimmed, attachments: codes.map { UploadedFile(code: $0) })
    }

    func loadMore() async {
        guard hasMore, !loading, let first = sorted.first else { return }
        await fetchMessages(before: first.id)
    }

    func dispose() {
        reconnectTask?.cancel()
        idleProbeTask?.cancel()
        streamTask?.cancel()
    }
}

func prettyAny(_ o: Any) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return String(describing: o)
}
