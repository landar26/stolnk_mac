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
							if !share.isLive { badge(share.paused ? "Paused" : "Expired", .secondary) }
						}
					}
					.tag(share.shareID)
				}
				Divider()
				Button { state.showNewShare() } label: {
					Label("Share a File…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
				}
				.buttonStyle(.plain).padding(10)
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
			if share.isLive { pathEditor }
			Spacer()
			Button("Revoke Share…", role: .destructive) { confirmingRevoke = true }.disabled(!share.isLive)
		}
		.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.onAppear { path = share.code }
		.onChange(of: share.code) { code in path = code }
		.sheet(isPresented: $showQR) { QRSheet(title: share.filename, url: share.url) { showQR = false } }
		.alert("Revoke this share?", isPresented: $confirmingRevoke) {
			Button("Cancel", role: .cancel) {}
			Button("Revoke", role: .destructive) { Task { await state.revokeShare(share) } }
		} message: {
			Text("The link stops working immediately and the file is deleted from our server. Copies people already downloaded remain with them.")
		}
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

	private var pathIsDirty: Bool {
		ShareCodeRules.normalise(path) != share.code
	}

	private func savePath() {
		savingPath = true
		Task {
			await state.setShareCode(share, code: path)
			savingPath = false
		}
	}
}
