import Foundation
import Security

/// Minimal generic-password wrapper. Only ever holds key blobs and the device
/// session token — never anything belonging to a sender.
public enum Keychain {
	/// The keychain service attribute — a storage key, not the bundle
	/// identifier, despite having once been given the same string. Changing it
	/// orphans every existing device's identity: the keys become unfindable,
	/// the Mac cannot re-authenticate, and its name stays taken on the server.
	/// So it stays as it is even when the app is rebranded.
	public static let service = "com.stolnk.mac"

	/// A miss and a refusal are different facts. On the file-backed keychain a
	/// denied access prompt comes back as an error, not as "no such item", and a
	/// caller that flattened both to nil would read a denial as a first launch.
	public enum ReadResult: Sendable {
		case found(Data)
		case missing
		case failed(OSStatus)
	}

	public static func read(_ account: String) -> ReadResult {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		var item: CFTypeRef?
		switch SecItemCopyMatching(query as CFDictionary, &item) {
		case errSecSuccess:
			guard let data = item as? Data else { return .failed(errSecInternalError) }
			return .found(data)
		case errSecItemNotFound:
			return .missing
		case let status:
			return .failed(status)
		}
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
