import AppKit
import Foundation
import StolnkCore
import StolnkLAN
import SwiftUI

/// PRD 10.4. Note what is absent: there is no "the sender can't reach you"
/// state, because with the relay path there is no such situation. A sleeping
/// Mac is a delay, not a failure.
enum ConnectionStatus: Equatable {
	case connecting
	case ready
	case receiving(progress: Double)
	case paused
	case offline

	var label: String {
		switch self {
		case .connecting: "Connecting"
		case .ready: "Ready"
		case .receiving(let progress): "Receiving \(Int(progress * 100))%"
		case .paused: "Paused"
		case .offline: "Offline"
		}
	}

	var symbol: String {
		switch self {
		case .connecting: "circle.dotted"
		case .ready: "circle.fill"
		case .receiving: "arrow.down.circle.fill"
		case .paused: "pause.circle.fill"
		case .offline: "circle"
		}
	}

	var tint: Color {
		switch self {
		case .ready: .green
		case .receiving: .accentColor
		case .paused: .orange
		case .connecting, .offline: .secondary
		}
	}
}

/// The Settings window is also where links are managed, so which tab it opens
/// on is a decision the caller makes.
enum SettingsTab: Hashable {
	case links
	case shares
	case plan
	case general
}

/// A refused action, phrased as what Pro would allow.
struct UpgradePrompt: Identifiable {
	let id = UUID()
	let title: String
	let message: String
}

@MainActor
final class AppState: ObservableObject {
	/// Shared because the app delegate drives startup and the receiver's
	/// callbacks arrive from outside any view hierarchy.
	static let shared = AppState()

	@Published private(set) var status: ConnectionStatus = .connecting
	@Published private(set) var inboxes: [InboxSummary] = []
	@Published private(set) var shares: [ShareSummary] = []
	@Published private(set) var shareUploads: [ShareUpload] = []
	@Published private(set) var recent: [LandedFile] = []
	@Published private(set) var isEnclaveBacked = false
	@Published private(set) var name: String?
	@Published var needsOnboarding = false
	@Published var lastError: String?
	/// The counterpart to `lastError`, for an action whose success is otherwise
	/// invisible. Clearing transfer records is the only one: there is no history
	/// screen for the result to show up in, so without this the button looks
	/// broken when it works.
	@Published var lastNotice: String?
	@Published var settingsTab: SettingsTab = .links
	/// Which inbox the Links tab has selected. Lives here rather than in the view
	/// because `WindowPresenter` reuses the window: opening Settings a second time
	/// does not rebuild the view, so a constructor argument would be ignored.
	@Published var selectedInboxID: String?
	@Published var selectedShareID: String?

	/// PRD 16 — the tier and this month's usage, as the server reports them.
	/// Optional because "not asked yet" and "Free" are different things, and
	/// showing a Pro user "Free" for a moment on launch would be a lie.
	@Published private(set) var plan: PlanState?

	/// Set when an action was refused for want of Pro. Drives a sheet rather than
	/// the general error line: PRD 6.2 wants this moment to read as an offer, and
	/// it is also the funnel's most informative event (PRD 15.4).
	@Published var upgradePrompt: UpgradePrompt?

	let store = InboxStore()
	private var identityKeys: DeviceIdentity?
	private var api: APIClient?
	private var receiver: Receiver?
	private var signalling: SignallingClient?
	/*
	 PRD 8.2 — answers DataChannel offers from send pages on the same network.

	 `nonisolated(unsafe)` because signalling frames arrive on the socket's own
	 queue and must not wait on the main actor to be dispatched — WebRTC
	 negotiation is the thing racing a two-second deadline. The ordering that
	 makes it safe is explicit rather than incidental: it is assigned in
	 `connectSignalling` *before* `client.start()`, so no frame can be delivered
	 until the write has happened, and `LanReceiver` guards its own state.
	 */
	private nonisolated(unsafe) var lanReceiver: LanReceiver?
	/// Kept so the LAN path reports a landed file through the identical closure
	/// the relay path uses, rather than a second one that could drift from it.
	private var receiverEvents: ReceiverEvents?
	private let notifier = Notifier()
	private let presenter = WindowPresenter()
	private var pollTimer: Timer?
	private var socketConnected = false

	struct ShareUpload: Identifiable, Sendable {
		let id: UUID
		let filename: String
		var progress: Double
	}

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
		shares = store.snapshot.shares

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
				await refreshShares()
				await refreshPlan()
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

	func showNewShare() {
		guard let file = FilePicker.choose(prompt: "Choose one file to share") else { return }
		presenter.show(id: "new-share", title: "Share a File") {
			NewShareView(file: file).environmentObject(self)
		}
	}

	func closeNewShare() { presenter.close(id: "new-share") }

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
		receiverEvents = events
		receiver = Receiver(api: api, identity: keys, store: store, events: events)
	}

	// MARK: - Delivery

	private func connectSignalling() {
		signalling?.stop()
		lanReceiver?.stopAll()
		let client = SignallingClient(
			urlProvider: { [weak self] in
				guard let api = await self?.api else { return nil }
				return await api.signallingURL()
			},
			onEvent: { [weak self] event in
				// Handled off the main actor on purpose: this is the frame the LAN
				// negotiation is waiting on, and its payload is a JSON dictionary
				// that could not cross an actor boundary anyway.
				if case .signal(let session, let payload) = event {
					self?.lanReceiver?.handle(session: session, payload: payload)
					return
				}
				Task { @MainActor [weak self] in
					guard let self else { return }
					switch event {
					case .signal:
						break  // Handled above, before the hop.
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

		/*
		 PRD 8.2 — the LAN answerer, wired to the same socket.
		 
		 It shares the Receiver, so a file that arrives over a DataChannel is
		 sanitised, quarantined, named and acknowledged by exactly the code that
		 handles a relay pull. The only difference is where the bytes came from.
		 */
		if let receiver, let api, let events = receiverEvents {
			lanReceiver = LanReceiver(
				receiver: receiver,
				api: api,
				answer: { [weak client] session, payload in
					client?.sendSignal(session: session, payload: payload)
				},
				// The same closure the relay path reports through, deliberately:
				// a file that arrived is a file that arrived, and the notification,
				// the Finder reveal and the recent list must not be able to
				// disagree about which transport it came in on.
				onLanded: { landed in events.landed(landed) }
			)
		}

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
		// Files that just landed spent someone's allowance, so the plan rides
		// along with the poll rather than getting a timer of its own.
		await refreshPlan()
		await refreshShares()
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

	// MARK: - Licensing (PRD 16)

	/// Where the licence key is kept so a seat can be released later without
	/// making someone dig the email out again. It is a credential, so it goes in
	/// the keychain rather than the settings file.
	private static let licenseKeyAccount = "license-key"

	var storedLicenseKey: String? {
		guard case let .found(data) = Keychain.read(Self.licenseKeyAccount) else { return nil }
		return String(data: data, encoding: .utf8)
	}

    /// Never surfaces an error. The plan is decoration on every screen that shows
    /// it — a failed refresh should leave the last known answer standing, not
    /// replace the Settings pane with a network complaint.
	func refreshPlan() async {
		guard let api else { return }
		plan = try? await api.plan()
	}

	func activateLicense(key: String) async -> String? {
		guard let api else { return "Not connected." }
		let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return "Enter your licence key." }
		do {
			plan = try await api.activateLicense(key: trimmed)
			Keychain.write(Self.licenseKeyAccount, Data(trimmed.utf8))
			// Pro raises the per-file ceiling on links that already exist, and the
			// list carries `sizeLimit`, so it is stale until this runs.
			await refreshInboxes()
			return nil
		} catch let error as APIError {
			return error.message
		} catch {
			return error.localizedDescription
		}
	}

	/// Hands this Mac's seat back so another one can take it.
	///
	/// The key is sent rather than the session (PRD 7.2): the same endpoint has
	/// to work for a Mac that no longer exists, so it cannot depend on one being
	/// able to authenticate.
	func releaseSeat() async -> String? {
		guard let api, let deviceID = store.snapshot.deviceID else { return "Not connected." }
		guard let key = storedLicenseKey else {
			return "This Mac does not have a licence key saved. Release it from your Creem receipt instead."
		}
		do {
			try await api.releaseLicense(key: key, deviceID: deviceID)
			Keychain.delete(Self.licenseKeyAccount)
			await refreshPlan()
			await refreshInboxes()
			return nil
		} catch let error as APIError {
			return error.message
		} catch {
			return error.localizedDescription
		}
	}

	func openPurchasePage() {
		guard let api else { return }
		NSWorkspace.shared.open(api.purchaseURL())
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

	func refreshShares() async {
		guard let api else { return }
		do {
			let response = try await api.shares()
			shares = response.shares
			store.mutate { $0.shares = response.shares }
		} catch {
			handle(error)
		}
	}

	func createShare(
		file: URL, ttlHours: Double, maxDownloads: Int?, password: String?, code: String?
	) async -> Bool {
		guard let api else { return false }
		let uploadID = UUID()
		do {
			let values = try file.resourceValues(forKeys: [.fileSizeKey, .nameKey])
			let filename = values.name ?? file.lastPathComponent
			let size = values.fileSize ?? 0
			var verifier: String?
			var salt: String?
			if let password, !password.isEmpty {
				let parameters = try await api.shareSalt()
				salt = parameters.salt
				verifier = try await SharePassword.derive(password, salt: parameters.salt, iterations: parameters.iterations)
			}
			let handle = try await api.createShare(
				filename: filename, size: size, ttlHours: ttlHours,
				maxDownloads: maxDownloads, password: verifier, passwordSalt: salt,
				code: code.map(ShareCodeRules.normalise))
			shareUploads.append(ShareUpload(id: uploadID, filename: filename, progress: 0))
			let scoped = file.startAccessingSecurityScopedResource()
			defer { if scoped { file.stopAccessingSecurityScopedResource() } }
			try await api.uploadShare(handle, from: file) { [weak self] progress in
				Task { @MainActor in
					guard let self, let index = self.shareUploads.firstIndex(where: { $0.id == uploadID }) else { return }
					self.shareUploads[index].progress = progress
				}
			}
			shareUploads.removeAll { $0.id == uploadID }
			// Remembered now so restoring this link later does not have to ask
			// which file it was. Written after the upload, so a link that never
			// finished leaves no binding behind.
			store.bindSource(shareID: handle.shareID, to: file)
			await refreshShares()
			copyShareURL(handle.url)
			closeNewShare()
			return true
		} catch let error as APIError where error.isUpgradeRequired {
			shareUploads.removeAll { $0.id == uploadID }
			upgradePrompt = UpgradePrompt(title: "Share with Pro", message: error.message)
		} catch {
			shareUploads.removeAll { $0.id == uploadID }
			handle(error)
		}
		return false
	}

	/// Repath a live link. `code_taken` is not a paywall, so it lands in
	/// `lastError` like any other refusal — only 402 becomes an upgrade prompt.
	func setShareCode(_ share: ShareSummary, code: String) async {
		guard let api else { return }
		do {
			_ = try await api.updateShareCode(share.shareID, code: ShareCodeRules.normalise(code))
			await refreshShares()
		} catch { handle(error) }
	}

	/// `nil` when the question could not be asked — never rendered as "taken".
	func isShareCodeAvailable(_ candidate: String, forShare shareID: String? = nil) async -> Bool? {
		guard let api else { return nil }
		return try? await api.shareCodeAvailable(
			ShareCodeRules.normalise(candidate), forShare: shareID)
	}

	/**
	 Put the file back behind a link that has ended.

	 The Mac does not remember which file a share came from — `createShare` uses
	 the URL and drops it — so this asks for it again. That is not only a
	 limitation: the record carries the original sha256 and the server refuses
	 anything else, so picking the file is also how the promise "this URL means
	 this file" survives the link coming back.

	 The size is checked here purely to fail fast. The hash is the real gate and
	 it lives on the server, where a wrong file costs an upload before it is
	 caught; a wrong size costs nothing to catch and is the common mistake.
	 */
	/// Why a share can or cannot be restored. `unrecorded` is its own case
	/// rather than another kind of `missing` because the advice differs: a file
	/// that moved might come back when a drive is plugged in, while a link made
	/// before this app remembered source files never had one to lose.
	enum ShareSource {
		case known(URL)
		case missing
		case unrecorded
	}

	func sourceFile(for share: ShareSummary) -> ShareSource {
		if let file = store.source(for: share.shareID) { return .known(file) }
		return store.snapshot.sources[share.shareID] == nil ? .unrecorded : .missing
	}

	func restoreShare(_ share: ShareSummary, from file: URL) async -> Bool {
		guard let api else { return false }
		let uploadID = UUID()
		do {
			let values = try file.resourceValues(forKeys: [.fileSizeKey])
			guard (values.fileSize ?? -1) == share.size else {
				lastError = "That file is a different size from the one this link was created for."
				return false
			}
			let handle = try await api.restoreShare(share.shareID)
			shareUploads.append(ShareUpload(id: uploadID, filename: share.filename, progress: 0))
			let scoped = file.startAccessingSecurityScopedResource()
			defer { if scoped { file.stopAccessingSecurityScopedResource() } }
			try await api.uploadShare(handle, from: file) { [weak self] progress in
				Task { @MainActor in
					guard let self, let index = self.shareUploads.firstIndex(where: { $0.id == uploadID }) else { return }
					self.shareUploads[index].progress = progress
				}
			}
			shareUploads.removeAll { $0.id == uploadID }
			// Where it lives now, which is not necessarily where it lived when
			// the link was made — that is often the whole reason we had to ask.
			store.bindSource(shareID: share.shareID, to: file)
			await refreshShares()
			return true
		} catch let error as APIError where error.isUpgradeRequired {
			shareUploads.removeAll { $0.id == uploadID }
			upgradePrompt = UpgradePrompt(title: "Restore with Pro", message: error.message)
		} catch {
			shareUploads.removeAll { $0.id == uploadID }
			// Includes the server's hash refusal, which is the wrong-file case
			// the size check above could not see.
			handle(error)
			await refreshShares()
		}
		return false
	}

	/// Pause or resume. Unlike `revokeShare` this is reversible, because it
	/// leaves the file where it is.
	func setSharePaused(_ share: ShareSummary, paused: Bool) async {
		guard let api else { return }
		do {
			_ = try await api.setSharePaused(share.shareID, paused: paused)
			await refreshShares()
		} catch { handle(error) }
	}

	func revokeShare(_ share: ShareSummary) async {
		guard let api else { return }
		do {
			try await api.revokeShare(share.shareID)
			await refreshShares()
		} catch { handle(error) }
	}

	/// Unlike revoking, this gives up the path too — see `deleteShare` in the
	/// Worker for why the two are separate actions.
	func deleteShare(_ share: ShareSummary) async {
		guard let api else { return }
		do {
			try await api.deleteShare(share.shareID)
			// The record is gone, so the mapping to a local file would sit in
			// state.json forever pointing at a share nothing can restore —
			// the same reason `unbind` exists for a deleted inbox.
			store.unbindSource(shareID: share.shareID)
			await refreshShares()
		} catch { handle(error) }
	}

	func copyShareURL(_ url: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(url, forType: .string)
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
		} catch let error as APIError where error.isUpgradeRequired {
			// PRD 6.2 — the wall sits at the end of the flow on purpose, so the
			// intent is recorded even when the user does not convert. Shown as a
			// sheet because at this exact moment the user has just told us what
			// they want; a red line under a form is the wrong reply to that.
			upgradePrompt = UpgradePrompt(
				title: "One folder per Mac on Free",
				message: error.message
			)
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
			lastNotice = nil
			_ = try await api.resetInbox(inbox.inboxID)
		} catch {
			handle(error)
		}
		await refreshInboxes()
	}

	/// Forget this inbox's finished transfers and keep its address.
	///
	/// Deleting the inbox already cleared its records, but only by giving up the
	/// link — this is the same clearing without that cost. Files already landed
	/// in the folder are not involved: they are on disk and this never touches
	/// disk. Anything still in flight is left alone by the server.
	func clearInboxTransfers(_ inbox: InboxSummary) async {
		guard let api else { return }
		do {
			lastError = nil
			lastNotice = nil
			let cleared = try await api.clearInboxTransfers(inbox.inboxID)
			lastNotice = cleared == 1
				? "Cleared 1 transfer record. Files already received are untouched."
				: "Cleared \(cleared) transfer records. Files already received are untouched."
		} catch {
			handle(error)
		}
	}

	/// The server refuses to delete the default inbox (PRD 6.2), so the failure
	/// has to be shown rather than swallowed — the UI disables the button, but a
	/// stale list would otherwise produce a click that silently does nothing.
	func deleteInbox(_ inbox: InboxSummary) async {
		guard let api else { return }
		do {
			lastError = nil
			lastNotice = nil
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
			await refreshShares()
			return true
		} catch {
			handle(error)
			return false
		}
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
