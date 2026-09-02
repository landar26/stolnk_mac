import AppKit
import StolnkCore
import SwiftUI

/**
 PRD 10.2 — first run, in three steps, targeting under 60 seconds to the first
 received file.

 The first screen asks for the whole address as well as a folder. A link is name
 + path and both halves are required — the name is the half that has to be
 sayable out loud, and asking for it later means most people never set one,
 which leaves them with a URL they cannot give to anyone without copy and paste.

 The QR code on the final step is the point of the whole screen. Without it,
 trying the product alone means finding some way to get a URL onto your phone;
 with it, you look up and scan. It doubles as the ten-second demo.
 */
struct OnboardingView: View {
	enum Mode {
		case firstRun
		case newInbox
	}

	let mode: Mode

	@EnvironmentObject private var state: AppState

	@State private var folder: URL = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent("Downloads/Inbox")
	@State private var step: Step = .chooseFolder
	@State private var name = ""
	@State private var nameStatus: NameStatus = .empty
	@State private var busy = false

	// Creating a second inbox reuses this window, so it needs its own fields.
	@State private var slug = "inbox"
	/// First run has a sensible default folder; creating a *second* inbox does
	/// not — see `newInboxStep`.
	@State private var folderPicked: Bool

	private enum Step {
		case chooseFolder
		case working
		case done
		case newInbox
	}

	init(mode: Mode) {
		self.mode = mode
		_step = State(initialValue: mode == .newInbox ? .newInbox : .chooseFolder)
		_folderPicked = State(initialValue: mode == .firstRun)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			switch step {
			case .chooseFolder: chooseFolderStep
			case .working: workingStep
			case .done: doneStep
			case .newInbox: newInboxStep
			}
		}
		.padding(28)
		.frame(width: 460)
		// The New Inbox flow is its own window, so the paywall has to be able to
		// appear here as well as in Settings — this is where someone is standing
		// when they hit it (PRD 6.2: the wall sits at the end of the flow).
		.sheet(item: $state.upgradePrompt) { prompt in
			UpgradeSheet(prompt: prompt) {
				state.upgradePrompt = nil
				state.closeNewInbox()
			}
		}
	}

	private var chooseFolderStep: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Turn your folders into inboxes.")
				.font(.title2.weight(.semibold))
			Text("Pick your address and a folder. Anyone with the link can send you files — no account, no app, nothing to install.")
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			VStack(alignment: .leading, spacing: 6) {
				Text("Your name").font(.callout.weight(.medium))
				NameField(name: $name, status: $nameStatus, suffix: state.nameSuffix)
				Text("The name is yours and every link on this Mac shares it. You can change it later in Settings.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			VStack(alignment: .leading, spacing: 6) {
				Text("Path for this folder").font(.callout.weight(.medium))
				HStack(spacing: 4) {
					Text(addressPreview)
						.font(.system(.callout, design: .monospaced))
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.head)
					TextField("inbox", text: $slug)
						.textFieldStyle(.roundedBorder)
						.frame(width: 140)
				}
				Text(PathRules.problem(with: slug) ?? "A link is a name and a path, both. Add another folder later and it gets its own path under the same name.")
					.font(.caption)
					.foregroundStyle(PathRules.problem(with: slug) == nil ? Color.secondary : Color.orange)
					.fixedSize(horizontal: false, vertical: true)
			}

			HStack {
				Image(systemName: "folder")
				Text(displayPath(folder))
					.font(.system(.callout, design: .monospaced))
					.lineLimit(1)
					.truncationMode(.head)
				Spacer()
				Button("Choose Folder…") {
					if let picked = FolderPicker.choose(prompt: "Choose where files should land") {
						folder = picked
					}
				}
			}
			.padding(10)
			.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

			if let error = state.lastError {
				VStack(alignment: .leading, spacing: 2) {
					Text(error)
						.font(.caption)
						.foregroundStyle(.orange)
						.fixedSize(horizontal: false, vertical: true)
					Text("Server: \(state.origin.absoluteString) — change it in Settings → General.")
						.font(.caption2)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}

			HStack {
				Spacer()
				Button("Create my inbox") { begin() }
					.keyboardShortcut(.defaultAction)
					.disabled(busy || nameStatus.blocksSubmission || PathRules.problem(with: slug) != nil)
			}
		}
	}

	private var workingStep: some View {
		VStack(alignment: .leading, spacing: 12) {
			ProgressView()
			Text("Generating your device key…")
			Text("Your keys are created in this Mac's Secure Enclave and never leave it.")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var doneStep: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("Your inbox is ready").font(.title2.weight(.semibold))

			if let inbox = state.inboxes.first {
				Text(inbox.url)
					.font(.system(.body, design: .monospaced))
					.textSelection(.enabled)
					.lineLimit(1)
					.truncationMode(.middle)

				HStack {
					Button("Copy Link") {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(inbox.url, forType: .string)
					}
					Button("Open Folder") {
						if let url = state.folder(for: inbox) { NSWorkspace.shared.open(url) }
					}
				}

				if let image = QRCode.image(for: inbox.url, size: 180) {
					HStack {
						Spacer()
						VStack(spacing: 8) {
							Image(nsImage: image)
								.interpolation(.none)
								.padding(8)
								.background(.white, in: RoundedRectangle(cornerRadius: 8))
							Text("Scan with your phone to try it")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
					}
				}

			}

			HStack {
				Spacer()
				Button("Done") { state.completeOnboarding() }
					.keyboardShortcut(.defaultAction)
			}
		}
	}

	private var newInboxStep: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("New inbox").font(.title2.weight(.semibold))
			Text("One link per folder. Give your client a link, your photographer another one.")
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			Form {
				TextField("Link path", text: $slug, prompt: Text("client-a"))
				Text(PathRules.problem(with: slug) ?? "The link will be \(addressPreview)\(PathRules.normalise(slug)).")
					.font(.caption)
					.foregroundStyle(PathRules.problem(with: slug) == nil ? Color.secondary : Color.orange)
					.fixedSize(horizontal: false, vertical: true)
				HStack {
					// No default folder here on purpose. First run can reasonably
					// guess ~/Downloads/Inbox; a *second* inbox cannot, and since the
					// name senders see is taken from the folder, guessing would hand
					// you two links called "Inbox" pointing at the same place.
					Text(folderPicked ? displayPath(folder) : "Choose a folder")
						.font(.system(.caption, design: .monospaced))
						.foregroundStyle(folderPicked ? .secondary : .tertiary)
						.lineLimit(1)
						.truncationMode(.head)
					Spacer()
					Button("Choose Folder…") {
						if let picked = FolderPicker.choose(prompt: "Where should these files land?") {
							folder = picked
							folderPicked = true
						}
					}
				}
			}

			if let error = state.lastError {
				Text(error).font(.caption).foregroundStyle(.orange)
			}

			HStack {
				Spacer()
				Button("Cancel") { state.closeNewInbox() }
				Button("Create") {
					Task {
						busy = true
						// Senders see the folder's name. You can change it afterwards
						// in Links, which is a better moment for it than this one.
						await state.createInbox(
							slug: slug.trimmingCharacters(in: .whitespaces).lowercased(),
							displayName: folder.lastPathComponent,
							folder: folder
						)
						busy = false
						// An upgrade prompt is a pending conversation, not a
						// finished one: closing the window out from under it would
						// leave the refusal with nowhere to be shown.
						if state.lastError == nil, state.upgradePrompt == nil {
							state.closeNewInbox()
						}
					}
				}
				.keyboardShortcut(.defaultAction)
				.disabled(busy || !folderPicked)
			}
		}
	}

	/// `ryan.stolnk.com/` — the fixed half of the address, shown before the field
	/// the path is typed into. During first run the name is still being typed, so
	/// it falls back to what is in the name field.
	private var addressPreview: String {
		let current = state.name ?? NameRules.normalise(name)
		return "\(current.isEmpty ? "your-name" : current)\(state.nameSuffix)/"
	}

	private func displayPath(_ url: URL) -> String {
		url.path.replacingOccurrences(
			of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
	}

	private func begin() {
		busy = true
		// Otherwise the previous attempt's message rides along with this one.
		state.lastError = nil
		step = .working
		Task {
			try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			let ok = await state.register(name: name, slug: slug, folder: folder)
			busy = false
			// A taken name fails atomically and creates nothing, so staying on this
			// screen lets the user simply try another one.
			step = ok ? .done : .chooseFolder
		}
	}
}
