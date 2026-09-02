import CryptoKit
import Foundation

public enum ConfirmationDecision: Sendable {
	case accept
	case acceptAlways
	case decline
	/// Nobody answered — the window was closed, or the prompt went unattended.
	/// Not a refusal: the file stays on the relay and is offered again on the
	/// next poll. Declining on a dismissed window would throw away a stranger's
	/// file on an accidental click.
	case postpone
}

/// Callbacks into the UI. Closures rather than a delegate protocol so the app
/// layer can bridge to the main actor at the boundary.
public struct ReceiverEvents: Sendable {
	public var confirm: @Sendable (PendingFile, String) async -> ConfirmationDecision
	public var progress: @Sendable (String, Int, Int) -> Void
	public var landed: @Sendable ([LandedFile]) -> Void
	public var failed: @Sendable (PendingFile, String?, Error) -> Void
	public var inboxUnavailable: @Sendable (String, String) -> Void

	public init(
		confirm: @escaping @Sendable (PendingFile, String) async -> ConfirmationDecision = { _, _ in .accept },
		progress: @escaping @Sendable (String, Int, Int) -> Void = { _, _, _ in },
		landed: @escaping @Sendable ([LandedFile]) -> Void = { _ in },
		failed: @escaping @Sendable (PendingFile, String?, Error) -> Void = { _, _, _ in },
		inboxUnavailable: @escaping @Sendable (String, String) -> Void = { _, _ in }
	) {
		self.confirm = confirm
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
	/// Longer than the app layer's own watchdog, so in a healthy build this
	/// never fires and the user's own click always wins.
	private let confirmationDeadline: UInt64

	public private(set) var isRunning = false

	public init(
		api: APIClient,
		identity: DeviceIdentity,
		store: InboxStore,
		events: ReceiverEvents,
		confirmationDeadline: UInt64 = 20 * 60 * 1_000_000_000
	) {
		self.confirmationDeadline = confirmationDeadline
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

		if store.snapshot.alwaysAccept == false, file.needsConfirmation {
			switch await confirm(file, named: safeName) {
			case .decline:
				try await api.decline(fileID: file.fileID)
				return nil
			case .postpone:
				// Left on the relay deliberately. The next poll asks again.
				return nil
			case .accept:
				try await api.accept(fileID: file.fileID, always: false)
			case .acceptAlways:
				try await api.accept(fileID: file.fileID, always: true)
			}
		} else if file.needsConfirmation {
			try await api.accept(fileID: file.fileID, always: false)
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

	/// Asks the UI, with a hard deadline.
	///
	/// The app layer runs its own, shorter watchdog; this is the backstop for
	/// the case where it does not answer at all. Without it a prompt that is
	/// never resolved suspends `receive` forever, `poll` never returns, and the
	/// `isRunning` guard silently swallows every later poll — socket pushes,
	/// the periodic timer, wake, launch — for the rest of the process. The
	/// symptom is a Mac that accepts nothing at all and reports no error.
	///
	/// Deliberately not a task group: a group awaits every child before it
	/// returns, so an ask that never answers would hang here exactly as it hung
	/// before. The ask is abandoned instead — whenever it does finish, its
	/// answer lands on a resolver that has already been settled and is
	/// discarded.
	private func confirm(_ file: PendingFile, named name: String) async -> ConfirmationDecision {
		let outcome = FirstAnswer()
		let asking = Task { [events] in await outcome.resolve(events.confirm(file, name)) }
		let deadline = Task { [confirmationDeadline] in
			try? await Task.sleep(nanoseconds: confirmationDeadline)
			await outcome.resolve(.postpone)
		}
		defer {
			asking.cancel()
			deadline.cancel()
		}
		return await outcome.value
	}

	public func clearPauseMemo(for inboxID: String) {
		pausedInboxes.remove(inboxID)
	}
}

/// Settles once. Later answers — an abandoned prompt finally being clicked —
/// are dropped rather than resuming a continuation twice.
private actor FirstAnswer {
	private var decision: ConfirmationDecision?
	private var waiter: CheckedContinuation<ConfirmationDecision, Never>?

	var value: ConfirmationDecision {
		get async {
			if let decision { return decision }
			return await withCheckedContinuation { waiter = $0 }
		}
	}

	func resolve(_ answer: ConfirmationDecision) {
		guard decision == nil else { return }
		decision = answer
		waiter?.resume(returning: answer)
		waiter = nil
	}
}
