import SwiftUI

/// Settings → General → Recording: detection nudge, auto-stop, audio retention.
struct RecordingSection: View {
	@EnvironmentObject var settings: AppSettings

	private var audioRetentionHint: String {
		switch settings.audioRetention {
		case "original":
			return "Keeps the full-quality WAV tracks - largest files, but the best source for re-generating the transcript later."
		case "delete":
			return "Removes the audio once transcribed: smallest, but you can't re-listen or Re-generate this meeting afterwards."
		default:
			return "Compresses the audio to small AAC files after transcribing (~10× smaller). You keep re-listen and Re-generate."
		}
	}

	var body: some View {
		Section("Recording") {
			Toggle("Suggest recording when a meeting is detected", isOn: $settings.suggestOnMeetingDetected)
			Text("Shows a \"Start recording?\" nudge when another app (Zoom, Teams, Meet, FaceTime…) starts using your microphone. Never records on its own.")
				.font(.caption).foregroundStyle(.secondary)

			if settings.suggestOnMeetingDetected {
				Toggle("Use my calendar to confirm meetings", isOn: $settings.useCalendarForMeetings)
					.padding(.leading, 18)
				Text("Only nudge during a scheduled calendar event (and name it in the prompt) - fewer false \"are you in a meeting?\" alerts. Asks for calendar access when you turn this on.")
					.font(.caption).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.leading, 18)
			}

			Toggle("Auto-stop a recording I forgot to stop", isOn: $settings.autoStopForgotten)
			if settings.autoStopForgotten {
				Stepper(value: $settings.autoStopSilenceMinutes, in: 2...60) {
					Text("Stop after the call is silent for \(settings.autoStopSilenceMinutes) min")
				}
				.padding(.leading, 18)
			}
			Text("Stops on its own when the call goes silent for that long, when your Mac sleeps or the screen locks, or after a 4-hour safety cap - then processes the meeting. You'll get a notification when it does.")
				.font(.caption).foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			Picker("Audio after transcription", selection: $settings.audioRetention) {
				Text("Compressed (recommended)").tag("compressed")
				Text("Best quality (keep original)").tag("original")
				Text("Delete (text only)").tag("delete")
			}
			Text(audioRetentionHint)
				.font(.caption).foregroundStyle(settings.audioRetention == "delete" ? .orange : .secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}