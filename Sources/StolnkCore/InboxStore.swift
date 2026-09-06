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
	#if DEBUG
	public static let defaultScheme = "http"
	public static let defaultBaseHost = "localhost:5173"
	#else
	public static let defaultScheme = "https"
	public static let defaultBaseHost = "stolnk.com"
	#endif

	/// The apex the Mac talks to. Inbox links live one label below it, at
	/// `<name>.<baseHost>`, but the Mac never assembles one — every URL it shows
	/// comes from the server.
	public var scheme: String = Self.defaultScheme
	public var baseHost: String = Self.defaultBaseHost
	public var deviceID: String?
	public var name: String?
	public var token: String?
	public var folders: [String: FolderBinding] = [:]
	public var inboxes: [InboxSummary] = []
	public var recent: [LandedFile] = []
	public var hasCompletedOnboarding = false
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

	/// Debug and release builds talk to different servers, and everything in this
	/// file is scoped to one of them: a device ID registered against localhost
	/// means nothing to production, and the folder bindings key off inbox IDs
	/// that only exist on one side. Sharing one file meant whichever build ran
	/// last won — and since only the release build repaired the origin, that
	/// repair was one-directional, so a single release run pinned every later
	/// debug run to production too.
	#if DEBUG
	private static let filename = "state-debug.json"
	#else
	private static let filename = "state.json"
	#endif

	public init(directory: URL? = nil) {
		let base =
			directory
			?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
				.appendingPathComponent("Stolnk", isDirectory: true)
		try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
		self.url = base.appendingPathComponent(Self.filename)

		var loaded = Self.decode(at: url)

		#if DEBUG
		// Adopt the file both configurations used to share, once, so a developer
		// keeps the device and folder bindings they already had. Only when it
		// holds a development origin: pulling production state into a debug run
		// is the exact confusion this split exists to end.
		if loaded == nil,
			let shared = Self.decode(at: base.appendingPathComponent("state.json")),
			shared.scheme == StoredState.defaultScheme,
			shared.baseHost == StoredState.defaultBaseHost
		{
			loaded = shared
		}
		#endif

		self.state = loaded.map(Self.repaired) ?? StoredState()
	}

	private static func decode(at url: URL) -> StoredState? {
		guard let data = try? Data(contentsOf: url) else { return nil }
		return try? JSONDecoder().decode(StoredState.self, from: data)
	}

	/// Earlier builds, made before configuration-specific defaults, wrote the
	/// development origin into every fresh install. Do not let that stale default
	/// make a released app try to connect to the user's own Mac.
	private static func repaired(_ state: StoredState) -> StoredState {
		#if DEBUG
		return state
		#else
		var state = state
		if state.scheme == "http", state.baseHost == "localhost:5173" {
			state.scheme = StoredState.defaultScheme
			state.baseHost = StoredState.defaultBaseHost
		}
		return state
		#endif
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
