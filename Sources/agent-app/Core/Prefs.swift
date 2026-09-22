import Foundation

// Prefs — the port of flutter prefs.dart over UserDefaults.

enum Prefs {
    private static let d = UserDefaults.standard

    /// Where the connection form points by default (PREFILL only — no token is
    /// baked in, so the app always starts at the setup/backends flow).
    static let defaultBase = "https://agent.agent.10.199.64.20.nip.io"

    static func loadBase() -> String {
        d.string(forKey: "agent.baseUrl") ?? ProcessInfo.processInfo.environment["AGENT_BASE_URL"] ?? defaultBase
    }

    /// Empty when never connected (AGENT_TOKEN may still inject one for CI):
    /// the caller must show the setup form.
    static func loadToken() -> String {
        d.string(forKey: "agent.token") ?? ProcessInfo.processInfo.environment["AGENT_TOKEN"] ?? ""
    }

    static func save(_ base: String, _ token: String) {
        d.set(base, forKey: "agent.baseUrl")
        d.set(token, forKey: "agent.token")
    }

    static func clearActive() {
        d.removeObject(forKey: "agent.baseUrl")
        d.removeObject(forKey: "agent.token")
    }

    /// Tri-state theme pref: "system" (the DEFAULT) | "light" | "dark". The
    /// legacy agent.darkMode boolean maps onto the explicit modes — never back
    /// to "system" (the user chose).
    static var themeMode: String {
        get {
            if let v = d.string(forKey: "agent.themeMode"),
               v == "system" || v == "light" || v == "dark" { return v }
            if let legacy = d.object(forKey: "agent.darkMode") as? Bool {
                return legacy ? "dark" : "light"
            }
            return "system"
        }
        set { d.set(newValue, forKey: "agent.themeMode") }
    }

    /// Whether the SYSTEM UI language is Chinese — resolves the "system"
    /// language preference (en otherwise).
    static var systemLangZh: Bool {
        Locale.current.language.languageCode?.identifier.hasPrefix("zh") == true
    }

    static var agentLocale: String {
        get { d.string(forKey: "agent.agentLocale") ?? "follow" }
        set { d.set(newValue, forKey: "agent.agentLocale") }
    }

    /// UI language pref: "system" (the DEFAULT) | "zh" | "en".
    static var uiLang: String {
        get { d.string(forKey: "agent.uiLang") ?? "system" }
        set { d.set(newValue, forKey: "agent.uiLang") }
    }

    static var effectiveAgentLocale: String {
        agentLocale == "follow" ? (I18n.shared.lang == .zh ? "zh" : "en") : agentLocale
    }

    /// The connection scope the read watermarks are stored under. Set before
    /// the store is built; keeps two users / tenants apart on one device.
    static var readScope: String = ""

    private static var readKey: String { "agent.readSeqs.\(readScope)" }

    static func readSeqs() -> [String: Int] {
        guard !readScope.isEmpty else { return [:] }
        return (d.string(forKey: readKey) ?? "")
            .split(separator: ",")
            .reduce(into: [:]) { acc, pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let v = Int(parts[1]) {
                    acc[String(parts[0])] = v
                }
            }
    }

    static func saveReadSeqs(_ seqs: [String: Int]) {
        guard !readScope.isEmpty else { return }
        d.set(seqs.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","), forKey: readKey)
    }

    static func backends() -> [BackendCfg] {
        let raw = d.string(forKey: "agent.backends") ?? ""
        if raw.isEmpty { return [] }
        return raw.split(separator: "\n").compactMap { line -> BackendCfg? in
            // 3 fields = legacy (no username); 4 = name/baseUrl/token/username.
            let p = line.split(separator: "\u{1}", maxSplits: 3)
            switch p.count {
            case 3: return BackendCfg(name: String(p[0]), baseUrl: String(p[1]), token: String(p[2]))
            case 4: return BackendCfg(name: String(p[0]), baseUrl: String(p[1]), token: String(p[2]), username: String(p[3]))
            default: return nil
            }
        }
    }

    private static func encode(_ list: [BackendCfg]) -> String {
        list.map { "\($0.name)\u{1}\($0.baseUrl)\u{1}\($0.token)\u{1}\($0.username)" }.joined(separator: "\n")
    }

    /// A saved user is identified by the FULL connection (baseUrl + token):
    /// one host may serve several tenants.
    static func upsertBackend(_ b: BackendCfg) {
        let list = backends().filter { !($0.baseUrl == b.baseUrl && $0.token == b.token) } + [b]
        d.set(encode(list), forKey: "agent.backends")
    }

    static func removeBackend(_ b: BackendCfg) {
        let list = backends().filter { !($0.baseUrl == b.baseUrl && $0.token == b.token) }
        d.set(encode(list), forKey: "agent.backends")
    }
}
