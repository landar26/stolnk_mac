import Foundation

/// Talks to the Worker. Holds the device session token and renews it by
/// re-signing a challenge whenever the server says it has expired.
public actor APIClient {
	public let origin: URL
	private let identity: DeviceIdentity
	private let session: URLSession
	private var deviceID: String?
	private var token: String?

	public init(origin: URL, identity: DeviceIdentity, session: URLSession = .shared) {
		self.origin = origin
		self.identity = identity
		self.session = session
	}

	public func adopt(deviceID: String, token: String?) {
		self.deviceID = deviceID
		self.token = token
	}

	public var currentDeviceID: String? { deviceID }
	public var currentToken: String? { token }

	// MARK: - Registration and auth

	/// The name is part of registration, not a later upgrade: it *is* the
	/// identity (PRD 6.1). A name already in use fails with 409 and creates
	/// nothing, so retrying with a different one is clean.
	///
	/// No display name is sent: the first inbox is the device's own, so the server
	/// names it after the name. It can be changed later like any other inbox's.
	public func register(name: String, slug: String) async throws -> RegistrationResult {
		let result: RegistrationResult = try await send(
			"POST", "/api/v1/devices",
			body: [
				"name": name,
				"slug": slug,
				"pubkey_sig": identity.signingPublicKeyEncoded,
				"pubkey_kex": identity.agreementPublicKeyEncoded,
			],
			authenticated: false
		)
		deviceID = result.deviceID
		token = result.token
		return result
	}

	/// Challenge-response against the Secure Enclave key. No password exists to
	/// be phished, and nothing exportable is ever sent.
	@discardableResult
	public func authenticate() async throws -> String {
		guard let deviceID else { throw APIError(status: 0, code: "no_device", message: "Not registered.") }
		struct Challenge: Codable { let nonce: String }
		let challenge: Challenge = try await send(
			"GET", "/api/v1/devices/\(deviceID)/challenge", authenticated: false)
		let signature = try identity.sign(challenge: challenge.nonce)
		let session: SessionToken = try await send(
			"POST", "/api/v1/devices/\(deviceID)/auth",
			body: ["nonce": challenge.nonce, "signature": signature],
			authenticated: false
		)
		token = session.token
		return session.token
	}

	// MARK: - Inboxes

	/// The name rides along, so a refresh keeps the displayed address current.
	public func inboxes() async throws -> (name: String, inboxes: [InboxSummary]) {
		struct Response: Codable { let name: String; let inboxes: [InboxSummary] }
		let response: Response = try await send("GET", "/api/v1/inboxes")
		return (response.name, response.inboxes)
	}

	public func createInbox(slug: String, displayName: String) async throws -> InboxSummary {
		try await send(
			"POST", "/api/v1/inboxes", body: ["slug": slug, "display_name": displayName])
	}

	/// `slug` nil leaves the path alone. There is no empty path to move to.
	public func updateInbox(
		_ inboxID: String,
		displayName: String? = nil,
		slug: String? = nil,
		paused: Bool? = nil
	) async throws -> InboxSummary {
		var body: [String: Any] = [:]
		if let displayName { body["display_name"] = displayName }
		if let slug { body["slug"] = slug }
		if let paused { body["paused"] = paused }
		return try await send("PATCH", "/api/v1/inboxes/\(inboxID)", body: body)
	}

	public func resetInbox(_ inboxID: String) async throws -> InboxSummary {
		try await send("POST", "/api/v1/inboxes/\(inboxID)/reset")
	}

	public func deleteInbox(_ inboxID: String) async throws {
		struct Response: Codable { let deleted: Bool }
		let _: Response = try await send("DELETE", "/api/v1/inboxes/\(inboxID)")
	}

	/// Forget this inbox's finished transfers, keeping the inbox and its address.
	/// Anything still in flight is left alone by the server. Returns how many
	/// records went, which is the only feedback the action can give: there is no
	/// history screen for the result to be visible in.
	public func clearInboxTransfers(_ inboxID: String) async throws -> Int {
		struct Response: Codable { let cleared: Int }
		let response: Response = try await send("DELETE", "/api/v1/inboxes/\(inboxID)/transfers")
		return response.cleared
	}

	/// Renaming. Every link moves with the name, so the server hands back the
	/// whole list rather than making the caller refresh.
	public func rename(to name: String) async throws -> [InboxSummary] {
		struct Response: Codable { let name: String; let inboxes: [InboxSummary] }
		let response: Response = try await send("POST", "/api/v1/names", body: ["name": name])
		return response.inboxes
	}

	public func nameAvailable(_ name: String) async throws -> Bool {
		struct Response: Codable { let name: String; let available: Bool }
		let escaped =
			name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
		let response: Response = try await send("GET", "/api/v1/names/\(escaped)/available")
		return response.available
	}

	// MARK: - Licensing (PRD 16)

	/// The tier and this month's usage. Cheap, and the only thing the app trusts
	/// on the subject — there is no local notion of "I am Pro".
	public func plan() async throws -> PlanState {
		try await send("GET", "/api/v1/licenses/status")
	}

	/// Claims a seat for this Mac. The key goes to our own server, which holds
	/// the Creem credentials; nothing in this app can talk to Creem directly, and
	/// no API key ships inside a downloadable binary.
	public func activateLicense(key: String) async throws -> PlanState {
		try await send("POST", "/api/v1/licenses/activate", body: ["key": key])
	}

	/// Releases a seat.
	///
	/// Authenticated by the key rather than by the session, deliberately: PRD 7.2
	/// means a Mac that is lost or dead can never sign anything again, so a seat
	/// that could only be freed by its own device would be stranded forever. The
	/// same call therefore works for *this* Mac and for one that is gone.
	public func releaseLicense(key: String, deviceID: String) async throws {
		struct Response: Codable { let released: Bool }
		let _: Response = try await send(
			"POST", "/api/v1/licenses/deactivate",
			body: ["key": key, "device_id": deviceID],
			authenticated: false
		)
	}

	/// Where to send someone who wants to buy. The Worker redirects to the
	/// checkout, so the price, the early-bird code and the provider can all
	/// change without shipping a new build.
	public nonisolated func purchaseURL() -> URL {
		origin.appendingPathComponent("api/v1/checkout")
	}

	// MARK: - Delivery

	public func pending() async throws -> PendingResponse {
		try await send("GET", "/api/v1/pending")
	}

	/// Deleting the relay object is the server's synchronous response to this
	/// call (PRD 8.5), so it must only be sent once the file is safely landed.
	///
	/// `plainSHA256` is sent only on the LAN path (PRD 8.2). There the sender
	/// never calls `complete`, so the server's row has no digest — and this Mac,
	/// having just checked it against the bytes it wrote, is the only party that
	/// can supply one worth having.
	public func acknowledge(fileID: String, plainSHA256: String? = nil) async throws {
		struct Response: Codable { let delivered: Bool }
		let body = plainSHA256.map { ["plain_sha256": $0] }
		let _: Response = try await send("POST", "/api/v1/files/\(fileID)/ack", body: body)
	}

	/// PRD 8.2 — the envelope for a file arriving over a DataChannel, which never
	/// appears in `/pending` because it never reaches the relay.
	public func lanFileMeta(fileID: String) async throws -> PendingFile {
		struct Response: Decodable { let file: PendingFile }
		let response: Response = try await send("GET", "/api/v1/files/\(fileID)/meta")
		return response.file
	}

	public func contentRequest(fileID: String, from offset: Int) async throws -> URLRequest {
		var request = URLRequest(url: origin.appendingPathComponent("api/v1/files/\(fileID)/content"))
		if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
		if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
		return request
	}

	public func signallingURL() -> URL? {
		guard let token else { return nil }
		var components = URLComponents(
			url: origin.appendingPathComponent("api/v1/ws/device"), resolvingAgainstBaseURL: false)
		components?.scheme = origin.scheme == "https" ? "wss" : "ws"
		components?.queryItems = [URLQueryItem(name: "token", value: token)]
		return components?.url
	}

	// MARK: - Plumbing

	private func send<T: Decodable>(
		_ method: String,
		_ path: String,
		body: [String: Any]? = nil,
		authenticated: Bool = true,
		allowRetry: Bool = true
	) async throws -> T {
		var request = URLRequest(url: origin.appendingPathComponent(String(path.dropFirst())))
		request.httpMethod = method
		if let body {
			request.httpBody = try JSONSerialization.data(withJSONObject: body)
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		if authenticated, let token {
			request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}

		let (data, response) = try await session.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0

		if status == 401, authenticated, allowRetry, deviceID != nil {
			// Sessions are short-lived by design; renewing one is silent.
			_ = try await authenticate()
			return try await send(method, path, body: body, authenticated: true, allowRetry: false)
		}

		guard (200..<300).contains(status) else {
			let decoded = try? JSONDecoder().decode(WireError.self, from: data)
			throw APIError(
				status: status,
				code: decoded?.error ?? "http_\(status)",
				message: decoded?.message ?? "Request failed (\(status))."
			)
		}
		return try JSONDecoder().decode(T.self, from: data)
	}

	private struct WireError: Codable {
		let error: String
		let message: String
	}
}
