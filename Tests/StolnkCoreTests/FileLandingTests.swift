import CryptoKit
import XCTest

@testable import StolnkCore

final class FileLandingTests: XCTestCase {
	private var directory: URL!

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("stolnk-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directory)
	}

	/// PRD 12.3 — without this the app is a Gatekeeper bypass.
	func testQuarantineIsApplied() throws {
		let file = directory.appendingPathComponent("sample.txt")
		try Data("hello".utf8).write(to: file)
		XCTAssertFalse(FileLanding.hasQuarantine(file))
		FileLanding.applyQuarantine(to: file)
		XCTAssertTrue(FileLanding.hasQuarantine(file))
	}

	private func makeSink(size: Int, digest: String) throws -> (DecryptingSink, SymmetricKey, PendingFile) {
		let key = SymmetricKey(size: .bits256)
		let file = PendingFile(
			fileID: Base64URL.encode(Data((0..<16).map { UInt8($0) })),
			transferID: "t",
			inboxID: "i",
			inboxName: "Inbox",
			senderSession: "s",
			needsConfirmation: false,
			encName: "",
			nameIV: "",
			size: size,
			cipherSize: CryptoBox.cipherSize(forPlaintextSize: size),
			noncePrefix: Base64URL.encode(Data([1, 2, 3, 4])),
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
			partURL: directory.appendingPathComponent("work.part")
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

	/// Bytes arrive in whatever sizes the network chooses, never aligned to
	/// chunk boundaries, so the sink has to reassemble across arbitrary splits.
	func testReassemblesAcrossArbitraryPacketBoundaries() throws {
		let plaintext = Data((0..<200_000).map { UInt8($0 % 251) })
		let digest = Data(SHA256.hash(data: plaintext)).hexString
		let (sink, key, file) = try makeSink(size: plaintext.count, digest: digest)
		let stream = try ciphertext(for: plaintext, key: key, file: file)

		var offset = 0
		var step = 1
		while offset < stream.count {
			let length = min(step, stream.count - offset)
			try sink.consume(stream.subdata(in: offset..<(offset + length)))
			offset += length
			step = min(step * 3 + 7, 65536)
		}
		try sink.finish(expecting: digest)

		let landed = try Data(contentsOf: sink.partURL)
		XCTAssertEqual(landed, plaintext)
	}

	func testEmptyFileRoundTrips() throws {
		let digest = Data(SHA256.hash(data: Data())).hexString
		let (sink, key, file) = try makeSink(size: 0, digest: digest)
		try sink.consume(try ciphertext(for: Data(), key: key, file: file))
		try sink.finish(expecting: digest)
		XCTAssertEqual(try Data(contentsOf: sink.partURL).count, 0)
	}

	/// PRD 9.3 — a stream that stops early must fail rather than land a partial
	/// file that looks complete.
	func testTruncatedStreamFailsAndLeavesNothing() throws {
		let plaintext = Data(repeating: 7, count: 5000)
		let digest = Data(SHA256.hash(data: plaintext)).hexString
		let (sink, key, file) = try makeSink(size: plaintext.count, digest: digest)
		let stream = try ciphertext(for: plaintext, key: key, file: file)

		try sink.consume(stream.prefix(1000))
		XCTAssertThrowsError(try sink.finish(expecting: digest))
		sink.abandon()
		XCTAssertFalse(FileManager.default.fileExists(atPath: sink.partURL.path))
	}

	func testWrongDigestFails() throws {
		let plaintext = Data(repeating: 3, count: 1000)
		let realDigest = Data(SHA256.hash(data: plaintext)).hexString
		let (sink, key, file) = try makeSink(size: plaintext.count, digest: realDigest)
		try sink.consume(try ciphertext(for: plaintext, key: key, file: file))

		XCTAssertThrowsError(try sink.finish(expecting: String(repeating: "0", count: 64))) { error in
			guard case CryptoBox.Failure.digestMismatch = error else {
				return XCTFail("expected a digest mismatch, got \(error)")
			}
		}
	}

	func testExtraBytesAreRejected() throws {
		let plaintext = Data(repeating: 9, count: 100)
		let digest = Data(SHA256.hash(data: plaintext)).hexString
		let (sink, key, file) = try makeSink(size: plaintext.count, digest: digest)
		var stream = try ciphertext(for: plaintext, key: key, file: file)
		stream.append(Data(repeating: 0, count: 8))

		XCTAssertThrowsError(try sink.consume(stream))
	}

	/// The working file must not be readable by other users while in flight.
	func testPartFileIsPrivate() throws {
		let digest = Data(SHA256.hash(data: Data())).hexString
		let (sink, _, _) = try makeSink(size: 0, digest: digest)
		let attributes = try FileManager.default.attributesOfItem(atPath: sink.partURL.path)
		XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
	}

	/// Retrying mid-file resumes at the last authenticated chunk instead of
	/// starting the whole download again.
	func testResumeOffsetTracksCompletedChunks() throws {
		let plaintext = Data(repeating: 4, count: CryptoBox.chunkSize + 500)
		let digest = Data(SHA256.hash(data: plaintext)).hexString
		let (sink, key, file) = try makeSink(size: plaintext.count, digest: digest)
		let stream = try ciphertext(for: plaintext, key: key, file: file)

		XCTAssertEqual(sink.resumeCiphertextOffset, 0)
		try sink.consume(stream.prefix(CryptoBox.chunkSize + CryptoBox.tagSize))
		XCTAssertEqual(sink.resumeCiphertextOffset, CryptoBox.chunkSize + CryptoBox.tagSize)

		try sink.consume(stream.suffix(from: CryptoBox.chunkSize + CryptoBox.tagSize))
		try sink.finish(expecting: digest)
		XCTAssertEqual(try Data(contentsOf: sink.partURL), plaintext)
	}
}
