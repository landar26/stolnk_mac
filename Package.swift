// swift-tools-version: 6.0
import PackageDescription

/**
 Stolnk for macOS.

 Split into a library and a thin executable so the protocol, crypto and
 file-landing logic can be unit tested directly — in particular against
 `testdata/vectors.json`, which the browser sender generates.

 No third-party dependencies: QR codes come from CoreImage, crypto from
 CryptoKit, everything else from Foundation.
 */
let package = Package(
	name: "Stolnk",
	platforms: [.macOS(.v13)],
	targets: [
		.target(name: "StolnkCore"),
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
			linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
		),
		.testTarget(name: "StolnkCoreTests", dependencies: ["StolnkCore"]),
	]
)
