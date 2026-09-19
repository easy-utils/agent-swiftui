import Foundation
import Observation

// AppStore — port of flutter store.dart over @Observable.

enum SiderTab { case chat, config }

enum AppPage: Equatable {
    case chatList
    case chatSession
    case chatOverlay
    case configRoot
    case configSub(String)
    case providersList
    case presetFormNew
    case providerForm
    case providerModels(String?)

    var key: String {
        switch self {
        case .chatList: return "chat_list"
        case .chatSession: return "chat_session"
        case .chatOverlay: return "chat_overlay"
        case .configRoot: return "config_root"
        case .configSub(let id): return "config_sub_\(id)"
        case .providersList: return "providers_list"
        case .presetFormNew: return "preset_form_new"
        case .providerForm: return "provider_form"
        case .providerModels(let id): return "provider_model_\(id ?? "new")"
        }
    }
}

func rootPageFor(_ tab: SiderTab) -> AppPage {
    tab == .chat ? .chatList : .configRoot
}

@Observable
@MainActor
final class AppStore {
    let api: AgentApi
    let local: LocalStore?
    private let scope: AppScope

    var siderTab: SiderTab = .chat
    var sessions: [Session] = []
    var activeSessionId: String?
    var sessionError = ""
    var sessionRevision = 0
    var providersRevision = 0

    /// Capability matrix (ListProvidersCatalog): api type -> capabilities.
    /// Seeded with the bundled fallback; refreshed from the server.
    var providerCatalog: [String: [String]] = fallbackApiTypeCapabilities

    func refreshProviderCatalog() {
        Task {
            if let c = try? await api.providerCatalog(), !c.isEmpty {
                providerCatalog = c
            }
        }
    }
    var providerDraft: ProviderDraft?
    var chatDrafts: [String: ChatDraft] = [:]
    var readSeqs: [String: Int] = [:]

    private var stacks: [SiderTab: [AppPage]] = [:]

    private var watchTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var attempt = 0
    private var firstSnapshot = true

    init(api: AgentApi, local: LocalStore?) {
        self.api = api
        self.local = local
        self.scope = AppScope.shared
        scope.attach { [weak self] in self?.onStoreTick() }
        Task { await hydrateLocal() }
        startSessionWatch()
    }

    private func onStoreTick() { /* reserved for cross-cutting refresh hooks */ }

    private func hydrateLocal() async {
        guard let l = local else { return }
        // MERGE (never clobber): the stream's first snapshot can land before
        // this read resolves and seed read watermarks; overwriting with the
        // older DB copy would flash every row back as unread.
        if let seqs = try? await l.loadReadSeqs() { readSeqs.merge(seqs) { _, newer in newer } }
        if let d = try? await l.loadDrafts() { chatDrafts = d }
    }

    func startSessionWatch() {
        watchTask?.cancel()
        reconnectTask?.cancel()
        watchTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await ev in self.api.watchSessions() {
                    self.applySessionEvent(ev)
                }
                self.onWatchClosed()
            } catch {
                self.onWatchClosed()
            }
        }
    }

    private func onWatchClosed() {
        guard attempt < 20 else { return }
        let secs = min(30, 1 << min(attempt, 5))
        attempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            self?.startSessionWatch()
        }
    }

    private func applySessionEvent(_ ev: SessionListEvent) {
        attempt = 0
        if ev.snapshot {
            sessions = ev.upserts
            if firstSnapshot {
                firstSnapshot = false
                for s in ev.upserts where readSeqs[s.id] == nil {
                    readSeqs[s.id] = s.messageSeq
                    // Mirror to the local DB: a cold start whose DB read loses
                    // the race must not repopulate from an empty table and
                    // flash unread again.
                    let seq = s.messageSeq
                    let id = s.id
                    let store = local
                    Task { try? await store?.setReadSeq(id, seq) }
                }
                Prefs.saveReadSeqs(readSeqs)
            }
        } else {
            var next = sessions
            for s in ev.upserts {
                if let i = next.firstIndex(where: { $0.id == s.id }) { next[i] = s } else { next.append(s) }
            }
            if !ev.removed.isEmpty { next.removeAll { ev.removed.contains($0.id) } }
            sessions = next
        }
        if let a = activeSession, (readSeqs[a.id] ?? -1) < a.messageSeq {
            readSeqs[a.id] = a.messageSeq
            Prefs.saveReadSeqs(readSeqs)
        }
        sessionError = ""
    }

    var activeSession: Session? { sessions.first { $0.id == activeSessionId } }
    func sessionById(_ id: String) -> Session? { sessions.first { $0.id == id } }

    func refreshSessions() async {
        do {
            sessions = try await api.listSessions()
            sessionError = ""
        } catch {
            sessionError = error.localizedDescription
            await MainActor.run { AuthGate.notify(error) }
        }
    }

    func deleteSession(_ id: String) async {
        try? await api.deleteSession(id)
        try? await local?.removeSession(id)
        if activeSessionId == id { closeSession() }
        await refreshSessions()
    }

    func deleteSessions(_ ids: [String]) async -> [String] {
        var failed: [String] = []
        var closedActive = false
        for id in ids {
            do {
                try await api.deleteSession(id)
                try? await local?.removeSession(id)
                if activeSessionId == id {
                    activeSessionId = nil
                    closedActive = true
                }
            } catch { failed.append(id) }
        }
        if closedActive { closeSession() }
        await refreshSessions()
        return failed
    }

    func forkSession(_ branch: String) async -> Bool {
        guard let id = activeSessionId else { return false }
        do {
            let s = try await api.fork(id, branch: branch)
            activeSessionId = s?.id
            await refreshSessions()
            return true
        } catch { return false }
    }

    func pickSession(_ id: String) {
        activeSessionId = id
        markSessionRead(id)
        pushPage(.chatSession)
    }

    func markSessionRead(_ id: String) {
        let seq = sessionById(id)?.messageSeq ?? readSeqs[id] ?? 0
        readSeqs[id] = seq
        Prefs.saveReadSeqs(readSeqs)
        Task { try? await local?.setReadSeq(id, seq) }
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].unreadCount = 0
        }
    }

    func unreadCountFor(_ s: Session) -> Int {
        guard let read = readSeqs[s.id] else { return s.messageSeq }
        return max(0, s.messageSeq - read)
    }

    func isUnread(_ s: Session) -> Bool { unreadCountFor(s) > 0 }

    // ---- drafts ----

    func draftFor(_ sessionId: String) -> ChatDraft {
        if let d = chatDrafts[sessionId] { return d }
        let d = ChatDraft()
        chatDrafts[sessionId] = d
        return d
    }

    func saveDraftText(_ sessionId: String, _ text: String) {
        var d = draftFor(sessionId)
        guard d.text != text else { return }
        d.text = text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && d.attachments.isEmpty {
            chatDrafts[sessionId] = nil
            Task { try? await local?.saveDraft(sessionId, "", []) }
            return
        }
        chatDrafts[sessionId] = d
        Task { try? await local?.saveDraft(sessionId, d.text, d.attachments) }
    }

    func saveDraftAttachments(_ sessionId: String, _ attachments: [UploadedFile]) {
        var d = draftFor(sessionId)
        d.attachments = attachments
        if d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty {
            chatDrafts[sessionId] = nil
            Task { try? await local?.saveDraft(sessionId, "", []) }
            return
        }
        chatDrafts[sessionId] = d
        Task { try? await local?.saveDraft(sessionId, d.text, d.attachments) }
    }

    func clearDraft(_ sessionId: String) {
        chatDrafts[sessionId] = nil
        Task { try? await local?.saveDraft(sessionId, "", []) }
    }

    // ---- provider draft ----

    func bumpProvidersRevision() { providersRevision += 1 }

    func beginProviderDraft(_ existing: ProviderInfo?) {
        if let p = existing {
            providerDraft = ProviderDraft(
                originalId: p.providerId, id: p.providerId, apiType: p.apiType,
                baseUrl: p.baseUrl, apiKey: p.apiKey, models: p.models
            )
        } else {
            providerDraft = ProviderDraft()
        }
    }

    func endProviderDraft() { providerDraft = nil }

    func closeSession() {
        activeSessionId = nil
        if stacks[.chat]?.count ?? 0 > 1 { stacks[.chat] = [rootPageFor(.chat)] }
    }

    func bumpSessionRevision() { sessionRevision += 1 }

    func applySession(_ updated: Session) {
        sessions = sessions.map { $0.id == updated.id ? updated : $0 }
        bumpSessionRevision()
    }

    func switchTab(_ tab: SiderTab) { siderTab = tab }

    // ---- navigation stacks ----

    private func stackFor(_ tab: SiderTab) -> [AppPage] {
        if let s = stacks[tab] { return s }
        let s = [rootPageFor(tab)]
        stacks[tab] = s
        return s
    }

    var currentStack: [AppPage] { stackFor(siderTab) }
    var topPage: AppPage { currentStack.last ?? rootPageFor(siderTab) }

    func pushPage(_ page: AppPage) {
        var list = stackFor(siderTab)
        if let idx = list.firstIndex(where: { $0.key == page.key }) {
            list.removeSublist(from: idx)
        }
        list.append(page)
        stacks[siderTab] = list
        bumpSessionRevision()
    }

    func pushSibling(_ page: AppPage) {
        var list = stackFor(siderTab)
        if list.count > 1 { list.removeLast() }
        stacks[siderTab] = list
        pushPage(page)
    }

    func popPage() {
        var list = stackFor(siderTab)
        if list.count > 1 {
            list.removeLast()
            stacks[siderTab] = list
            if siderTab == .chat && list.count == 1 { activeSessionId = nil }
            bumpSessionRevision()
        }
    }

    var canPopPage: Bool { currentStack.count > 1 }
}

private extension Array {
    mutating func removeSublist(from index: Int) {
        guard index < count else { return }
        removeSubrange(index...)
    }
}

/// A tiny main-actor tick hub (kept for future cross-cutting refreshes).
@MainActor
final class AppScope {
    static let shared = AppScope()
    private var handlers: [() -> Void] = []
    func attach(_ h: @escaping () -> Void) { handlers.append(h) }
    func tick() { handlers.forEach { $0() } }
}
