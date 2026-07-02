import SwiftUI
import AppKit

struct RecordPanel: View {
	@EnvironmentObject var controller: RecordingController
	@EnvironmentObject var settings: AppSettings
	@EnvironmentObject var detector: MeetingDetector

	/// Title of the meeting currently being processed (derived from its note path).
	private var activeTitle: String? {
		guard let id = controller.activeID else { return nil }
		return ((id as NSString).lastPathComponent as NSString).deletingPathExtension
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			// "Meeting detected" is surfaced as a desktop floating card (see
			// MeetingPromptController), not an in-app banner, so it reaches you while
			// you're in your meeting app rather than only inside this window.
			// No notes folder yet: recording can't save anywhere, so make the fix
			// obvious instead of silently doing nothing when Record is clicked.
			if settings.meetingsDirURL == nil && !controller.isRecording && !controller.busy {
				HStack(spacing: 8) {
					Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
					VStack(alignment: .leading, spacing: 1) {
						Text("Choose a notes folder to start").font(.caption.weight(.semibold))
						Text("Meetings are saved as Markdown in a folder you pick.")
							.font(.caption2).foregroundStyle(.secondary)
					}
					Spacer(minLength: 4)
					SettingsLink { Text("Open Settings") }
						.controlSize(.small).buttonStyle(.borderedProminent)
				}
				.padding(10)
				.background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
				.transition(.opacity)
			}

			HStack(spacing: 6) {
				Image(systemName: "globe").foregroundStyle(.secondary)
				Picker("Language", selection: $settings.language) {
					ForEach(meetingLanguages, id: \.code) { Text($0.name).tag($0.code) }
				}
				.labelsHidden()
			}
			.help("Pick the meeting's language for better accuracy")
			.disabled(controller.isRecording || controller.busy)

			if settings.speakerRecognitionEnabled {
				HStack(spacing: 6) {
					Image(systemName: "person.2").foregroundStyle(.secondary)
					Picker("Speakers", selection: $settings.speakerCount) {
						Text("Auto-detect").tag(0)
						ForEach(2...8, id: \.self) { Text("\($0) speakers").tag($0) }
					}
					.labelsHidden()
				}
				.help("How many people are on the other side of the call (improves speaker recognition)")
				.disabled(controller.isRecording || controller.busy)
			}

			Button(action: { controller.toggle() }) {
				Label(controller.isRecording ? "Stop & Transcribe" : "Record",
					systemImage: controller.isRecording ? "stop.fill" : "record.circle")
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.large)
			.tint(controller.isRecording ? .red : brand)
			.disabled(controller.busy || (settings.meetingsDirURL == nil && !controller.isRecording))
			.help(settings.meetingsDirURL == nil ? "Choose a notes folder in Settings first" : "")

			if controller.busy {
				if let title = activeTitle {
					Text(title)
						.font(.caption.weight(.semibold))
						.lineLimit(2).fixedSize(horizontal: false, vertical: true)
				}
				ProgressView(value: controller.progress).progressViewStyle(.linear)
				HStack {
					Text("\(Int(controller.progress * 100))%")
					if !controller.remaining.isEmpty {
						Spacer()
						Text(controller.remaining)
					}
					Spacer()
					Text(controller.elapsed)
				}
				.font(.caption).foregroundStyle(.secondary)
				Button("Stop processing", role: .destructive) { controller.cancelProcessing() }
					.controlSize(.small)
			} else {
				LevelBar(label: "System", level: controller.systemLevel)
				LevelBar(label: "Mic", level: controller.micLevel)
			}

			Text(controller.status)
				.font(.caption).foregroundStyle(.secondary)
				.lineLimit(3).fixedSize(horizontal: false, vertical: true)
		}
		.animation(.default, value: detector.suggestRecording)
		.onChange(of: controller.isRecording) {
			// Once recording, drop the nudge for this call so it doesn't reappear
			// after the recording stops while the meeting is still going.
			if controller.isRecording { detector.dismiss() }
		}
	}
}

struct LevelBar: View {
	let label: String
	let level: Float
	var body: some View {
		HStack(spacing: 8) {
			Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
			GeometryReader { geo in
				ZStack(alignment: .leading) {
					Capsule().fill(Color.secondary.opacity(0.15))
					Capsule().fill(brand.opacity(0.8))
						.frame(width: max(2, geo.size.width * CGFloat(min(max(level, 0), 1))))
				}
			}
			.frame(height: 6)
		}
	}
}
