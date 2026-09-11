import StolnkCore
import SwiftUI

/// What we currently know about a typed name. `unknown` is deliberately not
/// `taken`: a name that could not be checked must never be shown as unavailable.
enum NameStatus: Equatable {
	case empty
	case invalid(String)
	/// What is typed is the value the caller already holds. Not a verdict about
	/// availability — the question was never asked.
	case unchanged
	case checking
	case available
	case taken
	case unknown

	var blocksSubmission: Bool {
		switch self {
		case .empty, .invalid, .unchanged, .taken: true
		case .checking, .available, .unknown: false
		}
	}
}

/**
 A text field for something that has to be unique on the server: local
 validation, a debounced availability check, and a verdict the surrounding form
 can act on.

 Generic over what is being typed because there are now two of them — a device
 name and a share link's path — and the debounce, the cancellation and the
 "answer arrived for a value you have since typed past" guard are the whole
 substance of the thing. Copying them per field is how they drift.
 */
struct AvailabilityField: View {
	@Binding var text: String
	@Binding var status: NameStatus
	let placeholder: String
	/// Shown before the box, e.g. `ryan.stolnk.com/~`.
	var prefix: String?
	/// Shown after it, e.g. `.stolnk.com`.
	var suffix: String?
	var width: CGFloat = 180
	let normalise: (String) -> String
	let problem: (String) -> String?
	/// The value the caller already holds, so typing it back is `.unchanged`
	/// rather than the true but useless answer "taken".
	let current: String?
	/// `nil` means the question could not be asked, not that the answer is no.
	let check: (String) async -> Bool?
	/// The caption under the box. Takes the normalised text so a verdict can
	/// quote the address it is a verdict about.
	let describe: (NameStatus, String) -> String?

	@State private var probe: Task<Void, Never>?

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 4) {
				if let prefix {
					Text(prefix)
						.font(.system(.callout, design: .monospaced))
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.head)
				}
				TextField(placeholder, text: $text)
					.textFieldStyle(.roundedBorder)
					.frame(width: width)
				if let suffix {
					Text(suffix)
						.font(.system(.callout, design: .monospaced))
						.foregroundStyle(.secondary)
				}
				if status == .checking { ProgressView().controlSize(.small) }
			}

			if let message = describe(status, normalise(text)) {
				Text(message)
					.font(.caption)
					.foregroundStyle(tint)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.onAppear { evaluate(text) }
		.onChange(of: text) { value in evaluate(value) }
		// A successful rename changes what "unchanged" means without touching the
		// field, so the verdict has to be re-derived or it stays stuck on the
		// green "is free" for a name you now own.
		.onChange(of: current) { _ in evaluate(text) }
		.onDisappear { probe?.cancel() }
	}

	private var tint: Color {
		switch status {
		case .available: .green
		case .taken, .invalid: .orange
		default: .secondary
		}
	}

	private func evaluate(_ raw: String) {
		probe?.cancel()
		let normalised = normalise(raw)

		if normalised.isEmpty {
			status = .empty
			return
		}
		if let problem = problem(normalised) {
			status = .invalid(problem)
			return
		}
		if normalised == current {
			status = .unchanged
			return
		}

		status = .checking
		probe = Task {
			// Long enough that typing does not fire a request per keystroke.
			try? await Task.sleep(nanoseconds: 400_000_000)
			if Task.isCancelled { return }
			let answer = await check(normalised)
			if Task.isCancelled { return }
			guard normalise(text) == normalised else { return }
			status =
				switch answer {
				case .some(true): .available
				case .some(false): .taken
				case .none: .unknown
				}
		}
	}
}

/// The name field, shared by first run and Settings.
struct NameField: View {
	@Binding var name: String
	@Binding var status: NameStatus
	/// `.stolnk.com`. The name is the subdomain, so the site reads *after* the
	/// box — which is the whole point of the address model made visible.
	let suffix: String

	@EnvironmentObject private var state: AppState

	var body: some View {
		AvailabilityField(
			text: $name,
			status: $status,
			placeholder: "your-name",
			suffix: suffix,
			normalise: NameRules.normalise,
			problem: { NameRules.problem(with: $0) },
			current: state.name,
			check: { await state.isNameAvailable($0) },
			describe: { status, normalised in
				switch status {
				case .empty: nil
				case .invalid(let problem): problem
				// Nothing to report about your own name, and the form shows it already.
				case .unchanged: nil
				case .checking: nil
				case .available: "\(normalised)\(suffix) is free."
				case .taken: "That name is taken."
				case .unknown: "Could not check whether that name is free."
				}
			}
		)
	}
}
