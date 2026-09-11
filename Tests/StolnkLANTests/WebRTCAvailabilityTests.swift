import XCTest

@preconcurrency import WebRTC

/**
 PRD 8.2 — that libwebrtc is present, links, and gives us the one thing we
 actually want from it.

 Cheap, and worth keeping for the version bumps. The framework is 28 MB of
 prebuilt Chromium and by far the largest thing shipped; a release of it that
 dropped the macOS slice, changed the data-channel API, or started requiring a
 media permission would otherwise show up as a crash on a user's machine rather
 than here.

 The microphone case is the specific one being guarded. A receive-only peer
 connection has no business touching audio input, but `RTCPeerConnectionFactory`
 builds a default audio device module, and there are documented cases of that
 tripping the microphone prompt — which under the hardened runtime is a crash,
 not a prompt, without an entitlement this app has no reason to carry. If this
 test ever starts asking for permission, that is the change.
 */
final class WebRTCAvailabilityTests: XCTestCase {
	func testADataChannelPeerCanBeBuiltWithoutMedia() throws {
		RTCInitializeSSL()
		RTCSetMinDebugLogLevel(.warning)

		// nil codec factories: no encoders, no decoders, no capture devices.
		let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)

		let config = RTCConfiguration()
		config.iceServers = []
		config.sdpSemantics = .unifiedPlan
		config.continualGatheringPolicy = .gatherOnce
		config.keyType = .ECDSA

		let peer = factory.peerConnection(
			with: config,
			constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		)
		XCTAssertNotNil(peer, "no peer connection means no LAN path at all")

		let channel = peer?.dataChannel(
			forLabel: "stolnk", configuration: RTCDataChannelConfiguration())
		XCTAssertNotNil(channel, "the data channel is the only WebRTC feature this app uses")
		XCTAssertTrue(channel?.isOrdered ?? false, "ordered delivery is the default we rely on")

		channel?.close()
		peer?.close()
	}
}
