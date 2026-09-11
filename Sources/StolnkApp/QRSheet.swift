import SwiftUI

/// PRD 10.2 — the QR code is how you get a link onto a phone without first
/// solving the problem of getting a link onto a phone. Shared by the menu bar
/// and the Links tab, so it lives on its own rather than inside either.
struct QRSheet: View {
	let title: String
	let url: String
	let dismiss: () -> Void

	var body: some View {
		VStack(spacing: 12) {
			Text(title).font(.headline)
			if let image = QRCode.image(for: url) {
				Image(nsImage: image)
					.interpolation(.none)
					.padding(8)
					.background(.white, in: RoundedRectangle(cornerRadius: 8))
			}
			Text(url)
				.font(.system(.caption, design: .monospaced))
				.textSelection(.enabled)
			Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
		}
		.padding(20)
	}
}
