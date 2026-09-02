import Foundation

/**
 Keeps a WebSocket open to the device's Durable Object so the Mac learns about
 new files immediately.

 The socket is a latency optimisation, never the source of truth: everything it
 announces is also discoverable through `GET /pending`. That is what makes an
 asleep Mac a non-event — it reconnects on wake and collects whatever arrived
 (PRD 10.5).

 Keepalives are plain "ping" text frames, which the Durable Object answers from
 its auto-response pair without ever leaving hibernation. A JSON keepalive would
 wake the object and bill duration on every heartbeat, for every user, forever.
 */
public final class SignallingClient: NSObject, @unchecked Sendable {
	public enum Event: Sendable {
		case connected
		case disconnected
		case fileReady(fileID: String, needsConfirmation: Bool)
	}

	private let lock = NSLock()
	private var task: URLSessionWebSocketTask?
	private var session: URLSession?
	private var reconnectAttempt = 0
	private var stopped = true
	private var keepalive: Timer?
	/// When the server was last heard from. Every keepalive draws a "pong" out
	/// of the Durable Object's auto-response pair, so this advances roughly once
	/// per interval on a healthy socket.
	private var lastInbound = Date.distantPast
	/// Whether `.connected` has been reported for the current socket.
	private var announcedConnected = false

	private static let keepaliveInterval: TimeInterval = 45
	/// Two missed keepalives. One can be lost to a hiccup; two means the socket
	/// is not carrying frames any more.
	private static let livenessTimeout: TimeInterval = 100

	private let makeURL: @Sendable () async -> URL?
	private let onEvent: @Sendable (Event) -> Void

	public init(
		urlProvider: @escaping @Sendable () async -> URL?,
		onEvent: @escaping @Sendable (Event) -> Void
	) {
		self.makeURL = urlProvider
		self.onEvent = onEvent
		super.init()
	}

	public func start() {
		lock.lock()
		let wasStopped = stopped
		stopped = false
		lock.unlock()
		guard wasStopped else { return }
		Task { await connect() }
	}

	public func stop() {
		lock.lock()
		stopped = true
		let current = task
		task = nil
		keepalive?.invalidate()
		keepalive = nil
		lock.unlock()
		current?.cancel(with: .goingAway, reason: nil)
		onEvent(.disconnected)
	}

	/// Called on wake: the old socket died while the machine was asleep, so it is
	/// torn down and rebuilt rather than waited on.
	public func reconnectNow() {
		lock.lock()
		let current = task
		task = nil
		reconnectAttempt = 0
		let isStopped = stopped
		lock.unlock()
		current?.cancel(with: .goingAway, reason: nil)
		guard !isStopped else { return }
		Task { await connect() }
	}

	private func connect() async {
		let isStopped = lock.withLock { stopped }
		guard !isStopped, let url = await makeURL() else { return }

		let configuration = URLSessionConfiguration.default
		configuration.timeoutIntervalForRequest = 60
		let session = URLSession(configuration: configuration)
		let task = session.webSocketTask(with: url)

		lock.withLock {
			self.session = session
			self.task = task
		}

		lock.withLock {
			lastInbound = Date()
			announcedConnected = false
		}
		task.resume()
		// `.connected` is deliberately not announced here. `resume()` only means
		// the handshake was started; the Durable Object replying to "hello" is
		// the first evidence that frames actually flow, and claiming otherwise
		// makes a socket that never opened look healthy in the menu bar.
		send(text: #"{"type":"hello"}"#)
		startKeepalive()
		receive()
	}

	private func startKeepalive() {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			lock.lock()
			keepalive?.invalidate()
			keepalive = Timer.scheduledTimer(
				withTimeInterval: Self.keepaliveInterval, repeats: true
			) { [weak self] _ in
				self?.keepaliveTick()
			}
			lock.unlock()
		}
	}

	/**
	 Heartbeat, and the only thing that notices a socket which has quietly died.

	 A WebSocket carried by a proxy — or by a network that dropped the flow —
	 can stop delivering frames while TCP still reports the connection as
	 established. Nothing throws, `receive` never fails, and the app sits there
	 believing it is online while every push goes into a hole; files then wait
	 out the polling interval and it looks like nothing was sent. So silence is
	 treated as the failure it is, rather than waited on.
	 */
	private func keepaliveTick() {
		lock.lock()
		let current = task
		let silentFor = Date().timeIntervalSince(lastInbound)
		lock.unlock()
		guard let current else { return }

		if silentFor > Self.livenessTimeout {
			current.cancel(with: .goingAway, reason: nil)
			scheduleReconnect()
			return
		}

		// Matches the Durable Object's auto-response pair, so this never wakes it.
		current.send(.string("ping")) { [weak self] error in
			guard error != nil else { return }
			self?.scheduleReconnect()
		}
	}

	private func send(text: String) {
		lock.lock()
		let current = task
		lock.unlock()
		current?.send(.string(text)) { _ in }
	}

	private func receive() {
		lock.lock()
		let current = task
		lock.unlock()
		guard let current else { return }

		current.receive { [weak self] result in
			guard let self else { return }
			switch result {
			case .success(let message):
				let firstFrame: Bool = lock.withLock {
					defer { lastInbound = Date(); announcedConnected = true }
					return !announcedConnected
				}
				// The server answering at all is what proves the socket works.
				if firstFrame { onEvent(.connected) }
				if case .string(let text) = message { handle(text: text) }
				receive()
			case .failure:
				scheduleReconnect()
			}
		}
	}

	private func handle(text: String) {
		guard text != "pong",
			let data = text.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let type = object["type"] as? String
		else { return }

		if type == "file.ready", let fileID = object["file_id"] as? String {
			onEvent(
				.fileReady(
					fileID: fileID,
					needsConfirmation: object["needs_confirmation"] as? Bool ?? false
				))
		}
	}

	private func scheduleReconnect() {
		lock.lock()
		// A dead socket can be reported twice — a failed `receive` and a failed
		// keepalive send race each other. Without this the losers each start
		// their own reconnect and the device ends up with several sockets, all
		// of which the Durable Object counts as "online".
		guard task != nil else {
			lock.unlock()
			return
		}
		let isStopped = stopped
		reconnectAttempt = min(reconnectAttempt + 1, 6)
		let attempt = reconnectAttempt
		task = nil
		announcedConnected = false
		keepalive?.invalidate()
		keepalive = nil
		lock.unlock()

		guard !isStopped else { return }
		onEvent(.disconnected)

		// Capped exponential backoff with jitter, so a server restart does not get
		// a synchronised stampede from every Mac at once.
		let delay = min(pow(2.0, Double(attempt)), 60) + Double.random(in: 0...1)
		Task {
			try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
			await connect()
		}
	}
}
