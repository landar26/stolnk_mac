import AppKit
import Foundation
import StolnkCore
import UserNotifications

/**
 PRD 14 — notifications.

 `UNUserNotificationCenter` requires a real, signed application bundle. Running
 the executable directly from `swift run` has no bundle identifier and would
 trap, so development builds fall back to logging instead of crashing. Use
 `make app` for the real thing.
 */
@MainActor
final class Notifier {
	private var authorised = false
	private let isBundled = Bundle.main.bundleIdentifier != nil

	/// Held here because `UNUserNotificationCenter.delegate` is weak.
	private let router = NotificationRouter()

	func requestAuthorisation() async {
		guard isBundled else { return }
		let centre = UNUserNotificationCenter.current()
		// Must be set before authorisation is requested, or a notification that
		// arrives during the prompt is routed nowhere.
		centre.delegate = router
		authorised =
			(try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
	}

	func received(_ files: [LandedFile]) {
		guard let first = files.first else { return }

		let executables = files.filter(\.isExecutableLike)
		let title: String
		let body: String

		if !executables.isEmpty {
			// PRD 14 — an app bundle arriving is called out explicitly. It is not
			// blocked (receiving an installer from a client is normal) but it is
			// never allowed to look like an ordinary document.
			title = executables.count == 1 ? "⚠ Received an app bundle" : "⚠ Received app bundles"
			body = "\(executables.map(\.name).joined(separator: ", ")) · to \(first.inboxName)"
		} else if files.count == 1 {
			title = "File received · \(first.inboxName)"
			body = "\(first.name) · \(formatted(bytes: first.size))"
		} else {
			title = "\(files.count) files received · \(first.inboxName)"
			body = formatted(bytes: files.reduce(0) { $0 + $1.size })
		}

		post(title: title, body: body, revealing: first.fileURL)
	}

	/// PRD 13.2 — the prompt itself is a window, and a window can be behind
	/// something. This is the cue that survives that.
	func awaitingConfirmation(name: String, inboxName: String, fileID: String) {
		post(
			title: "Waiting for your OK · \(inboxName)",
			body: "\(name) — nothing is written until you accept.",
			userInfo: ["confirm": fileID]
		)
	}

	func inboxUnavailable(named name: String) {
		post(
			title: "Inbox paused · \(name)",
			body: "Its folder is missing or the volume is not mounted. Files are not being accepted.",
			revealing: nil
		)
	}

	func failed(name: String?, reason: String) {
		post(
			title: name.map { "Could not receive \($0)" } ?? "A transfer failed",
			body: reason,
			revealing: nil
		)
	}

	private func post(title: String, body: String, revealing url: URL?) {
		post(title: title, body: body, userInfo: url.map { ["path": $0.path] } ?? [:])
	}

	private func post(title: String, body: String, userInfo: [String: String]) {
		guard isBundled, authorised else {
			NSLog("[Stolnk] %@ — %@", title, body)
			return
		}
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.userInfo = userInfo
		UNUserNotificationCenter.current().add(
			UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
	}

	private func formatted(bytes: Int) -> String {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		return formatter.string(fromByteCount: Int64(bytes))
	}
}

/**
 Makes notifications clickable.

 Without a delegate the system drops a tap on the floor, and it also hides
 banners while the app is frontmost — which is exactly when a confirmation
 prompt has raised the app.
 */
private final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
	func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		willPresent notification: UNNotification
	) async -> UNNotificationPresentationOptions {
		[.banner, .sound]
	}

	func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse
	) async {
		let info = response.notification.request.content.userInfo
		if info["confirm"] is String {
			await AppState.shared.showConfirmation()
		} else if let path = info["path"] as? String {
			NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
		}
	}
}
