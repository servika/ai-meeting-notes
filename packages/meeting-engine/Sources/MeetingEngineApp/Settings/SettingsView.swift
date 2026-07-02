import SwiftUI

/// The Settings window: four tabs, each composed from self-contained section views
/// that live in their own files under Settings/. This shell only wires them up.
struct SettingsView: View {
	var body: some View {
		TabView {
			Form {
				StorageSection()
				RecordingSection()
				ExperimentalSection()
			}
			.formStyle(.grouped)
			.tabItem { Label("General", systemImage: "folder") }

			Form {
				TranscribeToggleSection()
				QuickSetupSection()
				TranscriptionModelSection()
				SpeakerRecognitionSection()
				ModelPerLanguageSection()
			}
			.formStyle(.grouped)
			.tabItem { Label("Transcription", systemImage: "waveform") }

			Form {
				SummarySection()
			}
			.formStyle(.grouped)
			.tabItem { Label("Summary", systemImage: "sparkles") }

			Form {
				AboutSection()
			}
			.formStyle(.grouped)
			.tabItem { Label("About", systemImage: "info.circle") }
		}
		.tint(brand)
		.frame(width: 720, height: 660)
	}
}