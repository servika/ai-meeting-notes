import Foundation
import CoreAudio

/// Watches the default input (microphone) device and, when another app starts
/// using it - Zoom, Teams, Google Meet, FaceTime, etc. - suggests that the user
/// start recording. It never starts capture on its own; it only raises
/// `suggestRecording` so the UI can show a gentle "Start recording?" nudge.
///
/// Signal: Core Audio's `kAudioDevicePropertyDeviceIsRunningSomewhere`, which is
/// true whenever any process is running the device. We suppress it while our own
/// app is recording (we'd be using the mic too) and only nudge on the rising
/// edge (idle → in-use), once per call.
final class MeetingDetector: ObservableObject {
	@Published var suggestRecording = false

	/// True while the app is recording/processing - provided by the app so we
	/// don't mistake our own mic use for a meeting (and don't nag mid-recording).
	var isBusy: () -> Bool = { false }
	/// Whether suggestions are enabled in Settings.
	var isEnabled: () -> Bool = { true }
	/// Fired once on the rising edge when a meeting is first detected (and enabled).
	/// Lets the app show the floating "are you in a meeting?" prompt.
	var onDetected: () -> Void = {}

	private var timer: Timer?
	private var wasInUse = false
	private var dismissedThisCall = false

	func start() {
		stop()
		timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
			self?.tick()
		}
	}

	func stop() {
		timer?.invalidate()
		timer = nil
	}

	/// User dismissed the nudge for the current call (don't re-suggest until the
	/// device goes idle and a new call starts).
	func dismiss() {
		suggestRecording = false
		dismissedThisCall = true
	}

	/// The user acted on (or no longer needs) the nudge.
	func clear() {
		suggestRecording = false
	}

	private func tick() {
		let inUse = Self.inputDeviceInUse()
		defer { wasInUse = inUse }

		guard inUse else {
			// Call ended (or mic idle): reset so the next call can nudge again.
			dismissedThisCall = false
			if suggestRecording { suggestRecording = false }
			return
		}
		// Mic is in use by *something*. Don't suggest if that something is us,
		// if suggestions are off, or if we've already nudged for this call.
		if isBusy() || !isEnabled() { return }
		if !wasInUse && !dismissedThisCall {
			suggestRecording = true
			onDetected()
		}
	}

	/// Whether the system's default input device is currently running in any
	/// process.
	private static func inputDeviceInUse() -> Bool {
		var deviceID = AudioDeviceID(0)
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		var addr = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultInputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain)
		guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
			deviceID != 0 else { return false }

		var running = UInt32(0)
		size = UInt32(MemoryLayout<UInt32>.size)
		addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
		guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running) == noErr else { return false }
		return running != 0
	}
}