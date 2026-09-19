import Foundation

/// Local-storage identity for the ACTIVE connection (gateway base URL + bearer
/// token).
///
/// WHY: the tenant lives inside the token (a client can never name it) and one
/// gateway host can serve several tenants, so every per-connection cache — the
/// sqlite mirror (sessions / messages / drafts / read watermarks) and the
/// persisted read watermarks — is keyed by this scope. Switching users starts
/// from a clean slate instead of leaking another tenant's data.
///
/// djb2 mod 2^31, computed in UInt64 so the value is identical to the Dart /
/// TypeScript / Kotlin ports.
func scopeOf(_ baseUrl: String, _ token: String) -> String {
    var h: UInt64 = 5381
    for b in Array("\(baseUrl)\n\(token)".utf8) {
        h = ((h * 33) + UInt64(b)) & 0x7fff_ffff
    }
    return String(format: "%08x", h)
}
