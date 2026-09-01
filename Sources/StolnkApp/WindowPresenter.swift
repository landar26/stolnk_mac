import AppKit
import SwiftUI

/**
 Shows SwiftUI views in real windows.

 A menu bar app runs as an `.accessory` application with no main window, and
 SwiftUI's `Window` scenes are opened by the framework at launch rather than on
 demand — which would put the onboarding screen in front of returning users
 every time. Managing these two windows directly keeps them tied to the events
 that should actually raise them: first run, and a sender waiting on a decision.
 */
@MainActor
final class WindowPresenter {
	private var windows: [String: NSWindow] = [:]

	func show<Content: View>(
		id: String,
		title: String,
		@ViewBuilder content: () -> Content
	) {
		if let existing = windows[id] {
			existing.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let hosting = NSHostingController(rootView: content())
		let window = NSWindow(contentViewController: hosting)
		window.title = title
		window.styleMask = [.titled, .closable]
		window.isReleasedWhenClosed = false
		window.center()
		windows[id] = window

		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	func close(id: String) {
		windows[id]?.close()
		windows[id] = nil
	}

	func isOpen(id: String) -> Bool {
		windows[id] != nil
	}
}
