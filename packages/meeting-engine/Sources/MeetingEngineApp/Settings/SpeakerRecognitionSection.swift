import SwiftUI
import MeetingEngineCore

/// Settings → Transcription → Speaker recognition (experimental): default remote
/// speaker count. Only shown when the feature is enabled and available.
struct SpeakerRecognitionSection: View {
	@EnvironmentObject var settings: AppSettings

	var body: some View {
		if settings.isEnabled(.speakerRecognition), Diarizer.isAvailable() {
			Section("Speaker recognition") {
				Picker("Speakers on the call (their side)", selection: $settings.speakerCount) {
					Text("Auto-detect").tag(0)
					ForEach(2...8, id: \.self) { Text("\($0)").tag($0) }
				}
				Text("Auto-detect is unreliable on real meeting audio - setting the exact number of remote speakers gives much better results. This is the default for new recordings; each meeting also keeps its own count (editable before re-generating). Turn the feature on/off under General → Experimental features.")
					.font(.caption).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}
}