import Foundation

/**
 A sender picks the filename, so a filename is attacker-controlled input
 (PRD 12.2). Everything in this file runs before a single byte is written.

 The dangerous cases, in order of how bad they are:

 - `../../.ssh/authorized_keys` — path traversal. Separators are stripped
   rather than escaped, so no traversal is representable at all.
 - `photo\u{202E}gnp.exe` — a right-to-left override renders that as
   `photoexe.png` in Finder while it stays an executable. Bidi controls are
   removed outright.
 - `.bashrc` — a leading dot hides the file from the user who is supposed to
   be reviewing what arrived.
 */
public enum FileNameSanitizer {
	public static let maximumByteLength = 200

	/// Extensions that get called out in the notification (PRD 14). Not blocked:
	/// receiving an installer from a client is legitimate. The user is told.
	public static let executableExtensions: Set<String> = [
		"app", "pkg", "dmg", "command", "scpt", "scptd", "workflow", "action",
		"osax", "kext", "prefpane", "qlgenerator", "saver", "mpkg", "term",
		"tool", "sh", "bash", "zsh", "shortcut", "webloc",
	]

	public static func isExecutableLike(_ name: String) -> Bool {
		let ext = (name as NSString).pathExtension.lowercased()
		return !ext.isEmpty && executableExtensions.contains(ext)
	}

	public static func sanitize(_ raw: String, now: Date = Date()) -> String {
		// Normalise first: otherwise a decomposed character could survive a check
		// that its composed twin fails.
		var name = raw.precomposedStringWithCanonicalMapping

		name = String(
			name.unicodeScalars.filter { scalar in
				// Path separators, including the classic Mac ':'.
				if scalar == "/" || scalar == "\\" || scalar == ":" { return false }
				// C0 and C1 control characters, and DEL.
				if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) { return false }
				// Bidi overrides and isolates — the RTLO disguise.
				if (0x202A...0x202E).contains(scalar.value) { return false }
				if (0x2066...0x2069).contains(scalar.value) { return false }
				if scalar.value == 0x200E || scalar.value == 0x200F { return false }
				// Zero-width characters, used to make two names look identical.
				if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D {
					return false
				}
				if scalar.value == 0xFEFF { return false }
				return true
			}.map(Character.init)
		)

		name = name.trimmingCharacters(in: .whitespacesAndNewlines)

		// A leading dot would hide the file; strip every one of them.
		while name.hasPrefix(".") { name.removeFirst() }
		name = name.trimmingCharacters(in: .whitespacesAndNewlines)

		// Trailing dots and spaces confuse round-tripping to other filesystems.
		while name.hasSuffix(".") || name.hasSuffix(" ") { name.removeLast() }

		if name.isEmpty {
			return "file-\(Int(now.timeIntervalSince1970))"
		}

		return truncate(name)
	}

	/// Truncates to `maximumByteLength` UTF-8 bytes while keeping the extension,
	/// and never splits a character in half.
	static func truncate(_ name: String) -> String {
		guard name.utf8.count > maximumByteLength else { return name }

		let nsName = name as NSString
		var ext = nsName.pathExtension
		// A 190-byte "extension" is not an extension.
		if ext.utf8.count > 16 { ext = "" }
		let base = ext.isEmpty ? name : nsName.deletingPathExtension
		let suffix = ext.isEmpty ? "" : ".\(ext)"
		let budget = maximumByteLength - suffix.utf8.count

		var truncated = ""
		var used = 0
		for character in base {
			let width = String(character).utf8.count
			if used + width > budget { break }
			truncated.append(character)
			used += width
		}
		if truncated.isEmpty { truncated = "file" }
		return truncated + suffix
	}

	/// PRD 12.4 — never overwrite. `photo.zip` becomes `photo (1).zip`.
	public static func uniqueName(
		for name: String,
		in directory: URL,
		exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
	) -> String {
		guard exists(directory.appendingPathComponent(name)) else { return name }

		let nsName = name as NSString
		let ext = nsName.pathExtension
		let base = ext.isEmpty ? name : nsName.deletingPathExtension
		let suffix = ext.isEmpty ? "" : ".\(ext)"

		var counter = 1
		while counter < 10_000 {
			let candidate = "\(base) (\(counter))\(suffix)"
			if !exists(directory.appendingPathComponent(candidate)) { return candidate }
			counter += 1
		}
		return "\(base)-\(UUID().uuidString)\(suffix)"
	}
}
