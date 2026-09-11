import StolnkCore
import SwiftUI

struct SettingsView: View {
	@EnvironmentObject private var state: AppState

	var body: some View {
		TabView(selection: $state.settingsTab) {
			InboxLinksView()
				.tabItem { Label("Links", systemImage: "link") }
				.tag(SettingsTab.links)

			SharesView()
				.tabItem { Label("Shares", systemImage: "square.and.arrow.up") }
				.tag(SettingsTab.shares)

			PlanSettings()
				.tabItem { Label("Plan", systemImage: "creditcard") }
				.tag(SettingsTab.plan)

			GeneralSettings()
				.tabItem { Label("General", systemImage: "gearshape") }
				.tag(SettingsTab.general)
		}
		.frame(width: 640, height: 460)
		// PRD 6.2/15.4 — the wall is an offer, and it is the funnel's most
		// informative moment, so it gets a sheet rather than a line of red text.
		.sheet(item: $state.upgradePrompt) { prompt in
			UpgradeSheet(prompt: prompt) { state.upgradePrompt = nil }
		}
	}
}

struct UpgradeSheet: View {
	@EnvironmentObject private var state: AppState
	let prompt: UpgradePrompt
	let dismiss: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(prompt.title).font(.headline)
			Text(prompt.message)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			Text("Pro is $39, paid once, for up to three Macs. There is no subscription.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			HStack {
				// Someone who already bought needs somewhere to go that is not the
				// shop, so both doors are on this sheet. `showSettings` rather than
				// setting the tab: this sheet also appears over the New Inbox
				// window, where Settings may not be open at all.
				Button("I have a key") {
					dismiss()
					state.showSettings(tab: .plan)
				}
				Spacer()
				Button("Not now") { dismiss() }
				Button("See Pro") {
					state.openPurchasePage()
					dismiss()
				}
				.keyboardShortcut(.defaultAction)
			}
		}
		.padding(20)
		.frame(width: 380)
	}
}

/// PRD 16 — what this Mac is entitled to, and how to change it.
///
/// Everything shown is the server's answer (`/licenses/status`). There is no
/// local idea of being Pro, which is why there is nothing here to defeat.
private struct PlanSettings: View {
	@EnvironmentObject private var state: AppState
	@State private var key = ""
	@State private var busy = false
	@State private var failure: String?
	@State private var confirmingRelease = false

	var body: some View {
		Form {
			Section("Plan") {
				LabeledContent("This Mac") {
					Text(planLabel)
						.foregroundStyle(state.plan?.isPro == true ? .green : .secondary)
				}

				if let plan = state.plan {
					VStack(alignment: .leading, spacing: 6) {
						ProgressView(value: plan.relayFraction)
						Text(allowanceLine(plan))
							.font(.caption)
							.foregroundStyle(plan.relayExhausted ? .orange : .secondary)
					}
					.padding(.vertical, 2)

					if let license = plan.license {
						LabeledContent("Licence") {
							Text("\(license.seatsUsed) of \(license.seats) Macs")
								.font(.system(.callout, design: .monospaced))
						}
					}
				}

				// PRD 16.2 — running out never takes the inbox down, so this says
				// what is still true rather than reading as a fault.
				if state.plan?.relayExhausted == true {
					Text(
						state.plan?.isPro == true
							? "Links are not accepting new files until the month turns over. Nothing has been lost, and nothing will be billed."
							: "Links are not accepting new files until the month turns over. Pro raises this to 300 GB a month."
					)
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				}
			}

			if state.plan?.isPro == true {
				Section("Licence") {
					HStack {
						Spacer()
						Button("Release This Mac") { confirmingRelease = true }
							.disabled(busy)
					}
					Text("Frees this Mac's seat so another one can use the licence. Your links and folders stay exactly as they are — this Mac simply goes back to Free.")
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			} else {
				Section("Upgrade") {
					// Pasted from the Creem receipt. The key goes to the Stolnk
					// server, which holds the payment credentials — this app has
					// none, so there is nothing in the binary worth extracting.
					TextField("Licence key", text: $key)
						.font(.system(.callout, design: .monospaced))
						.onSubmit { activate() }

					HStack {
						Button("Buy Stolnk Pro") { state.openPurchasePage() }
						Spacer()
						Button("Activate") { activate() }
							.keyboardShortcut(.defaultAction)
							.disabled(busy || key.trimmingCharacters(in: .whitespaces).isEmpty)
					}

					if let failure {
						Text(failure)
							.font(.caption)
							.foregroundStyle(.red)
							.fixedSize(horizontal: false, vertical: true)
					}

					Text("One payment, three Macs, no subscription. Your key arrives by email the moment you buy.")
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		}
		.formStyle(.grouped)
		.task { await state.refreshPlan() }
		.confirmationDialog(
			"Release this Mac's seat?",
			isPresented: $confirmingRelease,
			titleVisibility: .visible
		) {
			Button("Release", role: .destructive) { release() }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("This Mac goes back to Free. Links beyond the first are paused, not deleted, and come back if you activate again.")
		}
	}

	private var planLabel: String {
		guard let plan = state.plan else { return "—" }
		return plan.isPro ? "Pro" : "Free"
	}

	private func allowanceLine(_ plan: PlanState) -> String {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		let used = formatter.string(fromByteCount: Int64(plan.relayUsed))
		let limit = formatter.string(fromByteCount: Int64(plan.relayLimit))
		return "\(used) of \(limit) relayed this month"
	}

	private func activate() {
		busy = true
		failure = nil
		Task {
			failure = await state.activateLicense(key: key)
			if failure == nil { key = "" }
			busy = false
		}
	}

	private func release() {
		busy = true
		failure = nil
		Task {
			failure = await state.releaseSeat()
			busy = false
		}
	}
}

private struct GeneralSettings: View {
	@EnvironmentObject private var state: AppState
	@State private var origin = ""
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

				Text("Every inbox and active share link on this Mac moves to the new name at once. The old addresses stop working immediately, cutting off anyone holding them, and the name goes straight back into the pool for someone else to take.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			Section("Receiving") {
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

			Section("About") {
				// The one number that has to match what stolnk.com/download is
				// serving. Read from the bundle rather than compiled in, so it
				// cannot disagree with Scripts/bundle.sh's Info.plist — which
				// takes it from stolnk_mac/VERSION, the same file the dmg is
				// named after.
				LabeledContent("Version", value: Self.version)
			}
		}
		.formStyle(.grouped)
		.onAppear {
			let snapshot = state.store.snapshot
			origin = state.origin.absoluteString
			openFinderEveryTime = snapshot.openFinderEveryTime
			name = state.name ?? ""
		}
	}

	/// "1.0.0", or "unknown" for a bare `swift run` build with no bundle.
	private static var version: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
	}

	private func rename() {
		renaming = true
		Task {
			_ = await state.rename(to: NameRules.normalise(name))
			renaming = false
		}
	}
}
