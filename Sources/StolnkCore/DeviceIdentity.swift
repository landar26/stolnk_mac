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

		public var errorDescription: String? {
			"Could not save this Mac's device key to the keychain."
		}
	}

	private static let signingAccount = "device-signing-key"
	private static let agreementAccount = "device-agreement-key"
	private static let backingAccount = "device-key-backing"

	/// Loads the existing identity, or creates one on first launch.
	public static func loadOrCreate() throws -> DeviceIdentity {
		let wantsEnclave = SecureEnclave.isAvailable
		let storedBacking = Keychain.read(backingAccount).flatMap { String(data: $0, encoding: .utf8) }

		if let signingBlob = Keychain.read(signingAccount),
			let agreementBlob = Keychain.read(agreementAccount),
			let backing = storedBacking
		{
			if backing == "enclave", wantsEnclave {
				return DeviceIdentity(
					signing: .enclave(
						try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: signingBlob)),
					agreement: .enclave(
						try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: agreementBlob)),
					isEnclaveBacked: true
				)
			}
			if backing == "software" {
				return DeviceIdentity(
					signing: .software(try P256.Signing.PrivateKey(rawRepresentation: signingBlob)),
					agreement: .software(try P256.KeyAgreement.PrivateKey(rawRepresentation: agreementBlob)),
					isEnclaveBacked: false
				)
			}
		}

		if wantsEnclave {
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

	/// Writing all three or none. A key that generated but did not persist would
	/// come back as a different device on the next launch, quietly orphaning the
	/// user's URL — so a failed write is an error, not something to shrug at.
	private static func persist(signing: Data, agreement: Data, backing: String) throws {
		guard
			Keychain.write(signingAccount, signing),
			Keychain.write(agreementAccount, agreement),
			Keychain.write(backingAccount, Data(backing.utf8))
		else {
			Keychain.delete(signingAccount)
			Keychain.delete(agreementAccount)
			Keychain.delete(backingAccount)
			throw Failure.couldNotPersist
		}
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
		Keychain.delete(signingAccount)
		Keychain.delete(agreementAccount)
		Keychain.delete(backingAccount)
	}
}
