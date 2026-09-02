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
			MenuBarIcon()
				.accessibilityLabel("Stolnk")
		}
		.menuBarExtraStyle(.window)
	}
}

/// The folder-and-arrow mark, monochrome. This is the app icon's mark without
/// its background tile: a menu bar item is a template image, so only the alpha
/// channel survives and the system recolours it for the light or dark menu bar.
/// Pointing this at AppIcon.icns would draw a filled square — that artwork is
/// fully opaque, and a template image keeps nothing but the silhouette.
///
/// AppKit's template-image path is required here: blend modes inside a
/// `MenuBarExtra` label can be flattened away by the system, leaving a fully
/// transparent status item.
private struct MenuBarIcon: View {
	/// The source mark intentionally has generous app-icon padding, so its
	/// silhouette needs a slightly larger box than a bare SF Symbol would to
	/// match the optical size of its neighbours in the menu bar. This is the
	/// size the icon actually draws at — there is no separate frame to keep in
	/// step with it.
	private static let side: CGFloat = 23

	private static let image: NSImage = {
		// `Bundle.module`, not `Bundle.main`: running from Xcode or `swift run`
		// produces a bare executable whose main bundle has no Resources
		// directory, and the lookup would miss. The SF Symbol below is a last
		// resort — a menu bar app with no icon at all cannot be clicked — but it
		// should never be reached now that the resource is declared in
		// Package.swift.
		guard
			let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
			let image = NSImage(contentsOf: url)
		else {
			return NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Stolnk")
				?? NSImage()
		}
		image.isTemplate = true
		image.size = NSSize(width: side, height: side)
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
