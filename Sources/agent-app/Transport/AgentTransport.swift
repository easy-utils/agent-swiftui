// Agent transport wiring for the SwiftUI app.
//
// agent-sdk-swift is generated code only (typed messages + the
// AgentServiceClient). This file owns the transport via the easy-rpc
// composition root: `connect(baseUrl:token:)` installs the bearer metadata
// interceptor, and, because the agent is served with a private/self-signed CA
// that is NOT in the system trust store, it is handed a URLSession whose
// delegate additionally trusts that CA.
//
// Usage:
//     let client = makeAgentClient(baseUrl: url, token: token)

import AgentSDK
import Foundation
import easyRpc

/// PEM of the private agent ingress CA (same cert the Flutter app bundles as
/// `assets/certs/ca.crt`).
let agentCA_PEM = """
-----BEGIN CERTIFICATE-----
MIIDMzCCAhugAwIBAgIUKFLlzRhaBbJ6caHaT0dkOpp0GQcwDQYJKoZIhvcNAQEL
BQAwITEfMB0GA1UEAwwWMTAuMTk5LjY0LjIwLm5pcC5pbyBDQTAeFw0yNjA4Mjcw
OTE4NTFaFw00NjA4MjIwOTE4NTFaMCExHzAdBgNVBAMMFjEwLjE5OS42NC4yMC5u
aXAuaW8gQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCdhoKqa8QW
/VJFeNF49SuVw6hwH6D0okxgm84lfB7nbcuwo0FyZ0nZT+3qA1NgyRNpOlciTE93
SZyy41gnC1DF3lnwuaMOLhsc12Yo5PK1VJeIRS9kUEkb1OWLeVigSvt2JGhHQ5lz
CPZaKLttOZ5usqS0WUOwRriUFR8AP1i+Xzq0UvP8w9XtXF7/0KbDLknjOw/zF/+p
OSNUe04h8VSg8vdNfBV6gnRvuIyKTbcptfSyrvM7dWxOrGuxc/Ihz84GtKqCUpdm
2pzSO3Nx1dx7dsfQAjojavFaXLjgGr2CXfld24NmnXSo4a0YDIHjlx8w9FGv4j5s
PhBABXZ0ZNkpAgMBAAGjYzBhMB8GA1UdIwQYMBaAFJSeIcSko1pH75cqz0IfZ8Qy
k73fMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBSU
niHEpKNaR++XKs9CH2fEMpO93zANBgkqhkiG9w0BAQsFAAOCAQEAfW7jwq+0dlk6
bjG8M9n97TKAGgfRR9+u+upkpXD6V+SBAvdnxAYVb6iYUKswkYtv9BdHbTwGYZ2q
ISW7oii9nXVxALZWWb+Uf0LPt5qzWtb3GMPo+QIaB7tvpYsoR1FyiLCsgrRqLxCB
DEMLrHrlu89Lh6+pHPXeIj7kP6AWHUUJb6kyPqFifpQYvUsSoWGJ8Qktl9h4lxcB
oWh6beCV5SaDyUs592BSnqh3Vhp07ZgRsw2Vtk4GuA87f73OswdLKXEr//6G/EFt
ZX80bBaNMaLkG4P6cnQxKaId/UPSGQcdMeuC60KnerbQ+S/nKOyG3jONFOTdYAwr
uCF4K46QHw==
-----END CERTIFICATE-----
"""

/// URLSession delegate that evaluates the server trust against the system
/// roots PLUS the bundled private agent CA. On Apple platforms the system
/// evaluator is extended with the extra anchor via `SecTrustSetAnchorCertificates`
/// (`useSystemAnchors: true`) so a publicly-signed ingress still validates.
final class AgentTrustDelegate: NSObject, URLSessionDelegate {
    private let caCertificates: [SecCertificate]

    override init() {
        var certs: [SecCertificate] = []
        if let der = Data(base64Encoded: agentCA_PEM
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")) {
            if let cert = SecCertificateCreateWithData(nil, der as CFData) {
                certs.append(cert)
            }
        }
        self.caCertificates = certs
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              !caCertificates.isEmpty
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, caCertificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false) // keep system roots too
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Build the typed agent client over easy-rpc (URLSession + bearer auth),
/// trusting the bundled private CA.
func makeAgentClient(baseUrl: String, token: String) -> AgentServiceClient {
    let session = URLSession(
        configuration: .default,
        delegate: AgentTrustDelegate(),
        delegateQueue: nil,
    )
    let host = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
    let transport = connect(
        baseUrl: host,
        token: token,
        transport: URLSessionTransport(session: session, base: host),
    )
    return AgentServiceClient(transport)
}
