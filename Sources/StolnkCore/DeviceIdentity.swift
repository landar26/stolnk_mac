import CryptoKit
import Foundation

/**
 The device's two P-256 keypairs (PRD 9.1).

 Both live in the Secure Enclave where one is available. A Secure Enclave key
 hands back an opaque `dataRepresentation` blob that the app stores itself, so
 no keychain entitlement is needed and an ad-hoc signed development build takes
 the same path as a released one.

 Intel Macs and CI have no enclave, so there is a software fallback. It is
 strictly weaker — the private key exists in memory and in the keychain — and
 the app says so in Settings rather than quietly pretending otherwise.

 P-256 rather than Ed25519 is forced by the enclave, which does not support
 Ed25519. A non-exportable key is worth more here than the curve preference.
 */
public struct DeviceIdentity: Sendable {
	public enum SigningKey: Sendable {
		case enclave(SecureEnclave.P256.Signing.PrivateKey)
		case software(P256.Signing.PrivateKey)

		public var publicKey: P256.Signing.PublicKey {
			switch self {
			case .enclave(let key): key.publicKey
			case .software(let key): key.publicKey
			}
		}

		/// Raw `r || s`, which is what the Worker's WebCrypto verify expects.
		public func signature(for data: Data) throws -> Data {
			switch self {
			case .enclave(let key): try key.signature(for: data).rawRepresentation
			case .software(let key): try key.signature(for: data).rawRepresentation
			}
		}
	}

	public enum AgreementKey: Sendable {
		case enclave(SecureEnclave.P256.KeyAgreement.PrivateKey)
		case software(P256.KeyAgreement.PrivateKey)

		public var publicKey: P256.KeyAgreement.PublicKey {
			switch self {
			case .enclave(let key): key.publicKey
			case .software(let key): key.publicKey
			}
		}

		public func sharedSecret(with publicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
			switch self {
			case .enclave(let key): try key.sharedSecretFromKeyAgreement(with: publicKey)
			case .software(let key): try key.sharedSecretFromKeyAgreement(with: publicKey)
			}
		}
	}

	public let signing: SigningKey
	public let agreement: AgreementKey
	public let isEnclaveBacked: Bool

	public enum Failure: Error, LocalizedError {
		case couldNotPersist
		case keychainUnreadable(OSStatus)
		case corruptRecord

		public var errorDescription: String? {
			switch self {
			case .couldNotPersist:
				"Could not save this Mac's device key to the keychain."
			case .keychainUnreadable(let status):
				"Could not read this Mac's device key from the keychain (error \(status))."
			case .corruptRecord:
				"This Mac's device key record in the keychain is damaged."
			}
		}
	}

	/// Both keys and their backing live in a single keychain item. Three items
	/// meant three access prompts on every launch, and made persistence a
	/// three-writes-or-none dance; one item is one prompt and is atomic.
	private static let identityAccount = "device-identity"

	/// The pre-merge layout. Read once to fold into `identityAccount`, then gone.
	private static let legacySigningAccount = "device-signing-key"
	private static let legacyAgreementAccount = "device-agreement-key"
	private static let legacyBackingAccount = "device-key-backing"

	/// `Data` encodes to base64 through `JSONEncoder`, so the blobs survive the
	/// round trip without a hand-rolled container format.
	private struct Record: Codable {
		var backing: String
		var signing: Data
		var agreement: Data
	}

	/// Loads the existing identity, or creates one on first launch.
	public static func loadOrCreate() throws -> DeviceIdentity {
		if let record = try loadRecord(), let identity = try identity(from: record) {
			return identity
		}

		if SecureEnclave.isAvailable {
			let signing = try SecureEnclave.P256.Signing.PrivateKey()
			let agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey()
			try persist(
				signing: signing.dataRepresentation,
				agreement: agreement.dataRepresentation,
				backing: "enclave"
			)
			return DeviceIdentity(
				signing: .enclave(signing), agreement: .enclave(agreement), isEnclaveBacked: true)
		}

		let signing = P256.Signing.PrivateKey()
		let agreement = P256.KeyAgreement.PrivateKey()
		try persist(
			signing: signing.rawRepresentation,
			agreement: agreement.rawRepresentation,
			backing: "software"
		)
		return DeviceIdentity(
			signing: .software(signing), agreement: .software(agreement), isEnclaveBacked: false)
	}

	/// Nil where the stored keys cannot be used on this Mac — an enclave blob on
	/// a machine without an enclave is inert, and the caller has to start over.
	private static func identity(from record: Record) throws -> DeviceIdentity? {
		if record.backing == "enclave", SecureEnclave.isAvailable {
			return DeviceIdentity(
				signing: .enclave(
					try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: record.signing)),
				agreement: .enclave(
					try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: record.agreement)),
				isEnclaveBacked: true
			)
		}
		if record.backing == "software" {
			return DeviceIdentity(
				signing: .software(try P256.Signing.PrivateKey(rawRepresentation: record.signing)),
				agreement: .software(try P256.KeyAgreement.PrivateKey(rawRepresentation: record.agreement)),
				isEnclaveBacked: false
			)
		}
		return nil
	}

	/// Throws rather than reports "nothing stored" when the keychain refuses the
	/// read. Treating a denied prompt as a first launch would mint fresh keys
	/// over the top of perfectly good ones and orphan the user's URL.
	private static func loadRecord() throws -> Record? {
		switch Keychain.read(identityAccount) {
		case .found(let data):
			guard let record = try? JSONDecoder().decode(Record.self, from: data) else {
				throw Failure.corruptRecord
			}
			return record
		case .failed(let status):
			throw Failure.keychainUnreadable(status)
		case .missing:
			return try migrateLegacyRecord()
		}
	}

	/// Costs the old three prompts exactly once, on the first launch after the
	/// merge, and deletes the old items so it never happens again.
	private static func migrateLegacyRecord() throws -> Record? {
		guard let signing = try readLegacy(legacySigningAccount),
			let agreement = try readLegacy(legacyAgreementAccount),
			let backingData = try readLegacy(legacyBackingAccount),
			let backing = String(data: backingData, encoding: .utf8)
		else { return nil }

		let record = Record(backing: backing, signing: signing, agreement: agreement)
		try write(record)
		return record
	}

	private static func readLegacy(_ account: String) throws -> Data? {
		switch Keychain.read(account) {
		case .found(let data): return data
		case .missing: return nil
		case .failed(let status): throw Failure.keychainUnreadable(status)
		}
	}

	/// A key that generated but did not persist would come back as a different
	/// device on the next launch, quietly orphaning the user's URL — so a failed
	/// write is an error, not something to shrug at.
	private static func persist(signing: Data, agreement: Data, backing: String) throws {
		try write(Record(backing: backing, signing: signing, agreement: agreement))
	}

	private static func write(_ record: Record) throws {
		guard let blob = try? JSONEncoder().encode(record), Keychain.write(identityAccount, blob) else {
			Keychain.delete(identityAccount)
			throw Failure.couldNotPersist
		}
		// Leftovers from the old layout would be picked up as a second, stale
		// identity by anything still reading them. One item is the whole record.
		Keychain.delete(legacySigningAccount)
		Keychain.delete(legacyAgreementAccount)
		Keychain.delete(legacyBackingAccount)
	}

	/// Raw uncompressed points, `0x04 || X || Y`, as the API expects.
	public var signingPublicKeyEncoded: String {
		Base64URL.encode(signing.publicKey.x963Representation)
	}

	public var agreementPublicKeyEncoded: String {
		Base64URL.encode(agreement.publicKey.x963Representation)
	}

	public func sign(challenge: String) throws -> String {
		Base64URL.encode(try signing.signature(for: Data(challenge.utf8)))
	}

	/// Used when the user deliberately starts over. PRD 7.2 is explicit that
	/// enclave keys cannot be migrated: a new Mac means new keys, and anything
	/// still parked in the relay for the old ones can no longer be decrypted.
	public static func destroy() {
		Keychain.delete(identityAccount)
		Keychain.delete(legacySigningAccount)
		Keychain.delete(legacyAgreementAccount)
		Keychain.delete(legacyBackingAccount)
	}
}
