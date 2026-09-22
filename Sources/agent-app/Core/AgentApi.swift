import Foundation
import AgentSDK
import easyRpc
import SwiftProtobuf

// AgentApi — the facade over agent-sdk-swift (port of flutter api.dart).
// Unary calls go through the generated AgentServiceClient; streaming uses its
// AsyncThrowingStream surface.

func valueToJson(_ v: SwiftProtobuf.Google_Protobuf_Value?) -> Any? {
    switch v?.kind ?? .none {
    case .nullValue(.nullValue): return nil
    case .numberValue(let n): return n
    case .stringValue(let s): return s
    case .boolValue(let b): return b
    case .structValue(let st): return structToJson(st)
    case .listValue(let l): return l.values.map { valueToJson($0) }
    default: return nil
    }
}

func structToJson(_ st: SwiftProtobuf.Google_Protobuf_Struct?) -> [String: Any?] {
    guard let st else { return [:] }
    var out: [String: Any?] = [:]
    for (k, v) in st.fields { out[k] = valueToJson(v) }
    return out
}

private func decodeJson(_ data: String) -> [String: Any?] {
    guard !data.isEmpty, let d = data.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any?]
    else { return [:] }
    return obj
}

final class AgentApi: @unchecked Sendable {
    let baseUrl: String
    let token: String
    private let agent: AgentServiceClient

    init(baseUrl: String, token: String) {
        self.baseUrl = baseUrl
        self.token = token
        // The agent uses a private CA that is not in the system trust store;
        // makeAgentClient (Transport/AgentTransport.swift) uses a URLSession
        // that additionally anchors that CA, plus bearer auth.
        self.agent = makeAgentClient(baseUrl: baseUrl, token: token)
    }

    // ---- sessions ----

    func listSessions() async throws -> [Session] {
        try await agent.listSessions(req: Agent_V1_ListSessionsRequest()).sessions.map(sessionFromPb)
    }

    /// The caller's resolved identity (tenant id/name + role), from the token.
    func identity() async throws -> Identity {
        let r = try await agent.getIdentity(req: Agent_V1_GetIdentityRequest())
        return Identity(tenant: r.tenant, tenantName: r.tenantName, role: r.role)
    }

    /// Best-effort username for the saved-backend list ("" on failure).
    func resolveUsername() async -> String {
        (try? await identity().displayName) ?? ""
    }

    func createSession(_ params: [String: Any?]) async throws -> Session {
        var req = Agent_V1_CreateSessionRequest()
        req.name = params["name"] as? String ?? ""
        if let v = params["model"] as? String, !v.isEmpty { req.model = v }
        if let v = params["variant"] as? String, !v.isEmpty { req.variant = v }
        if let v = params["preset"] as? String, !v.isEmpty { req.preset = v }
        if let v = params["org"] as? String, !v.isEmpty { req.org = v }
        if let v = params["repo"] as? String, !v.isEmpty { req.repo = v }
        if let v = params["branch"] as? String, !v.isEmpty { req.branch = v }
        return Session(id: try await agent.createSession(req: req).sessionName)
    }

    func getSession(_ id: String) async throws -> Session? {
        var req = Agent_V1_GetSessionRequest(); req.id = id
        let r = try await agent.getSession(req: req)
        return r.hasSession ? sessionFromPb(r.session) : nil
    }

    func deleteSession(_ id: String) async throws {
        var req = Agent_V1_DeleteSessionRequest(); req.id = id
        _ = try await agent.deleteSession(req: req)
    }

    func renameSession(_ id: String, name: String) async throws -> Session? {
        var req = Agent_V1_RenameRequest(); req.id = id; req.name = name
        let r = try await agent.rename(req: req)
        return r.hasSession ? sessionFromPb(r.session) : nil
    }

    func prompt(_ id: String, _ prompt: String, attachments: [String] = []) async throws -> String {
        var req = Agent_V1_PromptRequest(); req.id = id; req.prompt = prompt
        req.attachments = attachments.map { c in
            var ref = Agent_V1_FileRef(); ref.code = c; return ref
        }
        for try await msg in agent.prompt(req: req) {
            if msg.event == "accepted", let mid = msg.params["message_id"] {
                return mid
            }
        }
        return ""
    }

    // ---- files ----

    func uploadFile(name: String, bytes: Data) async throws -> UploadedFile {
        var req = Agent_V1_IngestFileRequest()
        req.data = bytes; req.name = name
        // The agent DERIVES the content type from the bytes; adopt its answer.
        let r = try await agent.ingestFile(req: req)
        return UploadedFile(code: r.code, name: name, mime: r.mime, size: bytes.count)
    }

    func fetchFileBytes(_ code: String) async throws -> Data {
        var req = Agent_V1_GetFileRequest(); req.code = code
        return try await agent.getFile(req: req).data
    }

    func fileHead(_ code: String) async throws -> FileMeta {
        var req = Agent_V1_GetFileMetaRequest(); req.code = code
        let r = try await agent.getFileMeta(req: req)
        return FileMeta(
            contentType: r.mime.isEmpty ? nil : r.mime,
            length: Int(r.size),
            width: r.hasWidth ? Int(r.width) : nil,
            height: r.hasHeight ? Int(r.height) : nil,
            durationMs: r.hasDurationMs ? Int(r.durationMs) : nil,
            thumbCode: r.hasThumbCode && !r.thumbCode.isEmpty ? r.thumbCode : nil,
            thumbhash: r.hasThumbhash && !r.thumbhash.isEmpty ? r.thumbhash : nil,
        )
    }

    // ---- messages ----

    func messages(_ id: String, before: String? = nil, limit: Int = 30) async throws -> ([Message], Bool) {
        var req = Agent_V1_ListMessagesRequest(); req.id = id; req.limit = Int32(limit)
        if let b = before { req.before = b }
        let r = try await agent.listMessages(req: req)
        let msgs = r.messages.map(messageFromPb)
        return (msgs, msgs.count >= limit)
    }

    func messagesAfter(_ id: String, after: String, limit: Int = 200) async throws -> ([Message], Bool, String) {
        var req = Agent_V1_ListMessagesRequest(); req.id = id; req.limit = Int32(limit); req.after = after
        let r = try await agent.listMessages(req: req)
        return (r.messages.map(messageFromPb), r.resync, r.tipID)
    }

    // ---- session ops ----

    func settings(_ id: String, _ updates: [String: Any?]) async throws -> Session? {
        // Only model / preset / locale / variant are client-editable (proto
        // v0.18 dropped max_turns/system_prompt/group from UpdateSettingsRequest;
        // those are governed by the preset). Empty model/preset mean "leave
        // unchanged"; locale/variant use "" to clear an override.
        var req = Agent_V1_UpdateSettingsRequest(); req.id = id
        if let v = updates["model"] as? String, !v.isEmpty { req.model = v }
        if let v = updates["preset"] as? String, !v.isEmpty { req.preset = v }
        req.locale = updates["locale"] as? String ?? ""
        req.variant = updates["variant"] as? String ?? ""
        let r = try await agent.updateSettings(req: req)
        return r.hasSession ? sessionFromPb(r.session) : nil
    }

    func fork(_ id: String, branch: String) async throws -> Session? {
        var req = Agent_V1_ForkRequest(); req.id = id; req.name = branch
        let r = try await agent.fork(req: req)
        return r.hasSession ? sessionFromPb(r.session) : nil
    }

    func revert(_ id: String, messageId: String?) async throws {
        var req = Agent_V1_UndoRequest(); req.id = id; req.messageID = messageId ?? ""
        _ = try await agent.undo(req: req)
    }

    func interrupt(_ id: String) async throws -> Bool {
        var req = Agent_V1_InterruptRequest(); req.id = id
        return try await agent.interrupt(req: req).ok
    }

    func compact(_ id: String) async throws -> Bool {
        var req = Agent_V1_CompactRequest(); req.id = id
        return try await agent.compact(req: req).ok
    }

    func state(_ id: String) async throws -> (String, [Any?]) {
        var req = Agent_V1_StateRequest(); req.id = id
        let st = structToJson(try await agent.state(req: req).state)
        return ((st["status"] as? String) ?? "idle", (st["parts"] as? [Any?]) ?? [])
    }

    /// One page of the mailbox (NEWEST-FIRST, paged backward). Pass the oldest
    /// entry id you already hold as `before` to fetch the next older page.
    func mailbox(_ id: String, before: String = "", limit: Int = 0) async throws -> MailboxPage {
        var req = Agent_V1_MailboxRequest()
        req.id = id; req.before = before; req.limit = Int32(limit)
        let r = try await agent.mailbox(req: req)
        return MailboxPage(
            entries: r.mailbox.map { m in
                MailboxEntry(
                    id: m.id, msgType: m.msgType, payload: m.payload,
                    effectiveAt: m.effectiveAt.isEmpty ? nil : m.effectiveAt,
                    status: m.status, createdAt: m.createdAt,
                    consumedAt: m.consumedAt.isEmpty ? nil : m.consumedAt,
                    source: m.source,
                )
            },
            hasMore: r.hasMore_p,
        )
    }

    // ---- streams ----

    func streamEvents(_ sessionId: String, since: String = "") -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = Agent_V1_WatchSessionRequest()
                    req.id = sessionId; req.since = since
                    for try await msg in self.agent.watchSession(req: req) {
                        let params = structToJson(msg.params)
                        continuation.yield(
                            StreamEvent(
                                event: msg.event, params: params, eid: msg.eid,
                                runId: params["run_id"] as? String ?? "",
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func watchSessions() -> AsyncThrowingStream<SessionListEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await msg in self.agent.watchSessions(req: Agent_V1_WatchSessionsRequest()) {
                        continuation.yield(
                            SessionListEvent(
                                snapshot: msg.snapshot,
                                upserts: msg.upserts.map(sessionFromPb),
                                removed: Array(msg.removed),
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // ---- config / providers / models / presets / tools ----

    func setToolConfigValue(_ extId: String, _ name: String, _ value: Any?) async throws {
        var req = Agent_V1_SetExtensionConfigRequest()
        req.extID = extId; req.name = name
        req.value = SwiftProtobuf.Google_Protobuf_Value(stringValue: value.map { String(describing: $0) } ?? "")
        _ = try await agent.setExtensionConfig(req: req)
    }

    func providers() async throws -> [String: ProviderInfo] {
        let r = try await agent.listProviders(req: Agent_V1_ListProvidersRequest())
        var out: [String: ProviderInfo] = [:]
        for p in r.providers {
            out[p.providerID] = ProviderInfo(
                providerId: p.providerID, capability: p.capability,
                apiType: p.apiType, baseUrl: p.baseURL, apiKey: p.apiKey,
                headers: p.headers,
                models: p.models.map { m in
                    ProviderModel(id: m.id, name: m.name.isEmpty ? m.id : m.name,
                                   contextLimit: Int(m.contextLimit), modelType: m.modelType)
                }
            )
        }
        return out
    }

    func providerCatalog() async throws -> [String: [String]] {
        let r = try await agent.listProvidersCatalog(req: Agent_V1_ListProvidersCatalogRequest())
        var out: [String: [String]] = [:]
        for (k, v) in r.apiTypes { out[k] = v.capabilities }
        return out
    }

    func registerProvider(_ p: ProviderInfo) async throws {
        var pb = Agent_V1_Provider()
        pb.providerID = p.providerId; pb.capability = p.capability
        pb.apiType = p.apiType
        pb.baseURL = p.baseUrl; pb.apiKey = p.apiKey
        p.headers.forEach { pb.headers[$0.key] = $0.value }
        pb.models = p.models.map { m in
            var pm = Agent_V1_ProviderModel()
            pm.id = m.id; pm.name = m.name
            pm.contextLimit = Int64(m.contextLimit ?? 0); pm.modelType = m.modelType
            return pm
        }
        var req = Agent_V1_RegisterProviderRequest(); req.provider = pb
        _ = try await agent.registerProvider(req: req)
    }

    func deleteProvider(_ pid: String) async throws {
        var req = Agent_V1_DeleteProviderRequest(); req.providerID = pid
        _ = try await agent.deleteProvider(req: req)
    }

    func testProvider(apiType: String, baseUrl: String, apiKey: String, providerId: String = "", model: String? = nil, capability: String = "text") async throws -> (Bool, String) {
        var req = Agent_V1_TestProviderRequest()
        req.providerID = providerId; req.apiType = apiType
        req.baseURL = baseUrl; req.apiKey = apiKey
        req.model = model ?? ""; req.capability = capability
        let r = try await agent.testProvider(req: req)
        return (r.ok, r.result)
    }

    func models(providerId: String) async throws -> [ModelInfo] {
        guard !providerId.isEmpty else { return [] }
        var req = Agent_V1_ListModelsRequest(); req.providerID = providerId
        let r = try await agent.listModels(req: req)
        return r.models.map { m in
            ModelInfo(
                id: m.id, name: m.name, providerId: providerId, contextLimit: Int(m.contextLimit),
                variants: m.variants.map { ModelVariantInfo(id: $0.id, name: $0.name, description: $0.description_p) }
            )
        }
    }

    func presets(locale: String? = nil) async throws -> [Preset] {
        var req = Agent_V1_ListPresetsRequest(); req.locale = locale ?? ""
        let r = try await agent.listPresets(req: req)
        return r.presets.map {
            Preset(id: $0.id, systemPrompt: $0.systemPrompt, tools: Array($0.tools), maxTurns: Int($0.maxTurns), isSystem: $0.isSystem)
        }
    }

    func savePreset(_ p: Preset) async throws {
        var pb = Agent_V1_Preset()
        pb.id = p.id; pb.systemPrompt = p.systemPrompt; pb.maxTurns = Int32(p.maxTurns)
        pb.tools = p.tools
        var req = Agent_V1_UpsertPresetRequest(); req.preset = pb
        _ = try await agent.upsertPreset(req: req)
    }

    func deletePreset(_ id: String) async throws {
        var req = Agent_V1_DeletePresetRequest(); req.id = id
        _ = try await agent.deletePreset(req: req)
    }

    func tools(locale: String? = nil) async throws -> [ToolInfo] {
        var req = Agent_V1_ListToolsRequest(); req.locale = locale ?? ""
        let r = try await agent.listTools(req: req)
        return r.tools.map { tl in
            ToolInfo(
                name: tl.name, description: tl.description_p, category: tl.category,
                parameters: structToJson(tl.parameters).isEmpty ? nil : structToJson(tl.parameters),
                configFields: tl.configFields.map { c in
                    ToolConfigField(key: c.name, label: c.description_p.isEmpty ? c.name : c.description_p, type: c.type)
                },
                config: tl.configFields.map { c in
                    ToolConfigKnob(
                        name: c.name, type: c.type,
                        kind: c.kind, capability: c.capability,
                        enumValues: Array(c.enumValues),
                        defaultValue: c.hasDefault ? valueToJson(c.default) : nil,
                        description: c.description_p, scope: c.scope
                    )
                },
                requiredConfig: Array(tl.requiredConfig)
            )
        }
    }

    func setConfigKey(_ key: String, _ value: String) async throws {
        var req = Agent_V1_SetConfigRequest(); req.key = key; req.value = value
        _ = try await agent.setConfig(req: req)
    }

    func config(_ key: String) async throws -> String {
        var req = Agent_V1_GetConfigRequest(); req.key = key
        return try await agent.getConfig(req: req).value
    }

    func toolConfig() async throws -> [String: Any?] {
        let r = try await agent.getToolConfig(req: Agent_V1_GetToolConfigRequest())
        var out: [String: Any?] = [:]
        for (k, v) in r.config.values { out[k] = valueToJson(v) }
        return out
    }
}

// ---- auth-expired signal (port of flutter auth_gate.dart) ----
//
// Every agent RPC requires a bearer token; on 401/403 (unauthenticated /
// permission denied) the worst behavior is a silently empty screen. Any
// failing call marks the global flag; AgentApp shows the one-tap dialog.

@MainActor
enum AuthGate {
    static var expired = false

    static func notify(_ error: Error) {
        guard isAuthError(error) else { return }
        expired = true
    }
}

func isAuthError(_ error: Error) -> Bool {
    if let e = error as? RPCError {
        // 16 = unauthenticated, 7 = permission_denied.
        if e.code == 16 || e.code == 7 { return true }
    }
    // URLSession surfaces the HTTP status in the description.
    let s = String(describing: error)
    return s.contains("unauthenticated") || s.contains("permission_denied")
        || s.contains("401") || s.contains("403")
}

// ---- pb → model ----

func sessionFromPb(_ s: Agent_V1_Session) -> Session {
    Session(
        id: s.name, org: s.org, repo: s.repo, branch: s.branch,
        model: s.model, variant: s.variant, preset: s.preset,
        tipId: s.tipID.isEmpty ? nil : s.tipID,
        maxTurns: s.maxTurns == 0 ? nil : Int(s.maxTurns),
        systemPrompt: s.systemPrompt.isEmpty ? nil : s.systemPrompt,
        locale: s.locale.isEmpty ? nil : s.locale,
        inputTokens: Int(s.inputTokens), outputTokens: Int(s.outputTokens),
        totalTokens: Int(s.totalTokens),
        lastInputTokens: Int(s.lastInputTokens), lastOutputTokens: Int(s.lastOutputTokens),
        createdAt: s.createdAt, updatedAt: s.updatedAt,
        unreadCount: Int(s.unreadCount),
        lastMessageAt: s.lastMessageAt, lastMessagePreview: s.lastMessagePreview,
        messageSeq: Int(s.messageSeq),
        group: s.group
    )
}

func messageFromPb(_ m: Agent_V1_Message) -> Message {
    let decoded = m.parts.map { ($0, decodeJson($0.data)) }
    var results: [String: [String: Any?]] = [:]
    for (p, d) in decoded where p.type == "tool_result" {
        if let id = d["tool_use_id"] as? String, !id.isEmpty { results[id] = d }
    }
    var parts: [MessagePart] = []
    for (p, d) in decoded {
        switch p.type {
        case "text":
            parts.append(MessagePart(id: p.id, type: "text", text: d["text"] as? String ?? ""))
        case "reasoning":
            parts.append(MessagePart(id: p.id, type: "reasoning", text: d["text"] as? String ?? ""))
        case "summary", "compaction":
            parts.append(MessagePart(id: p.id, type: "compaction", text: d["summary"] as? String ?? ""))
        case "file":
            parts.append(MessagePart(
                id: p.id, type: "file",
                code: d["code"] as? String ?? "", name: d["name"] as? String ?? "",
                mime: d["mime"] as? String, size: (d["size"] as? NSNumber)?.intValue
            ))
        case "tool":
            let callId = (d["id"] as? String) ?? p.messageID
            let res = results[callId]
            parts.append(MessagePart(
                id: p.id, type: "tool", tool: d["name"] as? String ?? "", toolCallId: callId,
                state: ToolState(
                    status: res != nil ? "complete" : "running",
                    title: d["name"] as? String ?? "",
                    input: d["input"] as? [String: Any?],
                    output: res?["content"] as? String,
                    data: res?["metadata"] as? [String: Any?]
                )
            ))
        case "tool_result":
            let id = (d["tool_use_id"] as? String) ?? p.messageID
            if results[id] != nil && m.parts.contains(where: { $0.type == "tool" }) {
                break // merged above
            }
            parts.append(MessagePart(
                id: p.id, type: "tool", tool: "", toolCallId: id,
                state: ToolState(status: "complete", output: d["content"] as? String)
            ))
        default:
            break
        }
    }
    return Message(id: m.id, role: m.role, parts: parts,
                   createdAt: m.createdAt.isEmpty ? nil : m.createdAt, prevId: m.prevID,
                   source: m.source)
}

func mapMessagesToChat(_ msgs: [Message]) -> [ChatMessage] {
    msgs.enumerated().map { i, m in
        ChatMessage(
            id: m.id, role: m.role, status: "complete",
            parts: m.parts.map {
                ChatPart(id: $0.id, type: $0.type, text: $0.text ?? "", tool: $0.tool ?? "",
                         state: $0.state, code: $0.code, name: $0.name, mime: $0.mime, size: $0.size)
            },
            createdAt: m.createdAt ?? "", seq: i, prevId: m.prevId, source: m.source
        )
    }
}
