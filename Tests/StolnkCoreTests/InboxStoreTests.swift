import XCTest

@testable import StolnkCore

final class InboxStoreTests: XCTestCase {
	private var directory: URL!

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("stolnk-store-\(UUID().uuidString)", isDirectory: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directory)
	}

	private func makeFolder(_ name: String) throws -> URL {
		let url = directory.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	func testBindThenResolve() throws {
		let store = InboxStore(directory: directory)
		let folder = try makeFolder("landing")

		store.bind(inboxID: "inbox-1", to: folder)

		XCTAssertEqual(store.folder(for: "inbox-1")?.standardizedFileURL, folder.standardizedFileURL)
	}

	func testFreshStoreUsesTheBuildConfigurationOrigin() {
		let state = InboxStore(directory: directory).snapshot

		#if DEBUG
		XCTAssertEqual(state.scheme, "http")
		XCTAssertEqual(state.baseHost, "localhost:5173")
		#else
		XCTAssertEqual(state.scheme, "https")
		XCTAssertEqual(state.baseHost, "stolnk.com")
		#endif
	}

	#if !DEBUG
	func testReleaseMigratesTheLegacyLocalhostDefault() throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var legacy = StoredState()
		legacy.scheme = "http"
		legacy.baseHost = "localhost:5173"
		try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent("state.json"))

		let state = InboxStore(directory: directory).snapshot
		XCTAssertEqual(state.scheme, "https")
		XCTAssertEqual(state.baseHost, "stolnk.com")
	}
	#endif

	func testUnbindForgetsTheFolder() throws {
		let store = InboxStore(directory: directory)
		store.bind(inboxID: "inbox-1", to: try makeFolder("landing"))

		store.unbind(inboxID: "inbox-1")

		XCTAssertNil(store.folder(for: "inbox-1"))
		XCTAssertNil(store.snapshot.folders["inbox-1"])
	}

	/// Deleting an inbox must not leave a mapping behind in state.json, or the
	/// file grows a dead entry per deleted inbox for the life of the install.
	func testUnbindIsPersisted() throws {
		let store = InboxStore(directory: directory)
		store.bind(inboxID: "inbox-1", to: try makeFolder("landing"))
		store.bind(inboxID: "inbox-2", to: try makeFolder("other"))

		store.unbind(inboxID: "inbox-1")

		let reloaded = InboxStore(directory: directory)
		XCTAssertNil(reloaded.folder(for: "inbox-1"))
		XCTAssertNotNil(reloaded.folder(for: "inbox-2"))
	}
}
