import CryptoKit
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
	/// `slug` is optional, and the two callers differ on it. The Mac sends one so
	/// onboarding ends on a working URL in a single round trip; iOS sends none,
	/// because there a path is the name given to a *folder* and no folder has been
	/// picked yet. Omitting it registers the name and creates no inbox at all —
	/// which is not a half-built device, only one with no address yet.
	///
	/// No display name is sent: an inbox created here is the device's own, so the
	/// server names it after the name. It can be changed later like any other's.
	public func register(name: String, slug: String? = nil) async throws -> RegistrationResult {
		var payload: [String: Any] = [
			"name": name,
			"pubkey_sig": identity.signingPublicKeyEncoded,
			"pubkey_kex": identity.agreementPublicKeyEncoded,
		]
		if let slug { payload["slug"] = slug }
		let result: RegistrationResult = try await send(
			"POST", "/api/v1/devices", body: payload, authenticated: false)
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

	// MARK: - Outbound shares

	public func shareSalt() async throws -> (salt: String, iterations: Int) {
		struct Response: Codable { let salt: String; let iterations: Int }
		let response: Response = try await send("GET", "/api/v1/shares/salt")
		return (response.salt, response.iterations)
	}

	public func createShare(
		filename: String, size: Int, ttlHours: Double, maxDownloads: Int?,
		password: String?, passwordSalt: String?, code: String?
	) async throws -> ShareHandle {
		var body: [String: Any] = ["filename": filename, "size": size, "ttl_hours": ttlHours]
		if let maxDownloads { body["max_downloads"] = maxDownloads }
		if let password { body["password"] = password }
		if let passwordSalt { body["password_salt"] = passwordSalt }
		if let code, !code.isEmpty { body["code"] = code }
		return try await send("POST", "/api/v1/shares", body: body)
	}

	private func patchShare(_ shareID: String, _ body: [String: Any]) async throws -> ShareSummary {
		try await send("PATCH", "/api/v1/shares/\(shareID)", body: body)
	}

	/// Repath a live link. The old URL stops working the moment this returns.
	public func updateShareCode(_ shareID: String, code: String) async throws -> ShareSummary {
		try await patchShare(shareID, ["code": code])
	}

	/// Stop serving the link without giving up its bytes or its path — the
	/// reversible counterpart to revoking, which deletes the file and cannot be
	/// undone. A paused link answers 423 until it is resumed.
	public func setSharePaused(_ shareID: String, paused: Bool) async throws -> ShareSummary {
		try await patchShare(shareID, ["paused": paused])
	}

	/// Mirrors `nameAvailable`: a path that cannot be checked is never reported
	/// as taken, so the caller gets `nil` rather than a verdict it did not earn.
	///
	/// `forShare` is the share being renamed, and asking without it from an edit
	/// screen is a bug: a share holds its own path, so the server would answer
	/// "taken" about the very row doing the asking.
	public func shareCodeAvailable(_ code: String, forShare shareID: String? = nil) async throws -> Bool {
		struct Response: Codable { let available: Bool }
		let escaped = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code
		let path = shareID.map { "/api/v1/shares/\($0)/code-available/\(escaped)" }
			?? "/api/v1/shares/code-available/\(escaped)"
		let response: Response = try await send("GET", path)
		return response.available
	}

	public func shares() async throws -> (name: String, shares: [ShareSummary]) {
		struct Response: Codable { let name: String; let shares: [ShareSummary] }
		let response: Response = try await send("GET", "/api/v1/shares")
		return (response.name, response.shares)
	}

	/// Stop the link and release the file, but keep the record — and with it the
	/// claim on its path, so no later share can take that address.
	public func revokeShare(_ shareID: String) async throws {
		struct Response: Codable { let revoked: Bool }
		let _: Response = try await send("POST", "/api/v1/shares/\(shareID)/revoke")
	}

	/// Hand back an upload slot for a link that has ended, at the address it
	/// already had. The result is shaped like `createShare`'s so the same upload
	/// loop can carry it.
	public func restoreShare(_ shareID: String) async throws -> ShareHandle {
		try await send("POST", "/api/v1/shares/\(shareID)/restore")
	}

	/// Remove the record entirely, releasing the file and freeing its path.
	public func deleteShare(_ shareID: String) async throws {
		struct Response: Codable { let deleted: Bool }
		let _: Response = try await send("DELETE", "/api/v1/shares/\(shareID)")
	}

	public func uploadShare(
		_ handle: ShareHandle,
		from fileURL: URL,
		onProgress: @escaping @Sendable (Double) -> Void
	) async throws {
		struct Status: Codable { let completedParts: [Int]; enum CodingKeys: String, CodingKey { case completedParts = "completed_parts" } }
		let status: Status = try await send("GET", "/api/v1/shares/\(handle.shareID)")
		let completed = Set(status.completedParts)
		let file = try FileHandle(forReadingFrom: fileURL)
		defer { try? file.close() }
		var hasher = SHA256()
		let fileSize = (try fileURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
		let total = max(1, fileSize)
		var sent = 0
		for part in 1...handle.partCount {
			let expected = min(handle.partSize, max(0, fileSize - sent))
			var data = Data()
			while data.count < expected {
				let chunk = try file.read(upToCount: expected - data.count) ?? Data()
				if chunk.isEmpty { break }
				data.append(chunk)
			}
			guard data.count == expected else {
				throw APIError(status: 0, code: "file_changed", message: "The file changed while it was being uploaded.")
			}
			hasher.update(data: data)
			if !completed.contains(part) {
				let sentBeforePart = sent
				let partByteCount = data.count
				try await putSharePart(handle, part: part, data: data) { partProgress in
					onProgress(min(1, (Double(sentBeforePart) + Double(partByteCount) * partProgress) / Double(total)))
				}
			}
			sent += data.count
			onProgress(min(1, Double(sent) / Double(total)))
		}
		let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
		struct Complete: Codable { let state: String }
		let _: Complete = try await send(
			"POST", "/api/v1/shares/\(handle.shareID)/complete",
			body: ["sha256": digest], authenticated: false,
			extraHeaders: ["Authorization": "Bearer \(handle.token)"]
		)
	}

	private func putSharePart(
		_ handle: ShareHandle, part: Int, data: Data,
		onProgress: @escaping @Sendable (Double) -> Void
	) async throws {
		var request = URLRequest(url: origin.appendingPathComponent("api/v1/shares/\(handle.shareID)/parts/\(part)"))
		request.httpMethod = "PUT"
		request.setValue("Bearer \(handle.token)", forHTTPHeaderField: "Authorization")
		request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
		request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
		let delegate = UploadProgressDelegate(total: data.count, progress: onProgress)
		let (responseData, response) = try await session.upload(for: request, from: data, delegate: delegate)
		try decodeEmpty(responseData, response: response)
	}

	// MARK: - Licensing (PRD 16)

	/// The tier and this month's usage. Cheap, and the only thing the app trusts
	/// on the subject — there is no local notion of "I am Pro".
	public func plan() async throws -> PlanState {
		try await send("GET", "/api/v1/licenses/status")
	}

	/// Verifies a StoreKit transaction with Apple on the Worker and attaches the
	/// resulting non-consumable entitlement to this device. The transaction id is
	/// opaque input; product, bundle, purchase type and refund status all come
	/// from Apple's server response.
	public func verifyApplePurchase(transactionID: UInt64) async throws -> PlanState {
		try await send(
			"POST", "/api/v1/licenses/apple/verify",
			body: ["transaction_id": String(transactionID)]
		)
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
		allowRetry: Bool = true,
		extraHeaders: [String: String] = [:]
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
		for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }

		let (data, response) = try await session.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0

		if status == 401, authenticated, allowRetry, deviceID != nil {
			// Sessions are short-lived by design; renewing one is silent.
			_ = try await authenticate()
			return try await send(method, path, body: body, authenticated: true, allowRetry: false, extraHeaders: extraHeaders)
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

	private func decodeEmpty(_ data: Data, response: URLResponse) throws {
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard (200..<300).contains(status) else {
			let decoded = try? JSONDecoder().decode(WireError.self, from: data)
			throw APIError(status: status, code: decoded?.error ?? "http_\(status)", message: decoded?.message ?? "Request failed (\(status)).")
		}
	}

	private struct WireError: Codable {
		let error: String
		let message: String
	}
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
	private let total: Int64
	private let progress: @Sendable (Double) -> Void

	init(total: Int, progress: @escaping @Sendable (Double) -> Void) {
		self.total = Int64(max(1, total))
		self.progress = progress
	}

	func urlSession(
		_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
		totalBytesSent: Int64, totalBytesExpectedToSend: Int64
	) {
		progress(min(1, Double(totalBytesSent) / Double(total)))
	}
}
