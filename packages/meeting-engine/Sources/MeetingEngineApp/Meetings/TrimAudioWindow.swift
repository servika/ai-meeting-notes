import SwiftUI

/// Separate window for cutting the tail off a meeting's recording - for when the
/// user forgot to stop recording and the file has unrelated audio at the end.
/// Listen with the player to find where the meeting really ended, place the cut
/// point (slider or "Set to playhead"), then trim: both tracks are shortened and
/// the note is re-transcribed and re-summarized from the shorter audio.
struct TrimAudioWindow: View {
	let meetingID: String
	@EnvironmentObject var settings: AppSettings
	@EnvironmentObject var store: MeetingStore
	@EnvironmentObject var controller: RecordingController
	@Environment(\.dismiss) private var dismiss
	// `dismiss` called from inside the confirmation dialog only closes the dialog,
	// so the confirm action closes the whole window via `dismissWindow` instead.
	@Environment(\.dismissWindow) private var dismissWindow
	@StateObject private var player = MeetingAudioPlayer()
	@State private var cutTime: Double = 0
	@State private var confirming = false

	private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }

	/// The meeting's playable tracks (same resolution as MeetingDetail: prefer the
	/// WAV, fall back to the compressed m4a).
	private var audioURLs: [URL] {
		guard let meeting, let dir = settings.meetingsDirURL else { return [] }
		let content = store.content(of: meeting)
		let base = RecordingController.frontmatterValue("audio", in: content) ?? "recordings/\(meeting.title)"
		return ["mic", "system"].compactMap { part -> URL? in
			for ext in ["wav", "m4a"] {
				let u = dir.appendingPathComponent("\(base).\(part).\(ext)")
				if FileManager.default.fileExists(atPath: u.path) { return u }
			}
			return nil
		}
	}

	private var removedSeconds: Double { max(player.duration - cutTime, 0) }

	/// The cut must land inside the recording (with a little margin so a slider at
	/// the very end doesn't offer a no-op trim), and nothing else may be running.
	private var canTrim: Bool {
		player.ready && cutTime > 1 && removedSeconds > 0.5
			&& !controller.busy && !controller.isRecording
	}

	var body: some View {
		Group {
			if let meeting {
				trimContent(meeting)
			} else {
				ContentUnavailableView("Meeting not found", systemImage: "waveform",
					description: Text("This meeting is no longer in the list."))
					.frame(width: 460, height: 220)
			}
		}
		.onAppear {
			let urls = audioURLs
			Task {
				await player.load(urls: urls)
				cutTime = player.duration
			}
		}
		.onDisappear { player.teardown() }
	}

	private func trimContent(_ meeting: Meeting) -> some View {
		VStack(alignment: .leading, spacing: 14) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Trim “\(meeting.title)”")
					.font(.title3.weight(.semibold))
					.lineLimit(1)
				Text("Cut off everything after the meeting actually ended (e.g. you forgot to stop recording). Both tracks are shortened, then the note is re-transcribed and summarized.")
					.font(.callout).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			AudioPlayerView(player: player)
				.padding(.horizontal, -20) // undo the player's built-in inset to align with this window

			VStack(alignment: .leading, spacing: 6) {
				HStack {
					Text("Cut at \(timeLabel(cutTime))")
						.font(.callout.weight(.medium).monospacedDigit())
					Spacer()
					Button("Set to playhead") { cutTime = player.currentTime }
						.controlSize(.small)
						.disabled(!player.ready)
						.help("Place the cut point where playback currently is")
				}
				Slider(value: $cutTime, in: 0...max(player.duration, 0.1))
					.tint(.red)
				Text(removedSeconds > 0.5
					? "Keeps the first \(timeLabel(cutTime)) · removes the last \(timeLabel(removedSeconds))"
					: "Move the cut point left to choose what to remove.")
					.font(.caption).foregroundStyle(.secondary)
			}
			.disabled(!player.ready)

			HStack {
				if controller.busy {
					Text(controller.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
				}
				Spacer()
				Button("Cancel") { dismiss() }
				Button("Trim & Re-generate", role: .destructive) { confirming = true }
					.disabled(!canTrim)
			}
		}
		.padding(20)
		.frame(width: 540)
		.confirmationDialog("Trim this recording to \(timeLabel(cutTime))?", isPresented: $confirming) {
			Button("Trim & Re-generate", role: .destructive) {
				player.teardown()
				controller.trimAudio(meeting, endSeconds: cutTime)
				dismissWindow(id: "audio-trim")
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("This permanently removes the last \(timeLabel(removedSeconds)) of audio from both tracks and re-generates the note. This can't be undone.")
		}
	}

	private func timeLabel(_ seconds: Double) -> String {
		let s = max(0, Int(seconds.rounded()))
		let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
		return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
	}
}