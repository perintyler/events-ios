import Foundation

/// Where the app talks to Barry, and how it authenticates.
///
///  - Simulator: straight to the barry.works proxy on localhost, which injects
///    the API secret for loopback callers. Nothing to configure.
///  - Device: HTTPS over the personal tailnet to a userspace `tailscaled`
///    sidecar, which terminates TLS and proxies to the API on `127.0.0.1:4854`.
///
/// The device host is a real tailnet DNS name with a real Let's Encrypt
/// certificate, so there is no certificate prompt and no pinning to do. It
/// replaces the old `http://<tailscale-ip>` + `Host: barry.lan` Caddy route:
/// that shape shipped a hardcoded IP that went stale within a day, and the
/// sidecar's stable name removes the reason to edit an address at all.
///
/// The secret is REQUIRED on the device path. `:4854` rejects an unauthenticated
/// caller with 403 even from loopback — only `/health` is open — so unlike the
/// old proxy route there is nothing upstream filling the secret in.
struct ServerConfig: Equatable {
    var baseURL: String
    var secret: String

    static let defaultsKeyBase = "server.baseURL"

    /// The shipped default that was in force when `baseURL` was saved.
    ///
    /// `UserDefaults` survives reinstalling the app, so without this a base URL
    /// saved once outlives every future default: shipping a new address changes
    /// nothing, the app keeps dialling the old one, and the failure is a
    /// connection timeout that looks like the server being down. That is
    /// exactly what happened when the device path moved off a hardcoded
    /// Tailscale IP — every app had the new default compiled in and ignored it.
    ///
    /// Storing the default alongside the value distinguishes the two cases a
    /// bare saved string cannot: a value the user typed (keep it — they meant
    /// it) from one that is merely a fossil of an older build (discard it).
    static let defaultsKeyBaseOrigin = "server.baseURL.defaultAtSave"

    /// This app's OWN keychain item, never shared with the other Barry apps.
    /// Two apps sharing one item would mean signing out of either silently
    /// signs out the other, and the secret is cheap to enter twice.
    static let keychainSecretKey = "rocks.barry.events.secret"

    static let defaultDeviceURL = "https://barry-mac.tail5cb2f2.ts.net:8443"
    static let simulatorURL = "http://127.0.0.1:9429"

    /// The one route on the API that answers without a secret. The probe uses
    /// it to tell "the server is not there" apart from "the secret is wrong".
    static let healthPath = "/health"

    static var platformDefault: ServerConfig {
        #if targetEnvironment(simulator)
        ServerConfig(baseURL: simulatorURL, secret: "")
        #else
        ServerConfig(baseURL: defaultDeviceURL, secret: "")
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
            return ServerConfig(baseURL: args[i + 1], secret: secret)
        }

        let d = UserDefaults.standard
        var c = platformDefault
        c.baseURL = resolveBaseURL(
            saved: d.string(forKey: defaultsKeyBase),
            savedUnderDefault: d.string(forKey: defaultsKeyBaseOrigin),
            currentDefault: c.baseURL
        )
        c.secret = Keychain.read(key: keychainSecretKey) ?? ""
        return c
    }

    /// Which base URL wins: the saved one, or the shipped default.
    ///
    /// Pure so the rule can be tested without touching `UserDefaults`, which is
    /// process-wide state that a test cannot set without affecting the app.
    ///
    /// - Parameter savedUnderDefault: the shipped default at the time `saved`
    ///   was written. `nil` means the value predates this bookkeeping.
    static func resolveBaseURL(
        saved: String?,
        savedUnderDefault: String?,
        currentDefault: String
    ) -> String {
        guard let saved, !saved.isEmpty else { return currentDefault }

        // Written before this app recorded origins. It cannot be told apart
        // from a deliberate choice, so trust the default instead: a stale
        // fossil times out with no way for the user to know why, while a
        // genuine custom address is one visible edit away in Settings.
        guard let savedUnderDefault else { return currentDefault }

        // The saved value IS the default it was saved under — the user never
        // chose it, they just inherited whatever shipped. A newer default
        // supersedes it.
        if saved == savedUnderDefault { return currentDefault }

        // Saved differs from the default in force at the time, so the user
        // typed it. Their choice outranks a new default.
        return saved
    }

    func save() {
        UserDefaults.standard.set(baseURL, forKey: Self.defaultsKeyBase)
        // Stamp the default this was saved against, so a later build can tell
        // an inherited value from a chosen one.
        UserDefaults.standard.set(Self.platformDefault.baseURL, forKey: Self.defaultsKeyBaseOrigin)
        if secret.isEmpty {
            Keychain.delete(key: Self.keychainSecretKey)
        } else {
            Keychain.write(key: Self.keychainSecretKey, value: secret)
        }
    }

    /// Build a request for an API path, applying auth.
    func request(path: String, query: [URLQueryItem] = []) -> URLRequest? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url)
        apply(to: &req)
        return req
    }

    /// `packages/auth` accepts the secret as either `x-barry-secret` or
    /// `Authorization: Bearer`. The header is the simpler of the two — no
    /// scheme prefix to get wrong — so that is what this sends.
    func apply(to req: inout URLRequest) {
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
