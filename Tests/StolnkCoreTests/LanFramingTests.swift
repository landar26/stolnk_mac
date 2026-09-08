import CryptoKit
import XCTest

@testable import StolnkCore

/**
 PRD 8.2 — the wire contract between the send page's DataChannel writer
 (`react-app/lib/lan-send.ts`) and the sink that receives it.

 There is no separate LAN format to test: the ciphertext is the same stream the
 relay carries (docs/wire-format.md), and `DecryptingSink` derives every chunk
 boundary from the file size alone. What *is* specific to this path, and what
 these tests pin, is the framing the browser applies on the way out — fixed
 64 KiB messages, which divide neither the 1 MiB + 16 chunk nor the file.

 That mismatch is the point. A frame almost never ends where a chunk ends, so
 the receiver must hold a partial chunk across messages, and the last frame of a
 file is a short one. Both are the cases a hand test would skip.
 */
final class LanFramingTests: XCTestCase {
	/// Mirrors `FRAME_SIZE` in `react-app/lib/lan-send.ts`. If one side changes,
	/// this is what should notice — the failure otherwise is a corrupt file, not
	/// a failed request.
	private static let frameSize = 64 * 1024

	private var directory: URL!

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("stolnk-lan-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directory)
	}

	private func fixture(size: Int, digest: String) throws -> (DecryptingSink, SymmetricKey, PendingFile) {
		let key = SymmetricKey(size: .bits256)
		let file = PendingFile(
			fileID: Base64URL.encode(Data((0..<16).map { UInt8($0) })),
			transferID: "t",
			inboxID: "i",
			inboxName: "Inbox",
			encName: "",
			nameIV: "",
			size: size,
			cipherSize: CryptoBox.cipherSize(forPlaintextSize: size),
			noncePrefix: Base64URL.encode(Data([9, 8, 7, 6])),
			wrappedKey: "",
			keyIV: "",
			ephPub: "",
			plainSHA256: digest,
			createdAt: 0,
			expiresAt: 0
		)
		let sink = try DecryptingSink(
			file: file,
			contentKey: key,
			partURL: directory.appendingPathComponent("lan.part")
		)
		return (sink, key, file)
	}

	private func ciphertext(for plaintext: Data, key: SymmetricKey, file: PendingFile) throws -> Data {
		let total = CryptoBox.chunkCount(forPlaintextSize: plaintext.count)
		var out = Data()
		for index in 0..<total {
			let start = index * CryptoBox.chunkSize
			let end = min(plaintext.count, start + CryptoBox.chunkSize)
			let chunk = start < end ? plaintext.subdata(in: start..<end) : Data()
			out.append(
				try CryptoBox.encryptChunk(
					chunk,
					index: index,
					total: total,
					fileID: CryptoBox.fileIDBytes(file.fileID),
					noncePrefix: Base64URL.decode(file.noncePrefix)!,
					contentKey: key
				))
		}
		return out
	}

	/// Exactly what the browser puts on the channel: consecutive 64 KiB slices
	/// of the ciphertext stream, the last one short.
	private func frames(of ciphertext: Data) -> [Data] {
		stride(from: 0, to: ciphertext.count, by: Self.frameSize).map { offset in
			ciphertext.subdata(in: offset..<min(ciphertext.count, offset + Self.frameSize))
		}
	}

	/// Over 2 MiB, so the stream spans three chunks and ~35 frames and no frame
	/// boundary coincides with a chunk boundary.
	func testSixtyFourKilobyteFramesReassembleIntoTheFile() throws {
		let plaintext = Data((0..<2_300_000).map { UInt8($0 % 251) })
		let digest = Data(SHA256.hash(data: plaintext)).hexString
		let (sink, key, file) = try fixture(size: plaintext.count, digest: digest)
		let stream = try ciphertext(for: plaintext, key: key, file: file)

		let messages = frames(of: stream)
		XCTAssertGreaterThan(messages.count, 30, "the framing under test should span many messages")
		XCTAssertNotEqual(
			messages[0].count, CryptoBox.chunkSize + CryptoBox.tagSize,
			"a frame must not happen to be a whole chunk, or this proves nothing")

		for message in messages { try sink.consume(message) }
		try sink.finish(expecting: digest)

		let landed = try Data(contentsOf: sink.partURL)
		XCTAssertEqual(landed, plaintext)
	}

	/// A file smaller than one frame: the whole transfer is a single short
	/// message, which is the common case for a photo or a document.
	func testAFileSmallerThanOneFrameArrivesInOneMessage() throws {
		let plaintext = Data("局域网直传".utf8)
		let digest = Data(SHA256.hash(data: plaintext)).hexString
		let (sink, key, file) = try fixture(size: plaintext.count, digest: digest)
		let stream = try ciphertext(for: plaintext, key: key, file: file)

		XCTAssertEqual(frames(of: stream).count, 1)
		try sink.consume(stream)
		try sink.finish(expecting: digest)
		XCTAssertEqual(try Data(contentsOf: sink.partURL), plaintext)
	}

	/**
	 The failure that makes `ordered: true` non-negotiable.

	 SCTP can be told to deliver out of order, and if it were, this is what
	 would happen: not one damaged chunk, but every chunk from the swap onwards
	 failing its GCM tag, because the stream is unframed and the receiver counts
	 bytes to find boundaries. `LanReceiver` refuses a channel whose `isOrdered`
	 is false for exactly this reason.
	 */
	func testSwappedFramesAreRejectedRatherThanLanded() throws {
		let plaintext = Data((0..<2_300_000).map { UInt8($0 % 251) })
		let digest = Data(SHA256.hash(data: plaintext)).hexString
		let (sink, key, file) = try fixture(size: plaintext.count, digest: digest)
		let stream = try ciphertext(for: plaintext, key: key, file: file)

		var messages = frames(of: stream)
		messages.swapAt(20, 21)

		XCTAssertThrowsError(
			try {
				for message in messages { try sink.consume(message) }
				try sink.finish(expecting: digest)
			}())
		sink.abandon()
		XCTAssertFalse(FileManager.default.fileExists(atPath: sink.partURL.path))
	}

	/// A channel that dies mid-file leaves nothing behind. On this path there is
	/// no R2 object to resume from, so the sender restarts over the relay — but
	/// only after this side has cleaned up (PRD 9.3).
	func testAnInterruptedChannelLeavesNoHalfFile() throws {
		let plaintext = Data((0..<2_300_000).map { UInt8($0 % 251) })
		let digest = Data(SHA256.hash(data: plaintext)).hexString
		let (sink, key, file) = try fixture(size: plaintext.count, digest: digest)
		let stream = try ciphertext(for: plaintext, key: key, file: file)

		for message in frames(of: stream).prefix(18) { try sink.consume(message) }
		XCTAssertThrowsError(try sink.finish(expecting: digest))
		sink.abandon()
		XCTAssertFalse(FileManager.default.fileExists(atPath: sink.partURL.path))
	}

	/// The digest arrives in `file.end`, after the bytes, because it is computed
	/// over the plaintext as it streams. A sender that reports the wrong one is
	/// refused even though every chunk authenticated.
	func testAWrongEndDigestIsRefusedAfterAPerfectStream() throws {
		let plaintext = Data((0..<300_000).map { UInt8($0 % 251) })
		let digest = Data(SHA256.hash(data: plaintext)).hexString
		let (sink, key, file) = try fixture(size: plaintext.count, digest: digest)
		let stream = try ciphertext(for: plaintext, key: key, file: file)

		for message in frames(of: stream) { try sink.consume(message) }
		XCTAssertThrowsError(try sink.finish(expecting: String(repeating: "0", count: 64)))
	}
}
