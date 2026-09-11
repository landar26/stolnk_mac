import StolnkCore
import SwiftUI

struct NewShareView: View {
	@EnvironmentObject private var state: AppState
	let file: URL
	@State private var ttlHours = 24.0
	@State private var maxDownloads: Int?
	@State private var password = ""
	@State private var code = ""
	@State private var codeStatus = NameStatus.empty
	@State private var busy = false

	private func isInvalid(_ status: NameStatus) -> Bool {
		if case .invalid = status { return true }
		return false
	}

	private var size: Int {
		(try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Share a File").font(.title2.weight(.semibold))
			LabeledContent("File", value: file.lastPathComponent)
			LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))

			Picker("Expires", selection: $ttlHours) {
				Text("1 hour").tag(1.0)
				Text("24 hours").tag(24.0)
				Text("7 days — Pro").tag(168.0).disabled(state.plan?.isPro != true)
				Text("30 days — Pro").tag(720.0).disabled(state.plan?.isPro != true)
			}

			Picker("Downloads", selection: $maxDownloads) {
				Text("Unlimited").tag(Int?.none)
				Text("Once — burn after download").tag(Int?.some(1))
				Text("5 times").tag(Int?.some(5))
				Text("25 times").tag(Int?.some(25))
			}

			SecureField(state.plan?.isPro == true ? "Optional password" : "Password — Pro", text: $password)
				.disabled(state.plan?.isPro != true)

			VStack(alignment: .leading, spacing: 4) {
				Text("Link path").font(.callout.weight(.medium))
				AvailabilityField(
					text: $code,
					status: $codeStatus,
					placeholder: "leave blank for a random one",
					prefix: "\(state.addressPrefix(name: state.name ?? ""))~",
					width: 200,
					normalise: ShareCodeRules.normalise,
					problem: { ShareCodeRules.problem(with: $0) },
					current: nil,
					check: { await state.isShareCodeAvailable($0) },
					describe: { status, normalised in
						switch status {
						case .empty, .unchanged, .checking: nil
						case .invalid(let problem): problem
						case .available: "~\(normalised) is free."
						case .taken: "You already have a link at that path."
						case .unknown: "Could not check whether that path is free."
						}
					}
				)
			}

			// The whole cost of the feature, said where it is being bought. The
			// random path is the only lock a plaintext share has; choosing one
			// spends it, and that is the owner's call to make knowingly.
			if !code.isEmpty {
				Text("A path you choose is a path someone can guess. Anyone who guesses this address can download the file.")
					.font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
			}

			Text("This file is stored unencrypted on Stolnk's server so any browser can download it. Unlike files sent to an inbox, the server can read it.")
				.font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
			if maxDownloads != nil {
				Text("A download is counted when it starts, not when it finishes. An interrupted download still uses one.")
					.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			}

			if let error = state.lastError {
				Text(error).font(.caption).foregroundStyle(.red)
			}

			HStack {
				Button("Cancel") { state.closeNewShare() }
				Spacer()
				Button(busy ? "Uploading…" : "Create Link") {
					busy = true
					Task {
						_ = await state.createShare(
							file: file, ttlHours: ttlHours, maxDownloads: maxDownloads,
							password: password.isEmpty ? nil : password,
							code: code.isEmpty ? nil : code)
						busy = false
					}
				}
				.keyboardShortcut(.defaultAction)
				// `.empty` is a valid path here — it asks for a random one — so
				// `blocksSubmission` is not the right question to put to this field.
				.disabled(busy || codeStatus == .taken || isInvalid(codeStatus))
			}
		}
		.padding(20)
		.frame(width: 440)
	}
}
