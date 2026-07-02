import SwiftUI
import AppKit

struct MeetingRow: View {
	@EnvironmentObject var controller: RecordingController
	let meeting: Meeting
	private var isActive: Bool { controller.activeID == meeting.id }

	var body: some View {
		HStack(spacing: 10) {
			icon.font(.title2)
			VStack(alignment: .leading, spacing: 1) {
				Text(meeting.title).lineLimit(1)
				HStack(spacing: 5) {
					Text(meeting.modified, format: .dateTime.month().day().hour().minute())
					if meeting.durationSeconds > 0 { Text("· \(durationLabel(meeting.durationSeconds))") }
				}
				.font(.caption).foregroundStyle(.secondary)
			}
			Spacer(minLength: 0)
			if !isActive && noteIsOutdated(meeting.appVersion) {
				Image(systemName: "sparkles")
					.font(.caption).foregroundStyle(.orange)
					.help("Generated with an older version - re-generate to refresh")
			}
		}
		.padding(.vertical, 2)
	}

	@ViewBuilder private var icon: some View {
		if isActive && controller.isRecording {
			Image(systemName: "record.circle.fill").foregroundStyle(.red)
		} else if isActive && controller.busy {
			Image(systemName: "hourglass.circle.fill").foregroundStyle(.orange)
		} else {
			Image(systemName: "waveform.circle.fill").foregroundStyle(brand)
		}
	}
}
