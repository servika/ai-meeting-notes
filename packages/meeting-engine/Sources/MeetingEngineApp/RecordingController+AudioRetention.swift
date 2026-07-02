import Foundation
import AVFoundation

/// Audio-retention helpers for RecordingController: compress/keep/delete tracks
/// after transcription.
extension RecordingController {
	// MARK: audio retention

	/// Apply the audio-retention policy after a successful transcription. Returns
	/// the extension to embed ("wav"/"m4a"), or nil when the audio was deleted.
	static func finalizeAudio(systemWav: String, micWav: String, policy: String) -> String? {
		let fm = FileManager.default
		switch policy {
		case "delete":
			for p in [systemWav, micWav] { try? fm.removeItem(atPath: p) }
			return nil
		case "compressed":
			var allOK = true
			for wav in [systemWav, micWav] where fm.fileExists(atPath: wav) {
				let m4a = (wav as NSString).deletingPathExtension + ".m4a"
				if compressToM4A(wav: wav, m4a: m4a) {
					try? fm.removeItem(atPath: wav)
				} else {
					allOK = false
				}
			}
			return allOK ? "m4a" : "wav" // fall back to keeping WAV if encoding failed
		default: // "original"
			return "wav"
		}
	}

	/// Transcode a WAV to a small AAC `.m4a` (speech-quality bitrate) via afconvert.
	static func compressToM4A(wav: String, m4a: String) -> Bool {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
		p.arguments = ["-f", "m4af", "-d", "aac", "-b", "48000", wav, m4a]
		p.standardOutput = Pipe(); p.standardError = Pipe()
		do { try p.run() } catch { return false }
		p.waitUntilExit()
		return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: m4a)
	}

	static func audioStatusSuffix(_ policy: String) -> String {
		switch policy {
		case "compressed": return " · audio compressed"
		case "delete": return " · audio removed"
		default: return ""
		}
	}

	/// Length (seconds) of a recording, from whichever track exists.
	static func audioDurationSeconds(systemWav: String, micWav: String) -> Int {
		for p in [systemWav, micWav] {
			if let f = try? AVAudioFile(forReading: URL(fileURLWithPath: p)) {
				let secs = Double(f.length) / f.processingFormat.sampleRate
				if secs > 0 { return Int(secs.rounded()) }
			}
		}
		return 0
	}
}
