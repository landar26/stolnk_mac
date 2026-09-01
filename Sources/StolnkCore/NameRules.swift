import Foundation

/**
 The client half of the rules in `worker/limits.ts` and `worker/lib/inbox.ts`.

 These exist to answer while the user is still typing, not to decide anything:
 the server validates every one of them again, and its reserved-name list is
 deliberately not mirrored here — a list that drifts is worse than a round trip.
 */
/// A name is a DNS label, because it *is* one: `ryan.stolnk.com`.
public enum NameRules {
	public static let minLength = 3
	public static let maxLength = 20

	/// Normalises the way the server does before checking (`validateName`).
	public static func normalise(_ raw: String) -> String {
		raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	/// The problem with this name, phrased for the person typing it, or nil.
	public static func problem(with raw: String) -> String? {
		let name = normalise(raw)
		if name.isEmpty { return "Pick a name for your links." }
		if name.count < minLength || name.count > maxLength {
			return "A name is \(minLength)–\(maxLength) characters."
		}
		if !name.allSatisfy(isAllowed) {
			return "Use lowercase letters, numbers and hyphens."
		}
		if name.hasPrefix("-") || name.hasSuffix("-") {
			return "A name cannot start or end with a hyphen."
		}
		// RFC 5891's reserved LDH form, which is also what `xn--` punycode uses.
		if name.count >= 4, Array(name)[2] == "-", Array(name)[3] == "-" {
			return "A name cannot have two hyphens in the third and fourth positions."
		}
		return nil
	}

	private static func isAllowed(_ character: Character) -> Bool {
		character.isASCII && (character.isLowercase || character.isNumber || character == "-")
	}
}

public enum PathRules {
	public static let maxSegments = 3
	public static let maxSegmentLength = 32

	public static func normalise(_ raw: String) -> String {
		raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	/// Every link is a name *and* a path (`ryan.stolnk.com/client-a`), so an empty
	/// path is not an address — there is no bare-subdomain inbox to fall back on.
	public static func problem(with raw: String) -> String? {
		let path = normalise(raw)
		if path.isEmpty { return "Give this link a path." }
		if path.hasPrefix("/") || path.hasSuffix("/") {
			return "Leave off the leading and trailing slashes."
		}

		let segments = path.split(separator: "/", omittingEmptySubsequences: false)
		if segments.count > maxSegments {
			return "A path can be at most \(maxSegments) segments deep."
		}
		for segment in segments {
			if segment.isEmpty || segment.count > maxSegmentLength {
				return "Each segment is 1–\(maxSegmentLength) characters."
			}
			if !segment.allSatisfy(isAllowed) {
				return "Use lowercase letters, numbers and hyphens."
			}
		}
		return nil
	}

	private static func isAllowed(_ character: Character) -> Bool {
		character.isASCII && (character.isLowercase || character.isNumber || character == "-")
	}
}

/// The name senders see on the send page — "Send files to Client A". Unrelated
/// to the address; mirrors `MAX_DISPLAY_NAME` in `worker/limits.ts`.
public enum DisplayNameRules {
	public static let maxLength = 64

	public static func normalise(_ raw: String) -> String {
		raw.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public static func problem(with raw: String) -> String? {
		let value = normalise(raw)
		if value.isEmpty { return "Give this inbox a name senders will recognise." }
		if value.count > maxLength { return "Keep it under \(maxLength) characters." }
		return nil
	}
}
