import XCTest

@testable import StolnkCore

/**
 One test per row of PRD 12.2, plus the cases that motivated the table.

 The sender chooses the filename, so every string here is something a hostile
 sender could actually put on the wire.
 */
final class FileNameSanitizerTests: XCTestCase {
	func testStripsPathSeparators() {
		XCTAssertEqual(FileNameSanitizer.sanitize("../../.ssh/authorized_keys"), "sshauthorized_keys")
		XCTAssertEqual(FileNameSanitizer.sanitize("a/b/c.txt"), "abc.txt")
		XCTAssertEqual(FileNameSanitizer.sanitize(#"a\b\c.txt"#), "abc.txt")
		XCTAssertEqual(FileNameSanitizer.sanitize("Macintosh HD:file.txt"), "Macintosh HDfile.txt")
	}

	func testNoOutputCanEscapeItsDirectory() {
		for hostile in [
			"../evil", "..\\evil", "....//evil", "/etc/passwd", "~/../../root",
			"..", ".", "./../x",
		] {
			let result = FileNameSanitizer.sanitize(hostile)
			XCTAssertFalse(result.contains("/"), "\(hostile) -> \(result)")
			XCTAssertFalse(result.contains("\\"), "\(hostile) -> \(result)")
			XCTAssertFalse(result.hasPrefix("."), "\(hostile) -> \(result)")
			XCTAssertFalse(result.isEmpty, "\(hostile) produced an empty name")
		}
	}

	func testRejectsLeadingDots() {
		XCTAssertEqual(FileNameSanitizer.sanitize(".bashrc"), "bashrc")
		XCTAssertEqual(FileNameSanitizer.sanitize("...hidden.txt"), "hidden.txt")
	}

	/// A right-to-left override makes `photo<RTLO>gnp.exe` render as
	/// `photoexe.png` while remaining an executable. This is the single most
	/// effective filename disguise on macOS.
	func testStripsBidiOverrides() {
		let disguised = "photo\u{202E}gnp.exe"
		let result = FileNameSanitizer.sanitize(disguised)
		XCTAssertEqual(result, "photognp.exe")
		XCTAssertFalse(result.unicodeScalars.contains { $0.value == 0x202E })
	}

	func testStripsControlAndZeroWidthCharacters() {
		XCTAssertEqual(FileNameSanitizer.sanitize("a\u{0000}b\u{001B}c.txt"), "abc.txt")
		XCTAssertEqual(FileNameSanitizer.sanitize("in\u{200B}voice.pdf"), "invoice.pdf")
		XCTAssertEqual(FileNameSanitizer.sanitize("x\u{FEFF}y.txt"), "xy.txt")
	}

	/// Decomposed and precomposed forms look identical but are different bytes;
	/// normalising keeps them from being treated as two distinct files.
	func testNormalisesToNFC() {
		let decomposed = "cafe\u{0301}.txt"
		let precomposed = "café.txt"
		XCTAssertEqual(FileNameSanitizer.sanitize(decomposed), precomposed)
		XCTAssertEqual(FileNameSanitizer.sanitize(decomposed), FileNameSanitizer.sanitize(precomposed))
	}

	func testTruncatesKeepingTheExtension() {
		let long = String(repeating: "a", count: 500) + ".mov"
		let result = FileNameSanitizer.sanitize(long)
		XCTAssertLessThanOrEqual(result.utf8.count, FileNameSanitizer.maximumByteLength)
		XCTAssertTrue(result.hasSuffix(".mov"))
	}

	/// Truncation counts UTF-8 bytes but must not cut a character in half.
	func testTruncationDoesNotSplitCharacters() {
		let long = String(repeating: "客", count: 200) + ".mov"
		let result = FileNameSanitizer.sanitize(long)
		XCTAssertLessThanOrEqual(result.utf8.count, FileNameSanitizer.maximumByteLength)
		XCTAssertTrue(result.hasSuffix(".mov"))
		XCTAssertNotNil(result.data(using: .utf8))
		XCTAssertFalse(result.contains("\u{FFFD}"))
	}

	func testFallsBackForEmptyNames() {
		XCTAssertTrue(FileNameSanitizer.sanitize("").hasPrefix("file-"))
		XCTAssertTrue(FileNameSanitizer.sanitize("...").hasPrefix("file-"))
		XCTAssertTrue(FileNameSanitizer.sanitize("\u{202E}\u{0000}").hasPrefix("file-"))
	}

	func testKeepsLegitimateNamesIntact() {
		for name in ["shoot.mov", "客户素材 final ✅.mov", "Invoice #42 (final).pdf", "a.b.c.tar.gz"] {
			XCTAssertEqual(FileNameSanitizer.sanitize(name), name)
		}
	}

	func testFlagsExecutableTypes() {
		XCTAssertTrue(FileNameSanitizer.isExecutableLike("Setup.app"))
		XCTAssertTrue(FileNameSanitizer.isExecutableLike("installer.PKG"))
		XCTAssertTrue(FileNameSanitizer.isExecutableLike("run.command"))
		XCTAssertFalse(FileNameSanitizer.isExecutableLike("shoot.mov"))
		XCTAssertFalse(FileNameSanitizer.isExecutableLike("notes"))
	}

	/// PRD 12.4 — never overwrite what is already there.
	func testUniqueNameAvoidsCollisions() {
		let directory = URL(fileURLWithPath: "/tmp/stolnk-test")
		let taken: Set<String> = ["photo.zip", "photo (1).zip"]
		let name = FileNameSanitizer.uniqueName(for: "photo.zip", in: directory) { url in
			taken.contains(url.lastPathComponent)
		}
		XCTAssertEqual(name, "photo (2).zip")
	}

	func testUniqueNameLeavesFreeNamesAlone() {
		let directory = URL(fileURLWithPath: "/tmp/stolnk-test")
		let name = FileNameSanitizer.uniqueName(for: "fresh.zip", in: directory) { _ in false }
		XCTAssertEqual(name, "fresh.zip")
	}
}
