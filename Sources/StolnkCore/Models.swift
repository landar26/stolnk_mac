import Foundation

public struct InboxSummary: Codable, Identifiable, Sendable, Hashable {
	public let inboxID: String
	/// The path under the name. Every link has one.
	public let slug: String
	/// The whole address. The server builds it, so nothing here has to.
	public let url: String
	public let displayName: String
	public let paused: Bool
	public let sizeLimit: Int
	public let hasPassword: Bool

	public var id: String { inboxID }

	enum CodingKeys: String, CodingKey {
		case inboxID = "inbox_id"
		case slug
		case url
		case displayName = "display_name"
		case paused
		case sizeLimit = "size_limit"
		case hasPassword = "has_password"
	}
}

public struct ShareSummary: Codable, Identifiable, Sendable, Hashable {
	public let shareID: String
	public let code: String
	public let url: String
	public let filename: String
	public let size: Int
	public let sha256: String?
	public let maxDownloads: Int?
	public let downloads: Int
	public let downloadsLeft: Int?
	public let state: String
	public let paused: Bool
	public let hasPassword: Bool
	public let createdAt: Double
	public let expiresAt: Double
	public let lastDownloadAt: Double?

	public var id: String { shareID }
	/// A stranger holding the URL gets the file right now.
	public var isLive: Bool { state == "ready" && !paused && expiresAt > Date().timeIntervalSince1970 * 1000 }
	/// The link has not ended — it may still be paused. This is what can be
	/// repathed, revoked or resumed, and it is deliberately wider than `isLive`:
	/// a paused link is stopped, not finished, and locking its controls would
	/// leave the only way out of a pause being to destroy the link.
	public var isActive: Bool { state == "ready" && expiresAt > Date().timeIntervalSince1970 * 1000 }

	enum CodingKeys: String, CodingKey {
		case shareID = "share_id", code, url, filename, size, sha256
		case maxDownloads = "max_downloads"
		case downloads
		case downloadsLeft = "downloads_left"
		case state, paused
		case hasPassword = "has_password"
		case createdAt = "created_at"
		case expiresAt = "expires_at"
		case lastDownloadAt = "last_download_at"
	}
}

public struct ShareHandle: Codable, Sendable, Hashable {
	public let shareID: String
	public let code: String
	public let url: String
	public let token: String
	public let partSize: Int
	public let partCount: Int
	public let expiresAt: Double

	enum CodingKeys: String, CodingKey {
		case shareID = "share_id", code, url, token
		case partSize = "part_size"
		case partCount = "part_count"
		case expiresAt = "expires_at"
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

/// What the device is entitled to, and what it has spent (PRD 16.1).
///
/// The server is the authority: nothing here is derived on this side, and the
/// app never decides for itself that it is Pro. That matters because the
/// alternative — a licence check the client performs — is a licence check the
/// client can be patched out of.
public struct PlanState: Codable, Sendable, Equatable {
	public struct License: Codable, Sendable, Equatable {
		public let seats: Int
		public let seatsUsed: Int
		public let status: String

		enum CodingKeys: String, CodingKey {
			case seats
			case seatsUsed = "seats_used"
			case status
		}
	}

	public let tier: String
	public let relayUsed: Int
	public let relayLimit: Int
	public let license: License?

	public var isPro: Bool { tier == "pro" }

	/// 0...1, clamped. Used for the allowance bar in Settings.
	public var relayFraction: Double {
		guard relayLimit > 0 else { return 0 }
		return min(1, Double(relayUsed) / Double(relayLimit))
	}

	public var relayExhausted: Bool { relayUsed >= relayLimit }

	enum CodingKeys: String, CodingKey {
		case tier
		case relayUsed = "relay_used"
		case relayLimit = "relay_limit"
		case license
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

	/// PRD 16 — Pro would lift this. Distinct from `isQuota`, which means
	/// "waiting is the only option": these two want opposite screens, and the
	/// difference is the whole reason the server uses two status codes.
	public var isUpgradeRequired: Bool { code == "upgrade_required" }

	/// The licence exists but every seat is taken (PRD 16.1).
	public var isSeatsFull: Bool { code == "seats_full" }
	public var isUnknownLicense: Bool { code == "license_not_found" }
}
