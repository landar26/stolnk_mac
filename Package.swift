// swift-tools-version: 6.0
import PackageDescription

/**
 Stolnk for macOS.

 Split into a library and a thin executable so the protocol, crypto and
 file-landing logic can be unit tested directly — in particular against
 `testdata/vectors.json`, which the browser sender generates.

 One third-party dependency, and it is a deliberate exception rather than a
 drift: QR codes come from CoreImage, crypto from CryptoKit, everything else
 from Foundation — except WebRTC.

 LAN direct (PRD 8.2) needs the Mac to answer a DataChannel from a browser. The
 send page is served over HTTPS, so it cannot open a plain socket to a private
 address — mixed content forbids it — and WebRTC's DTLS is the only transport a
 browser will carry to a peer on the local network. Speaking it means ICE, DTLS
 and SCTP, which is not something to hand-roll on the path that receives other
 people's files. So: Google's libwebrtc, prebuilt, pinned.

 It is not free. It is by a wide margin the largest thing in the app. If that
 ever stops being worth a fast local transfer, the honest fix is to drop the
 feature and this dependency together — everything else here works without it,
 which is why the relay path never asks whether it is present.
 */
let package = Package(
	name: "Stolnk",
	platforms: [.macOS(.v13)],
	dependencies: [
		.package(url: "https://github.com/stasel/WebRTC.git", .upToNextMajor(from: "152.0.0")),
	],
	targets: [
		// WebRTC lives here rather than in StolnkApp so the LAN receiver can be
		// unit tested. The tests never mention it: what they exercise is the
		// framing and `DecryptingSink`, behind a protocol the real data channel
		// and a fake one both satisfy.
		.target(name: "StolnkCore", dependencies: [.product(name: "WebRTC", package: "WebRTC")]),
		// The menu bar icon is declared here rather than only copied in by
		// Scripts/bundle.sh, so that `swift run` and Xcode — neither of which
		// builds a .app — find it too. Loading it through `Bundle.module` gives
		// the bare executable and the bundled app one code path. The app's own
		// AppIcon.icns stays outside the target: it is read by the bundle's
		// Info.plist, never by code.
		.executableTarget(
			name: "StolnkApp",
			dependencies: ["StolnkCore"],
			resources: [.process("Resources")],
			// Two rpaths, for the two places the framework can be. `swift build`
			// leaves it next to the executable; Scripts/bundle.sh puts it in
			// Contents/Frameworks. Both, so `swift run` and the .app load the
			// same library rather than one of them failing at launch.
			linkerSettings: [
				.unsafeFlags([
					"-Xlinker", "-rpath", "-Xlinker", "@executable_path",
					"-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
				])
			]
		),
		.testTarget(name: "StolnkCoreTests", dependencies: ["StolnkCore"]),
	]
)
