import CryptoKit
import Foundation

/// Callbacks into the UI. Closures rather than a delegate protocol so the app
/// layer can bridge to the main actor at the boundary.
public struct ReceiverEvents: Sendable {
	public var progress: @Sendable (String, Int, Int) -> Void
	public var landed: @Sendable ([LandedFile]) -> Void
	public var failed: @Sendable (PendingFile, String?, Error) -> Void
	public var inboxUnavailable: @Sendable (String, String) -> Void

	public init(
		progress: @escaping @Sendable (String, Int, Int) -> Void = { _, _, _ in },
		landed: @escaping @Sendable ([LandedFile]) -> Void = { _ in },
		failed: @escaping @Sendable (PendingFile, String?, Error) -> Void = { _, _, _ in },
		inboxUnavailable: @escaping @Sendable (String, String) -> Void = { _, _ in }
	) {
		self.progress = progress
		self.landed = landed
		self.failed = failed
		self.inboxUnavailable = inboxUnavailable
	}
}

/**
 Collects everything waiting in the relay and lands it.

 Runs on every signal that something might be waiting: a socket push, a wake
 from sleep, app launch, or the periodic poll. It is safe to call redundantly —
 a file already being handled is skipped, and a file already delivered is gone
 from `/pending`.
 */
public actor Receiver {
	private let api: APIClient
	private let identity: DeviceIdentity
	private let store: InboxStore
	private let events: ReceiverEvents
	private var inFlight = Set<String>()
	private var pausedInboxes = Set<String>()

	public private(set) var isRunning = false

	public init(
		api: APIClient,
		identity: DeviceIdentity,
		store: InboxStore,
		events: ReceiverEvents
	) {
		self.api = api
		self.identity = identity
		self.store = store
		self.events = events
	}

	public func poll() async {
		guard !isRunning else { return }
		isRunning = true
		defer { isRunning = false }

		let pending: PendingResponse
		do {
			pending = try await api.pending()
		} catch {
			return
		}

		var landed: [LandedFile] = []
		for file in pending.files {
			if inFlight.contains(file.fileID) { continue }
			inFlight.insert(file.fileID)
			defer { inFlight.remove(file.fileID) }

			do {
				if let result = try await receive(file) { landed.append(result) }
			} catch {
				events.failed(file, nil, error)
			}
		}

		if !landed.isEmpty { events.landed(landed) }
	}

	private func receive(_ file: PendingFile) async throws -> LandedFile? {
		// Unwrap first: a file this Mac cannot decrypt should never have reached
		// the point of touching the filesystem.
		let kek = try CryptoBox.deriveKEK(
			ephemeralPublicKey: Base64URL.decode(file.ephPub) ?? Data(),
			privateKey: identity.agreement
		)
		let contentKey = try CryptoBox.unwrapContentKey(
			wrappedKey: Base64URL.decode(file.wrappedKey) ?? Data(),
			keyIV: Base64URL.decode(file.keyIV) ?? Data(),
			kek: kek
		)
		let rawName = try CryptoBox.decryptName(
			encName: Base64URL.decode(file.encName) ?? Data(),
			nameIV: Base64URL.decode(file.nameIV) ?? Data(),
			contentKey: contentKey
		)
		let safeName = FileNameSanitizer.sanitize(rawName)

		guard let folder = store.folder(for: file.inboxID) else {
			// PRD 12.5 — pause instead of landing somewhere the user did not choose.
			if !pausedInboxes.contains(file.inboxID) {
				pausedInboxes.insert(file.inboxID)
				_ = try? await api.updateInbox(file.inboxID, paused: true)
				events.inboxUnavailable(file.inboxID, file.inboxName)
			}
			return nil
		}

		try FileLanding.checkSpace(for: file.size, in: folder)

		// The working file is hidden and 0600 so a half-written transfer is
		// neither visible nor readable by anyone else while it is in progress.
		let partURL = folder.appendingPathComponent(".stolnk-\(file.fileID).part")
		try? FileManager.default.removeItem(at: partURL)

		let sink = try DecryptingSink(file: file, contentKey: contentKey, partURL: partURL)
		let downloader = RelayDownloader()
		defer { downloader.invalidate() }

		do {
			var attempt = 0
			while true {
				do {
					let request = try await api.contentRequest(
						fileID: file.fileID, from: sink.resumeCiphertextOffset)
					try await downloader.download(request, into: sink)
					break
				} catch let error as CryptoBox.Failure {
					// Authentication failures are not transient: retrying cannot help,
					// and continuing would risk landing something tampered with.
					throw error
				} catch {
					attempt += 1
					guard attempt < 3 else { throw error }
					sink.discardPartialBuffer()
					events.progress(file.fileID, sink.plaintextWritten, file.size)
					try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
				}
			}

			try sink.finish(expecting: file.plainSHA256)
		} catch {
			// PRD 9.3 — leave no half file behind, ever.
			sink.abandon()
			events.failed(file, safeName, error)
			return nil
		}

		// Quarantine before the file becomes visible under its real name, so it is
		// never briefly present without the Gatekeeper marker.
		FileLanding.applyQuarantine(to: partURL)

		let finalName = FileNameSanitizer.uniqueName(for: safeName, in: folder)
		let destination = folder.appendingPathComponent(finalName)
		do {
			try FileManager.default.moveItem(at: partURL, to: destination)
			try? FileManager.default.setAttributes(
				[.posixPermissions: 0o644], ofItemAtPath: destination.path)
		} catch {
			sink.abandon()
			events.failed(file, safeName, error)
			return nil
		}

		// Only now is it safe to ACK: the server deletes the relay copy the moment
		// this returns, so the file must already be on disk.
		try await api.acknowledge(fileID: file.fileID)

		let landed = LandedFile(
			id: file.fileID,
			name: finalName,
			size: file.size,
			inboxName: file.inboxName,
			url: destination,
			receivedAt: Date(),
			isExecutableLike: FileNameSanitizer.isExecutableLike(finalName)
		)
		store.recordReceipt(landed)
		events.progress(file.fileID, file.size, file.size)
		return landed
	}

	public func clearPauseMemo(for inboxID: String) {
		pausedInboxes.remove(inboxID)
	}
}
