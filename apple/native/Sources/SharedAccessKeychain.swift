import Foundation
import Security
import SwiftUI

struct SharedAccessCredential: Codable, Equatable {
    let link: String
    let password: String?
}

protocol SharedAccessStorage {
    func read() throws -> SharedAccessCredential?
    func write(_ value: SharedAccessCredential) throws
    func remove() throws
}

struct SharedAccessKeychain: SharedAccessStorage {
    let account: String
    init(account: String = "shared-portal") { self.account = account }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.krafify.vetaretro.shared-access",
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func read() throws -> SharedAccessCredential? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DirectCloudError.keychain }
        return try JSONDecoder().decode(SharedAccessCredential.self, from: data)
    }
    func write(_ value: SharedAccessCredential) throws {
        _ = try KrafifySharedConnection.validateLink(value.link)
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; attributes.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw DirectCloudError.keychain }
        } else if status != errSecSuccess { throw DirectCloudError.keychain }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DirectCloudError.keychain }
    }
}

@MainActor final class SharedAccessForm: ObservableObject {
    @Published var address = ""
    @Published var password = ""
    @Published var remember = true
    @Published private(set) var hasSavedAccess = false
    private let storage: any SharedAccessStorage
    init(storage: any SharedAccessStorage = SharedAccessKeychain()) { self.storage = storage }
    func restore() throws {
        guard let saved = try storage.read() else { hasSavedAccess = false; return }
        _ = try KrafifySharedConnection.validateLink(saved.link)
        address = saved.link; password = saved.password ?? ""; remember = true; hasSavedAccess = true
    }
    func forget() throws {
        try storage.remove()
        address = ""; password = ""; hasSavedAccess = false
    }
    func authenticate(http: DirectCloudHTTP = DirectCloudURLSession(allowDownloadRedirects: false)) async throws -> KrafifySharedConnection {
        let link = try KrafifySharedConnection.validateLink(address).absoluteString
        let submitted = password, shouldRemember = remember
        let source = KrafifySharedConnection(http: http)
        do {
            try await source.login(link: link, password: submitted)
            try Task.checkCancellation()
        } catch {
            if case KrafifySharedError.password = error {
                password = ""
                // Forget only the rejected saved password, retaining the address for replacement.
                if let saved = try storage.read(), saved.link == link, saved.password == submitted {
                    try storage.write(.init(link: link, password: nil))
                }
            }
            throw error
        }
        if shouldRemember { try storage.write(.init(link: link, password: submitted)); hasSavedAccess = true }
        else { try storage.remove(); hasSavedAccess = false }
        return source
    }
}
