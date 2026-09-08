import Foundation
@preconcurrency import WebRTC

/**
 PRD 8.2 — the Mac's half of a LAN direct transfer.

 A send page on the same network offers a DataChannel; this answers it, and the
 ciphertext arrives peer to peer instead of through R2. Nothing else changes: the
 bytes are the same bytes (docs/wire-format.md), they go into the same
 `DecryptingSink`, and they land through the same `Receiver.land` — quarantine,
 unique name, atomic rename, ACK. LAN is a second pipe onto one stream, not a
 second format, which is why `testdata/vectors.json` covers it without knowing
 it exists.

 Host candidates only, `iceServers: []`. No STUN, no TURN, nothing to deploy and
 nothing to operate. Two machines on the same subnet connect; anything else
 fails, and failing is fine — the sender falls back to the relay and is never
 shown an error for it.

 What this deliberately does not do is trust the peer. The DataChannel says only
 which file id is coming; every fact that decides what happens to the bytes —
 the size that frames the chunks, the envelope that decrypts them, and above all
 the inbox that decides which folder they land in — is fetched from the server
 under this device's own credentials.
 */
public final class LanReceiver: NSObject, @unchecked Sendable {
	/**
	 One negotiation, and the file transfer running over it.

	 `@unchecked Sendable` because every mutable field is written and read under
	 `LanReceiver.lock`, and the immutable `peer` is safe to touch from any
	 thread by libwebrtc's own contract. It crosses threads constantly: offers
	 arrive on the socket's queue, ciphertext on libwebrtc's signalling thread,
	 and landing happens in a Task.
	 */
	private final class Session: @unchecked Sendable {
		let peer: RTCPeerConnection
		var channel: RTCDataChannel?
		var file: PendingFile?
		var landing: Receiver.Landing?
		var failure: Error?
		init(peer: RTCPeerConnection) { self.peer = peer }
	}

	/**
	 One factory for the process.

	 Creating one starts libwebrtc's signalling, worker and network threads, and
	 releasing it stops them; doing that per transfer would churn threads for no
	 reason. `nil` codec factories because this carries no media — only a data
	 channel — and asking for encoders would pull in hardware we never use.
	 */
	private static let factory: RTCPeerConnectionFactory = {
		RTCInitializeSSL()
		// libwebrtc logs at INFO to stderr by default, which in a menu bar app
		// means a Console full of ICE chatter nobody asked for.
		RTCSetMinDebugLogLevel(.warning)
		return RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
	}()

	private let lock = NSLock()
	private var sessions: [String: Session] = [:]

	private let receiver: Receiver
	private let api: APIClient
	private let answer: @Sendable (String, Data) -> Void
	private let onLanded: @Sendable ([LandedFile]) -> Void

	/**
	 Only ever one negotiation at a time.

	 A signalling token is handed to anyone holding the inbox link, so offers are
	 not a scarce or trusted resource. One at a time bounds what a stranger can
	 make this machine allocate, and matches the product anyway: a send page
	 uploads one file at a time.
	 */
	private static let maxSessions = 1

	public init(
		receiver: Receiver,
		api: APIClient,
		answer: @escaping @Sendable (String, Data) -> Void,
		onLanded: @escaping @Sendable ([LandedFile]) -> Void
	) {
		self.receiver = receiver
		self.api = api
		self.answer = answer
		self.onLanded = onLanded
		super.init()
	}

	// MARK: - Signalling

	public func handle(session id: String, payload raw: Data) {
		guard let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
			return
		}
		switch payload["kind"] as? String {
		case "offer":
			if let sdp = payload["sdp"] as? String { offered(id, sdp: sdp) }
		case "ice":
			if let candidate = payload["candidate"] as? [String: Any] { iced(id, candidate) }
		default:
			break
		}
	}

	public func stopAll() {
		let open = lock.withLock { () -> [Session] in
			let all = Array(sessions.values)
			sessions.removeAll()
			return all
		}
		for session in open { close(session) }
	}

	private func offered(_ id: String, sdp: String) {
		let existing = lock.withLock { sessions[id] }
		if existing != nil { return }

		let config = RTCConfiguration()
		// PRD 8.2 — the whole design in one line. No STUN, no TURN: only addresses
		// this machine already has, which is exactly the set that can be reached
		// without leaving the network.
		config.iceServers = []
		config.sdpSemantics = .unifiedPlan
		// With no reflexive or relay candidates to wait for, there is nothing that
		// arrives late.
		config.continualGatheringPolicy = .gatherOnce
		config.candidateNetworkPolicy = .all
		// Some networks hand out nothing but link-local addresses.
		config.disableLinkLocalNetworks = false
		// A faster DTLS handshake than RSA, and the sender is waiting on it.
		config.keyType = .ECDSA

		let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
		guard
			let peer = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
		else { return }

		let session = Session(peer: peer)
		let accepted = lock.withLock { () -> Bool in
			guard sessions.count < Self.maxSessions else { return false }
			sessions[id] = session
			return true
		}
		guard accepted else {
			peer.close()
			return
		}

		peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
			guard let self, error == nil else {
				self?.finish(id)
				return
			}
			peer.answer(for: constraints) { [weak self] local, error in
				guard let self, let local, error == nil else {
					self?.finish(id)
					return
				}
				peer.setLocalDescription(local) { [weak self] error in
					guard let self, error == nil else {
						self?.finish(id)
						return
					}
					self.reply(id, ["kind": "answer", "sdp": local.sdp])
				}
			}
		}
	}

	private func iced(_ id: String, _ candidate: [String: Any]) {
		guard let session = lock.withLock({ sessions[id] }),
			let sdp = candidate["candidate"] as? String
		else { return }
		session.peer.add(
			RTCIceCandidate(
				sdp: sdp,
				sdpMLineIndex: Int32(candidate["sdpMLineIndex"] as? Int ?? 0),
				sdpMid: candidate["sdpMid"] as? String
			)
		) { _ in
			// One route lost is not the session; ICE has others to try.
		}
	}

	private func sessionID(for peer: RTCPeerConnection) -> String? {
		lock.withLock { sessions.first(where: { $0.value.peer === peer })?.key }
	}

	private func sessionID(for channel: RTCDataChannel) -> String? {
		lock.withLock { sessions.first(where: { $0.value.channel === channel })?.key }
	}

	private func finish(_ id: String) {
		guard let session = lock.withLock({ sessions.removeValue(forKey: id) }) else { return }
		close(session)
	}

	private func close(_ session: Session) {
		// A sink that never finished has a `.part` file to remove. PRD 9.3: never
		// leave half a file behind, whatever went wrong.
		if session.landing != nil && session.file != nil {
			session.landing?.sink.abandon()
		}
		session.channel?.close()
		session.peer.close()
	}

	// MARK: - The transfer itself

	private func control(_ session: Session, _ id: String, _ text: String) {
		guard let data = text.data(using: .utf8),
			let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let type = message["type"] as? String
		else { return }

		switch type {
		case "file.begin":
			guard let fileID = message["file_id"] as? String else { return }
			begin(session, id, fileID: fileID)
		case "file.end":
			guard let digest = message["plain_sha256"] as? String else { return }
			end(session, id, digest: digest)
		default:
			break
		}
	}

	private func begin(_ session: Session, _ id: String, fileID: String) {
		Task { [weak self] in
			guard let self else { return }
			do {
				// The peer said only which file. Everything that matters comes from
				// the server, authenticated as this device — most of all `inboxID`,
				// which is what decides the folder these bytes end up in.
				let file = try await self.api.lanFileMeta(fileID: fileID)
				guard let landing = try await self.receiver.prepare(file) else {
					// The inbox has no folder bound, so nothing can land here at all.
					// Ending the session frees the one slot rather than holding it
					// until the sender gives up.
					self.reject(session, fileID: fileID, reason: "That inbox is not set up on this Mac.")
					self.finish(id)
					return
				}
				self.lock.withLock {
					session.file = file
					session.landing = landing
				}
				/*
				 Only now may the sender start. Fetching the envelope is a round
				 trip to the Worker, and the send page can put frames on the wire
				 the instant it has written `file.begin` — so without this the
				 opening frames of every LAN transfer would arrive before there
				 was a sink to take them. On a local network the handshake costs
				 well under a millisecond; the race it removes is the whole first
				 chunk of the file.
				 */
				self.send(session, ["type": "file.ready", "file_id": fileID])
			} catch {
				self.reject(session, fileID: fileID, reason: "This Mac could not accept that file.")
				self.finish(id)
			}
		}
	}

	private func end(_ session: Session, _ id: String, digest: String) {
		Task { [weak self] in
			guard let self else { return }
			let (file, landing, failure) = self.lock.withLock {
				(session.file, session.landing, session.failure)
			}
			guard let file, let landing else { return }

			do {
				if let failure { throw failure }
				// The digest the sender computed over the plaintext, checked against
				// what was actually written. The AEAD already authenticates every
				// chunk; this catches the file being the wrong file.
				try landing.sink.finish(expecting: digest)
			} catch {
				landing.sink.abandon()
				self.reject(session, fileID: file.fileID, reason: "The file did not arrive intact.")
				self.finish(id)
				return
			}

			do {
				// `digest` rather than `file.plainSHA256`: on this path the server's
				// row has none, because the sender never called `complete`.
				if let landed = try await self.receiver.land(file, landing, digest: digest) {
					self.onLanded([landed])
					self.confirm(session, fileID: file.fileID)
				} else {
					self.reject(session, fileID: file.fileID, reason: "This Mac could not store the file.")
				}
			} catch {
				self.reject(session, fileID: file.fileID, reason: "This Mac could not store the file.")
			}
			self.finish(id)
		}
	}

	private func confirm(_ session: Session, fileID: String) {
		send(session, ["type": "file.ok", "file_id": fileID])
	}

	private func reject(_ session: Session, fileID: String, reason: String) {
		send(session, ["type": "file.error", "file_id": fileID, "message": reason])
	}

	private func send(_ session: Session, _ message: [String: Any]) {
		guard let channel = session.channel,
			let data = try? JSONSerialization.data(withJSONObject: message)
		else { return }
		channel.sendData(RTCDataBuffer(data: data, isBinary: false))
	}
}

// MARK: - RTCPeerConnectionDelegate

extension LanReceiver: RTCPeerConnectionDelegate {
	public func peerConnection(_ peer: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
		guard let id = sessionID(for: peer), let session = lock.withLock({ sessions[id] }) else {
			dataChannel.close()
			return
		}
		/*
		 The ciphertext is one unframed stream, so a reordered message does not
		 cost one chunk — it fails the GCM tag of every chunk after it. Refusing
		 an unordered channel turns that into a clean refusal rather than a file
		 that arrives corrupt.
		 */
		guard dataChannel.isOrdered else {
			dataChannel.close()
			finish(id)
			return
		}
		// Held in the session because the Objective-C wrapper does not retain it:
		// drop the reference and the channel closes under you.
		lock.withLock { session.channel = dataChannel }
		dataChannel.delegate = self
	}

	public func peerConnection(_ peer: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
		guard let id = sessionID(for: peer) else { return }
		var payload: [String: Any] = ["kind": "ice"]
		var wire: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": Int(candidate.sdpMLineIndex)]
		if let mid = candidate.sdpMid { wire["sdpMid"] = mid }
		payload["candidate"] = wire
		reply(id, payload)
	}

	/// Signalling goes back out as bytes, so `SignallingClient` never has to
	/// know what is in it.
	private func reply(_ id: String, _ payload: [String: Any]) {
		guard JSONSerialization.isValidJSONObject(payload),
			let data = try? JSONSerialization.data(withJSONObject: payload)
		else { return }
		answer(id, data)
	}

	public func peerConnection(_ peer: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
		guard state == .failed || state == .closed, let id = sessionID(for: peer) else { return }
		finish(id)
	}

	public func peerConnection(_ peer: RTCPeerConnection, didChange _: RTCSignalingState) {}
	public func peerConnection(_ peer: RTCPeerConnection, didAdd _: RTCMediaStream) {}
	public func peerConnection(_ peer: RTCPeerConnection, didRemove _: RTCMediaStream) {}
	public func peerConnectionShouldNegotiate(_ peer: RTCPeerConnection) {}
	public func peerConnection(_ peer: RTCPeerConnection, didChange _: RTCIceConnectionState) {}
	public func peerConnection(_ peer: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
	public func peerConnection(_ peer: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
}

// MARK: - RTCDataChannelDelegate

extension LanReceiver: RTCDataChannelDelegate {
	public func dataChannelDidChangeState(_ channel: RTCDataChannel) {
		guard channel.readyState == .closed, let id = sessionID(for: channel) else { return }
		finish(id)
	}

	public func dataChannel(_ channel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
		guard let id = sessionID(for: channel), let session = lock.withLock({ sessions[id] }) else {
			return
		}

		guard buffer.isBinary else {
			if let text = String(data: buffer.data, encoding: .utf8) { control(session, id, text) }
			return
		}

		/*
		 Consumed synchronously, on libwebrtc's signalling thread.

		 `DecryptingSink.consume` is AES-GCM plus a write — comfortably faster
		 than any local network — and libwebrtc offers no receive-side flow
		 control, so handing this to a queue would only move an unbounded buffer
		 somewhere less visible. Nothing slow belongs here: this thread also runs
		 ICE and DTLS.

		 A failure is recorded rather than thrown, and answered at `file.end`, so
		 the sender learns what happened instead of watching the channel vanish.
		 */
		guard let landing = lock.withLock({ session.landing }) else { return }
		if lock.withLock({ session.failure }) != nil { return }
		do {
			try landing.sink.consume(buffer.data)
		} catch {
			lock.withLock { session.failure = error }
		}
	}
}
