import AppKit
import StolnkCore
import SwiftUI

/**
 Every link in one place: what it is, where it lands, and the two operations
 that cannot be taken back.

 The menu bar (PRD 10.3) answers "which link goes where" at a glance and keeps
 the reversible actions. Reset and Delete live here instead, because both need
 to be explained before they happen — Reset makes the old address 404 for
 everyone holding it (PRD 6.3), and Delete takes anything still parked in the
 relay with it.
 */
struct InboxLinksView: View {
	@EnvironmentObject private var state: AppState

	var body: some View {
		HStack(spacing: 0) {
			list
				.frame(width: 220)
			Divider()
			detail
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
		// The list arrives asynchronously and shrinks when an inbox is deleted, so
		// the selection is settled whenever it changes rather than only on appear —
		// otherwise the detail pane and the highlighted row disagree.
		.onAppear { settleSelection() }
		.onChange(of: state.inboxes) { _ in settleSelection() }
	}

	private var selected: InboxSummary? {
		state.inboxes.first { $0.inboxID == state.selectedInboxID }
	}

	private func settleSelection() {
		if selected == nil { state.selectedInboxID = state.inboxes.first?.inboxID }
	}

	private var list: some View {
		VStack(spacing: 0) {
			List(state.inboxes, selection: $state.selectedInboxID) { inbox in
				VStack(alignment: .leading, spacing: 3) {
					Text(inbox.displayName)
						.font(.callout.weight(.medium))
						.lineLimit(1)
					Text(inbox.url)
						.font(.system(.caption2, design: .monospaced))
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
					HStack(spacing: 4) {
							if inbox.paused { LinkBadge("Paused", tint: .orange) }
						if inbox.hasPassword { LinkBadge("Password", tint: .accentColor) }
						if inbox.confirmFirst { LinkBadge("Confirm first", tint: .secondary) }
					}
				}
				.padding(.vertical, 2)
				.tag(inbox.inboxID)
			}

			Divider()

			Button {
				state.showNewInbox()
			} label: {
				Label("New Inbox…", systemImage: "plus")
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.buttonStyle(.plain)
			.contentShape(Rectangle())
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
		}
	}

	@ViewBuilder
	private var detail: some View {
		if let inbox = selected {
			InboxLinkDetail(inbox: inbox)
				.id(inbox.inboxID)
		} else {
			VStack {
				Spacer()
				Text("No inboxes yet.")
					.foregroundStyle(.secondary)
				Spacer()
			}
			.frame(maxWidth: .infinity)
		}
	}
}

private struct LinkBadge: View {
	let text: String
	let tint: Color

	init(_ text: String, tint: Color) {
		self.text = text
		self.tint = tint
	}

	var body: some View {
		Text(text)
			.font(.caption2)
			.padding(.horizontal, 5)
			.padding(.vertical, 1)
			.background(tint.opacity(0.18), in: Capsule())
			.foregroundStyle(tint)
	}
}

private struct InboxLinkDetail: View {
	let inbox: InboxSummary

	@EnvironmentObject private var state: AppState
	@State private var qrTarget: InboxSummary?
	@State private var copied = false
	@State private var confirmingReset = false
	@State private var confirmingClear = false
	@State private var confirmingDelete = false
	@State private var path = ""
	@State private var savingPath = false
	@State private var displayName = ""
	@State private var savingName = false

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				link
				nameEditor
				pathEditor
				folder
				options
				dangerZone

				if let error = state.lastError {
					Text(error)
						.font(.caption)
						.foregroundStyle(.orange)
						.fixedSize(horizontal: false, vertical: true)
				}

				if let notice = state.lastNotice {
					Text(notice)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.padding(20)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.onAppear {
			path = inbox.slug
			displayName = inbox.displayName
		}
		.onChange(of: inbox.slug) { value in
			// A reset rewrites the path behind the user's back; keep the field
			// showing what the link actually is.
			if !savingPath { path = value }
		}
		.onChange(of: inbox.displayName) { value in
			if !savingName { displayName = value }
		}
		.sheet(item: $qrTarget) { inbox in
			QRSheet(inbox: inbox) { qrTarget = nil }
		}
		.alert("Reset this link?", isPresented: $confirmingReset) {
			Button("Cancel", role: .cancel) {}
			Button("Reset Link", role: .destructive) {
				Task { await state.resetInbox(inbox) }
			}
		} message: {
			Text(
				"\(inbox.url) stops working immediately — anyone who already has it gets a \"not found\" page, and there is no way to bring it back. This inbox gives that path up and takes a new one; your name does not change.\n\nFiles already on their way are unaffected."
			)
		}
		.alert("Clear records for “\(inbox.displayName)”?", isPresented: $confirmingClear) {
			Button("Cancel", role: .cancel) {}
			Button("Clear Records") {
				Task { await state.clearInboxTransfers(inbox) }
			}
		} message: {
			Text(
				"""
				Deletes what the server still remembers about files already \
				delivered here: their sizes, when they arrived, and their encrypted \
				names. Files on this Mac are not touched, and anything still on its \
				way is left alone.
				"""
			)
		}
		.alert("Delete “\(inbox.displayName)”?", isPresented: $confirmingDelete) {
			Button("Cancel", role: .cancel) {}
			Button("Delete Inbox", role: .destructive) {
				Task { await state.deleteInbox(inbox) }
			}
		} message: {
			Text(
				"The link stops working and cannot be recreated. Files still waiting in the relay for this inbox — anything sent while this Mac was asleep — are discarded with it.\n\nFiles already in \(folderLabel) are not touched."
			)
		}
	}

	// MARK: - Sections

	private var link: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(inbox.displayName).font(.title3.weight(.semibold))

			Text(inbox.url)
				.font(.system(.callout, design: .monospaced))
				.textSelection(.enabled)
				.lineLimit(1)
				.truncationMode(.middle)

			HStack(spacing: 8) {
				Button(copied ? "Copied" : "Copy Link") { copy() }
				Button("QR") { qrTarget = inbox }
			}
			.controlSize(.small)
		}
	}

	/// What senders see, which is not part of the address at all. Keeping this
	/// out of the New Inbox sheet and putting it here is deliberate: at creation
	/// time the folder's name is a good enough answer, and calling it "name"
	/// alongside a product whose name means something else only ever confused it.
	private var nameEditor: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Shown to senders").font(.callout.weight(.medium))

			HStack(spacing: 4) {
				TextField("Client A", text: $displayName)
					.textFieldStyle(.roundedBorder)
					.frame(width: 220)
				Button("Save") { saveDisplayName() }
					.controlSize(.small)
					.disabled(!nameIsDirty || nameProblem != nil || savingName)
			}

			Text(nameProblem ?? "The send page says “Send files to \(displayName)”. This is not your address — that is edited below.")
				.font(.caption)
				.foregroundStyle(nameProblem == nil ? Color.secondary : Color.orange)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	/// The name half of the address belongs to the device and is edited in
	/// Settings; the path half belongs to this link and is edited here.
	private var pathEditor: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Path").font(.callout.weight(.medium))

			HStack(spacing: 4) {
				Text(addressPrefix)
					.font(.system(.callout, design: .monospaced))
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.head)
				TextField("client-a", text: $path)
					.textFieldStyle(.roundedBorder)
					.frame(width: 160)
				Button("Save") { savePath() }
					.controlSize(.small)
					.disabled(!pathIsDirty || pathProblem != nil || savingPath)
			}

			Text(pathProblem ?? "Saving a new path makes the old one stop working immediately.")
				.font(.caption)
				.foregroundStyle(pathProblem == nil ? Color.secondary : Color.orange)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var folder: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Files land in").font(.callout.weight(.medium))

			// PRD 12.5 — a missing folder or an unmounted volume pauses the inbox
			// rather than landing files somewhere else, so say so here too.
			Text(folderLabel)
				.font(.system(.caption, design: .monospaced))
				.foregroundStyle(folderURL == nil ? .orange : .secondary)
				.lineLimit(1)
				.truncationMode(.head)

			HStack(spacing: 8) {
				Button("Open Folder") { openFolder() }
					.disabled(folderURL == nil)
				Button("Choose Folder…") { chooseFolder() }
			}
			.controlSize(.small)
		}
	}

	private var options: some View {
		VStack(alignment: .leading, spacing: 8) {
			Toggle(
				"Paused",
				isOn: Binding(
					get: { inbox.paused },
					set: { value in Task { await state.setPaused(inbox, paused: value) } }
				)
			)
			Text("A paused inbox shows senders \"not accepting files right now\" instead of an upload box.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			LabeledContent("Largest file") { Text(sizeLimitLabel) }
				.font(.callout)
		}
	}

	private var dangerZone: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Revoking and forgetting").font(.callout.weight(.medium))

			HStack(spacing: 8) {
				Button("Reset Link…") { confirmingReset = true }
				Button("Clear Records…") { confirmingClear = true }
				Button("Delete Inbox…", role: .destructive) { confirmingDelete = true }
			}
			.controlSize(.small)

			Text("Reset keeps the inbox and changes its address. Clear Records forgets what was sent here, keeping both. Delete removes it entirely, freeing the address for a new one.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
	}

	// MARK: - Helpers

	private var folderURL: URL? { state.folder(for: inbox) }

	private var folderLabel: String {
		guard let folderURL else { return "Folder unavailable — inbox paused" }
		return folderURL.path.replacingOccurrences(
			of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
	}

	private var addressPrefix: String {
		state.addressPrefix(name: state.name ?? "")
	}

	private var pathIsDirty: Bool {
		PathRules.normalise(path) != inbox.slug
	}

	private var pathProblem: String? {
		PathRules.problem(with: path)
	}

	private func savePath() {
		savingPath = true
		Task {
			await state.setSlug(inbox, slug: path)
			savingPath = false
		}
	}

	private var nameIsDirty: Bool {
		DisplayNameRules.normalise(displayName) != inbox.displayName
	}

	private var nameProblem: String? {
		DisplayNameRules.problem(with: displayName)
	}

	private func saveDisplayName() {
		savingName = true
		Task {
			await state.setDisplayName(inbox, to: displayName)
			savingName = false
		}
	}

	private var sizeLimitLabel: String {
		ByteCountFormatter.string(fromByteCount: Int64(inbox.sizeLimit), countStyle: .file)
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
