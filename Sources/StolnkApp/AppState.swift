import AppKit
import Foundation
import StolnkCore
import SwiftUI

/// PRD 10.4. Note what is absent: there is no "the sender can't reach you"
/// state, because with the relay path there is no such situation. A sleeping
/// Mac is a delay, not a failure.
enum ConnectionStatus: Equatable {
	case connecting
	case ready
	case receiving(progress: Double)
	case waiting(count: Int)
	case paused
	case offline

	var label: String {
		switch self {
		case .connecting: "Connecting"
		case .ready: "Ready"
		case .receiving(let progress): "Receiving \(Int(progress * 100))%"
		case .waiting(let count): "\(count) waiting"
		case .paused: "Paused"
		case .offline: "Offline"
		}
	}

	var symbol: String {
		switch self {
		case .connecting: "circle.dotted"
		case .ready: "circle.fill"
		case .receiving: "arrow.down.circle.fill"
		case .waiting: "envelope.fill"
		case .paused: "pause.circle.fill"
		case .offline: "circle"
		}
	}

	var tint: Color {
		switch self {
		case .ready: .green
		case .receiving, .waiting: .accentColor
		case .paused: .orange
		case .connecting, .offline: .secondary
		}
	}
}

/// The Settings window is also where links are managed, so which tab it opens
/// on is a decision the caller makes.
enum SettingsTab: Hashable {
	case links
	case general
}

struct ConfirmationRequest: Identifiable {
	let id: String
	let file: PendingFile
	let filename: String
	let continuation: CheckedContinuation<ConfirmationDecision, Never>
	/// Resolves the request as `.postpone` if it is left unattended, so a
	/// forgotten prompt cannot hold the receiver open indefinitely.
	let watchdog: Task<Void, Never>
}

@MainActor
final class AppState: ObservableObject {
	/// Shared because the app delegate drives startup and the receiver's
	/// callbacks arrive from outside any view hierarchy.
	static let shared = AppState()

	@Published private(set) var status: ConnectionStatus = .connecting
	@Published private(set) var inboxes: [InboxSummary] = []
	@Published private(set) var recent: [LandedFile] = []
	@Published private(set) var isEnclaveBacked = false
	@Published private(set) var name: String?
	@Published var confirmation: ConfirmationRequest?
	@Published var needsOnboarding = false
	@Published var lastError: String?
	@Published var settingsTab: SettingsTab = .links
	/// Which inbox the Links tab has selected. Lives here rather than in the view
	/// because `WindowPresenter` reuses the window: opening Settings a second time
	/// does not rebuild the view, so a constructor argument would be ignored.
	@Published var selectedInboxID: String?

	let store = InboxStore()
	private var identityKeys: DeviceIdentity?
	private var api: APIClient?
	private var receiver: Receiver?
	private var signalling: SignallingClient?
	private let notifier = Notifier()
	private let presenter = WindowPresenter()
	private var pollTimer: Timer?
	private var socketConnected = false

	/// The apex. Every API call goes here; inbox links live one label below it.
	var origin: URL {
		let state = store.snapshot
		return URL(string: "\(state.scheme)://\(state.baseHost)")
			?? URL(string: "\(StoredState.defaultScheme)://\(StoredState.defaultBaseHost)")!
	}

	/// `.stolnk.com` — what a name field shows after the box being typed into.
	var nameSuffix: String { SiteAddress.suffix(baseHost: store.snapshot.baseHost) }

	/// `ryan.stolnk.com/` — the fixed part before a path being edited.
	func addressPrefix(name: String) -> String {
		SiteAddress.prefix(name: name, baseHost: store.snapshot.baseHost)
	}

	// MARK: - Startup

	func start() async {
		recent = store.snapshot.recent

		// Deliberately not awaited. Asking for notification permission involves a
		// system prompt, and on an unnotarised build that call can stall; letting
		// it gate startup would mean no device key and no registration — the app
		// would sit there looking connected and never receive anything. Delivery
		// works without notifications; notifications do not work without delivery.
		Task { await notifier.requestAuthorisation() }

		// Key loading and the network are separate failures with separate
		// remedies, so they do not share a catch. A key failure used to skip
		// `showOnboarding()` entirely, leaving a first-run user with a menu bar
		// icon reading Offline and no way to find out why.
		let keys: DeviceIdentity
		do {
			keys = try DeviceIdentity.loadOrCreate()
		} catch {
			lastError = error.localizedDescription
			status = .offline
			if store.snapshot.deviceID == nil {
				needsOnboarding = true
				showOnboarding()
			}
			return
		}

		do {
			identityKeys = keys
			isEnclaveBacked = keys.isEnclaveBacked
			let client = APIClient(origin: origin, identity: keys)
			api = client

			let saved = store.snapshot
			if let deviceID = saved.deviceID {
				await client.adopt(deviceID: deviceID, token: saved.token)
				name = saved.name
				try await client.authenticate()
				await persistToken()
				// A device with a name has been through onboarding by definition —
				// the name and the first inbox are the only things it produces.
				// Trusting the flag alone meant that closing the last screen
				// instead of pressing Done left it false forever, and a fully
				// set-up Mac was greeted with "Welcome to Stolnk" on every launch.
				needsOnboarding = saved.name == nil
				if !needsOnboarding, !saved.hasCompletedOnboarding {
					store.mutate { $0.hasCompletedOnboarding = true }
				}
			} else {
				needsOnboarding = true
			}

			if needsOnboarding { showOnboarding() }

			buildReceiver(api: client, keys: keys)
			if saved.deviceID != nil {
				await refreshInboxes()
				connectSignalling()
				await poll()
				startPolling()
			}
		} catch {
			handle(error)
			status = .offline
		}
	}

	/**
	 PRD 7.1 — registration is one screen and one call. The name is not an
	 upgrade over a random address, it *is* the identity, so it goes up with the
	 keys: a name already in use fails with 409 and creates nothing, which is
	 what makes retrying with another one clean.

	 The path goes up with it because every link is a name *and* a path — there is
	 no bare-subdomain address for a first inbox to fall back on (PRD 6.2).
	 */
	func register(name chosen: String, slug: String, folder: URL) async -> Bool {
		// Startup may have failed to produce keys. Try once more here rather than
		// returning: this runs from a button, and a button that does nothing at
		// all is worse than one that reports why.
		guard let keys = try? resolvedIdentityKeys() else { return false }
		let client = api ?? APIClient(origin: origin, identity: keys)
		api = client
		lastError = nil

		guard store.snapshot.deviceID == nil else {
			return await rename(to: NameRules.normalise(chosen))
		}

		do {
			let result = try await client.register(
				name: NameRules.normalise(chosen), slug: PathRules.normalise(slug))
			store.mutate { state in
				state.deviceID = result.deviceID
				state.name = result.name
				state.token = result.token
			}
			name = result.name

			let (_, list) = try await client.inboxes()
			if let first = list.first { store.bind(inboxID: first.inboxID, to: folder) }
			inboxes = list
			store.mutate { $0.inboxes = list }

			buildReceiver(api: client, keys: keys)
			connectSignalling()
			startPolling()
			status = .ready
			return true
		} catch {
			handle(error)
			return false
		}
	}

	/// nil means the question could not be asked, which is not the same answer as
	/// "taken" and must not be shown as one.
	func isNameAvailable(_ candidate: String) async -> Bool? {
		guard let api else { return nil }
		return try? await api.nameAvailable(NameRules.normalise(candidate))
	}

	private func resolvedIdentityKeys() throws -> DeviceIdentity {
		if let identityKeys { return identityKeys }
		do {
			let keys = try DeviceIdentity.loadOrCreate()
			identityKeys = keys
			isEnclaveBacked = keys.isEnclaveBacked
			return keys
		} catch {
			handle(error)
			throw error
		}
	}

	/**
	 What to do with an error from the API.

	 Almost everything is worth showing and nothing more. The exception is the
	 server telling us it has no record of this Mac: no amount of retrying fixes
	 that, and the app used to sit on "Offline · Unknown device" with no way out,
	 because the code that opens onboarding runs *after* the call that throws.
	 */
	func handle(_ error: Error) {
		if let apiError = error as? APIError, apiError.code == "unknown_device" {
			forgetDevice()
			return
		}
		lastError = error.localizedDescription
	}

	/**
	 Drops this Mac's registration and goes back to first run.

	 The Secure Enclave keys stay: nothing ties a public key to one device row, so
	 registering again with them is fine. The folder bindings do not — they are
	 keyed by inbox id, and every one of those inboxes went with the device.

	 In production this should never fire; devices are never deleted. In
	 development it fires every time the local D1 is reset, which is exactly when
	 being stuck with no way forward is most expensive.
	 */
	func forgetDevice() {
		store.mutate { state in
			state.deviceID = nil
			state.token = nil
			state.name = nil
			state.inboxes = []
			state.folders = [:]
			state.hasCompletedOnboarding = false
		}
		api = nil
		receiver = nil
		signalling?.stop()
		signalling = nil
		pollTimer?.invalidate()
		pollTimer = nil
		name = nil
		inboxes = []
		status = .offline
		lastError = "This Mac is no longer registered on the server. Set it up again below."
		needsOnboarding = true
		showOnboarding()
	}

	func completeOnboarding() {
		store.mutate { $0.hasCompletedOnboarding = true }
		needsOnboarding = false
		presenter.close(id: "onboarding")
	}

	// MARK: - Windows

	/// Closing the window counts as finishing it, but only once there is
	/// something to come back to. Dismissed mid-registration the flag is left
	/// alone, so the next launch offers setup again rather than handing over a
	/// menu bar with no address in it.
	private func onboardingDismissed() {
		guard store.snapshot.name != nil else {
			needsOnboarding = true
			return
		}
		completeOnboarding()
	}

	func showOnboarding() {
		presenter.show(
			id: "onboarding",
			title: "Welcome to Stolnk",
			onClose: { [weak self] in self?.onboardingDismissed() }
		) {
			OnboardingView(mode: .firstRun).environmentObject(self)
		}
	}

	func showNewInbox() {
		presenter.show(id: "new-inbox", title: "New Inbox") {
			OnboardingView(mode: .newInbox).environmentObject(self)
		}
	}

	func closeNewInbox() {
		presenter.close(id: "new-inbox")
	}

	/// Settings goes through the same presenter as every other window rather
	/// than through SwiftUI's `Settings` scene: opening that scene from a menu
	/// bar app means `SettingsLink` (macOS 14) or the `showSettingsWindow:`
	/// selector, and the selector silently does nothing on current macOS — the
	/// button looked dead. There is no `Settings` scene any more.
	func showSettings(tab: SettingsTab = .links, select inboxID: String? = nil) {
		settingsTab = tab
		if let inboxID { selectedInboxID = inboxID }
		lastError = nil
		presenter.show(id: "settings", title: "Stolnk Settings") {
			SettingsView().environmentObject(self)
		}
	}

	private func buildReceiver(api: APIClient, keys: DeviceIdentity) {
		let events = ReceiverEvents(
			confirm: { [weak self] file, name in
				guard let self else { return .decline }
				return await self.askForConfirmation(file: file, filename: name)
			},
			progress: { [weak self] _, received, total in
				Task { @MainActor [weak self] in
					guard let self, total > 0 else { return }
					let fraction = Double(received) / Double(total)
					self.status = fraction >= 1 ? .ready : .receiving(progress: fraction)
				}
			},
			landed: { [weak self] files in
				Task { @MainActor [weak self] in
					guard let self else { return }
					self.recent = self.store.snapshot.recent
					self.status = .ready
					self.notifier.received(files)
					self.revealIfAppropriate(files)
				}
			},
			failed: { [weak self] _, name, error in
				Task { @MainActor [weak self] in
					guard let self else { return }
					self.status = .ready
					self.handle(error)
					self.notifier.failed(name: name, reason: error.localizedDescription)
				}
			},
			inboxUnavailable: { [weak self] _, name in
				Task { @MainActor [weak self] in
					guard let self else { return }
					self.status = .paused
					self.notifier.inboxUnavailable(named: name)
					await self.refreshInboxes()
				}
			}
		)
		receiver = Receiver(api: api, identity: keys, store: store, events: events)
	}

	// MARK: - Confirmation (PRD 13.2)

	private func askForConfirmation(file: PendingFile, filename: String) async -> ConfirmationDecision {
		await withCheckedContinuation { continuation in
			let watchdog = Task { [weak self] in
				try? await Task.sleep(nanoseconds: Self.confirmationWatchdog)
				guard !Task.isCancelled else { return }
				self?.resolveConfirmation(.postpone)
			}
			confirmation = ConfirmationRequest(
				id: file.fileID,
				file: file,
				filename: filename,
				continuation: continuation,
				watchdog: watchdog
			)
			// The window can be missed — behind another app, on another Space —
			// so the menu bar and a notification carry the same news.
			status = .waiting(count: 1)
			notifier.awaitingConfirmation(
				name: filename, inboxName: file.inboxName, fileID: file.fileID)
			showConfirmation()
		}
	}

	/// Raises the pending prompt, or brings it back after it was dismissed.
	/// Reachable from the menu bar and from the notification.
	func showConfirmation() {
		guard confirmation != nil else { return }
		presenter.show(
			id: "confirm",
			title: "Incoming files",
			onClose: { [weak self] in self?.resolveConfirmation(.postpone) }
		) {
			ConfirmationView().environmentObject(self)
		}
	}

	/// Idempotent and re-entrant: `presenter.close` detaches the window
	/// delegate before closing, and `confirmation` is cleared first, so a
	/// second call — from the watchdog, or from a close that races a click —
	/// finds nothing to do.
	func resolveConfirmation(_ decision: ConfirmationDecision) {
		guard let request = confirmation else { return }
		confirmation = nil
		request.watchdog.cancel()
		presenter.close(id: "confirm")
		if case .receiving = status {} else { status = .ready }
		request.continuation.resume(returning: decision)
	}

	/// Shorter than `Receiver`'s own deadline, so this is the path that
	/// normally reclaims an unattended prompt and the backstop stays unused.
	private static let confirmationWatchdog: UInt64 = 15 * 60 * 1_000_000_000

	// MARK: - Delivery

	private func connectSignalling() {
		signalling?.stop()
		let client = SignallingClient(
			urlProvider: { [weak self] in
				guard let api = await self?.api else { return nil }
				return await api.signallingURL()
			},
			onEvent: { [weak self] event in
				Task { @MainActor [weak self] in
					guard let self else { return }
					switch event {
					case .connected:
						self.socketConnected = true
						if case .receiving = self.status {} else { self.status = .ready }
					case .disconnected:
						self.socketConnected = false
						if case .receiving = self.status {} else { self.status = .connecting }
					case .fileReady:
						await self.poll()
					}
				}
			}
		)
		signalling = client
		client.start()
		observeWake()
	}

	/**
	 PRD 10.5 — on wake, reconnect and collect. The app does not request the
	 right to keep the machine awake: being a bad citizen about battery to shave
	 a few seconds off delivery is not a trade this product makes.
	 */
	private func observeWake() {
		NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didWakeNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.signalling?.reconnectNow()
				await self.poll()
			}
		}
	}

	private func startPolling() {
		pollTimer?.invalidate()
		// A safety net under the socket, not the primary path — hence minutes.
		pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
			Task { @MainActor [weak self] in await self?.poll() }
		}
	}

	func poll() async {
		guard let receiver else { return }
		await receiver.poll()
		if case .receiving = status {} else {
			status = socketConnected ? .ready : .connecting
		}
	}

	private func revealIfAppropriate(_ files: [LandedFile]) {
		let state = store.snapshot
		// PRD 14 — Finder opens once, as proof the thing works. After that it
		// would just be an app stealing focus.
		let shouldReveal = state.openFinderEveryTime || !state.hasOpenedFinderOnce
		guard shouldReveal, let first = files.first else { return }
		store.mutate { $0.hasOpenedFinderOnce = true }
		NSWorkspace.shared.activateFileViewerSelecting([first.fileURL])
	}

	// MARK: - Inbox management

	func refreshInboxes() async {
		guard let api else { return }
		do {
			let (currentName, list) = try await api.inboxes()
			name = currentName
			inboxes = list
			store.mutate {
				$0.name = currentName
				$0.inboxes = list
			}
			if list.allSatisfy({ $0.paused }), !list.isEmpty { status = .paused }
		} catch {
			handle(error)
		}
	}

	func folder(for inbox: InboxSummary) -> URL? {
		store.folder(for: inbox.inboxID)
	}

	func createInbox(slug: String, displayName: String, folder: URL) async {
		guard let api else { return }
		do {
			let inbox = try await api.createInbox(slug: slug, displayName: displayName)
			store.bind(inboxID: inbox.inboxID, to: folder)
			await refreshInboxes()
		} catch let error as APIError where error.status == 402 {
			// PRD 6.2 — the wall sits at the end of the flow on purpose, so the
			// intent is recorded even when the user does not convert.
			lastError = error.message
		} catch {
			handle(error)
		}
	}

	func rebind(inbox: InboxSummary, to folder: URL) async {
		store.bind(inboxID: inbox.inboxID, to: folder)
		await receiver?.clearPauseMemo(for: inbox.inboxID)
		if inbox.paused { _ = try? await api?.updateInbox(inbox.inboxID, paused: false) }
		await refreshInboxes()
		await poll()
	}

	func setPaused(_ inbox: InboxSummary, paused: Bool) async {
		guard let api else { return }
		_ = try? await api.updateInbox(inbox.inboxID, paused: paused)
		await refreshInboxes()
	}

	/// Moving a link to a different path. The server refuses an empty path and one
	/// another inbox already holds.
	func setSlug(_ inbox: InboxSummary, slug: String) async {
		guard let api else { return }
		do {
			lastError = nil
			_ = try await api.updateInbox(inbox.inboxID, slug: PathRules.normalise(slug))
		} catch {
			handle(error)
		}
		await refreshInboxes()
	}

	/// The name senders see. Not the address — that is the name plus the path,
	/// and both are edited elsewhere.
	func setDisplayName(_ inbox: InboxSummary, to value: String) async {
		guard let api else { return }
		do {
			lastError = nil
			_ = try await api.updateInbox(
				inbox.inboxID, displayName: DisplayNameRules.normalise(value))
		} catch {
			handle(error)
		}
		await refreshInboxes()
	}

	func resetInbox(_ inbox: InboxSummary) async {
		guard let api else { return }
		do {
			lastError = nil
			_ = try await api.resetInbox(inbox.inboxID)
		} catch {
			handle(error)
		}
		await refreshInboxes()
	}

	/// The server refuses to delete the default inbox (PRD 6.2), so the failure
	/// has to be shown rather than swallowed — the UI disables the button, but a
	/// stale list would otherwise produce a click that silently does nothing.
	func deleteInbox(_ inbox: InboxSummary) async {
		guard let api else { return }
		do {
			lastError = nil
			try await api.deleteInbox(inbox.inboxID)
			store.unbind(inboxID: inbox.inboxID)
			await receiver?.clearPauseMemo(for: inbox.inboxID)
			if selectedInboxID == inbox.inboxID { selectedInboxID = nil }
		} catch {
			handle(error)
		}
		await refreshInboxes()
	}

	/// Renaming. Every link moves with the name, and the old one is released
	/// immediately — there is no grace redirect (PRD 6.1).
	func rename(to chosen: String) async -> Bool {
		guard let api else { return false }
		do {
			lastError = nil
			let list = try await api.rename(to: chosen)
			inboxes = list
			name = chosen
			store.mutate {
				$0.inboxes = list
				$0.name = chosen
			}
			return true
		} catch {
			handle(error)
			return false
		}
	}

	func setAlwaysAccept(_ value: Bool) {
		store.mutate { $0.alwaysAccept = value }
		objectWillChange.send()
	}

	func setOpenFinderEveryTime(_ value: Bool) {
		store.mutate { $0.openFinderEveryTime = value }
		objectWillChange.send()
	}

	/// The Server field in Settings takes a whole origin; it is split here so the
	/// rest of the app never has to parse one.
	func setOrigin(_ value: String) {
		let trimmed = value.trimmingCharacters(in: .whitespaces)
		guard let url = URL(string: trimmed), let host = url.host else { return }
		let port = url.port.map { ":\($0)" } ?? ""
		store.mutate {
			$0.scheme = url.scheme ?? "https"
			$0.baseHost = "\(host)\(port)"
		}
		objectWillChange.send()
	}

	private func persistToken() async {
		guard let api else { return }
		let token = await api.currentToken
		store.mutate { $0.token = token }
	}
}
