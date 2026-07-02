import SwiftUI

/// Settings → Transcription: the on/off toggle for the transcription stage.
struct TranscribeToggleSection: View {
	@EnvironmentObject var settings: AppSettings

	var body: some View {
		Section {
			Toggle("Transcribe meetings", isOn: $settings.transcribeMeetings)
				.disabled(!settings.transcriptionAvailable)
			if settings.transcribeMeetings, let reason = settings.transcriptionUnavailableReason {
				stageNote(reason)
			}
			Text("When on, each recording is transcribed after it stops. Audio is always saved either way.")
				.font(.caption).foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}