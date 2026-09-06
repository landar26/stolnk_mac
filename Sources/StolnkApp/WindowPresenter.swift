import AppKit
import SwiftUI

/**
 Shows SwiftUI views in real windows.

 A menu bar app runs as an `.accessory` application with no main window, and
 SwiftUI's `Window` scenes are opened by the framework at launch rather than on
 demand — which would put the onboarding screen in front of returning users
 every time. Managing these windows directly keeps them tied to the events that
 should actually raise them: first run, and the user asking.
 */
@MainActor
final class WindowPresenter {
	private var windows: [String: NSWindow] = [:]
	/// `NSWindow.delegate` is weak, so the observers have to be held here.
	private var observers: [String: CloseObserver] = [:]

	/// `onClose` fires only when the *user* closes the window, never when
	/// `close(id:)` takes it down — so a window whose dismissal means something
	/// (onboarding abandoned rather than finished) can tell the two apart.
	func show<Content: View>(
		id: String,
		title: String,
		onClose: (() -> Void)? = nil,
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

		if let onClose {
			let observer = CloseObserver { [weak self] in
				self?.windows[id] = nil
				self?.observers[id] = nil
				onClose()
			}
			observers[id] = observer
			window.delegate = observer
		}

		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	func close(id: String) {
		// Detach first: closing programmatically is not a dismissal, and letting
		// it reach `onClose` would report an abandonment that did not happen.
		windows[id]?.delegate = nil
		observers[id] = nil
		windows[id]?.close()
		windows[id] = nil
	}

	func isOpen(id: String) -> Bool {
		windows[id] != nil
	}
}

private final class CloseObserver: NSObject, NSWindowDelegate {
	private let onClose: () -> Void

	init(onClose: @escaping () -> Void) {
		self.onClose = onClose
	}

	func windowWillClose(_ notification: Notification) {
		MainActor.assumeIsolated { onClose() }
	}
}
