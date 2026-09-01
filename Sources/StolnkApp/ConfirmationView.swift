import StolnkCore
import SwiftUI

/**
 PRD 13.2 — the first file of each new sending session needs a nod.

 Not every file: that would be intolerable. But silently writing a stranger's
 files onto someone's disk is the most alarming thing this product could do,
 and one click per sender is a cheap way to retire the entire category of
 complaint. Later files in the same session land without asking.
 */
struct ConfirmationView: View {
	@EnvironmentObject private var state: AppState

	var body: some View {
		if let request = state.confirmation {
			VStack(alignment: .leading, spacing: 14) {
				Text("Incoming files").font(.headline)

				Text("Someone wants to send you a file to your \"\(request.file.inboxName)\" inbox.")
					.fixedSize(horizontal: false, vertical: true)

				HStack(spacing: 8) {
					Image(systemName: icon(for: request.filename))
						.foregroundStyle(isRisky(request.filename) ? .orange : .secondary)
					VStack(alignment: .leading, spacing: 2) {
						Text(request.filename).lineLimit(1).truncationMode(.middle)
						Text(size(request.file.size))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.padding(10)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

				if isRisky(request.filename) {
					Label(
						"This is an application or script. Only accept it if you were expecting it.",
						systemImage: "exclamationmark.triangle"
					)
					.font(.caption)
					.foregroundStyle(.orange)
					.fixedSize(horizontal: false, vertical: true)
				}

				HStack {
					Button("Decline", role: .destructive) { state.resolveConfirmation(.decline) }
					Spacer()
					Button("Always accept from this link") { state.resolveConfirmation(.acceptAlways) }
					Button("Accept") { state.resolveConfirmation(.accept) }
						.keyboardShortcut(.defaultAction)
				}
			}
			.padding(24)
			.frame(width: 440)
		} else {
			Text("Nothing waiting for confirmation.")
				.foregroundStyle(.secondary)
				.padding(40)
		}
	}

	private func isRisky(_ name: String) -> Bool {
		FileNameSanitizer.isExecutableLike(name)
	}

	private func icon(for name: String) -> String {
		isRisky(name) ? "app.badge" : "doc"
	}

	private func size(_ bytes: Int) -> String {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		return formatter.string(fromByteCount: Int64(bytes))
	}
}
