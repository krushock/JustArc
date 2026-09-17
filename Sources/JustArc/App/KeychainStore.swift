import Foundation
import Security

/// Optional per-archive password storage. Off by default; the browser and the
/// Quick Extract prompt both offer it as a checkbox.
enum KeychainStore {
    private static let service = "com.justarc.archive-password"

    private static func account(for archive: URL) -> String {
        archive.standardizedFileURL.path
    }

    static func password(for archive: URL) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: archive),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &item) {
            SecItemCopyMatching(query as CFDictionary, $0)
        }
        query.removeAll()
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(password: String, for archive: URL) -> Bool {
        guard !password.isEmpty else { return false }
        let account = account(for: archive)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrLabel as String] = "JustArc — \(archive.lastPathComponent)"
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func remove(for archive: URL) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: archive),
        ]
        SecItemDelete(query as CFDictionary)
    }
}
