// swift-tools-version: 6.0
import PackageDescription

/**
 Stolnk.

 Three targets, and the split between the first two is the load-bearing one.

 `StolnkCore` is the protocol, the crypto, the device identity and the delivery
 pipeline. It has no dependencies at all — Foundation, CryptoKit and Security —
 and it is the thing `testdata/vectors.json` pins against the browser sender.
 That is also what makes it the whole of what a non-Mac client needs: the iOS
 receiver links this target and nothing else.

 `StolnkLAN` is LAN direct (PRD 8.2) and the one third-party dependency.

 The Mac has to answer a DataChannel from a browser. The send page is served
 over HTTPS, so it cannot open a plain socket to a private address — mixed
 content forbids it — and WebRTC's DTLS is the only transport a browser will
 carry to a peer on the local network. Speaking it means ICE, DTLS and SCTP,
 which is not something to hand-roll on the path that receives other people's
 files. So: Google's libwebrtc, prebuilt, pinned.

 It is not free. At 28 MB of prebuilt Chromium it is by a wide margin the
 largest thing in the app, which is why it is a target of its own rather than
 part of Core. Nothing in Core references it and the relay path never asks
 whether it is present, so a client that has no use for a local-network
 transfer — iOS, where the receiver is a phone and the sender is not on its
 network — pays nothing for it. If a fast local transfer ever stops being worth
 the dependency, the honest fix is to drop this target and the package together.
 */
let package = Package(
	name: "Stolnk",
	platforms: [.macOS(.v13), .iOS(.v17)],
	products: [
		// Exists so an Xcode target can link it. The package is otherwise
		// consumed only by its own executable, which needs no product.
		.library(name: "StolnkCore", targets: ["StolnkCore"])
	],
	dependencies: [
		.package(url: "https://github.com/stasel/WebRTC.git", .upToNextMajor(from: "152.0.0"))
	],
	targets: [
		.target(name: "StolnkCore"),
		// Separate from StolnkApp rather than folded into it so the LAN receiver
		// can be unit tested. The framing tests never mention WebRTC: what they
		// exercise is the framing and `DecryptingSink`, behind a protocol the
		// real data channel and a fake one both satisfy.
		.target(
			name: "StolnkLAN",
			dependencies: ["StolnkCore", .product(name: "WebRTC", package: "WebRTC")]
		),
		// The menu bar icon is declared here rather than only copied in by
		// Scripts/bundle.sh, so that `swift run` and Xcode — neither of which
		// builds a .app — find it too. Loading it through `Bundle.module` gives
		// the bare executable and the bundled app one code path. The app's own
		// AppIcon.icns stays outside the target: it is read by the bundle's
		// Info.plist, never by code.
		.executableTarget(
			name: "StolnkApp",
			dependencies: ["StolnkCore", "StolnkLAN"],
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
		.testTarget(name: "StolnkLANTests", dependencies: ["StolnkLAN"]),
	]
)
