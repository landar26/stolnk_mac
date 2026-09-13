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

/// The local file a share was made from, plus enough to survive it being moved.
///
/// Kept so restoring a link does not have to ask which file it was. The record
/// on the server knows everything about the share except its bytes, and this is
/// the last piece — without it the one thing standing between an ended link and
/// working again is a file picker the user has to answer correctly.
public struct SourceBinding: Codable, Sendable, Hashable {
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
	public var shares: [ShareSummary] = []
	/// Keyed by share id. See `SourceBinding`.
	public var sources: [String: SourceBinding] = [:]
	public var recent: [LandedFile] = []
	public var hasCompletedOnboarding = false
	/// PRD 14 — Finder opens once, on the first successful receive, as proof it
	/// worked. After that it would just be a machine stealing focus.
	public var hasOpenedFinderOnce = false
	public var openFinderEveryTime = false

	public init() {}

	enum CodingKeys: String, CodingKey {
		case scheme, baseHost, deviceID, name, token, folders, inboxes, shares, sources, recent
		case hasCompletedOnboarding, hasOpenedFinderOnce, openFinderEveryTime
	}

	public init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		scheme = try values.decodeIfPresent(String.self, forKey: .scheme) ?? Self.defaultScheme
		baseHost = try values.decodeIfPresent(String.self, forKey: .baseHost) ?? Self.defaultBaseHost
		deviceID = try values.decodeIfPresent(String.self, forKey: .deviceID)
		name = try values.decodeIfPresent(String.self, forKey: .name)
		token = try values.decodeIfPresent(String.self, forKey: .token)
		folders = try values.decodeIfPresent([String: FolderBinding].self, forKey: .folders) ?? [:]
		inboxes = try values.decodeIfPresent([InboxSummary].self, forKey: .inboxes) ?? []
		shares = try values.decodeIfPresent([ShareSummary].self, forKey: .shares) ?? []
		sources = try values.decodeIfPresent([String: SourceBinding].self, forKey: .sources) ?? [:]
		recent = try values.decodeIfPresent([LandedFile].self, forKey: .recent) ?? []
		hasCompletedOnboarding = try values.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
		hasOpenedFinderOnce = try values.decodeIfPresent(Bool.self, forKey: .hasOpenedFinderOnce) ?? false
		openFinderEveryTime = try values.decodeIfPresent(Bool.self, forKey: .openFinderEveryTime) ?? false
	}
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

	/**
	 Where a relative `FolderBinding.path` is anchored.

	 macOS stores absolute paths, and can: the user picked a folder anywhere on
	 the disk and that path is stable. iOS has neither half of that. Every folder
	 is inside the app's own container, and the container path carries a UUID
	 that is regenerated on reinstall and can change on update. An absolute path
	 written today is one that resolves to nothing after the next App Store
	 update — a binding silently lost, and files landing nowhere. So off macOS
	 the stored path is relative, and this is what it is relative to.

	 Documents rather than Application Support because the landing folders are
	 the product: with `UIFileSharingEnabled` this is the tree the Files app
	 shows, and a received file the owner cannot reach from Files has not really
	 arrived.
	 */
	#if os(macOS)
	private static var landingRoot: URL? { nil }
	#else
	private static var landingRoot: URL? {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
	}
	#endif

	public func bind(inboxID: String, to folder: URL) {
		#if os(macOS)
		// Security-scoped: the grant from the open panel does not outlive the
		// process without one, so a relaunch would otherwise lose the folder.
		let bookmark = try? folder.bookmarkData(
			options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
		let stored = folder.path
		#else
		// Nothing off macOS hands out a security scope, and the folder is inside
		// the container this process already owns.
		let bookmark: Data? = nil
		let stored = Self.relativePath(of: folder) ?? folder.path
		#endif
		mutate { $0.folders[inboxID] = FolderBinding(path: stored, bookmark: bookmark) }
	}

	/// Turns a stored `FolderBinding.path` back into a URL. Identity on macOS,
	/// where the path is absolute; anchored to the container off it. An absolute
	/// path is always taken as-is, so a binding written by an older build still
	/// resolves.
	private static func resolve(_ path: String) -> URL {
		guard let root = landingRoot, !path.hasPrefix("/") else {
			return URL(fileURLWithPath: path)
		}
		return path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
	}

	/// `folder` expressed relative to the landing root, or nil when it is not
	/// inside it. Nil leaves the caller storing an absolute path, which does not
	/// survive a container move — still the better failure, since the
	/// alternative is a path that silently resolves to a folder the user never
	/// chose.
	private static func relativePath(of folder: URL) -> String? {
		guard let root = landingRoot else { return nil }
		let rootPath = root.standardizedFileURL.path
		let folderPath = folder.standardizedFileURL.path
		guard folderPath == rootPath || folderPath.hasPrefix(rootPath + "/") else { return nil }
		return String(folderPath.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
	}

	/// Remember the file a share was made from.
	public func bindSource(shareID: String, to file: URL) {
		#if os(macOS)
		// Tracks the file through a rename or a move, which a stored path cannot.
		// Not for access: this app is deliberately unsandboxed (PRD 10.1), so the
		// path alone already opens.
		let bookmark = try? file.bookmarkData(
			options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
		let stored = file.path
		#else
		// Relative for the same reason `bind(inboxID:to:)` is — the container path
		// carries a UUID that is regenerated on reinstall, so an absolute path
		// written today resolves to nothing after the next update, and Restore
		// would silently lose a file that is still sitting in the drive.
		let bookmark: Data? = nil
		let stored = Self.relativePath(of: file) ?? file.path
		#endif
		mutate { $0.sources[shareID] = SourceBinding(path: stored, bookmark: bookmark) }
	}

	public func unbindSource(shareID: String) {
		mutate { $0.sources[shareID] = nil }
	}

	/**
	 The file a share was made from, or nil when it can no longer be found.

	 Nil is a normal answer, not a failure: files get moved to other machines,
	 emptied out of Downloads, or deleted once they have been sent. The caller
	 falls back to asking. What this must never do is return a *different* file
	 — the server checks the hash, but a picker pre-filled with the wrong thing
	 wastes an upload to find that out.
	 */
	public func source(for shareID: String) -> URL? {
		guard let binding = snapshot.sources[shareID] else { return nil }

		#if os(macOS)
		if let bookmark = binding.bookmark {
			var stale = false
			if let resolved = try? URL(
				resolvingBookmarkData: bookmark,
				options: [.withSecurityScope],
				relativeTo: nil,
				bookmarkDataIsStale: &stale
			) {
				if isReadableFile(resolved) {
					if stale { bindSource(shareID: shareID, to: resolved) }
					return resolved
				}
			}
		}
		#endif

		let fallback = Self.resolveFile(binding.path)
		return isReadableFile(fallback) ? fallback : nil
	}

	/// The file counterpart of `resolve(_:)`. Identity on macOS and for any
	/// absolute path, so a binding written by an older build still resolves.
	private static func resolveFile(_ path: String) -> URL {
		guard let root = landingRoot, !path.hasPrefix("/"), !path.isEmpty else {
			return URL(fileURLWithPath: path)
		}
		return root.appendingPathComponent(path, isDirectory: false)
	}

	private func isReadableFile(_ url: URL) -> Bool {
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
			!isDirectory.boolValue
		else { return false }
		return FileManager.default.isReadableFile(atPath: url.path)
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

		#if os(macOS)
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
		#endif

		let fallback = Self.resolve(binding.path)
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
