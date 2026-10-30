import Foundation
import CryptoKit
import Security
import AuthenticationServices
import UIKit

struct DirectCloudToken: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    static func decode(_ data: Data, previousRefresh: String? = nil, now: Date = Date()) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty,
              let type = object["token_type"] as? String, type.lowercased() == "bearer" else { throw DirectCloudError.invalidResponse }
        let seconds = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        guard seconds.isFinite, seconds > 0 else { throw DirectCloudError.invalidResponse }
        return .init(accessToken: access, refreshToken: object["refresh_token"] as? String ?? previousRefresh,
                     expiresAt: now.addingTimeInterval(seconds))
    }
}

enum DirectCloudKeychain {
    private static let service = "com.krafify.vetaretro.cloud.oauth"
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false]
    }
    static func read(_ key: String) throws -> DirectCloudToken? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw DirectCloudError.keychain }
        return try JSONDecoder().decode(DirectCloudToken.self, from: data)
    }
    static func write(_ token: DirectCloudToken, key: String) throws {
        let data = try JSONEncoder().encode(token)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(key); q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw DirectCloudError.keychain }
        } else if status != errSecSuccess { throw DirectCloudError.keychain }
    }
    static func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DirectCloudError.keychain }
    }
}

struct DirectCloudPKCE {
    let verifier: String
    let state: String
    static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DirectCloudError.invalidCallback }
        return base64URL(Data(bytes))
    }
    init() throws { verifier = try Self.random(); state = try Self.random() }
    init(verifier: String, state: String) { self.verifier = verifier; self.state = state }
    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    func authorizationURL(_ config: DirectCloudConfiguration) -> URL {
        var c = URLComponents(string: config.provider.authorizationEndpoint)!
        var fields = ["client_id": config.clientID, "redirect_uri": config.redirectURI, "response_type": "code",
                      "scope": config.provider.scopes, "state": state, "code_challenge": challenge, "code_challenge_method": "S256"]
        switch config.provider {
        case .google: fields["access_type"] = "offline"; fields["prompt"] = "consent select_account"
        case .onedrive: fields["prompt"] = "select_account"
        case .dropbox: fields["token_access_type"] = "offline"
        }
        c.queryItems = fields.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        return c.url!
    }
    func code(from url: URL, config: DirectCloudConfiguration) throws -> String {
        guard let expected = URLComponents(string: config.redirectURI), let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme, actual.host == expected.host, actual.path == expected.path,
              actual.port == expected.port, actual.user == nil, actual.password == nil, actual.fragment == nil else { throw DirectCloudError.invalidCallback }
        let items = actual.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states.first?.value == state else { throw DirectCloudError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw DirectCloudError.permission }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else { throw DirectCloudError.invalidCallback }
        return code
    }
}

@MainActor final class DirectCloudAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor! }
    func cancel() { session?.cancel() }
    func connect(_ config: DirectCloudConfiguration, http: DirectCloudHTTP = DirectCloudURLSession()) async throws -> DirectCloudToken {
        guard session == nil else { throw DirectCloudError.invalidCallback }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else { throw DirectCloudError.invalidCallback }
        anchor = window
        let pkce = try DirectCloudPKCE()
        defer { session = nil; anchor = nil }
        let callback: URL = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let auth = ASWebAuthenticationSession(url: pkce.authorizationURL(config), callbackURLScheme: config.callbackScheme) { url, error in
                    if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { continuation.resume(throwing: CancellationError()) }
                    else if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: DirectCloudError.invalidCallback) }
                }
                auth.presentationContextProvider = self
                auth.prefersEphemeralWebBrowserSession = true
                session = auth
                if !auth.start() { continuation.resume(throwing: DirectCloudError.invalidCallback) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
        try Task.checkCancellation()
        let code = try pkce.code(from: callback, config: config)
        var req = URLRequest(url: URL(string: config.provider.tokenEndpoint)!)
        req.httpMethod = "POST"; req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = DirectCloudAPI.form(["grant_type": "authorization_code", "client_id": config.clientID,
            "redirect_uri": config.redirectURI, "code": code, "code_verifier": pkce.verifier])
        let (data, response) = try await http.data(req)
        guard response.statusCode == 200 else { throw DirectCloudError.reconnect }
        let token = try DirectCloudToken.decode(data)
        try Task.checkCancellation()
        try DirectCloudKeychain.write(token, key: config.credentialKey)
        return token
    }
}
