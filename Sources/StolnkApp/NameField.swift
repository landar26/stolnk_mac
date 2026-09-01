import StolnkCore
import SwiftUI

/// What we currently know about a typed name. `unknown` is deliberately not
/// `taken`: a name that could not be checked must never be shown as unavailable.
enum NameStatus: Equatable {
	case empty
	case invalid(String)
	/// What is typed is the name this Mac already holds. Not a verdict about
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
 The name field, shared by first run and Settings.

 Both places need the same three things — local validation, a debounced
 availability check, and a verdict the surrounding form can act on — so the
 debounce lives here once rather than in each screen.
 */
struct NameField: View {
	@Binding var name: String
	@Binding var status: NameStatus
	/// `.stolnk.com`. The name is the subdomain, so the site reads *after* the
	/// box — which is the whole point of the address model made visible.
	let suffix: String

	@EnvironmentObject private var state: AppState
	@State private var probe: Task<Void, Never>?

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 4) {
				TextField("your-name", text: $name)
					.textFieldStyle(.roundedBorder)
					.frame(width: 180)
				Text(suffix)
					.font(.system(.callout, design: .monospaced))
					.foregroundStyle(.secondary)
				if status == .checking { ProgressView().controlSize(.small) }
			}

			if let message {
				Text(message)
					.font(.caption)
					.foregroundStyle(tint)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.onAppear { evaluate(name) }
		.onChange(of: name) { value in evaluate(value) }
		// A successful rename changes what "unchanged" means without touching the
		// field, so the verdict has to be re-derived or it stays stuck on the
		// green "is free" for a name you now own.
		.onChange(of: state.name) { _ in evaluate(name) }
		.onDisappear { probe?.cancel() }
	}

	private var message: String? {
		switch status {
		case .empty: nil
		case .invalid(let problem): problem
		// Nothing to report about your own name, and the form shows it already.
		case .unchanged: nil
		case .checking: nil
		case .available: "\(NameRules.normalise(name))\(suffix) is free."
		case .taken: "That name is taken."
		case .unknown: "Could not check whether that name is free."
		}
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
		let normalised = NameRules.normalise(raw)

		if normalised.isEmpty {
			status = .empty
			return
		}
		if let problem = NameRules.problem(with: normalised) {
			status = .invalid(problem)
			return
		}
		// Only ask about a name that is actually different. Settings opens with the
		// current name in the box, and asking whether you may have the name you
		// already hold gets the literally true, entirely useless answer "taken".
		if normalised == state.name {
			status = .unchanged
			return
		}

		status = .checking
		probe = Task {
			// Long enough that typing a name does not fire a request per keystroke.
			try? await Task.sleep(nanoseconds: 400_000_000)
			if Task.isCancelled { return }
			let answer = await state.isNameAvailable(normalised)
			if Task.isCancelled { return }
			guard NameRules.normalise(name) == normalised else { return }
			status =
				switch answer {
				case .some(true): .available
				case .some(false): .taken
				case .none: .unknown
				}
		}
	}
}
