import CryptoKit
import Foundation

/**
 Decrypts a ciphertext stream and lands it in the user's folder.

 The invariant is PRD 9.3 and 12.1: nothing partially written ever becomes
 visible. Plaintext accumulates in a `.part` file with 0600 permissions, and
 only after every chunk has authenticated and the whole-file SHA-256 matches
 does it get its real name. Any failure deletes the `.part` and lands nothing.
 */
public enum FileLanding {
	public enum Failure: Error, LocalizedError {
		case notADirectory(URL)
		case insufficientSpace(needed: Int, available: Int)
		case unexpectedTrailingBytes
		case incompleteStream(received: Int, expected: Int)

		public var errorDescription: String? {
			switch self {
			case .notADirectory(let url):
				"The folder \(url.path) is not available."
			case .insufficientSpace(let needed, let available):
				"Not enough disk space: \(needed) bytes needed, \(available) free."
			case .unexpectedTrailingBytes:
				"The sender's file was longer than it declared."
			case .incompleteStream(let received, let expected):
				"The transfer stopped early (\(received) of \(expected) bytes)."
			}
		}
	}

	/// PRD 13.4 — refuse rather than fill the disk. Includes headroom so the
	/// machine does not end up wedged at exactly zero free bytes.
	public static func checkSpace(for size: Int, in directory: URL) throws {
		let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
		guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
		let needed = Int64(size) + 256 * 1024 * 1024
		if available < needed {
			throw Failure.insufficientSpace(needed: Int(needed), available: Int(available))
		}
	}

	/**
	 PRD 12.3 — everything that lands gets quarantined.

	 Without this the app is a delivery channel that bypasses Gatekeeper: a
	 client could send an executable and it would launch without the "downloaded
	 from the internet" check. That is a line this product does not get to cross,
	 and it would also be noticed during notarisation.
	 */
	public static func applyQuarantine(to url: URL, agent: String = "Stolnk") {
		let flags = "0081"
		let timestamp = String(format: "%08x", Int(Date().timeIntervalSince1970))
		let value = "\(flags);\(timestamp);\(agent);\(UUID().uuidString)"
		let data = Array(value.utf8)
		_ = url.withUnsafeFileSystemRepresentation { path in
			setxattr(path, "com.apple.quarantine", data, data.count, 0, 0)
		}
	}

	public static func hasQuarantine(_ url: URL) -> Bool {
		url.withUnsafeFileSystemRepresentation { path in
			getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) > 0
		}
	}
}

/**
 Consumes ciphertext as it arrives and writes authenticated plaintext.

 Chunk boundaries are derived from the plaintext size rather than read from a
 header (see docs/wire-format.md), so this holds at most one chunk plus a
 partial one — memory stays flat whether the file is 1 KB or 20 GB, which is a
 stated acceptance requirement.
 */
/**
 Streaming decryption into a `.part` file.

 `@unchecked Sendable` with a real lock behind it, rather than a promise. Both
 transports hand this object across threads: the relay path drives it from
 URLSession's delegate queue, and the LAN path (PRD 8.2) fills it on libwebrtc's
 signalling thread and then finishes it from a Task. Neither ever calls in
 concurrently — the ciphertext is one ordered stream — but "never concurrently"
 is an argument about callers, and this holds the file handle, the running
 digest and the chunk cursor. The lock costs nothing next to AES-GCM and makes
 the guarantee structural.
 */
public final class DecryptingSink: @unchecked Sendable {
	public let partURL: URL
	private let lock = NSLock()
	private let contentKey: SymmetricKey
	private let fileIDBytes: Data
	private let noncePrefix: Data
	private let totalChunks: Int
	private let plaintextSize: Int
	private let handle: FileHandle

	private var buffer = Data()
	private var nextChunk = 0
	private var hasher = SHA256()
	private var _plaintextWritten = 0
	private var _ciphertextConsumed = 0
	public var plaintextWritten: Int { lock.withLock { _plaintextWritten } }
	public var ciphertextConsumed: Int { lock.withLock { _ciphertextConsumed } }

	public init(
		file: PendingFile,
		contentKey: SymmetricKey,
		partURL: URL,
		resumingFromChunk startChunk: Int = 0,
		existingHasher: SHA256? = nil
	) throws {
		self.partURL = partURL
		self.contentKey = contentKey
		self.fileIDBytes = CryptoBox.fileIDBytes(file.fileID)
		self.noncePrefix = Base64URL.decode(file.noncePrefix) ?? Data()
		self.totalChunks = CryptoBox.chunkCount(forPlaintextSize: file.size)
		self.plaintextSize = file.size
		self.nextChunk = startChunk
		if let existingHasher { self.hasher = existingHasher }

		if !FileManager.default.fileExists(atPath: partURL.path) {
			FileManager.default.createFile(
				atPath: partURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
		}
		self.handle = try FileHandle(forWritingTo: partURL)
		try self.handle.seekToEnd()
	}

	/// Ciphertext length of chunk `index`: full chunks carry 1 MiB plus a tag,
	/// the last carries whatever remains plus a tag.
	private func cipherLength(ofChunk index: Int) -> Int {
		let plain =
			index == totalChunks - 1
			? plaintextSize - index * CryptoBox.chunkSize
			: CryptoBox.chunkSize
		return max(0, plain) + CryptoBox.tagSize
	}

	public func consume(_ data: Data) throws {
		lock.lock()
		defer { lock.unlock() }
		buffer.append(data)
		_ciphertextConsumed += data.count

		while nextChunk < totalChunks {
			let needed = cipherLength(ofChunk: nextChunk)
			guard buffer.count >= needed else { break }

			let slice = buffer.prefix(needed)
			buffer.removeFirst(needed)

			let plain = try CryptoBox.decryptChunk(
				Data(slice),
				index: nextChunk,
				total: totalChunks,
				fileID: fileIDBytes,
				noncePrefix: noncePrefix,
				contentKey: contentKey
			)
			if !plain.isEmpty {
				handle.write(plain)
				hasher.update(data: plain)
				_plaintextWritten += plain.count
			}
			nextChunk += 1
		}

		if nextChunk >= totalChunks && !buffer.isEmpty {
			throw FileLanding.Failure.unexpectedTrailingBytes
		}
	}

	/// Verifies the whole-file digest. Per-chunk tags already prove each chunk is
	/// authentic; this catches assembly mistakes they cannot see, such as a part
	/// written twice or a stream that ended early.
	public func finish(expecting digest: String) throws {
		lock.lock()
		defer { lock.unlock() }
		try handle.close()
		guard nextChunk == totalChunks else {
			throw FileLanding.Failure.incompleteStream(
				received: _plaintextWritten, expected: plaintextSize)
		}
		guard _plaintextWritten == plaintextSize else {
			throw FileLanding.Failure.incompleteStream(
				received: _plaintextWritten, expected: plaintextSize)
		}
		let computed = Data(hasher.finalize()).hexString
		guard computed == digest else { throw CryptoBox.Failure.digestMismatch }
	}

	/// Ciphertext offset at which a retry should resume: the start of the first
	/// chunk not yet authenticated. Because the sink keeps its hasher and its
	/// open file handle across retries, a dropped connection costs at most one
	/// chunk rather than the whole file.
	public var resumeCiphertextOffset: Int {
		lock.lock()
		defer { lock.unlock() }
		return (0..<nextChunk).reduce(0) { $0 + cipherLength(ofChunk: $1) }
	}

	/// Discards a half-received chunk before resuming from `resumeCiphertextOffset`.
	public func discardPartialBuffer() {
		lock.lock()
		defer { lock.unlock() }
		buffer.removeAll(keepingCapacity: false)
	}

	public func abandon() {
		lock.lock()
		defer { lock.unlock() }
		try? handle.close()
		try? FileManager.default.removeItem(at: partURL)
	}
}
