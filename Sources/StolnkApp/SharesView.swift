import AppKit
import StolnkCore
import SwiftUI

struct SharesView: View {
	@EnvironmentObject private var state: AppState

	var body: some View {
		HStack(spacing: 0) {
			VStack(spacing: 0) {
				List(state.shares, selection: $state.selectedShareID) { share in
					VStack(alignment: .leading, spacing: 3) {
						Text(share.filename).lineLimit(1)
						Text(share.url).font(.system(.caption2, design: .monospaced))
							.foregroundStyle(.secondary).lineLimit(1)
						HStack(spacing: 4) {
							if share.hasPassword { badge("Password", .accentColor) }
							if share.maxDownloads == 1 { badge("Burn after read", .orange) }
							if let ended = endedBadge(share) { badge(ended.0, ended.1) }
						}
					}
					.tag(share.shareID)
				}
				Divider()
				Button { state.showNewShare() } label: {
					Label("Share a File…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
				}
				.buttonStyle(.plain).padding(10)
				.disabled(state.shareSlotsFull)
				// Said where the button is, rather than only in the sheet the
				// button no longer opens. A greyed control with no reason beside
				// it is the thing this is meant to avoid.
				if state.shareSlotsFull {
					VStack(alignment: .leading, spacing: 4) {
						Text(state.shareSlotsMessage)
							.font(.caption).foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
						if state.plan?.isPro != true {
							Button("See Pro") {
								state.upgradePrompt = UpgradePrompt(
									title: "Share with Pro", message: state.shareSlotsMessage)
							}
							.buttonStyle(.link).font(.caption)
						}
					}
					.padding(.horizontal, 10).padding(.bottom, 10)
				}
			}
			.frame(width: 220)
			Divider()
			detail
		}
		.task { await state.refreshShares() }
		.onAppear { settleSelection() }
		.onChange(of: state.shares) { _ in settleSelection() }
	}

	private var selected: ShareSummary? { state.shares.first { $0.shareID == state.selectedShareID } }
	private func settleSelection() { if selected == nil { state.selectedShareID = state.shares.first?.shareID } }

	@ViewBuilder private var detail: some View {
		if let share = selected { ShareDetail(share: share).id(share.shareID) }
		else { Text("No shared files yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
	}

	/// Nothing for a link that is serving. Otherwise the reason it is not —
	/// which stopped being "Expired or paused" once revoked records began
	/// outliving the link, and once a pause became something you can undo.
	private func endedBadge(_ share: ShareSummary) -> (String, Color)? {
		if share.isLive { return nil }
		if share.paused && share.isActive { return ("Paused", .orange) }
		switch share.state {
		case "uploading": return ("Uploading", .secondary)
		case "revoked": return ("Revoked", .secondary)
		case "spent": return ("Used up", .secondary)
		case "aborted": return ("Failed", .secondary)
		default: return ("Expired", .secondary)
		}
	}

	private func badge(_ text: String, _ color: Color) -> some View {
		Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
			.background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
	}
}

private struct ShareDetail: View {
	@EnvironmentObject private var state: AppState
	let share: ShareSummary
	@State private var copied = false
	@State private var showQR = false
	@State private var confirmingRevoke = false
	@State private var confirmingDelete = false
	@State private var restoring = false
	/// Resolved once per share rather than per render: it stats the disk, and
	/// both the button and the text below it need the answer.
	@State private var source: AppState.ShareSource = .unrecorded
	@State private var path = ""
	@State private var pathStatus = NameStatus.empty
	@State private var savingPath = false

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(share.filename).font(.title3.weight(.semibold))
			Text(share.url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
			HStack {
				Button(copied ? "Copied" : "Copy Link") {
					state.copyShareURL(share.url); copied = true
					DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
				}
				Button("QR") { showQR = true }
				Button("Open") { if let url = URL(string: share.url) { NSWorkspace.shared.open(url) } }
			}
			LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(share.size), countStyle: .file))
			LabeledContent("Expires") { Text(Date(timeIntervalSince1970: share.expiresAt / 1000), style: .relative) }
			LabeledContent("Downloads", value: share.maxDownloads.map { "\(share.downloads) of \($0)" } ?? "\(share.downloads) served")
			if share.hasPassword { LabeledContent("Password", value: "Required") }
			if share.isActive { pathEditor }
			Spacer()
			if share.paused && share.isActive {
				Text("Paused. Anyone opening the link is told it is temporarily unavailable — the file and the path are still yours, and resuming puts it straight back.")
					.font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
			}
			if !share.isActive && share.state != "uploading" {
				Text(restoreHint)
					.font(.caption)
					.foregroundStyle(restorableFile == nil ? .orange : .secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				if !share.isActive && share.state != "uploading" {
					// No ellipsis, and nothing to choose: the link was made from
					// one specific file and that is the only file it can come
					// back as, so there is no question worth asking.
					Button("Restore") { restore() }.disabled(restoring || restorableFile == nil)
				}
				// Pause is the only reversible way to stop a link, so it leads.
				// Revoking deletes the file, which is why there is no "unrevoke"
				// next to it and why this button is not spelled the same way.
				if share.isActive {
					Button(share.paused ? "Resume" : "Pause") {
						Task { await state.setSharePaused(share, paused: !share.paused) }
					}
				}
				Spacer()
				Button("Revoke…", role: .destructive) { confirmingRevoke = true }.disabled(!share.isActive)
				Button("Delete…", role: .destructive) { confirmingDelete = true }
			}
		}
		.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.onAppear {
			path = share.code
			source = state.sourceFile(for: share)
		}
		.onChange(of: share.code) { code in path = code }
		.sheet(isPresented: $showQR) { QRSheet(title: share.filename, url: share.url) { showQR = false } }
		.alert("Revoke this share?", isPresented: $confirmingRevoke) {
			Button("Cancel", role: .cancel) {}
			Button("Revoke", role: .destructive) { Task { await state.revokeShare(share) } }
		} message: {
			Text("This cannot be undone — the file is deleted from our server, so there is nothing to turn back on. To stop the link temporarily, pause it instead. The record and its path stay yours. Copies people already downloaded remain with them.")
		}
		.alert("Delete this share?", isPresented: $confirmingDelete) {
			Button("Cancel", role: .cancel) {}
			Button("Delete", role: .destructive) { Task { await state.deleteShare(share) } }
		} message: {
			Text(deleteWarning)
		}
	}

	/// Said differently for a live link because deleting one does two things at
	/// once, and the path being handed back is the half that outlives the file.
	private var deleteWarning: String {
		let released = "Its path becomes free, so a later link can use that address — anyone still holding this one would reach a different file."
		return share.isLive
			? "The link stops working immediately and the file is deleted from our server. \(released) Copies people already downloaded remain with them."
			: "The record is removed from this list. \(released)"
	}

	/// The path half of a share address, edited here for the same reason an
	/// inbox path is edited on its own link rather than in Settings: it belongs
	/// to this link, not to the device.
	private var pathEditor: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Path").font(.callout.weight(.medium))
			HStack(spacing: 4) {
				AvailabilityField(
					text: $path,
					status: $pathStatus,
					placeholder: "invoice-2026",
					prefix: "\(state.addressPrefix(name: state.name ?? ""))~",
					width: 180,
					normalise: ShareCodeRules.normalise,
					problem: { ShareCodeRules.problem(with: $0) },
					current: share.code,
					check: { await state.isShareCodeAvailable($0, forShare: share.shareID) },
					describe: { status, _ in
						switch status {
						// The path it already has. The caption below says the rest.
						case .unchanged, .checking: nil
						case .empty: "A link needs a path."
						case .invalid(let problem): problem
						case .available: nil
						case .taken: "You already have a link at that path."
						case .unknown: "Could not check whether that path is free."
						}
					}
				)
				Button("Save") { savePath() }
					.controlSize(.small)
					// "Is there anything to save?" is answered from the model, not
					// from the availability verdict: that one arrives over the
					// network and can land after the save it was asked about, which
					// leaves the button live on a path already stored. The verdict
					// still gets a veto — it is what knows about `.taken`.
					.disabled(!pathIsDirty || pathStatus.blocksSubmission || savingPath)
			}
			Text("Changing the path breaks the old link immediately. Anyone you already sent it to gets nothing.")
				.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
		}
	}

	private var restoreHint: String {
		switch source {
		case .known(let file):
			return "This link has ended, but it still holds /~\(share.code). Restoring uploads \(file.lastPathComponent) again and the address starts working. It must be that same file — the record checks, which is what keeps the link honest for anyone still holding it."
		case .missing:
			// Deliberately not "delete this link" flat out. The commonest way a
			// file goes missing is an external drive that is not plugged in, and
			// telling someone to throw away a working link because their SSD is
			// in a bag would be wrong more often than it is right.
			return "\(share.filename) is no longer where it was, so this link cannot be restored. If it lived on a drive that is not connected, reconnect it and try again. Otherwise the only thing left to do with this link is delete it."
		case .unrecorded:
			return "This link was made before the app started remembering which file a share came from, so it cannot be restored. Delete it and share the file again to get a link that can be."
		}
	}

	private var pathIsDirty: Bool {
		ShareCodeRules.normalise(path) != share.code
	}

	private var restorableFile: URL? {
		if case .known(let file) = source { return file }
		return nil
	}

	private func restore() {
		guard let file = restorableFile else { return }
		restoring = true
		Task {
			_ = await state.restoreShare(share, from: file)
			// It may have moved under us, and a failed restore should not leave
			// the button promising a file that is no longer there.
			source = state.sourceFile(for: share)
			restoring = false
		}
	}

	private func savePath() {
		savingPath = true
		Task {
			await state.setShareCode(share, code: path)
			savingPath = false
		}
	}
}
