import SwiftUI

@main
struct MeetingNotesApp: App {
	@StateObject private var settings: AppSettings
	@StateObject private var store: MeetingStore
	@StateObject private var controller: RecordingController
	@StateObject private var detector: MeetingDetector
	@StateObject private var updates = UpdateChecker()
	/// Notion-style floating "are you in a meeting?" card + optional calendar signal.
	private let prompt = MeetingPromptController()
	private let calendar = CalendarMonitor()

	init() {
		let s = AppSettings()
		let st = MeetingStore()
		let c = RecordingController(settings: s, store: st)
		let d = MeetingDetector()
		let promptCtl = prompt
		let cal = calendar
		d.isBusy = { [weak c] in c?.isRecording == true || c?.busy == true }
		d.isEnabled = { [weak s] in s?.suggestOnMeetingDetected ?? true }
		// On detection, show the floating desktop card over whatever app you're in -
		// always, since it's a desktop notification, not an in-app element. When the
		// calendar is opted in, only prompt during a real event and name it.
		d.onDetected = { [weak c, weak s, weak d] in
			Task { @MainActor in
				guard let c, let s else { return }
				var subtitle = "Another app is using your microphone."
				if s.useCalendarForMeetings {
					guard let title = cal.currentEventTitle() else { return }
					subtitle = "“\(title)” is on your calendar right now."
				}
				promptCtl.show(
					subtitle: subtitle,
					onStart: { d?.clear(); c.start() },
					onDismiss: { d?.dismiss() })
			}
		}
		_settings = StateObject(wrappedValue: s)
		_store = StateObject(wrappedValue: st)
		_controller = StateObject(wrappedValue: c)
		_detector = StateObject(wrappedValue: d)
	}

	var body: some Scene {
		WindowGroup {
			ContentView()
				.environmentObject(settings)
				.environmentObject(store)
				.environmentObject(controller)
				.environmentObject(detector)
				.frame(minWidth: 760, minHeight: 480)
				.environmentObject(updates)
				.onAppear {
						detector.start()
						updates.checkIfDue()
						NotificationManager.shared.configure()
						// Tapping "Record" on the notification clears the nudge and starts capture.
						NotificationManager.shared.onRecord = { detector.clear(); controller.start() }
						if settings.useCalendarForMeetings { calendar.requestAccess() }
					}
					.onChange(of: settings.useCalendarForMeetings) { _, on in
						if on { calendar.requestAccess() }
					}
		}
		Settings {
			SettingsView().environmentObject(settings).environmentObject(updates)
		}

		MenuBarExtra {
			MenuBarContent(controller: controller, detector: detector)
		} label: {
			MenuBarLabel(controller: controller, detector: detector)
		}
		.menuBarExtraStyle(.menu)
	}
}