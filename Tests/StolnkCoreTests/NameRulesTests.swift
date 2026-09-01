import XCTest

@testable import StolnkCore

/// These mirror `worker/limits.ts` and `worker/lib/inbox.ts`. They are about
/// answering while the user types — the server still decides — so what matters
/// is that nothing legal is rejected here and nothing obviously illegal gets
/// through to a round trip.
final class NameRulesTests: XCTestCase {
	func testNameAcceptsWhatTheServerAccepts() {
		for name in ["ryan", "a-b-c", "abc", "r2d2", String(repeating: "a", count: 20)] {
			XCTAssertNil(NameRules.problem(with: name), name)
		}
	}

	func testNameRejectsLengthAndCharset() {
		XCTAssertNotNil(NameRules.problem(with: ""))
		XCTAssertNotNil(NameRules.problem(with: "ab"))
		XCTAssertNotNil(NameRules.problem(with: String(repeating: "a", count: 21)))
		XCTAssertNotNil(NameRules.problem(with: "ryan smith"))
		XCTAssertNotNil(NameRules.problem(with: "ryan_smith"))
		XCTAssertNotNil(NameRules.problem(with: "ryan/smith"))
	}

	/// A name is a DNS label, so the edges and the reserved LDH form matter in a
	/// way they did not when it was just a path segment.
	func testNameRejectsWhatIsNotALegalHostnameLabel() {
		XCTAssertNotNil(NameRules.problem(with: "-ryan"))
		XCTAssertNotNil(NameRules.problem(with: "ryan-"))
		XCTAssertNotNil(NameRules.problem(with: "xn--abc"))
		XCTAssertNotNil(NameRules.problem(with: "ab--cd"))
		// A hyphen anywhere else is still fine.
		XCTAssertNil(NameRules.problem(with: "a-b"))
		XCTAssertNil(NameRules.problem(with: "abc-def"))
	}

	/// The display name is a different thing from the address, and the rules say
	/// so: anything non-empty and short enough is fine.
	func testDisplayNameOnlyRequiresSomethingShortEnough() {
		XCTAssertNil(DisplayNameRules.problem(with: "Client A"))
		XCTAssertNil(DisplayNameRules.problem(with: "收图 / 2026"))
		XCTAssertNotNil(DisplayNameRules.problem(with: ""))
		XCTAssertNotNil(DisplayNameRules.problem(with: "   "))
		XCTAssertNotNil(DisplayNameRules.problem(with: String(repeating: "a", count: 65)))
		XCTAssertEqual(DisplayNameRules.normalise("  Client A  "), "Client A")
	}

	/// The address the UI shows while a name is being typed.
	func testSiteAddressComposesNameAndHost() {
		XCTAssertEqual(SiteAddress.suffix(baseHost: "stolnk.com"), ".stolnk.com")
		XCTAssertEqual(SiteAddress.prefix(name: "ryan", baseHost: "stolnk.com"), "ryan.stolnk.com/")
		XCTAssertEqual(
			SiteAddress.prefix(name: "ryan", baseHost: "localhost:5173"), "ryan.localhost:5173/")
	}

	func testNameNormalisesTheWayTheServerDoes() {
		XCTAssertEqual(NameRules.normalise("  Ryan  "), "ryan")
		XCTAssertNil(NameRules.problem(with: "  RYAN  "))
	}

	/// There is no bare-subdomain inbox, so an empty path is not an address.
	func testEmptyPathIsNotAnAddress() {
		XCTAssertNotNil(PathRules.problem(with: ""))
		XCTAssertNotNil(PathRules.problem(with: "   "))
		XCTAssertEqual(PathRules.normalise("  Client-A "), "client-a")
	}

	func testPathAcceptsUpToThreeSegments() {
		XCTAssertNil(PathRules.problem(with: "client-a"))
		XCTAssertNil(PathRules.problem(with: "a/b/c"))
		XCTAssertNotNil(PathRules.problem(with: "a/b/c/d"))
	}

	func testPathRejectsEmptySegmentsAndBadCharacters() {
		XCTAssertNotNil(PathRules.problem(with: "/client-a"))
		XCTAssertNotNil(PathRules.problem(with: "client-a/"))
		XCTAssertNotNil(PathRules.problem(with: "a//b"))
		XCTAssertNotNil(PathRules.problem(with: "client a"))
		XCTAssertNotNil(PathRules.problem(with: String(repeating: "a", count: 33)))
	}
}
