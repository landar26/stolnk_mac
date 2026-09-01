import Foundation

/**
 The address model, as far as the Mac needs to know it (PRD 6.1).

 A link is `<name>.<baseHost>` plus an optional path, so the UI shows the name
 with the site as a *suffix* — `ryan.stolnk.com` — rather than as a prefix. The
 whole URL of an existing inbox always comes from the server; these are for the
 fields where the user is still typing a name that does not exist yet.
 */
public enum SiteAddress {
	/// `.stolnk.com`, for a field the name is typed into.
	public static func suffix(baseHost: String) -> String {
		".\(baseHost)"
	}

	/// `ryan.stolnk.com/`, the fixed part before a path being edited.
	public static func prefix(name: String, baseHost: String) -> String {
		"\(name).\(baseHost)/"
	}
}
