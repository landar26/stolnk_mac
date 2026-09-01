import CryptoKit
import XCTest

@testable import StolnkCore

/**
 Cross-language interoperability.

 These are the tests that matter most in this package. A mismatch between
 WebCrypto's framing and CryptoKit's does not produce a crash or a compile
 error — it produces files that upload successfully and cannot be opened. So
 both directions are checked against vectors the browser generated: Swift must
 decrypt what JavaScript sealed, and Swift's own encryption must reproduce
 JavaScript's ciphertext byte for byte.
 */
final class CryptoBoxTests: XCTestCase {
	private var root: Vectors.Root!
	private var contentKey: SymmetricKey!

	override func setUpWithError() throws {
		root = try Vectors.load()

		let privateKey = try P256.KeyAgreement.PrivateKey(
			rawRepresentation: XCTUnwrap(Base64URL.decode(root.recipient.private_raw)))
		let kek = try CryptoBox.deriveKEK(
			ephemeralPublicKey: XCTUnwrap(Base64URL.decode(root.envelope.eph_pub)),
			privateKey: .software(privateKey)
		)
		contentKey = try CryptoBox.unwrapContentKey(
			wrappedKey: XCTUnwrap(Base64URL.decode(root.envelope.wrapped_key)),
			keyIV: XCTUnwrap(Base64URL.decode(root.envelope.key_iv)),
			kek: kek
		)
	}

	func testHKDFAndUnwrapMatchTheBrowser() throws {
		let raw = contentKey.withUnsafeBytes { Data($0) }
		XCTAssertEqual(
			Base64URL.encode(raw),
			root.envelope.expected_content_key,
			"ECDH/HKDF disagreement — check the info string and the shared-secret encoding"
		)
	}

	func testFilenameDecrypts() throws {
		let name = try CryptoBox.decryptName(
			encName: XCTUnwrap(Base64URL.decode(root.filename.enc_name)),
			nameIV: XCTUnwrap(Base64URL.decode(root.filename.name_iv)),
			contentKey: contentKey
		)
		XCTAssertEqual(name, root.filename.plaintext)
	}

	func testDecryptsEveryVector() throws {
		let prefix = try XCTUnwrap(Base64URL.decode(root.envelope.nonce_prefix))

		for vector in root.vectors {
			let ciphertext = try XCTUnwrap(Base64URL.decode(vector.ciphertext))
			let expected = Vectors.plaintext(for: vector)
			XCTAssertEqual(expected.count, vector.size, "\(vector.label): seed produced wrong length")
			XCTAssertEqual(
				ciphertext.count,
				CryptoBox.cipherSize(forPlaintextSize: vector.size),
				"\(vector.label): ciphertext length disagrees with the framing rule"
			)

			var assembled = Data()
			var offset = 0
			let fileID = CryptoBox.fileIDBytes(vector.file_id)
			for index in 0..<vector.chunk_count {
				let plainLength =
					index == vector.chunk_count - 1
					? vector.size - index * CryptoBox.chunkSize
					: CryptoBox.chunkSize
				let length = max(0, plainLength) + CryptoBox.tagSize
				let slice = ciphertext.subdata(in: offset..<(offset + length))
				assembled.append(
					try CryptoBox.decryptChunk(
						slice,
						index: index,
						total: vector.chunk_count,
						fileID: fileID,
						noncePrefix: prefix,
						contentKey: contentKey
					))
				offset += length
			}

			XCTAssertEqual(assembled, expected, "\(vector.label): plaintext mismatch")
			XCTAssertEqual(
				Data(SHA256.hash(data: assembled)).hexString,
				vector.plain_sha256,
				"\(vector.label): digest mismatch"
			)
		}
	}

	/// AES-GCM is deterministic given key, nonce, AAD and plaintext, so
	/// re-encrypting must reproduce the browser's bytes exactly. This is what
	/// proves the nonce layout and AAD byte order agree, rather than merely that
	/// Swift can undo its own work.
	func testEncryptionReproducesBrowserCiphertext() throws {
		let prefix = try XCTUnwrap(Base64URL.decode(root.envelope.nonce_prefix))

		for vector in root.vectors {
			let plaintext = Vectors.plaintext(for: vector)
			let fileID = CryptoBox.fileIDBytes(vector.file_id)
			var produced = Data()
			for index in 0..<vector.chunk_count {
				let start = index * CryptoBox.chunkSize
				let end = min(plaintext.count, start + CryptoBox.chunkSize)
				let chunk = start < end ? plaintext.subdata(in: start..<end) : Data()
				produced.append(
					try CryptoBox.encryptChunk(
						chunk,
						index: index,
						total: vector.chunk_count,
						fileID: fileID,
						noncePrefix: prefix,
						contentKey: contentKey
					))
			}
			XCTAssertEqual(
				Base64URL.encode(produced), vector.ciphertext, "\(vector.label): ciphertext mismatch")
		}
	}

	func testTamperedChunkIsRejected() throws {
		let prefix = try XCTUnwrap(Base64URL.decode(root.envelope.nonce_prefix))
		let ciphertext = try XCTUnwrap(Base64URL.decode(root.tampered.ciphertext))

		XCTAssertThrowsError(
			try CryptoBox.decryptChunk(
				ciphertext,
				index: 0,
				total: 1,
				fileID: CryptoBox.fileIDBytes(root.tampered.file_id),
				noncePrefix: prefix,
				contentKey: contentKey
			)
		) { error in
			guard case CryptoBox.Failure.chunkAuthenticationFailed = error else {
				return XCTFail("expected an authentication failure, got \(error)")
			}
		}
	}

	/// The AAD carries the chunk index, so a chunk replayed into another slot
	/// must fail even though its own tag is intact.
	func testReorderedChunkIsRejected() throws {
		let prefix = try XCTUnwrap(Base64URL.decode(root.envelope.nonce_prefix))
		let vector = try XCTUnwrap(root.vectors.first { $0.label == "multi-chunk" })
		let ciphertext = try XCTUnwrap(Base64URL.decode(vector.ciphertext))
		let first = ciphertext.prefix(CryptoBox.chunkSize + CryptoBox.tagSize)

		XCTAssertThrowsError(
			try CryptoBox.decryptChunk(
				Data(first),
				index: 1,
				total: vector.chunk_count,
				fileID: CryptoBox.fileIDBytes(vector.file_id),
				noncePrefix: prefix,
				contentKey: contentKey
			)
		)
	}

	/// The AAD also carries the total count, so a truncated stream cannot be
	/// passed off as a complete shorter one.
	func testTruncatedStreamIsRejected() throws {
		let prefix = try XCTUnwrap(Base64URL.decode(root.envelope.nonce_prefix))
		let vector = try XCTUnwrap(root.vectors.first { $0.label == "multi-chunk" })
		let ciphertext = try XCTUnwrap(Base64URL.decode(vector.ciphertext))
		let first = ciphertext.prefix(CryptoBox.chunkSize + CryptoBox.tagSize)

		XCTAssertThrowsError(
			try CryptoBox.decryptChunk(
				Data(first),
				index: 0,
				total: 1,
				fileID: CryptoBox.fileIDBytes(vector.file_id),
				noncePrefix: prefix,
				contentKey: contentKey
			)
		)
	}

	func testFramingArithmetic() {
		XCTAssertEqual(CryptoBox.chunkCount(forPlaintextSize: 0), 1)
		XCTAssertEqual(CryptoBox.cipherSize(forPlaintextSize: 0), 16)
		XCTAssertEqual(CryptoBox.chunkCount(forPlaintextSize: CryptoBox.chunkSize), 1)
		XCTAssertEqual(CryptoBox.chunkCount(forPlaintextSize: CryptoBox.chunkSize + 1), 2)
		XCTAssertEqual(
			CryptoBox.cipherSize(forPlaintextSize: CryptoBox.chunkSize + 1),
			CryptoBox.chunkSize + 1 + 32
		)
	}
}
