import CryptoKit
import Foundation

/// Loads `testdata/vectors.json`, which the browser sender generates via
/// `npm run vectors`. Keeping one set of vectors for both implementations is
/// the only practical way to be sure the Mac can open what the browser sealed.
enum Vectors {
	struct Root: Decodable {
		let kek_info: String
		let chunk_size: Int
		let recipient: Recipient
		let envelope: Envelope
		let filename: Filename
		let vectors: [Vector]
		let tampered: Tampered
	}

	struct Recipient: Decodable {
		let private_raw: String
		let public_raw: String
	}

	struct Envelope: Decodable {
		let wrapped_key: String
		let key_iv: String
		let eph_pub: String
		let nonce_prefix: String
		let expected_content_key: String
	}

	struct Filename: Decodable {
		let plaintext: String
		let enc_name: String
		let name_iv: String
	}

	struct Vector: Decodable {
		let label: String
		let file_id: String
		let size: Int
		let plaintext: String?
		let seed: String?
		let ciphertext: String
		let plain_sha256: String
		let chunk_count: Int
	}

	struct Tampered: Decodable {
		let from: String
		let file_id: String
		let size: Int
		let ciphertext: String
	}

	static let url: URL = {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()  // StolnkCoreTests
			.deletingLastPathComponent()  // Tests
			.deletingLastPathComponent()  // stolnk_mac
			.deletingLastPathComponent()  // repository root
			.appendingPathComponent("testdata/vectors.json")
	}()

	static func load() throws -> Root {
		let data = try Data(contentsOf: url)
		return try JSONDecoder().decode(Root.self, from: data)
	}

	/// Mirrors `seededBytes` in scripts/gen-vectors.ts so large plaintexts do not
	/// have to be stored: block n is SHA-256(utf8(seed) || uint32_be(n)).
	static func seededBytes(seed: String, length: Int) -> Data {
		var out = Data()
		out.reserveCapacity(length)
		var counter: UInt32 = 0
		let seedBytes = Data(seed.utf8)
		while out.count < length {
			var input = seedBytes
			input.append(counter.bigEndianBytesForTest)
			out.append(Data(SHA256.hash(data: input)))
			counter += 1
		}
		return out.prefix(length)
	}

	static func plaintext(for vector: Vector) -> Data {
		if let inline = vector.plaintext { return Base64URL.decode(inline) ?? Data() }
		guard let seed = vector.seed else { return Data() }
		return seededBytes(seed: seed, length: vector.size)
	}
}

import StolnkCore

extension UInt32 {
	var bigEndianBytesForTest: Data {
		var value = bigEndian
		return Data(bytes: &value, count: 4)
	}
}
