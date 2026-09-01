import StolnkCore
import SwiftUI

struct SettingsView: View {
	@EnvironmentObject private var state: AppState

	var body: some View {
		TabView(selection: $state.settingsTab) {
			InboxLinksView()
				.tabItem { Label("Links", systemImage: "link") }
				.tag(SettingsTab.links)

			GeneralSettings()
				.tabItem { Label("General", systemImage: "gearshape") }
				.tag(SettingsTab.general)
		}
		.frame(width: 640, height: 460)
	}
}

private struct GeneralSettings: View {
	@EnvironmentObject private var state: AppState
	@State private var origin = ""
	@State private var alwaysAccept = false
	@State private var openFinderEveryTime = false
	@State private var name = ""
	@State private var nameStatus: NameStatus = .empty
	@State private var renaming = false

	var body: some View {
		Form {
			// PRD 6.1 — the name is shared by every link this Mac owns, so it is
			// device-level and lives here rather than on any one link.
			Section("Name") {
				LabeledContent("Current") {
					Text(state.name.map { $0 + state.nameSuffix } ?? "—")
						.font(.system(.callout, design: .monospaced))
				}

				NameField(name: $name, status: $nameStatus, suffix: state.nameSuffix)

				HStack {
					Spacer()
					Button("Change Name") { rename() }
						.disabled(renaming || nameStatus.blocksSubmission)
				}

				Text("Every link on this Mac moves to the new name at once, and the old address stops working immediately — anyone holding a link to it is cut off, and the name goes straight back into the pool for someone else to take.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			Section("Receiving") {
				Toggle("Accept files without asking", isOn: $alwaysAccept)
					.onChange(of: alwaysAccept) { value in state.setAlwaysAccept(value) }
				Text("Stolnk normally asks once per sender before writing anything to disk. Turning this off means files land silently.")
					.font(.caption)
					.foregroundStyle(.secondary)

				Toggle("Reveal in Finder after every file", isOn: $openFinderEveryTime)
					.onChange(of: openFinderEveryTime) { value in
						state.setOpenFinderEveryTime(value)
					}
			}

			Section("Security") {
				LabeledContent("Device keys") {
					// PRD 9.1/7.2 — the app says which one it got rather than
					// implying the enclave in both cases.
					Text(state.isEnclaveBacked ? "Secure Enclave" : "Software (no Secure Enclave)")
						.foregroundStyle(state.isEnclaveBacked ? .green : .orange)
				}
				Text(
					state.isEnclaveBacked
						? "Your private keys cannot be exported from this Mac — not by Stolnk, and not by us. They also cannot be moved to a new Mac."
						: "This Mac has no Secure Enclave, so keys are stored in the keychain instead."
				)
				.font(.caption)
				.foregroundStyle(.secondary)
			}

			Section("Server") {
				TextField("Origin", text: $origin)
					.onSubmit { state.setOrigin(origin) }
				Text("Change this only if you are running your own Stolnk server.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.onAppear {
			let snapshot = state.store.snapshot
			origin = state.origin.absoluteString
			alwaysAccept = snapshot.alwaysAccept
			openFinderEveryTime = snapshot.openFinderEveryTime
			name = state.name ?? ""
		}
	}

	private func rename() {
		renaming = true
		Task {
			_ = await state.rename(to: NameRules.normalise(name))
			renaming = false
		}
	}
}
