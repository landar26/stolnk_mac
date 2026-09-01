import Foundation

public struct InboxSummary: Codable, Identifiable, Sendable, Hashable {
	public let inboxID: String
	/// The path under the name. Every link has one.
	public let slug: String
	/// The whole address. The server builds it, so nothing here has to.
	public let url: String
	public let displayName: String
	public let paused: Bool
	public let confirmFirst: Bool
	public let sizeLimit: Int
	public let hasPassword: Bool

	public var id: String { inboxID }

	enum CodingKeys: String, CodingKey {
		case inboxID = "inbox_id"
		case slug
		case url
		case displayName = "display_name"
		case paused
		case confirmFirst = "confirm_first"
		case sizeLimit = "size_limit"
		case hasPassword = "has_password"
	}
}

public struct RegistrationResult: Codable, Sendable {
	public let deviceID: String
	public let name: String
	public let token: String
	public let expiresAt: Double

	enum CodingKeys: String, CodingKey {
		case deviceID = "device_id"
		case name
		case token
		case expiresAt = "expires_at"
	}
}

public struct SessionToken: Codable, Sendable {
	public let token: String
	public let expiresAt: Double

	enum CodingKeys: String, CodingKey {
		case token
		case expiresAt = "expires_at"
	}
}

/// One file parked in the relay, with everything needed to decrypt it.
public struct PendingFile: Codable, Sendable, Identifiable, Hashable {
	public let fileID: String
	public let transferID: String
	public let inboxID: String
	public let inboxName: String
	public let senderSession: String
	public let needsConfirmation: Bool
	public let encName: String
	public let nameIV: String
	public let size: Int
	public let cipherSize: Int
	public let noncePrefix: String
	public let wrappedKey: String
	public let keyIV: String
	public let ephPub: String
	public let plainSHA256: String
	public let createdAt: Double
	public let expiresAt: Double

	public var id: String { fileID }

	enum CodingKeys: String, CodingKey {
		case fileID = "file_id"
		case transferID = "transfer_id"
		case inboxID = "inbox_id"
		case inboxName = "inbox_name"
		case senderSession = "sender_session"
		case needsConfirmation = "needs_confirmation"
		case encName = "enc_name"
		case nameIV = "name_iv"
		case size
		case cipherSize = "cipher_size"
		case noncePrefix = "nonce_prefix"
		case wrappedKey = "wrapped_key"
		case keyIV = "key_iv"
		case ephPub = "eph_pub"
		case plainSHA256 = "plain_sha256"
		case createdAt = "created_at"
		case expiresAt = "expires_at"
	}
}

public struct PendingResponse: Codable, Sendable {
	public let chunkSize: Int
	public let files: [PendingFile]

	enum CodingKeys: String, CodingKey {
		case chunkSize = "chunk_size"
		case files
	}
}

public struct APIError: Error, LocalizedError, Sendable {
	public let status: Int
	public let code: String
	public let message: String

	public var errorDescription: String? { message }

	/// The server refuses rather than bills when a quota runs out (PRD 8.6 #3),
	/// so this is a state the UI explains, not an error it reports.
	public var isQuota: Bool { code == "quota_exceeded" }
	public var isAuth: Bool { status == 401 }
}
