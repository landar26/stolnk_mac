import Foundation
import Security

/// Minimal generic-password wrapper. Only ever holds key blobs and the device
/// session token — never anything belonging to a sender.
public enum Keychain {
	public static let service = "com.stolnk.mac"

	public static func read(_ account: String) -> Data? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		var item: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
		return item as? Data
	}

	@discardableResult
	public static func write(_ account: String, _ data: Data) -> Bool {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		let attributes: [String: Any] = [
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
		]
		let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		if status == errSecSuccess { return true }
		if status == errSecItemNotFound {
			return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
		}
		return false
	}

	public static func delete(_ account: String) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		SecItemDelete(query as CFDictionary)
	}
}
