import CryptoKit
import XCTest

@testable import StolnkCore

/**
 Drives the real receiving stack against a running dev server.

 The unit tests cover each piece; this covers the seam between them —
 `APIClient` authenticating with a P-256 key, `Receiver` orchestrating,
 `DecryptingSink` streaming, and the file arriving quarantined under a sanitised
 name. Everything from `POST /transfers` onwards is the code that ships.

 Opt-in, because it needs a server:

   npm run dev                                  # in stolnk/
   STOLNK_LIVE=1 swift test
 */
final class LiveDeliveryTests: XCTestCase {
	private var origin: URL!
	private var workspace: URL!

	override func setUpWithError() throws {
		try XCTSkipUnless(
			ProcessInfo.processInfo.environment["STOLNK_LIVE"] == "1",
			"set STOLNK_LIVE=1 with a dev server running"
		)
		origin = URL(
			string: ProcessInfo.processInfo.environment["STOLNK_ORIGIN"] ?? "http://localhost:5173")!
		workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent("stolnk-live-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let workspace { try? FileManager.default.removeItem(at: workspace) }
	}

	func testFileArrivesDecryptedQuarantinedAndIntact() async throws {
		// A software-backed identity: the enclave is not available in a test
		// process and the wire format is identical either way.
		let identity = DeviceIdentity(
			signing: .software(P256.Signing.PrivateKey()),
			agreement: .software(P256.KeyAgreement.PrivateKey()),
			isEnclaveBacked: false
		)
		let api = APIClient(origin: origin, identity: identity)
		let deviceName = "live-\(UUID().uuidString.prefix(8).lowercased())"
		_ = try await api.register(name: deviceName, slug: "inbox")

		let (_, inboxes) = try await api.inboxes()
		let inbox = try XCTUnwrap(inboxes.first)

		let destination = workspace.appendingPathComponent("landing")
		try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
		let store = InboxStore(directory: workspace.appendingPathComponent("state"))
		store.bind(inboxID: inbox.inboxID, to: destination)

		// A name a hostile sender might pick: a leading dot to hide it, a
		// right-to-left override to disguise the extension, and a path separator.
		let hostileName = ".\u{202E}gepj/客户 photo.jpg"
		let payload = Data((0..<(1_500_000)).map { UInt8(($0 &* 31 &+ 7) % 251) })
		let expected = Data(SHA256.hash(data: payload)).hexString

		try await send(payload, named: hostileName, to: inbox, api: api)

		let confirmed = ConfirmationRecorder()
		let receiver = Receiver(
			api: api,
			identity: identity,
			store: store,
			events: ReceiverEvents(
				confirm: { _, _ in
					await confirmed.record()
					return .acceptAlways
				}
			)
		)
		await receiver.poll()

		let landed = try FileManager.default.contentsOfDirectory(atPath: destination.path)
			.filter { !$0.hasPrefix(".") }
		XCTAssertEqual(landed.count, 1, "expected exactly one file, got \(landed)")

		let name = try XCTUnwrap(landed.first)
		// PRD 13.2 — the first file of a new session is confirmed, not silent.
		let asked = await confirmed.count
		XCTAssertEqual(asked, 1, "the first file of a session should require confirmation")

		// PRD 12.2 — the disguise is gone before anything reaches disk.
		XCTAssertFalse(name.hasPrefix("."), "leading dot survived: \(name)")
		XCTAssertFalse(name.contains("/"), "path separator survived: \(name)")
		XCTAssertFalse(
			name.unicodeScalars.contains { $0.value == 0x202E }, "RTLO survived: \(name)")

		let url = destination.appendingPathComponent(name)
		let contents = try Data(contentsOf: url)
		XCTAssertEqual(Data(SHA256.hash(data: contents)).hexString, expected, "content mismatch")

		// PRD 12.3 — landed files carry the Gatekeeper marker.
		XCTAssertTrue(FileLanding.hasQuarantine(url), "quarantine attribute missing")

		// PRD 9.3 / 12.1 — no working file left behind.
		let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path)
			.filter { $0.hasSuffix(".part") }
		XCTAssertTrue(leftovers.isEmpty, "left a .part file: \(leftovers)")

		// PRD 8.5 — after the ACK there is nothing left waiting.
		let pending = try await api.pending()
		XCTAssertTrue(pending.files.isEmpty, "file still pending after delivery")
	}

	/**
	 A dismissed prompt must not cost the sender their file, and must not wedge
	 the receiver.

	 The regression this pins: `askForConfirmation` used to have no answer for a
	 closed window, so the continuation was never resumed, `poll` never
	 returned, and the `isRunning` guard then swallowed every later poll —
	 socket push, timer, wake, launch — for the rest of the process. A Mac in
	 that state accepts nothing and reports nothing. If `poll` ever hangs again
	 this test does not fail an assertion, it times out, which is the point.
	 */
	func testPostponedConfirmationKeepsTheFileAndAsksAgain() async throws {
		let identity = DeviceIdentity(
			signing: .software(P256.Signing.PrivateKey()),
			agreement: .software(P256.KeyAgreement.PrivateKey()),
			isEnclaveBacked: false
		)
		let api = APIClient(origin: origin, identity: identity)
		let deviceName = "live-\(UUID().uuidString.prefix(8).lowercased())"
		_ = try await api.register(name: deviceName, slug: "inbox")

		let (_, inboxes) = try await api.inboxes()
		let inbox = try XCTUnwrap(inboxes.first)

		let destination = workspace.appendingPathComponent("landing")
		try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
		let store = InboxStore(directory: workspace.appendingPathComponent("state"))
		store.bind(inboxID: inbox.inboxID, to: destination)

		let payload = Data("postponed".utf8)
		try await send(payload, named: "note.txt", to: inbox, api: api)

		func receiver(deciding decision: ConfirmationDecision, recorder: ConfirmationRecorder)
			-> Receiver
		{
			Receiver(
				api: api,
				identity: identity,
				store: store,
				events: ReceiverEvents(
					confirm: { _, _ in
						await recorder.record()
						return decision
					}
				)
			)
		}

		let firstAsk = ConfirmationRecorder()
		await receiver(deciding: .postpone, recorder: firstAsk).poll()

		let askedOnce = await firstAsk.count
		XCTAssertEqual(askedOnce, 1, "the file should have been offered once")

		let afterPostpone = try FileManager.default.contentsOfDirectory(atPath: destination.path)
		XCTAssertTrue(afterPostpone.isEmpty, "postponing wrote something: \(afterPostpone)")

		// Postponing is not declining: the relay still holds it.
		let stillPending = try await api.pending()
		XCTAssertEqual(stillPending.files.count, 1, "postponing discarded the file")

		let secondAsk = ConfirmationRecorder()
		await receiver(deciding: .accept, recorder: secondAsk).poll()

		let askedAgain = await secondAsk.count
		XCTAssertEqual(askedAgain, 1, "the next poll should ask again")

		let landed = try FileManager.default.contentsOfDirectory(atPath: destination.path)
			.filter { !$0.hasPrefix(".") }
		XCTAssertEqual(landed, ["note.txt"], "file did not land after accepting")
		XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("note.txt")), payload)
		let drained = try await api.pending()
		XCTAssertTrue(drained.files.isEmpty, "still pending after delivery")
	}

	/**
	 A prompt that is never answered at all must not hold the receiver open.

	 The app layer's own watchdog is the path that normally reclaims an
	 unattended prompt; this covers the case where the app layer answers
	 nothing, ever — a UI bug, a deadlocked main actor. `poll` has to come back
	 regardless, or `isRunning` stays set and every later poll is swallowed.
	 */
	func testUnansweredConfirmationStillReleasesThePoll() async throws {
		let identity = DeviceIdentity(
			signing: .software(P256.Signing.PrivateKey()),
			agreement: .software(P256.KeyAgreement.PrivateKey()),
			isEnclaveBacked: false
		)
		let api = APIClient(origin: origin, identity: identity)
		let deviceName = "live-\(UUID().uuidString.prefix(8).lowercased())"
		_ = try await api.register(name: deviceName, slug: "inbox")

		let (_, inboxes) = try await api.inboxes()
		let inbox = try XCTUnwrap(inboxes.first)

		let destination = workspace.appendingPathComponent("landing")
		try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
		let store = InboxStore(directory: workspace.appendingPathComponent("state"))
		store.bind(inboxID: inbox.inboxID, to: destination)

		try await send(Data("stuck".utf8), named: "note.txt", to: inbox, api: api)

		let receiver = Receiver(
			api: api,
			identity: identity,
			store: store,
			// Never answers. This is the shape of a closed window before the fix.
			events: ReceiverEvents(confirm: { _, _ in
				await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
				return .accept
			}),
			confirmationDeadline: 300_000_000
		)

		await receiver.poll()

		let running = await receiver.isRunning
		XCTAssertFalse(running, "poll did not release; later polls would be swallowed")

		// Treated as postponed, so the file is still there to be offered again.
		let landedNothing = try FileManager.default.contentsOfDirectory(atPath: destination.path)
		XCTAssertTrue(landedNothing.isEmpty, "an unanswered prompt wrote something")
		let stillPending = try await api.pending()
		XCTAssertEqual(stillPending.files.count, 1, "an unanswered prompt discarded the file")
	}

	/**
	 The push has to reach the app, not merely be sent.

	 This is the seam that failed in production while every other test passed:
	 the socket connected, presence reported the Mac online, and the frame still
	 never arrived — so files waited out the five-minute poll and the Mac looked
	 dead. Presence is not evidence of delivery, and neither is a green socket.
	 */
	func testUploadPushesFileReadyToTheApp() async throws {
		let identity = DeviceIdentity(
			signing: .software(P256.Signing.PrivateKey()),
			agreement: .software(P256.KeyAgreement.PrivateKey()),
			isEnclaveBacked: false
		)
		let api = APIClient(origin: origin, identity: identity)
		let deviceName = "live-\(UUID().uuidString.prefix(8).lowercased())"
		_ = try await api.register(name: deviceName, slug: "inbox")

		let (_, inboxes) = try await api.inboxes()
		let inbox = try XCTUnwrap(inboxes.first)

		let connected = expectation(description: "socket reports connected")
		let pushed = expectation(description: "file.ready arrives")
		let seen = FileReadyRecorder()

		let client = SignallingClient(
			urlProvider: { await api.signallingURL() },
			onEvent: { event in
				switch event {
				case .connected:
					connected.fulfill()
				case .fileReady(let fileID, _):
					Task {
						if await seen.record(fileID) { pushed.fulfill() }
					}
				case .disconnected:
					break
				}
			}
		)
		client.start()
		defer { client.stop() }

		// `.connected` must mean the server actually answered, not just that a
		// task was resumed — otherwise it cannot be trusted as a health signal.
		await fulfillment(of: [connected], timeout: 10)

		try await send(Data("pushed".utf8), named: "pushed.txt", to: inbox, api: api)
		await fulfillment(of: [pushed], timeout: 10)

		let fileID = await seen.fileID
		XCTAssertNotNil(fileID, "the push carried no file id")
	}

	// MARK: - A minimal sender, standing in for the browser

	private func send(
		_ plaintext: Data,
		named name: String,
		to inbox: InboxSummary,
		api: APIClient
	) async throws {
		// The sender addresses the inbox by host, not by path, so this one call
		// goes to the subdomain. Everything below it is token-authenticated and
		// stays on the apex, where the Mac already talks.
		let sender = try XCTUnwrap(URL(string: inbox.url))
		let slug = inbox.slug
		let resolved = try await json(
			"GET", "/api/v1/resolve?slug=\(slug)",
			base: sender)
		let kexPub = try XCTUnwrap(
			Base64URL.decode(try XCTUnwrap(resolved["kex_pub"] as? String)))
		let recipient = try P256.KeyAgreement.PublicKey(x963Representation: kexPub)

		let contentKey = SymmetricKey(size: .bits256)
		let ephemeral = P256.KeyAgreement.PrivateKey()
		let kek = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
			.hkdfDerivedSymmetricKey(
				using: SHA256.self,
				salt: Data(),
				sharedInfo: CryptoBox.kekInfo,
				outputByteCount: 32
			)

		let keyIV = AES.GCM.Nonce()
		let wrapped = try AES.GCM.seal(
			contentKey.withUnsafeBytes { Data($0) }, using: kek, nonce: keyIV)
		let nameIV = AES.GCM.Nonce()
		let sealedName = try AES.GCM.seal(Data(name.utf8), using: contentKey, nonce: nameIV)
		let noncePrefix = Data((0..<4).map { _ in UInt8.random(in: 0...255) })

		let created = try await json(
			"POST", "/api/v1/transfers",
			body: [
				"inbox_id": inbox.inboxID,
				"files": [
					[
						"enc_name": Base64URL.encode(sealedName.ciphertext + sealedName.tag),
						"name_iv": Base64URL.encode(Data(nameIV)),
						"size": plaintext.count,
						"nonce_prefix": Base64URL.encode(noncePrefix),
						"wrapped_key": Base64URL.encode(wrapped.ciphertext + wrapped.tag),
						"key_iv": Base64URL.encode(Data(keyIV)),
						"eph_pub": Base64URL.encode(ephemeral.publicKey.x963Representation),
					]
				],
			])

		let transferID = try XCTUnwrap(created["transfer_id"] as? String)
		let token = try XCTUnwrap(created["token"] as? String)
		let files = try XCTUnwrap(created["files"] as? [[String: Any]])
		let fileID = try XCTUnwrap(files.first?["file_id"] as? String)

		let total = CryptoBox.chunkCount(forPlaintextSize: plaintext.count)
		var ciphertext = Data()
		for index in 0..<total {
			let start = index * CryptoBox.chunkSize
			let end = min(plaintext.count, start + CryptoBox.chunkSize)
			ciphertext.append(
				try CryptoBox.encryptChunk(
					plaintext.subdata(in: start..<end),
					index: index,
					total: total,
					fileID: CryptoBox.fileIDBytes(fileID),
					noncePrefix: noncePrefix,
					contentKey: contentKey
				))
		}

		var upload = URLRequest(
			url: origin.appendingPathComponent("api/v1/transfers/\(transferID)/files/\(fileID)/parts/1"))
		upload.httpMethod = "PUT"
		upload.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
		let (_, partResponse) = try await URLSession.shared.upload(for: upload, from: ciphertext)
		XCTAssertEqual((partResponse as? HTTPURLResponse)?.statusCode, 200)

		_ = try await json(
			"POST", "/api/v1/transfers/\(transferID)/files/\(fileID)/complete",
			body: ["plain_sha256": Data(SHA256.hash(data: plaintext)).hexString],
			token: token
		)
	}

	private func json(
		_ method: String,
		_ path: String,
		body: [String: Any]? = nil,
		token: String? = nil,
		base: URL? = nil
	) async throws -> [String: Any] {
		let root = base.map { "\($0.scheme ?? "http")://\($0.host ?? "")\($0.port.map { ":\($0)" } ?? "")" }
			?? origin.absoluteString
		var request = URLRequest(url: URL(string: root + path)!)
		request.httpMethod = method
		if let body {
			request.httpBody = try JSONSerialization.data(withJSONObject: body)
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
		let (data, response) = try await URLSession.shared.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard (200..<300).contains(status) else {
			throw NSError(
				domain: "live", code: status,
				userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
		}
		return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
	}
}

private actor ConfirmationRecorder {
	private(set) var count = 0
	func record() { count += 1 }
}

private actor FileReadyRecorder {
	private(set) var fileID: String?

	/// True the first time only, so the expectation is not over-fulfilled if the
	/// server ever pushes the same file twice.
	func record(_ id: String) -> Bool {
		guard fileID == nil else { return false }
		fileID = id
		return true
	}
}
