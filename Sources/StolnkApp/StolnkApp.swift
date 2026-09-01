import AppKit
import StolnkCore
import SwiftUI

@main
struct StolnkApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
	@ObservedObject private var state = AppState.shared

	var body: some Scene {
		MenuBarExtra {
			MenuBarView()
				.environmentObject(state)
				.frame(width: 340)
		} label: {
			FileGoMenuBarIcon()
				.frame(width: 20, height: 20)
				.accessibilityLabel("Stolnk")
		}
		.menuBarExtraStyle(.window)
	}
}

/// The FileGo folder-and-arrow mark. AppKit's template-image path is required
/// here: blend modes inside a `MenuBarExtra` label can be flattened away by
/// the system, leaving a fully transparent status item.
private struct FileGoMenuBarIcon: View {
	private static let image: NSImage = {
		guard
			let url = Bundle.main.url(forResource: "FileGoMenuBarIcon", withExtension: "png"),
			let image = NSImage(contentsOf: url)
		else {
			return NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Stolnk")
				?? NSImage()
		}
		image.isTemplate = true
		// The source mark intentionally has generous app-icon padding. Give the
		// bitmap a larger intrinsic size so its visible silhouette matches the
		// optical size of neighbouring macOS menu bar symbols.
		image.size = NSSize(width: 23, height: 23)
		return image
	}()

	var body: some View {
		Image(nsImage: Self.image)
			.renderingMode(.template)
	}
}

/// A menu bar app has no Dock icon and no windows at rest, so the activation
/// policy is `.accessory`. Setting it in code rather than relying only on
/// `LSUIElement` means `swift run` behaves the same as the bundled app.
final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)
		// Startup is driven from here rather than from a scene's `task`, so it
		// runs exactly once whether or not the user opens anything.
		Task { await AppState.shared.start() }
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}
}
