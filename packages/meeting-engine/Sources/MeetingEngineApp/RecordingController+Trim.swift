import Foundation
import AVFoundation

/// Trim-end support for RecordingController: cut everything after a chosen point
/// from a meeting's audio tracks (typically a recording the user forgot to stop),
/// then re-generate the note from the shortened audio.
extension RecordingController {
	// MARK: trim

	/// Shorten both tracks to `endSeconds`, fix the note's stored duration, and
	/// re-transcribe + re-summarize. No-op while another job is running.
	func trimAudio(_ meeting: Meeting, endSeconds: Double) {
		guard !busy, !isRecording, endSeconds > 1, let meetingsDir = settings.meetingsDirURL else { return }
		busy = true
		progress = 0
		status = "Trimming audio…"
		activeID = meeting.url.path

		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			guard let self = self else { return }
			let content = (try? String(contentsOf: meeting.url, encoding: .utf8)) ?? ""
			let audioBase = Self.frontmatterValue("audio", in: content) ?? "recordings/\(meeting.title)"
			// Each track may still be the original WAV or the compressed M4A.
			var tracks: [String] = []
			for part in ["system", "mic"] {
				for ext in ["wav", "m4a"] {
					let p = meetingsDir.appendingPathComponent("\(audioBase).\(part).\(ext)").path
					if FileManager.default.fileExists(atPath: p) { tracks.append(p); break }
				}
			}
			guard !tracks.isEmpty else {
				DispatchQueue.main.async {
					self.busy = false; self.activeID = nil
					self.status = "No saved audio to trim (it may have been removed after transcription)."
				}
				return
			}

			var allOK = true
			for path in tracks where !Self.trimTrack(path: path, endSeconds: endSeconds) { allOK = false }
			guard allOK else {
				// Each track is replaced atomically, so a failed one is left unchanged.
				DispatchQueue.main.async {
					self.busy = false; self.activeID = nil
					self.status = "Couldn't trim the audio - the recording was left unchanged."
				}
				return
			}

			// Keep the note's duration honest: re-generate trusts the frontmatter.
			Self.updateFrontmatterDuration(noteURL: meeting.url, seconds: Int(endSeconds.rounded()))
			DispatchQueue.main.async {
				self.busy = false
				self.regenerate(meeting)
			}
		}
	}

	/// Trim one track file in place to `endSeconds`. Returns false on failure; the
	/// original file is only replaced after the shortened copy is fully written.
	static func trimTrack(path: String, endSeconds: Double) -> Bool {
		(path as NSString).pathExtension.lowercased() == "wav"
			? trimWAV(path: path, endSeconds: endSeconds)
			: trimM4A(path: path, endSeconds: endSeconds)
	}

	private static func trimWAV(path: String, endSeconds: Double) -> Bool {
		let url = URL(fileURLWithPath: path)
		guard let src = try? AVAudioFile(forReading: url) else { return false }
		let keep = AVAudioFramePosition((endSeconds * src.processingFormat.sampleRate).rounded())
		guard keep > 0 else { return false }
		guard keep < src.length else { return true } // cut point past the end - nothing to do
		let tmpURL = URL(fileURLWithPath: path + ".trim.tmp.wav")
		try? FileManager.default.removeItem(at: tmpURL)
		guard copyFrames(from: src, to: tmpURL, count: keep) else {
			try? FileManager.default.removeItem(at: tmpURL)
			return false
		}
		do {
			_ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
			return true
		} catch {
			try? FileManager.default.removeItem(at: tmpURL)
			return false
		}
	}

	/// Copy the first `count` frames of `src` into a new file at `tmpURL`, in the
	/// source's own file format. Scoped so the destination is closed on return.
	private static func copyFrames(from src: AVAudioFile, to tmpURL: URL, count: AVAudioFramePosition) -> Bool {
		guard let dst = try? AVAudioFile(forWriting: tmpURL, settings: src.fileFormat.settings),
			let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: 1 << 16)
		else { return false }
		var remaining = count
		while remaining > 0 {
			let n = AVAudioFrameCount(min(remaining, AVAudioFramePosition(buf.frameCapacity)))
			do {
				try src.read(into: buf, frameCount: n)
				if buf.frameLength == 0 { break }
				try dst.write(from: buf)
			} catch { return false }
			remaining -= AVAudioFramePosition(buf.frameLength)
		}
		return true
	}

	private static func trimM4A(path: String, endSeconds: Double) -> Bool {
		let url = URL(fileURLWithPath: path)
		if let f = try? AVAudioFile(forReading: url) {
			let dur = Double(f.length) / f.processingFormat.sampleRate
			if endSeconds >= dur - 0.05 { return true } // nothing to cut
		}
		let tmpURL = URL(fileURLWithPath: (path as NSString).deletingPathExtension + ".trim.tmp.m4a")
		let range = CMTimeRange(start: .zero, duration: CMTime(seconds: endSeconds, preferredTimescale: 600))
		// Passthrough keeps the existing AAC data (no lossy re-encode); some assets
		// refuse it, so fall back to a fresh AAC encode.
		for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
			try? FileManager.default.removeItem(at: tmpURL)
			guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: preset) else { continue }
			session.outputURL = tmpURL
			session.outputFileType = .m4a
			session.timeRange = range
			let sem = DispatchSemaphore(value: 0)
			session.exportAsynchronously { sem.signal() }
			sem.wait()
			if session.status == .completed {
				do {
					_ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
					return true
				} catch { break }
			}
		}
		try? FileManager.default.removeItem(at: tmpURL)
		return false
	}

	/// Rewrite the `duration:` frontmatter line after a trim (leaves the note
	/// untouched when it has no duration - re-generate then measures the audio).
	static func updateFrontmatterDuration(noteURL: URL, seconds: Int) {
		guard let content = try? String(contentsOf: noteURL, encoding: .utf8), content.hasPrefix("---") else { return }
		var lines = content.components(separatedBy: "\n")
		for i in 1..<lines.count {
			if lines[i] == "---" { return }
			if lines[i].hasPrefix("duration:") {
				lines[i] = "duration: \(seconds)"
				try? lines.joined(separator: "\n").write(to: noteURL, atomically: true, encoding: .utf8)
				return
			}
		}
	}
}