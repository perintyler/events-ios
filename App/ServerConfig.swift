import Foundation

/// Where the app talks to Barry, and how it authenticates.
///
/// The reachability recipe is the one `bags/barry-iphone` established, reused
/// rather than rediscovered:
///  - Simulator: straight to the barry.works proxy on localhost.
///  - Device: over Tailscale to the Mac, with a Host header so Caddy routes
///    the request to the barry.works site block (which injects the API secret
///    for trusted-network callers).
///
/// Every Barry service binds 127.0.0.1 ONLY. There is no route to a raw
/// service port from a phone — the tailnet address reaches Caddy on :80, and
/// the `Host` header selects the site block. `bags/point-guard-ios` points at
/// `100.x.x.x:3868` and its device path has never worked for exactly this
/// reason; do not copy that shape.
///
/// `defaultTailscaleHost` is a STARTING POINT, not a constant. A tailnet
/// address changes (this Mac moved from 100.101.38.91 to 100.97.236.110 in a
/// single day, and `bags/plans/plans-iphone` still ships the stale one). It is
/// overridable in Settings and persisted, so a moved Mac is a text-field edit
/// rather than a rebuild. Find the current value with `tailscale ip -4`.
struct ServerConfig: Equatable {
    var baseURL: String
    var hostHeader: String
    var secret: String

    static let defaultsKeyBase = "server.baseURL"
    static let defaultsKeyHost = "server.hostHeader"

    /// This app's OWN keychain item, never shared with the other Barry apps.
    /// Two apps sharing one item would mean signing out of either silently
    /// signs out the other, and the secret is cheap to enter twice.
    static let keychainSecretKey = "rocks.barry.events.secret"

    static let defaultTailscaleHost = "100.97.236.110"
    static let defaultHostHeader = "barry.lan"

    static var platformDefault: ServerConfig {
        #if targetEnvironment(simulator)
        ServerConfig(baseURL: "http://127.0.0.1:9429", hostHeader: "", secret: "")
        #else
        ServerConfig(
            baseURL: "http://\(defaultTailscaleHost)",
            hostHeader: defaultHostHeader,
            secret: ""
        )
        #endif
    }

    static func load() -> ServerConfig {
        // UI/integration-test hook: `-eventsBaseURL <url>` overrides everything
        // else and skips the keychain, so a test can point the app at an
        // unreachable server (to exercise the error state) without touching
        // real persisted settings. Never wired to anything but launch arguments.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-eventsBaseURL"), args.count > i + 1 {
            var secret = ""
            if let s = args.firstIndex(of: "-eventsSecret"), args.count > s + 1 {
                secret = args[s + 1]
            }
            return ServerConfig(baseURL: args[i + 1], hostHeader: "", secret: secret)
        }

        let d = UserDefaults.standard
        var c = platformDefault
        if let base = d.string(forKey: defaultsKeyBase), !base.isEmpty { c.baseURL = base }
        if let host = d.string(forKey: defaultsKeyHost) { c.hostHeader = host }
        c.secret = Keychain.read(key: keychainSecretKey) ?? ""
        return c
    }

    func save() {
        let d = UserDefaults.standard
        d.set(baseURL, forKey: Self.defaultsKeyBase)
        d.set(hostHeader, forKey: Self.defaultsKeyHost)
        if secret.isEmpty {
            Keychain.delete(key: Self.keychainSecretKey)
        } else {
            Keychain.write(key: Self.keychainSecretKey, value: secret)
        }
    }

    /// Build a request for an API path, applying the host header and auth.
    func request(path: String, query: [URLQueryItem] = []) -> URLRequest? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url)
        apply(to: &req)
        return req
    }

    /// The tailnet is trusted by `packages/auth`, so the secret is usually
    /// unnecessary today — the proxy injects one. It is still sent when set so
    /// the app keeps working if that trust ever narrows (BARRY_TAILSCALE_IPS
    /// can restrict to a device allowlist).
    func apply(to req: inout URLRequest) {
        if !hostHeader.isEmpty { req.setValue(hostHeader, forHTTPHeaderField: "Host") }
        if !secret.isEmpty { req.setValue(secret, forHTTPHeaderField: "x-barry-secret") }
    }
}

/// Minimal keychain wrapper for the one secret the app stores.
///
/// No `kSecAttrAccessGroup`: that exists to share an item with a widget
/// extension, and this app has none. Requesting a group without the matching
/// entitlement fails with errSecMissingEntitlement.
enum Keychain {
    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(key: String, value: String) {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
