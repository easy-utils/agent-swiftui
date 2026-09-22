import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// LocalStore — the sqlite mirror (schema identical to the Flutter Drift DB)
// over the system SQLite3 C API.

final class LocalStore: @unchecked Sendable {
    private var db: OpaquePointer?

    /// Open the mirror for [scope] (the active gateway+token identity). One
    /// sqlite file per scope: a different user/tenant must never read another's
    /// sessions, drafts or unread watermarks.
    static func open(_ scope: String) throws -> LocalStore {
        let s = LocalStore()
        try s.openDb(scope)
        return s
    }

    private func openDb(_ scope: String) throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agent-app", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("agent_app_\(scope).sqlite3").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: Int(sqlite3_errcode(db)))
        }
        for stmt in LocalStore.schema.split(separator: ";") where !stmt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try exec(String(stmt))
        }
        // v5 cache migration: the message ORIGIN `source` column. When absent,
        // drop the message cache + anchors so the next open refetches with
        // source intact (source-less rows would misrender a hand-off).
        if !hasColumn("local_messages", "source") {
            try exec("ALTER TABLE local_messages ADD COLUMN source TEXT DEFAULT ''")
            try exec("DELETE FROM local_messages")
            try exec("DELETE FROM local_sync_state")
        }
    }

    private func hasColumn(_ table: String, _ column: String) -> Bool {
        guard let stmt = try? prepare("PRAGMA table_info(\(table))") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column { return true }
        }
        return false
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS local_sessions (
      id TEXT PRIMARY KEY, model TEXT DEFAULT '', variant TEXT DEFAULT '', preset TEXT DEFAULT '',
      system_prompt TEXT DEFAULT '', max_turns INTEGER DEFAULT 0, locale TEXT DEFAULT '',
      org TEXT DEFAULT '', repo TEXT DEFAULT '', branch TEXT DEFAULT '',
      server_tip_id TEXT DEFAULT '', message_seq INTEGER DEFAULT 0,
      last_message_at TEXT DEFAULT '', last_message_preview TEXT DEFAULT '',
      updated_at TEXT DEFAULT '', last_synced_at INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS local_messages (
      session_id TEXT NOT NULL, id TEXT NOT NULL, role TEXT, prev_id TEXT DEFAULT '',
      created_at TEXT DEFAULT '', order_key INTEGER, status TEXT DEFAULT 'complete',
      parts_json TEXT DEFAULT '[]', source TEXT DEFAULT '', PRIMARY KEY (session_id, id));
    CREATE TABLE IF NOT EXISTS local_sync_state (
      session_id TEXT PRIMARY KEY, oldest_id TEXT DEFAULT '', has_more INTEGER DEFAULT 1, tip_id TEXT DEFAULT '');
    CREATE TABLE IF NOT EXISTS local_drafts (
      session_id TEXT PRIMARY KEY, draft_text TEXT DEFAULT '', attachments_json TEXT DEFAULT '[]');
    CREATE TABLE IF NOT EXISTS read_seqs (session_id TEXT PRIMARY KEY, seq INTEGER DEFAULT 0);
    """

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(err)
            throw NSError(domain: "sqlite", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "sqlite", code: Int(sqlite3_errcode(db)),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, _ text: String?) {
        sqlite3_bind_text(stmt, idx, text ?? "", -1, SQLITE_TRANSIENT)
    }

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, _ v: Int32) {
        sqlite3_bind_int(stmt, idx, v)
    }

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, _ v: Int64) {
        sqlite3_bind_int64(stmt, idx, v)
    }

    private func colText(_ stmt: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
    }

    private func colInt(_ stmt: OpaquePointer, _ i: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, i))
    }

    private func run(_ sql: String, _ bindFn: (OpaquePointer) -> Void) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindFn(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "sqlite", code: Int(sqlite3_errcode(db)),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func query<T>(_ sql: String, _ args: [String], _ fn: (OpaquePointer) -> T) throws -> [T] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() { bind(stmt, Int32(i + 1), a) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(fn(stmt))
        }
        return out
    }

    // ---- sessions ----

    func loadSessions() throws -> [Session] {
        try query("SELECT * FROM local_sessions ORDER BY updated_at DESC", []) { s in
            Session(
                id: colText(s, 0),
                org: colText(s, 7), repo: colText(s, 8), branch: colText(s, 9),
                model: colText(s, 1), variant: colText(s, 2), preset: colText(s, 3),
                tipId: colText(s, 10).isEmpty ? nil : colText(s, 10),
                maxTurns: colInt(s, 5) > 0 ? colInt(s, 5) : nil,
                systemPrompt: colText(s, 4).isEmpty ? nil : colText(s, 4),
                locale: colText(s, 6).isEmpty ? nil : colText(s, 6),
                updatedAt: colText(s, 14),
                unreadCount: nil,
                lastMessageAt: colText(s, 12), lastMessagePreview: colText(s, 13),
                messageSeq: colInt(s, 11)
            )
        }
    }

    func upsertSessions(_ sessions: [Session]) throws {
        for x in sessions {
            try run("INSERT OR REPLACE INTO local_sessions VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)") { s in
                bind(s, 1, x.id); bind(s, 2, x.model); bind(s, 3, x.variant); bind(s, 4, x.preset)
                bind(s, 5, x.systemPrompt ?? ""); bind(s, 6, Int32(x.maxTurns ?? 0)); bind(s, 7, x.locale ?? "")
                bind(s, 8, x.org); bind(s, 9, x.repo); bind(s, 10, x.branch)
                bind(s, 11, x.tipId ?? ""); bind(s, 12, Int32(x.messageSeq))
                bind(s, 13, x.lastMessageAt); bind(s, 14, x.lastMessagePreview)
                bind(s, 15, x.updatedAt); bind(s, 16, Int64(Date().timeIntervalSince1970))
            }
        }
    }

    func removeSession(_ id: String) throws {
        for sql in [
            "DELETE FROM local_messages WHERE session_id = ?",
            "DELETE FROM local_sync_state WHERE session_id = ?",
            "DELETE FROM local_sessions WHERE id = ?",
        ] {
            try run(sql) { bind($0, 1, id) }
        }
    }

    // ---- messages ----

    func loadMessages(_ sessionId: String) throws -> [ChatMessage] {
        try query(
            "SELECT id, role, prev_id, created_at, order_key, status, parts_json, source FROM local_messages WHERE session_id = ? ORDER BY order_key ASC",
            [sessionId]
        ) { s in
            ChatMessage(
                id: colText(s, 0), role: colText(s, 1), status: colText(s, 5),
                parts: LocalJson.partsFrom(colText(s, 6)),
                createdAt: colText(s, 3), seq: colInt(s, 4), prevId: colText(s, 2),
                source: colText(s, 7)
            )
        }
    }

    func serverTipId(_ sessionId: String) throws -> String {
        try query("SELECT tip_id FROM local_sync_state WHERE session_id = ?", [sessionId]) { colText($0, 0) }.first ?? ""
    }

    func oldestCachedId(_ sessionId: String) throws -> String {
        try query("SELECT id FROM local_messages WHERE session_id = ? ORDER BY order_key ASC LIMIT 1", [sessionId]) { colText($0, 0) }.first ?? ""
    }

    func applyServerMessages(_ sessionId: String, _ msgs: [Message], replace: Bool, tipId: String) throws {
        try exec("BEGIN")
        do {
            if replace {
                try run("DELETE FROM local_messages WHERE session_id = ?") { bind($0, 1, sessionId) }
            }
            var order = try query("SELECT MAX(order_key) FROM local_messages WHERE session_id = ?", [sessionId]) { colInt($0, 0) }.first ?? 0
            order += 1
            for m in msgs {
                let j = LocalJson.partsOf(m.parts)
                try run("INSERT OR REPLACE INTO local_messages VALUES (?,?,?,?,?,?,?,?,?)") { s in
                    bind(s, 1, sessionId); bind(s, 2, m.id); bind(s, 3, m.role)
                    bind(s, 4, m.prevId); bind(s, 5, m.createdAt ?? "")
                    bind(s, 6, Int32(order)); bind(s, 7, "complete"); bind(s, 8, j)
                    bind(s, 9, m.source)
                }
                order += 1
            }
            try syncState(sessionId, tipId)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func persistMessages(_ sessionId: String, _ msgs: [ChatMessage], tipId: String) throws {
        try exec("BEGIN")
        do {
            try run("DELETE FROM local_messages WHERE session_id = ?") { bind($0, 1, sessionId) }
            var order: Int32 = 0
            for m in msgs where !m.isLocal {
                try run("INSERT OR REPLACE INTO local_messages VALUES (?,?,?,?,?,?,?,?,?)") { s in
                    bind(s, 1, sessionId); bind(s, 2, m.id); bind(s, 3, m.role)
                    bind(s, 4, m.prevId); bind(s, 5, m.createdAt)
                    bind(s, 6, order); bind(s, 7, m.status); bind(s, 8, LocalJson.chatPartsOf(m.parts))
                    bind(s, 9, m.source)
                }
                order += 1
            }
            try syncState(sessionId, tipId)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func syncState(_ sessionId: String, _ tipId: String) throws {
        let oldest = try oldestCachedId(sessionId)
        try run("INSERT OR REPLACE INTO local_sync_state VALUES (?,?,?,?)") { s in
            bind(s, 1, sessionId); bind(s, 2, oldest)
            bind(s, 3, Int32(oldest.isEmpty ? 0 : 1)); bind(s, 4, tipId)
        }
    }

    // ---- drafts ----

    func saveDraft(_ sessionId: String, _ text: String, _ attachments: [UploadedFile]) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            try run("DELETE FROM local_drafts WHERE session_id = ?") { bind($0, 1, sessionId) }
            return
        }
        let j = LocalJson.filesOf(attachments)
        try run("INSERT OR REPLACE INTO local_drafts VALUES (?,?,?)") { s in
            bind(s, 1, sessionId); bind(s, 2, text); bind(s, 3, j)
        }
    }

    func loadDrafts() throws -> [String: ChatDraft] {
        try query("SELECT session_id, draft_text, attachments_json FROM local_drafts", []) {
            (colText($0, 0), ChatDraft(text: colText($0, 1), attachments: LocalJson.filesFrom(colText($0, 2))))
        }.reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    // ---- read watermarks ----

    func setReadSeq(_ sessionId: String, _ seq: Int) throws {
        try run("INSERT OR REPLACE INTO read_seqs VALUES (?,?)") { s in
            bind(s, 1, sessionId); bind(s, 2, Int32(seq))
        }
    }

    func loadReadSeqs() throws -> [String: Int] {
        try query("SELECT session_id, seq FROM read_seqs", []) { (colText($0, 0), colInt($0, 1)) }
            .reduce(into: [:]) { $0[$1.0] = $1.1 }
    }
}

// Tiny JSON codecs for the cached rows (JSONSerialization-based).

enum LocalJson {
    static func partsOf(_ parts: [MessagePart]) -> String {
        let arr: [[String: Any?]] = parts.map {
            var o: [String: Any?] = ["id": $0.id, "type": $0.type]
            if let v = $0.text { o["text"] = v }
            if let v = $0.tool { o["tool"] = v }
            if let v = $0.code { o["code"] = v }
            if let v = $0.name { o["name"] = v }
            if let v = $0.mime { o["mime"] = v }
            if let v = $0.size { o["size"] = v }
            return o
        }
        return encode(arr)
    }

    static func chatPartsOf(_ parts: [ChatPart]) -> String {
        let arr: [[String: Any?]] = parts.map {
            var o: [String: Any?] = ["id": $0.id, "type": $0.type]
            if !$0.text.isEmpty { o["text"] = $0.text }
            if !$0.tool.isEmpty { o["tool"] = $0.tool }
            if let st = $0.state {
                var so: [String: Any?] = ["status": st.status, "title": st.title]
                if let v = st.output { so["output"] = v }
                o["state"] = so
            }
            if let v = $0.code { o["code"] = v }
            if let v = $0.name { o["name"] = v }
            if let v = $0.mime { o["mime"] = v }
            if let v = $0.size { o["size"] = v }
            return o
        }
        return encode(arr)
    }

    static func filesOf(_ files: [UploadedFile]) -> String {
        let arr: [[String: Any?]] = files.map {
            ["code": $0.code, "name": $0.name, "mime": $0.mime, "size": $0.size,
             "localPath": $0.localPath, "state": $0.uploadState.rawValue]
        }
        return encode(arr)
    }

    static func partsFrom(_ json: String) -> [ChatPart] {
        decode(json).compactMap { o in
            guard let id = o["id"] as? String, let type = o["type"] as? String else { return nil }
            let st = (o["state"] as? [String: Any?]).map {
                ToolState(status: $0["status"] as? String ?? "", title: $0["title"] as? String ?? "",
                          output: $0["output"] as? String)
            }
            return ChatPart(
                id: id, type: type, text: o["text"] as? String ?? "", tool: o["tool"] as? String ?? "",
                state: st, code: o["code"] as? String, name: o["name"] as? String,
                mime: o["mime"] as? String, size: (o["size"] as? NSNumber)?.intValue
            )
        }
    }

    static func filesFrom(_ json: String) -> [UploadedFile] {
        decode(json).compactMap { o in
            UploadedFile(
                code: o["code"] as? String ?? "", name: o["name"] as? String,
                mime: o["mime"] as? String, size: (o["size"] as? NSNumber)?.intValue
            )
        }
    }

    private static func encode(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private static func decode(_ json: String) -> [[String: Any?]] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any?]] else { return [] }
        return arr
    }
}
