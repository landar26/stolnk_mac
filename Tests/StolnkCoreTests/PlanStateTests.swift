import XCTest

@testable import StolnkCore

/// The wire contract for PRD 16, from the app's side.
///
/// These pin the shape `/api/v1/licenses/status` returns, because the failure
/// they guard against is quiet: a renamed field decodes as nil, the app falls
/// back to "Free", and a paying user is shown a paywall. Nothing crashes and
/// nothing logs — they just email asking why they were charged.
final class PlanStateTests: XCTestCase {
	private func decode(_ json: String) throws -> PlanState {
		try JSONDecoder().decode(PlanState.self, from: Data(json.utf8))
	}

	func testDecodesTheFreeShape() throws {
		// No `license` key at all: a device that has never activated anything.
		let plan = try decode(
			#"{"tier":"free","relay_used":0,"relay_limit":3221225472}"#)
		XCTAssertFalse(plan.isPro)
		XCTAssertNil(plan.license)
		XCTAssertEqual(plan.relayLimit, 3 * 1024 * 1024 * 1024)
		XCTAssertFalse(plan.relayExhausted)
	}

	func testDecodesTheProShape() throws {
		let plan = try decode(
			"""
			{"tier":"pro","relay_used":1073741824,"relay_limit":322122547200,
			 "license":{"seats":3,"seats_used":2,"status":"active"}}
			"""
		)
		XCTAssertTrue(plan.isPro)
		XCTAssertEqual(plan.license?.seats, 3)
		XCTAssertEqual(plan.license?.seatsUsed, 2)
		XCTAssertEqual(plan.license?.status, "active")
	}

	func testAllowanceFractionIsClampedAndSafe() throws {
		let half = try decode(#"{"tier":"free","relay_used":50,"relay_limit":100}"#)
		XCTAssertEqual(half.relayFraction, 0.5, accuracy: 0.0001)
		XCTAssertFalse(half.relayExhausted)

		// Over budget is reachable: the ceiling is checked before a transfer is
		// accepted, so the last accepted one can land on the far side of it.
		let over = try decode(#"{"tier":"free","relay_used":150,"relay_limit":100}"#)
		XCTAssertEqual(over.relayFraction, 1.0)
		XCTAssertTrue(over.relayExhausted)

		// A zero limit must not divide by zero and must not read as "plenty left".
		let zero = try decode(#"{"tier":"free","relay_used":0,"relay_limit":0}"#)
		XCTAssertEqual(zero.relayFraction, 0)
		XCTAssertTrue(zero.relayExhausted)
	}

	/// 402 and 413 mean opposite things to a user — "buy this" versus "wait" —
	/// so the app must not collapse them into one error screen.
	func testUpgradeAndQuotaAreDistinct() {
		let upgrade = APIError(status: 402, code: "upgrade_required", message: "x")
		XCTAssertTrue(upgrade.isUpgradeRequired)
		XCTAssertFalse(upgrade.isQuota)

		let quota = APIError(status: 413, code: "quota_exceeded", message: "x")
		XCTAssertTrue(quota.isQuota)
		XCTAssertFalse(quota.isUpgradeRequired)

		let seats = APIError(status: 409, code: "seats_full", message: "x")
		XCTAssertTrue(seats.isSeatsFull)
		XCTAssertFalse(seats.isUnknownLicense)
	}
}
