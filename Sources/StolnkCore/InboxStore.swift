import Foundation

/// Where an inbox's files land, plus enough to survive a folder being renamed.
public struct FolderBinding: Codable, Sendable, Hashable {
	public var path: String
	public var bookmark: Data?

	public init(path: String, bookmark: Data? = nil) {
		self.path = path
		self.bookmark = bookmark
	}
}

public struct LandedFile: Codable, Sendable, Identifiable, Hashable {
	public let id: String
	public let name: String
	public let size: Int
	public let inboxName: String
	public let url: String
	public let receivedAt: Date
	public let isExecutableLike: Bool

	public init(
		id: String, name: String, size: Int, inboxName: String, url: URL, receivedAt: Date,
		isExecutableLike: Bool
	) {
		self.id = id
		self.name = name
		self.size = size
		self.inboxName = inboxName
		self.url = url.path
		self.receivedAt = receivedAt
		self.isExecutableLike = isExecutableLike
	}

	public var fileURL: URL { URL(fileURLWithPath: url) }
}

public struct StoredState: Codable, Sendable {
	/// The apex the Mac talks to. Inbox links live one label below it, at
	/// `<name>.<baseHost>`, but the Mac never assembles one — every URL it shows
	/// comes from the server.
	public var scheme: String = "http"
	public var baseHost: String = "localhost:5173"
	public var deviceID: String?
	public var name: String?
	public var token: String?
	public var folders: [String: FolderBinding] = [:]
	public var inboxes: [InboxSummary] = []
	public var recent: [LandedFile] = []
	public var hasCompletedOnboarding = false
	/// PRD 13.2 — the escape hatch for users who find the prompt tiresome.
	public var alwaysAccept = false
	/// PRD 14 — Finder opens once, on the first successful receive, as proof it
	/// worked. After that it would just be a machine stealing focus.
	public var hasOpenedFinderOnce = false
	public var openFinderEveryTime = false

	public init() {}
}

/// Persists to Application Support. Deliberately not the keychain: none of this
/// is secret, and the token in it is short-lived and re-derivable from the
/// Secure Enclave key.
public final class InboxStore: @unchecked Sendable {
	private let lock = NSLock()
	private let url: URL
	private var state: StoredState

	public init(directory: URL? = nil) {
		let base =
			directory
			?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
				.appendingPathComponent("Stolnk", isDirectory: true)
		try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
		self.url = base.appendingPathComponent("state.json")

		if let data = try? Data(contentsOf: url),
			let decoded = try? JSONDecoder().decode(StoredState.self, from: data)
		{
			self.state = decoded
		} else {
			self.state = StoredState()
		}
	}

	public var snapshot: StoredState {
		lock.lock()
		defer { lock.unlock() }
		return state
	}

	public func mutate(_ body: (inout StoredState) -> Void) {
		lock.lock()
		body(&state)
		let copy = state
		lock.unlock()
		persist(copy)
	}

	private func persist(_ state: StoredState) {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		guard let data = try? encoder.encode(state) else { return }
		try? data.write(to: url, options: [.atomic])
	}

	// MARK: - Folders

	public func bind(inboxID: String, to folder: URL) {
		let bookmark = try? folder.bookmarkData(
			options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
		mutate { $0.folders[inboxID] = FolderBinding(path: folder.path, bookmark: bookmark) }
	}

	/// Drops an inbox's folder binding. Deleting an inbox on the server leaves
	/// nothing that refers to it, so the local mapping would otherwise sit in
	/// state.json forever, pointing at a folder nothing can deliver to.
	public func unbind(inboxID: String) {
		mutate { $0.folders[inboxID] = nil }
	}

	/**
	 Resolves an inbox's folder, or nil when it is gone.

	 PRD 12.5 is explicit that a missing folder or an unmounted external volume
	 must pause the inbox rather than silently land files somewhere else. Someone
	 pointing an inbox at `/Volumes/SSD/Raw` needs the files to be on that SSD or
	 nowhere — quietly using `~/Downloads` instead loses them in plain sight.
	 */
	public func folder(for inboxID: String) -> URL? {
		guard let binding = snapshot.folders[inboxID] else { return nil }

		if let bookmark = binding.bookmark {
			var stale = false
			if let resolved = try? URL(
				resolvingBookmarkData: bookmark,
				options: [.withSecurityScope],
				relativeTo: nil,
				bookmarkDataIsStale: &stale
			) {
				if isUsable(resolved) {
					if stale { bind(inboxID: inboxID, to: resolved) }
					return resolved
				}
			}
		}

		let fallback = URL(fileURLWithPath: binding.path)
		return isUsable(fallback) ? fallback : nil
	}

	private func isUsable(_ url: URL) -> Bool {
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
			isDirectory.boolValue
		else { return false }
		return FileManager.default.isWritableFile(atPath: url.path)
	}

	public func recordReceipt(_ file: LandedFile) {
		mutate { state in
			state.recent.insert(file, at: 0)
			if state.recent.count > 20 { state.recent.removeLast(state.recent.count - 20) }
		}
	}
}
