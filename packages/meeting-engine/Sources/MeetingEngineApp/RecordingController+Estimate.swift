import Foundation

/// Processing-time estimate helpers for RecordingController: learned per-model
/// rates (self-calibrating EMA) used to show a countdown.
extension RecordingController {
	/// Update the learned rate (processing seconds per audio second) for a model.
	static func recordRate(audioSeconds: Double, model: String, processingSeconds: Double) {
		guard audioSeconds > 1, processingSeconds > 0 else { return }
		let key = rateKey(model)
		let new = processingSeconds / audioSeconds
		let prev = UserDefaults.standard.double(forKey: key)
		UserDefaults.standard.set(prev > 0 ? prev * 0.6 + new * 0.4 : new, forKey: key)
	}

	static func processingRate(forModel model: String) -> Double {
		let stored = UserDefaults.standard.double(forKey: rateKey(model))
		if stored > 0 { return stored }
		let m = model.lowercased()
		if m.contains("large") { return 1.5 }
		if m.contains("medium") { return 1.0 }
		if m.contains("small") { return 0.5 }
		if m.contains("tiny") { return 0.1 }
		return 0.25 // base, or unknown
	}

	static func rateKey(_ model: String) -> String {
		"procRate." + (model as NSString).lastPathComponent
	}

	/// Compact duration like `45s`, `2m 05s`, `1h 03m`.
	static func shortTime(_ seconds: TimeInterval) -> String {
		let s = max(0, Int(seconds.rounded()))
		if s < 60 { return "\(s)s" }
		if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
		return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
	}
}
