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
	private func makeFile(_ name: String, bytes: String = "x") throws -> URL {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appendingPathComponent(name)
		try Data(bytes.utf8).write(to: url)
		return url
	}

	func testShareSourceSurvivesARelaunch() throws {
		let store = InboxStore(directory: directory)
		let file = try makeFile("report.pdf")

		store.bindSource(shareID: "share-1", to: file)

		let reloaded = InboxStore(directory: directory)
		XCTAssertEqual(reloaded.source(for: "share-1")?.standardizedFileURL, file.standardizedFileURL)
	}

	/// Nil is the normal answer for a file that has been moved off the machine
	/// or thrown away, and the caller is expected to ask instead.
	func testAMissingShareSourceResolvesToNil() throws {
		let store = InboxStore(directory: directory)
		let file = try makeFile("gone.pdf")
		store.bindSource(shareID: "share-1", to: file)
		try FileManager.default.removeItem(at: file)

		XCTAssertNil(store.source(for: "share-1"))
	}

	/// A share was made from a file, not a folder, and handing one back would
	/// send the restore straight into an upload it cannot perform.
	func testAFolderIsNotAShareSource() throws {
		let store = InboxStore(directory: directory)
		store.bindSource(shareID: "share-1", to: try makeFolder("not-a-file"))

		XCTAssertNil(store.source(for: "share-1"))
	}

	func testUnbindingAShareSourceIsPersisted() throws {
		let store = InboxStore(directory: directory)
		store.bindSource(shareID: "share-1", to: try makeFile("one.pdf"))
		store.bindSource(shareID: "share-2", to: try makeFile("two.pdf"))

		store.unbindSource(shareID: "share-1")

		let reloaded = InboxStore(directory: directory)
		XCTAssertNil(reloaded.source(for: "share-1"))
		XCTAssertNotNil(reloaded.source(for: "share-2"))
	}

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
