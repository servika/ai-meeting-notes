import SwiftUI
import AppKit

struct ContentView: View {
	@EnvironmentObject var settings: AppSettings
	@EnvironmentObject var store: MeetingStore
	@EnvironmentObject var controller: RecordingController
	@EnvironmentObject var updates: UpdateChecker
	@State private var selection: Meeting.ID?
	@State private var query = ""

	private var filteredMeetings: [Meeting] {
		let q = query.trimmingCharacters(in: .whitespaces).lowercased()
		guard !q.isEmpty else { return store.meetings }
		return store.meetings.filter { $0.searchHay.contains(q) }
	}

	var body: some View {
		VStack(spacing: 0) {
			updateBanner
			NavigationSplitView {
			VStack(spacing: 0) {
				List(filteredMeetings, selection: $selection) { meeting in
					MeetingRow(meeting: meeting)
						.contextMenu {
							Button("Delete", role: .destructive) {
								store.delete(meeting)
								if selection == meeting.id { selection = nil }
							}
						}
				}
				.listStyle(.sidebar)
				.searchable(text: $query, placement: .sidebar, prompt: "Search title or content")

				Divider()
				RecordPanel().environmentObject(controller).padding(14)
			}
			.navigationSplitViewColumnWidth(min: 250, ideal: 290)
		} detail: {
			if let id = selection, let meeting = store.meetings.first(where: { $0.id == id }) {
				// Only show processing state on the meeting actually being processed,
				// not whichever one happens to be selected.
				let isProcessingThis = controller.busy && controller.activeID == meeting.id
				MeetingDetail(
					meeting: meeting,
					content: store.content(of: meeting),
					busy: isProcessingThis,
					progress: controller.progress,
					status: controller.status,
					eta: controller.remaining,
					onRename: { newName in
						if let renamed = store.rename(meeting, to: newName) {
							selection = renamed.id
							// If we renamed the note of the in-progress/processing recording,
							// keep the controller pointed at it so finalize writes there
							// instead of creating a duplicate.
							if controller.activeID == meeting.id { controller.activeID = renamed.id }
						}
					},
					onRegenerate: { count in controller.regenerate(meeting, speakerCount: count) },
					onCompress: { controller.compressAudio(meeting) },
					onDelete: { store.delete(meeting); selection = nil },
					onCancel: { controller.cancelProcessing() })
			} else if settings.meetingsDirURL == nil {
				// First run: guide the user to set up before anything else.
				ContentUnavailableView {
					Label("Welcome to AI Meeting Notes", systemImage: "waveform")
				} description: {
					Text("To get started, choose a folder where your meeting notes will be saved. Then pick a transcription model, and you're ready to record.")
				} actions: {
					SettingsLink { Text("Open Settings to set up") }
						.buttonStyle(.borderedProminent)
				}
			} else {
				ContentUnavailableView("No meeting selected", systemImage: "waveform",
					description: Text("Record a meeting, or pick one from the list."))
			}
		}
		.tint(brand)
		.onAppear { store.reload(folder: settings.meetingsDirURL) }
		.onChange(of: controller.activeID) {
			if let id = controller.activeID { selection = id }
		}
		}
	}

	/// A slim "update available" bar at the top of the window. Empty (no space)
	/// when the app is current or the user dismissed the notice.
	@ViewBuilder private var updateBanner: some View {
		if updates.updateAvailable, let v = updates.latestVersion {
			HStack(spacing: 10) {
				Image(systemName: "arrow.down.circle.fill").foregroundStyle(brand)
				Text("Version \(v) is available.").font(.callout)
				Spacer()
				if let url = updates.releaseURL {
					Link("Download", destination: url)
						.buttonStyle(.borderedProminent).controlSize(.small)
				}
				Button { updates.dismiss() } label: { Image(systemName: "xmark") }
					.buttonStyle(.borderless).controlSize(.small)
					.help("Dismiss until the next version")
			}
			.padding(.horizontal, 14).padding(.vertical, 8)
			.background(.bar)
		}
	}
}
