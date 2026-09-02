import AppKit
import StolnkCore
import SwiftUI

/// PRD 10.3. Each inbox shows the URL and the folder it points at, one above
/// the other, because "which link goes where" is the question this product
/// exists to answer.
struct MenuBarView: View {
	@EnvironmentObject private var state: AppState
	@State private var qrTarget: InboxSummary?

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header

			if state.confirmation != nil {
				Divider()
				awaitingConfirmation
			}

			Divider()

			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					// Every inbox is deletable, so having none is a real state and
					// not just the moment before the first list arrives.
					if state.inboxes.isEmpty {
						Text("No links yet.")
							.font(.callout)
							.foregroundStyle(.secondary)
							.padding(.horizontal, 12)
							.padding(.vertical, 14)
					}

					ForEach(state.inboxes) { inbox in
						InboxRow(inbox: inbox, qrTarget: $qrTarget)
						Divider()
					}
				}
			}
			.frame(maxHeight: 320)

			Button {
				state.showNewInbox()
			} label: {
				Label("New Inbox…", systemImage: "plus")
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.buttonStyle(.plain)
			.padding(.horizontal, 12)
			.padding(.vertical, 8)

			if !state.recent.isEmpty {
				Divider()
				recent
			}

			Divider()
			footer
		}
		.sheet(item: $qrTarget) { inbox in
			QRSheet(inbox: inbox) { qrTarget = nil }
		}
	}

	private var header: some View {
		HStack(spacing: 8) {
			Image(systemName: state.status.symbol)
				.foregroundStyle(state.status.tint)
			VStack(alignment: .leading, spacing: 1) {
				Text("Stolnk").font(.headline)
				Text(state.status.label)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			if case .receiving(let progress) = state.status {
				ProgressView(value: progress).frame(width: 60)
			}
		}
		.padding(12)
	}

	/// The prompt is a separate window, so it can end up behind another app or
	/// be closed by mistake. This is the way back to it — without it a waiting
	/// file is invisible and looks like nothing arrived.
	private var awaitingConfirmation: some View {
		Button {
			state.showConfirmation()
		} label: {
			HStack(spacing: 8) {
				Image(systemName: "envelope.fill")
					.foregroundStyle(Color.accentColor)
				VStack(alignment: .leading, spacing: 1) {
					Text("A file is waiting for your OK").font(.callout)
					Text(state.confirmation?.filename ?? "")
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
				Spacer()
				Text("Review…").font(.caption).foregroundStyle(.secondary)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	private var recent: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("Recent")
				.font(.caption.weight(.semibold))
				.foregroundStyle(.secondary)
				.padding(.horizontal, 12)
				.padding(.top, 8)

			ForEach(state.recent.prefix(5)) { file in
				Button {
					NSWorkspace.shared.activateFileViewerSelecting([file.fileURL])
				} label: {
					HStack(spacing: 6) {
						Image(systemName: file.isExecutableLike ? "exclamationmark.triangle" : "checkmark")
							.foregroundStyle(file.isExecutableLike ? .orange : .green)
							.font(.caption)
						Text(file.name).lineLimit(1).truncationMode(.middle)
						Spacer()
						Text(file.receivedAt, style: .relative)
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
				}
				.buttonStyle(.plain)
				.padding(.horizontal, 12)
			}
			.padding(.bottom, 8)
		}
	}

	private var footer: some View {
		HStack(spacing: 12) {
			icon("link", "Manage Links") { state.showSettings(tab: .links) }
			icon("gearshape", "Settings") { state.showSettings(tab: .general) }
			Spacer()
			// Quit keeps its word. An icon-only quit in a menu bar popover is a
			// coin flip the user only gets to lose.
			Button("Quit") { NSApp.terminate(nil) }
				.buttonStyle(.plain)
				.contentShape(Rectangle())
		}
		.font(.callout)
		.padding(12)
	}

	/// A footer icon. The label is not decoration: an unlabelled glyph is a guess
	/// until you click it, so it becomes both the tooltip and the VoiceOver name.
	/// The frame is larger than the glyph so the hit area is a target rather than
	/// a pixel hunt.
	private func icon(
		_ symbol: String,
		_ label: String,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Image(systemName: symbol)
				.imageScale(.large)
				.frame(width: 24, height: 22)
		}
		.buttonStyle(.plain)
		.contentShape(Rectangle())
		.help(label)
		.accessibilityLabel(label)
	}
}

private struct InboxRow: View {
	let inbox: InboxSummary
	@Binding var qrTarget: InboxSummary?
	@EnvironmentObject private var state: AppState
	@State private var copied = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Text(inbox.url)
					.font(.system(.callout, design: .monospaced))
					.lineLimit(1)
					.truncationMode(.middle)
				if inbox.paused {
					Text("Paused")
						.font(.caption2)
						.padding(.horizontal, 5)
						.padding(.vertical, 1)
						.background(.orange.opacity(0.2), in: Capsule())
				}
			}

			HStack(spacing: 4) {
				Image(systemName: "arrow.turn.down.right").font(.caption2)
				Text(folderLabel)
					.font(.caption)
					.foregroundStyle(folderURL == nil ? .orange : .secondary)
					.lineLimit(1)
					.truncationMode(.head)
			}

			HStack(spacing: 6) {
				Button(copied ? "Copied" : "Copy") { copy() }
				Button("QR") { qrTarget = inbox }
				Button("Open Folder") { openFolder() }
					.disabled(folderURL == nil)
				Spacer()
				Menu {
					Button(inbox.paused ? "Resume" : "Pause") {
						Task { await state.setPaused(inbox, paused: !inbox.paused) }
					}
					Button("Choose Folder…") { chooseFolder() }
					// Reset and Delete are irreversible (PRD 6.3; deleting also
					// discards anything still parked in the relay), so they live in
					// the Links tab, where there is room to confirm them properly.
					Button("Manage Link…") {
						state.showSettings(tab: .links, select: inbox.inboxID)
					}
				} label: {
					Image(systemName: "ellipsis.circle")
				}
				.menuStyle(.borderlessButton)
				.frame(width: 30)
			}
			.font(.caption)
			.buttonStyle(.bordered)
			.controlSize(.small)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
	}

	private var folderURL: URL? { state.folder(for: inbox) }

	private var folderLabel: String {
		guard let folderURL else { return "Folder unavailable — inbox paused" }
		return folderURL.path.replacingOccurrences(
			of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
	}

	private func copy() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(inbox.url, forType: .string)
		copied = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
	}

	private func openFolder() {
		guard let folderURL else { return }
		NSWorkspace.shared.open(folderURL)
	}

	private func chooseFolder() {
		guard let folder = FolderPicker.choose(prompt: "Choose where files should land") else { return }
		Task { await state.rebind(inbox: inbox, to: folder) }
	}
}

enum FolderPicker {
	@MainActor
	static func choose(prompt: String) -> URL? {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.canCreateDirectories = true
		panel.allowsMultipleSelection = false
		panel.prompt = "Choose"
		panel.message = prompt
		NSApp.activate(ignoringOtherApps: true)
		return panel.runModal() == .OK ? panel.url : nil
	}
}
