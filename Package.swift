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
		.executableTarget(
			name: "StolnkApp",
			dependencies: ["StolnkCore"],
			linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
		),
		.testTarget(name: "StolnkCoreTests", dependencies: ["StolnkCore"]),
	]
)
