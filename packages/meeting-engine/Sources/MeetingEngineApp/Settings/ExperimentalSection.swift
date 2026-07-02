import SwiftUI
import MeetingEngineCore

/// Settings → General → Experimental features: the master switch + per-flag toggles.
struct ExperimentalSection: View {
	@EnvironmentObject var settings: AppSettings

	private func flagUnavailableReason(_ flag: FeatureFlag) -> String? {
		switch flag {
		case .speakerRecognition: return Diarizer.unavailableReason()
		}
	}

	var body: some View {
		Section("Experimental features") {
			Toggle("Enable experimental features", isOn: $settings.experimentalMode)
			Text("Turns on new, in-development R&D features. These are rough around the edges and may change or be removed - off by default so the regular experience is unaffected.")
				.font(.caption).foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			ForEach(FeatureFlag.allCases) { flag in
				Toggle(flag.title, isOn: settings.flagBinding(flag))
					.disabled(!settings.experimentalMode || flagUnavailableReason(flag) != nil)
				Text(flag.details)
					.font(.caption).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				if settings.experimentalMode, let reason = flagUnavailableReason(flag) {
					stageNote("Unavailable: \(reason).")
				}
			}
		}
	}
}