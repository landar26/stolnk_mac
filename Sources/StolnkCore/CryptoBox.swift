import CryptoKit
import Foundation

/**
 The receiving half of the envelope in `docs/wire-format.md`.

 Every constant here has a counterpart in `src/shared/envelope.ts`, and
 `CryptoBoxTests` checks both against the same vectors. Getting the nonce
 layout or the AAD byte order subtly wrong would produce files that upload
 fine and fail to open, which is exactly the kind of bug that only shows up
 once someone has lost something.
 */
public enum CryptoBox {
	public static let chunkSize = 1024 * 1024
	public static let tagSize = 16
	public static let kekInfo = Data("stolnk/v1/kek".utf8)

	public enum Failure: Error, LocalizedError {
		case malformedKey
		case unwrapFailed
		case chunkAuthenticationFailed(index: Int)
		case digestMismatch

		public var errorDescription: String? {
			switch self {
			case .malformedKey: "The sender's key material was malformed."
			case .unwrapFailed: "This file was not encrypted for this Mac."
			case .chunkAuthenticationFailed(let index):
				"The file was altered in transit (chunk \(index) failed its check)."
			case .digestMismatch: "The file did not match its checksum."
			}
		}
	}

	public static func chunkCount(forPlaintextSize size: Int) -> Int {
		max(1, Int((Double(size) / Double(chunkSize)).rounded(.up)))
	}

	public static func cipherSize(forPlaintextSize size: Int) -> Int {
		size + chunkCount(forPlaintextSize: size) * tagSize
	}

	/// 4-byte per-file prefix followed by the big-endian chunk index.
	public static func nonce(prefix: Data, index: Int) -> Data {
		var bytes = Data(prefix.prefix(4))
		bytes.append(UInt64(index).bigEndianBytes)
		return bytes
	}

	/// Binds a chunk to its position and to the total count, so neither
	/// reordering nor truncation survives authentication.
	public static func aad(fileID: Data, index: Int, total: Int) -> Data {
		var bytes = Data(fileID.prefix(16))
		if bytes.count < 16 { bytes.append(Data(repeating: 0, count: 16 - bytes.count)) }
		bytes.append(UInt32(index).bigEndianBytes)
		bytes.append(UInt32(total).bigEndianBytes)
		return bytes
	}

	/// `file_id` travels as base64url text but is authenticated as raw bytes.
	public static func fileIDBytes(_ fileID: String) -> Data {
		guard var bytes = Base64URL.decode(fileID) else { return Data(repeating: 0, count: 16) }
		if bytes.count > 16 { bytes = bytes.prefix(16) }
		if bytes.count < 16 { bytes.append(Data(repeating: 0, count: 16 - bytes.count)) }
		return bytes
	}

	/// ECDH against the Secure Enclave key, then HKDF, exactly as WebCrypto does it.
	public static func deriveKEK(
		ephemeralPublicKey: Data,
		privateKey: DeviceIdentity.AgreementKey
	) throws -> SymmetricKey {
		guard let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKey)
		else { throw Failure.malformedKey }
		let shared = try privateKey.sharedSecret(with: publicKey)
		return shared.hkdfDerivedSymmetricKey(
			using: SHA256.self,
			salt: Data(),
			sharedInfo: kekInfo,
			outputByteCount: 32
		)
	}

	/**
	 Unwraps the content key.

	 WebCrypto returns AES-GCM output as `ciphertext || tag`, while CryptoKit's
	 `combined` form is `nonce || ciphertext || tag`, so the sealed box is
	 assembled from its parts rather than parsed.
	 */
	public static func unwrapContentKey(
		wrappedKey: Data,
		keyIV: Data,
		kek: SymmetricKey
	) throws -> SymmetricKey {
		guard wrappedKey.count > tagSize else { throw Failure.unwrapFailed }
		let split = wrappedKey.count - tagSize
		guard
			let nonce = try? AES.GCM.Nonce(data: keyIV),
			let box = try? AES.GCM.SealedBox(
				nonce: nonce,
				ciphertext: wrappedKey.prefix(split),
				tag: wrappedKey.suffix(tagSize)
			),
			let raw = try? AES.GCM.open(box, using: kek)
		else { throw Failure.unwrapFailed }
		return SymmetricKey(data: raw)
	}

	public static func decryptName(
		encName: Data,
		nameIV: Data,
		contentKey: SymmetricKey
	) throws -> String {
		guard encName.count > tagSize else { throw Failure.unwrapFailed }
		let split = encName.count - tagSize
		guard
			let nonce = try? AES.GCM.Nonce(data: nameIV),
			let box = try? AES.GCM.SealedBox(
				nonce: nonce,
				ciphertext: encName.prefix(split),
				tag: encName.suffix(tagSize)
			),
			let plain = try? AES.GCM.open(box, using: contentKey),
			let name = String(data: plain, encoding: .utf8)
		else { throw Failure.unwrapFailed }
		return name
	}

	public static func decryptChunk(
		_ ciphertext: Data,
		index: Int,
		total: Int,
		fileID: Data,
		noncePrefix: Data,
		contentKey: SymmetricKey
	) throws -> Data {
		guard ciphertext.count >= tagSize else { throw Failure.chunkAuthenticationFailed(index: index) }
		let split = ciphertext.count - tagSize
		guard
			let nonce = try? AES.GCM.Nonce(data: nonce(prefix: noncePrefix, index: index)),
			let box = try? AES.GCM.SealedBox(
				nonce: nonce,
				ciphertext: ciphertext.prefix(split),
				tag: ciphertext.suffix(tagSize)
			),
			let plain = try? AES.GCM.open(
				box,
				using: contentKey,
				authenticating: aad(fileID: fileID, index: index, total: total)
			)
		else { throw Failure.chunkAuthenticationFailed(index: index) }
		return plain
	}

	/// Test-only mirror of the browser's encryption, so the vectors can be
	/// checked in both directions rather than only on decrypt.
	public static func encryptChunk(
		_ plaintext: Data,
		index: Int,
		total: Int,
		fileID: Data,
		noncePrefix: Data,
		contentKey: SymmetricKey
	) throws -> Data {
		let box = try AES.GCM.seal(
			plaintext,
			using: contentKey,
			nonce: try AES.GCM.Nonce(data: nonce(prefix: noncePrefix, index: index)),
			authenticating: aad(fileID: fileID, index: index, total: total)
		)
		return box.ciphertext + box.tag
	}
}
