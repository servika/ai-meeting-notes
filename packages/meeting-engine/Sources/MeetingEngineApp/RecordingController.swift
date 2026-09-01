import Foundation
import AppKit
import AVFoundation
import MeetingEngineCore

/// Drives record → stop → transcribe → summarize → save-to-vault (and
/// re-generate for existing meetings), exposing observable state for the UI.
final class RecordingController: ObservableObject {
	@Published var isRecording = false
	@Published var busy = false
	@Published var status = "Ready."
	@Published var systemLevel: Float = 0
	@Published var micLevel: Float = 0
	@Published var progress: Double = 0
	@Published var elapsed: String = ""
	/// Estimated time remaining for the current processing (live, from progress).
	@Published var remaining: String = ""
	/// The meeting currently being recorded or processed (for selection + row icon).
	@Published var activeID: String?

	private var recorder: MeetingRecorder?
	private var stamp = ""
	private var procTimer: Timer?
	// Auto-stop watchdog (for a recording the user forgot to stop).
	private var watchdog: Timer?
	private var recordStart: Date?
	private var lastSound: Date?
	private var sleepObserver: NSObjectProtocol?
	private var lockObserver: NSObjectProtocol?
	/// Below this peak level (0…1) on both tracks counts as "silent".
	private static let silenceLevel: Float = 0.02
	/// Hard safety cap: never let a forgotten recording run past this.
	private static let maxRecordingSeconds: TimeInterval = 4 * 3600
	private var procStart: Date?
	/// First reliable (elapsed, progress) sample once processing is underway, used
	/// to extrapolate "time left" from the live rate - accurate even on the first
	/// run, before the per-model estimate has calibrated.
	private var progressAnchor: (t: TimeInterval, p: Double)?
	/// Estimated total processing time for the current run (seconds); the UI shows
	/// it counting down. 0 = unknown.
	private var estimatedTotal: TimeInterval = 0
	private var cancelToken: CancelToken?
	// Internal (not private) so the RecordingController+… extension files can use it.
	let settings: AppSettings
	private let store: MeetingStore

	init(settings: AppSettings, store: MeetingStore) {
		self.settings = settings
		self.store = store
	}

	func toggle() { isRecording ? stop() : start() }

	/// Stop an in-progress transcription/summarization. The recording's audio is
	/// kept, so the meeting can be re-generated later.
	func cancelProcessing() {
		cancelToken?.cancel()
		status = "Stopping…"
	}

	func start() {
		guard let meetingsDir = settings.meetingsDirURL else {
			status = "Choose a notes folder in Settings (⌘,) before recording."
			return
		}
		let recordingsDir = meetingsDir.appendingPathComponent("recordings", isDirectory: true)
		try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

		stamp = Self.timestamp()
		let outBase = recordingsDir.appendingPathComponent("Meeting \(stamp)").path
		let r = MeetingRecorder(log: { [weak self] msg in DispatchQueue.main.async { self?.status = msg } })
		r.onLevel = { [weak self] s, m in DispatchQueue.main.async { self?.systemLevel = s; self?.micLevel = m } }
		do {
			try r.start(outBase: outBase, appName: nil)
			recorder = r
			isRecording = true
			startWatchdog()
			status = "Recording… click Stop when the meeting ends."
			// Show the new meeting in the list immediately (and select it), so it's
			// not confused with whatever was previously highlighted.
			let title = "Meeting \(stamp)"
			let noteURL = meetingsDir.appendingPathComponent("\(title).md")
			let placeholder = Self.buildNote(title: title, date: stamp, audioBase: "recordings/Meeting \(stamp)",
				durationSeconds: 0, speakerCount: settings.speakerRecognitionEnabled ? settings.speakerCount : 0, summary: "", transcript: "_Recording in progress…_")
			try? placeholder.write(to: noteURL, atomically: true, encoding: .utf8)
			store.reload(folder: meetingsDir)
			activeID = noteURL.path
		} catch {
			status = "Couldn't start: \(error)"
		}
	}

	func stop() {
		guard let r = recorder else { return }
		stopWatchdog()
		isRecording = false
		busy = true
		progress = 0
		status = "Finishing recording…"
		startElapsedTimer()
		let stamp = self.stamp
		let token = CancelToken()
		cancelToken = token
		guard let meetingsDir = settings.meetingsDirURL else { busy = false; stopElapsedTimer(); return }

		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			guard let self = self else { return }
			let result = r.stop()
			DispatchQueue.main.async { self.systemLevel = 0; self.micLevel = 0 }

			let estModel = self.settings.modelPath(for: self.settings.language.isEmpty ? "auto" : self.settings.language)
			self.beginEstimate(audioSeconds: result.duration, model: estModel)
			let audioBase = "recordings/Meeting \(stamp)"
			// Follow a rename made during recording *or* while this transcription runs,
			// so we update the placeholder note instead of creating a duplicate. The
			// destination is resolved right before each write (see `currentNoteURL`),
			// never up front: transcription takes minutes and the note can move under us.
			let fallbackURL = meetingsDir.appendingPathComponent("Meeting \(stamp).md")
			// New recordings seed their speaker count from the current setting; it's
			// then persisted per meeting and can be corrected before re-generating.
			let speakers = self.settings.speakerRecognitionEnabled ? self.settings.speakerCount : 0
			do {
				let (transcript, summary, model, summaryModel, summaryError) = try self.transcribeAndSummarize(systemWav: result.systemURL.path, micWav: result.micURL.path, speakerCount: speakers, cancel: token)
				// Apply the audio-retention policy - but only when transcription ran,
				// so an audio-only recording is never compressed/deleted out from under
				// the user (the audio is the content in that case).
				let policy = self.settings.transcribeMeetings ? self.settings.audioRetention : "original"
				if policy != "original" { DispatchQueue.main.async { self.status = "Optimizing audio…" } }
				let audioExt = Self.finalizeAudio(systemWav: result.systemURL.path, micWav: result.micURL.path, policy: policy)
				let noteURL = self.currentNoteURL(audioBase: audioBase, in: meetingsDir, fallback: fallbackURL)
				let title = noteURL.deletingPathExtension().lastPathComponent
				let note = Self.buildNote(title: title, date: stamp, audioBase: audioBase, durationSeconds: Int(result.duration.rounded()), speakerCount: speakers, summary: summary, transcript: transcript, audioExt: audioExt, model: model, summaryModel: summaryModel)
				try note.write(to: noteURL, atomically: true, encoding: .utf8)
				Self.recordRate(audioSeconds: result.duration, model: estModel, processingSeconds: Date().timeIntervalSince(self.procStart ?? Date()))
				let saved = "Saved \(noteURL.lastPathComponent)" + Self.audioStatusSuffix(policy)
				self.finish(status: summaryError == nil ? "✅ " + saved
					: "⚠️ \(saved) - summary failed (\(summaryError!)). Re-generate to retry.")
			} catch is CancelledError {
				// Keep the recording as a re-generatable note.
				let noteURL = self.currentNoteURL(audioBase: audioBase, in: meetingsDir, fallback: fallbackURL)
				let title = noteURL.deletingPathExtension().lastPathComponent
				let note = Self.buildNote(title: title, date: stamp, audioBase: audioBase, durationSeconds: Int(result.duration.rounded()), speakerCount: speakers, summary: "",
					transcript: "_Transcription stopped. Open this meeting and click Re-generate to process it._")
				try? note.write(to: noteURL, atomically: true, encoding: .utf8)
				self.finish(status: "Stopped - re-generate when ready")
			} catch {
				self.finish(status: "Failed: \(error)")
			}
			DispatchQueue.main.async { self.recorder = nil }
		}
	}

	/// Re-transcribe + re-summarize an existing meeting from its saved audio.
	/// `speakerCount` overrides the note's stored count (nil keeps it as-is).
	func regenerate(_ meeting: Meeting, speakerCount: Int? = nil) {
		guard !busy, !isRecording else { return }
		busy = true
		progress = 0
		status = "Re-generating…"
		activeID = meeting.url.path
		startElapsedTimer()
		let token = CancelToken()
		cancelToken = token
		guard let meetingsDir = settings.meetingsDirURL else { busy = false; stopElapsedTimer(); return }
		let noteURL = meeting.url
		let title = meeting.title

		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			guard let self = self else { return }
			let content = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
			let date = Self.frontmatterValue("date", in: content) ?? title
			let audioBase = Self.frontmatterValue("audio", in: content) ?? "recordings/\(title)"
			// Audio may be the original WAV or a compressed M4A - use whichever exists.
			let audioExt = ["wav", "m4a"].first { e in
				FileManager.default.fileExists(atPath: meetingsDir.appendingPathComponent(audioBase + ".system." + e).path)
					|| FileManager.default.fileExists(atPath: meetingsDir.appendingPathComponent(audioBase + ".mic." + e).path)
			} ?? "wav"
			let systemWav = meetingsDir.appendingPathComponent(audioBase + ".system." + audioExt).path
			let micWav = meetingsDir.appendingPathComponent(audioBase + ".mic." + audioExt).path
			let dur = Int(Self.frontmatterValue("duration", in: content) ?? "") ?? Self.audioDurationSeconds(systemWav: systemWav, micWav: micWav)
			// An explicit override wins; otherwise keep whatever the note recorded.
			let speakers = self.settings.speakerRecognitionEnabled
				? (speakerCount ?? Int(Self.frontmatterValue("speakers", in: content) ?? "") ?? 0)
				: 0

			guard FileManager.default.fileExists(atPath: systemWav) || FileManager.default.fileExists(atPath: micWav) else {
				self.finish(status: "No saved audio found (it may have been removed after transcription).")
				return
			}
			let estModel = self.settings.modelPath(for: self.settings.language.isEmpty ? "auto" : self.settings.language)
			self.beginEstimate(audioSeconds: Double(dur), model: estModel)
			do {
				let (transcript, summary, model, summaryModel, summaryError) = try self.transcribeAndSummarize(systemWav: systemWav, micWav: micWav, speakerCount: speakers, cancel: token)
				// If this run's summary failed (e.g. an overloaded local model timed out),
				// don't wipe the note's existing summary - keep it rather than overwrite it
				// with nothing. The transcript is always refreshed.
				var finalSummary = summary
				var finalSummaryModel = summaryModel
				if summaryError != nil {
					let previous = Self.existingSummaryBlock(in: content)
					// Keeping the old summary means keeping the model that wrote it -
					// otherwise the note would credit this run's engine for text it
					// didn't produce (or drop the attribution entirely).
					if !previous.isEmpty {
						finalSummary = previous
						finalSummaryModel = Self.frontmatterValue("summary_model", in: content) ?? ""
					}
				}
				// Re-generate only re-transcribes; it never changes the audio. Use the
				// "Compress audio" action to shrink a recording without re-transcribing.
				// Re-resolve the note here, not up front: a rename during the (minutes-long)
				// re-generation would otherwise recreate the old filename as a duplicate.
				let outURL = self.currentNoteURL(audioBase: audioBase, in: meetingsDir, fallback: noteURL)
				let outTitle = outURL.deletingPathExtension().lastPathComponent
				let note = Self.buildNote(title: outTitle, date: date, audioBase: audioBase, durationSeconds: dur, speakerCount: speakers, summary: finalSummary, transcript: transcript, audioExt: audioExt, model: model, summaryModel: finalSummaryModel)
				try note.write(to: outURL, atomically: true, encoding: .utf8)
				Self.recordRate(audioSeconds: Double(dur), model: estModel, processingSeconds: Date().timeIntervalSince(self.procStart ?? Date()))
				if let summaryError {
					let kept = Self.existingSummaryBlock(in: content).isEmpty ? "" : " (kept the previous one)"
					self.finish(status: "⚠️ Re-generated transcript - summary failed\(kept): \(summaryError)")
				} else {
					self.finish(status: "✅ Re-generated \(outTitle)")
				}
			} catch is CancelledError {
				self.finish(status: "Stopped. The existing note is unchanged.")
			} catch {
				self.finish(status: "Failed: \(error)")
			}
		}
	}

	/// Compress a meeting's WAV tracks to AAC `.m4a` in place - no re-transcription -
	/// and rewrite the note's audio embeds. For shrinking older, high-quality
	/// recordings without paying the cost of re-transcribing.
	func compressAudio(_ meeting: Meeting) {
		guard !busy, !isRecording, let meetingsDir = settings.meetingsDirURL else { return }
		let noteURL = meeting.url
		busy = true
		progress = 0
		status = "Compressing audio…"
		startElapsedTimer()
		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			guard let self = self else { return }
			let content = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
			let audioBase = Self.frontmatterValue("audio", in: content) ?? "recordings/\(meeting.title)"
			let systemWav = meetingsDir.appendingPathComponent(audioBase + ".system.wav").path
			let micWav = meetingsDir.appendingPathComponent(audioBase + ".mic.wav").path
			guard FileManager.default.fileExists(atPath: systemWav) || FileManager.default.fileExists(atPath: micWav) else {
				self.finish(status: "Nothing to compress (audio is already optimized).")
				return
			}
			let ext = Self.finalizeAudio(systemWav: systemWav, micWav: micWav, policy: "compressed")
			if ext == "m4a" {
				// Re-resolve (and re-read) the note at write time - it may have been
				// renamed while compressing, and writing the stale path back would
				// resurrect the old filename as a duplicate.
				let outURL = self.currentNoteURL(audioBase: audioBase, in: meetingsDir, fallback: noteURL)
				let current = (try? String(contentsOf: outURL, encoding: .utf8)) ?? content
				let audioName = (audioBase as NSString).lastPathComponent
				let updated = current
					.replacingOccurrences(of: "\(audioName).mic.wav", with: "\(audioName).mic.m4a")
					.replacingOccurrences(of: "\(audioName).system.wav", with: "\(audioName).system.m4a")
				try? updated.write(to: outURL, atomically: true, encoding: .utf8)
				self.finish(status: "✅ Audio compressed")
			} else {
				self.finish(status: "Couldn't compress audio (kept the original).")
			}
		}
	}

	// MARK: pipeline

	/// Transcribe both tracks (with weighted progress) and summarize. Runs on a
	/// background queue; updates `progress`/`status` on the main queue.
	private func transcribeAndSummarize(systemWav: String, micWav: String, speakerCount: Int, cancel: CancelToken) throws -> (transcript: String, summary: String, model: String, summaryModel: String, summaryError: String?) {
		let lang = settings.language.isEmpty ? "auto" : settings.language
		let model = (settings.modelPath(for: lang) as NSString).expandingTildeInPath
		let hint = settings.transcriptionPrompt
		let setProgress: (Double) -> Void = { p in DispatchQueue.main.async { self.progress = p } }

		// Stage 1: transcription (opt-out). When off, we keep just the audio note.
		var transcript = ""
		var usedModel = ""
		if settings.transcribeMeetings {
			usedModel = Self.modelDisplayName(model)
			DispatchQueue.main.async { self.status = "Transcribing…"; self.progress = 0.05 }
			var them = try Transcriber.transcribe(wavPath: systemWav, model: model, language: lang, prompt: hint, speaker: "Them",
				progress: { setProgress(0.05 + $0 * 0.45) }, cancel: cancel, log: { _ in })
			let you = try Transcriber.transcribe(wavPath: micWav, model: model, language: lang, prompt: hint, speaker: "You",
				progress: { setProgress(0.50 + $0 * 0.38) }, cancel: cancel, log: { _ in })

			// Experimental: split the single "Them" into per-speaker labels by running
			// diarization on the system track and relabeling its segments by overlap.
			// Best-effort - on any failure we keep the plain "Them" transcript.
			if settings.speakerRecognitionEnabled, Diarizer.isAvailable() {
				DispatchQueue.main.async { self.status = "Identifying speakers…"; self.progress = 0.90 }
				do {
					let spans = try Diarizer.diarize(wavPath: systemWav, speakerCount: speakerCount, cancel: cancel, log: { _ in })
					them = Diarizer.relabel(them, using: spans)
				} catch is CancelledError {
					throw CancelledError()
				} catch {
					DispatchQueue.main.async { self.status = "Speaker recognition skipped: \(error)" }
				}
			}
			// Drop cross-track echo (in-person/speakerphone meetings capture the same
			// room on both tracks) before merging, so the transcript isn't doubled.
			transcript = Transcriber.diarizedMarkdown(Transcriber.removeCrossTalkEchoes(them + you))
		}

		if cancel.isCancelled { throw CancelledError() }

		// Stage 2: summary (opt-out). Needs a transcript and a configured engine.
		// `summaryError` is non-nil when a summary was expected but didn't come through
		// (engine threw - e.g. an overloaded local model timing out - or returned empty).
		// Callers use it to avoid clobbering a good existing summary with nothing and to
		// report the failure honestly instead of a false "done".
		var summary = ""
		var summaryModel = ""
		var summaryError: String?
		if settings.summarizeMeetings, !transcript.isEmpty, let engine = Self.engine(from: settings) {
			DispatchQueue.main.async { self.status = "Summarizing…"; self.progress = 0.92 }
			let prompt = settings.currentPrompt().replacingOccurrences(of: "{{language}}", with: Self.languageName(lang))
			do {
				summary = try Summarizer.summarize(transcript: transcript, prompt: prompt, engine: engine)
				if summary.isEmpty { summaryError = "the model returned an empty summary" }
				// Only claim a model when it actually produced a summary - an empty or
				// failed run must not label the note with a model that wrote nothing.
				if !summary.isEmpty { summaryModel = engine.label }
			} catch {
				summaryError = "\(error)"
				DispatchQueue.main.async { self.status = "Summary failed: \(error)" }
			}
		}
		return (transcript, summary, usedModel, summaryModel, summaryError)
	}

	/// The summary markdown block (the `## …` sections before Transcript/Audio) from
	/// an existing note, so a failed re-summary can keep it instead of erasing it.
	/// Empty when the note has no recognizable summary sections.
	static func existingSummaryBlock(in content: String) -> String {
		var body = content
		if body.hasPrefix("---"),
			let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 3)..<body.endIndex) {
			body = String(body[end.upperBound...])
		}
		// Cut off the Transcript/Audio sections - everything after the summary.
		for marker in ["\n## Transcript", "\n## Audio"] {
			if let r = body.range(of: marker) { body = String(body[..<r.lowerBound]); break }
		}
		// Start at the first "## " heading (skips the leading "# Title" line).
		guard let start = body.range(of: "## ") else { return "" }
		return String(body[start.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Friendly whisper-model name from its file path, for the note's `model:`
	/// frontmatter - e.g. "…/ggml-large-v3-turbo.bin" -> "large-v3-turbo".
	private static func modelDisplayName(_ path: String) -> String {
		var name = (path as NSString).lastPathComponent
		if name.hasSuffix(".bin") { name = String(name.dropLast(4)) }
		if name.hasPrefix("ggml-") { name = String(name.dropFirst(5)) }
		return name
	}

	private func finish(status: String) {
		DispatchQueue.main.async {
			self.busy = false
			self.progress = 1
			self.cancelToken = nil
			self.activeID = nil
			self.stopElapsedTimer()
			self.status = status
			self.store.reload(folder: self.settings.meetingsDirURL)
		}
	}

	// MARK: helpers

	/// Human-readable language for the `{{language}}` prompt slot. "auto" (or
	/// anything unknown) tells the model to match the transcript's language.
	private static func languageName(_ code: String) -> String {
		switch code {
		case "uk": return "Ukrainian"
		case "en": return "English"
		default: return "the same language as the transcript"
		}
	}

	private static func engine(from s: AppSettings) -> SummaryEngine? {
		switch s.summaryEngine {
		case "ollama": return .ollama(url: s.ollamaURL, model: s.ollamaModel)
		case "claude": return .claude(apiKey: s.claudeAPIKey, model: s.claudeModel)
		default: return nil
		}
	}

	/// `audioExt` is the extension of the kept tracks ("wav" or "m4a"), or nil when
	/// the audio was deleted after transcription.
	/// Internal rather than private so the tests can pin the note format (it has to
	/// stay byte-compatible with the Windows app - see NOTE-FORMAT.md).
	static func buildNote(title: String, date: String, audioBase: String, durationSeconds: Int, speakerCount: Int = 0, summary: String, transcript: String, audioExt: String? = "wav", model: String = "", summaryModel: String = "") -> String {
		let audioName = (audioBase as NSString).lastPathComponent
		var s = "---\ntype: meeting\ntags: [meeting]\ndate: \(date)\naudio: \(audioBase)\n"
		if durationSeconds > 0 { s += "duration: \(durationSeconds)\n" }
		if speakerCount >= 2 { s += "speakers: \(speakerCount)\n" }
		// Which whisper model produced this transcript - so a garbled note is
		// traceable to the model used (e.g. a weak default vs. large-v3-turbo).
		if !model.isEmpty { s += "model: \(model)\n" }
		// Which engine + model wrote the summary (`provider/model`), so summary
		// quality is comparable across engines on a real archive. Absent when the
		// note has no summary.
		if !summaryModel.isEmpty { s += "summary_model: \(summaryModel)\n" }
		s += "app_version: \(appVersion)\n"
		s += "---\n\n# \(title)\n\n"
		if !summary.isEmpty { s += summary + "\n\n" }
		s += "## Transcript\n\n" + (transcript.isEmpty ? "_(no speech detected)_" : transcript) + "\n"
		// Embed the audio so Obsidian shows inline players. The app hides this
		// section (it has its own access to the recordings).
		s += "\n## Audio\n\n"
		if let ext = audioExt {
			s += "**You (microphone)**\n\n![[\(audioName).mic.\(ext)]]\n\n"
			s += "**Them (system audio)**\n\n![[\(audioName).system.\(ext)]]\n"
		} else {
			s += "_Audio removed after transcription to save space._\n"
		}
		return s
	}


	/// Find an existing note that links the given audio base - matches even if the
	/// note file was renamed during recording.
	static func existingNoteURL(audioBase: String, in dir: URL) -> URL? {
		let items = (try? FileManager.default.contentsOfDirectory(
			at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
		for url in items where url.pathExtension.lowercased() == "md" {
			let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
			if frontmatterValue("audio", in: content) == audioBase { return url }
		}
		return nil
	}

	/// The note to write a finalized recording into. Prefers `preferredPath` (the
	/// note the controller has tracked for this recording since `start()`) when it
	/// still exists and links this recording, otherwise falls back to scanning for
	/// any note that links the recording. Returns nil only when no note links it,
	/// so the caller can create a fresh one. Trusting the tracked note first avoids
	/// spawning a duplicate when a frontmatter re-scan transiently misses the
	/// (possibly just-renamed) placeholder.
	static func targetNoteURL(preferredPath: String?, audioBase: String, in dir: URL) -> URL? {
		if let preferredPath, FileManager.default.fileExists(atPath: preferredPath) {
			let url = URL(fileURLWithPath: preferredPath)
			let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
			if frontmatterValue("audio", in: content) == audioBase { return url }
		}
		return existingNoteURL(audioBase: audioBase, in: dir)
	}

	/// `activeID` read from a background queue without racing the main thread.
	private var trackedNotePath: String? {
		Thread.isMainThread ? activeID : DispatchQueue.main.sync { self.activeID }
	}

	/// The note to write into *right now*. Processing takes minutes, and the user
	/// can rename the note while it runs - so the destination has to be re-resolved
	/// at write time. A URL captured before the run would recreate the pre-rename
	/// filename and leave the vault with two notes for one meeting.
	func currentNoteURL(audioBase: String, in dir: URL, fallback: URL) -> URL {
		Self.targetNoteURL(preferredPath: trackedNotePath, audioBase: audioBase, in: dir) ?? fallback
	}

	/// Read a `key: value` line from a note's YAML frontmatter block.
	static func frontmatterValue(_ key: String, in content: String) -> String? {
		guard content.hasPrefix("---") else { return nil }
		var inBlock = false
		for (i, line) in content.components(separatedBy: "\n").enumerated() {
			if i == 0, line == "---" { inBlock = true; continue }
			if inBlock, line == "---" { break }
			if inBlock, line.hasPrefix("\(key):") {
				return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
			}
		}
		return nil
	}

	// MARK: auto-stop watchdog

	/// Start watching a live recording so one the user forgot to stop doesn't run
	/// forever: stop when the call goes silent, when the Mac sleeps / the screen
	/// locks, or at the safety cap. All gated by `settings.autoStopForgotten`,
	/// re-checked live so toggling the setting mid-recording takes effect.
	private func startWatchdog() {
		recordStart = Date()
		lastSound = Date()
		watchdog?.invalidate()
		watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
			self?.watchdogTick()
		}
		let ws = NSWorkspace.shared.notificationCenter
		sleepObserver = ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
			self?.autoStop(reason: "your Mac went to sleep")
		}
		lockObserver = DistributedNotificationCenter.default().addObserver(
			forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
		) { [weak self] _ in
			self?.autoStop(reason: "the screen locked")
		}
	}

	private func stopWatchdog() {
		watchdog?.invalidate(); watchdog = nil
		if let o = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); sleepObserver = nil }
		if let o = lockObserver { DistributedNotificationCenter.default().removeObserver(o); lockObserver = nil }
		recordStart = nil; lastSound = nil
	}

	private func watchdogTick() {
		guard isRecording, settings.autoStopForgotten else { return }
		let now = Date()
		// Any sound on either track means the meeting is still live - reset the clock.
		if max(systemLevel, micLevel) > Self.silenceLevel { lastSound = now }

		if let start = recordStart, now.timeIntervalSince(start) >= Self.maxRecordingSeconds {
			autoStop(reason: "the \(Int(Self.maxRecordingSeconds / 3600))-hour limit was reached"); return
		}
		let silenceLimit = Double(max(1, settings.autoStopSilenceMinutes)) * 60
		if let last = lastSound, now.timeIntervalSince(last) >= silenceLimit {
			autoStop(reason: "the call was silent for \(settings.autoStopSilenceMinutes) min"); return
		}
	}

	/// Stop the current recording automatically and let the user know why. Honors
	/// the setting (sleep/lock can fire after it's toggled off) and no-ops if we're
	/// no longer recording.
	private func autoStop(reason: String) {
		guard isRecording, settings.autoStopForgotten else { return }
		status = "Auto-stopped recording (\(reason)). Processing…"
		Task { @MainActor in NotificationManager.shared.notifyAutoStopped(reason: reason) }
		stop()
	}

	private func startElapsedTimer() {
		procStart = Date()
		progressAnchor = nil
		elapsed = "0s"
		remaining = ""
		procTimer?.invalidate()
		procTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			guard let self = self, let start = self.procStart else { return }
			let e = Date().timeIntervalSince(start)
			self.elapsed = Self.shortTime(e)
			self.remaining = self.estimateRemaining(elapsed: e)
		}
	}

	/// "Time left" string. Once real progress is flowing we extrapolate from the
	/// observed rate (works on the very first run, no learned estimate needed);
	/// before that we fall back to the up-front per-model estimate.
	private func estimateRemaining(elapsed e: TimeInterval) -> String {
		let p = progress
		// Anchor on the first meaningful progress sample (past the initial jump to
		// 5%), then extrapolate the remaining work from the rate since the anchor.
		if p > 0.07, p < 0.99 {
			if let a = progressAnchor, p > a.p + 0.01, e > a.t {
				let rate = (p - a.p) / (e - a.t)        // progress per second
				let rem = (1 - p) / max(rate, 0.0001)
				return rem > 2 ? "~\(Self.shortTime(rem)) left" : "finishing…"
			}
			if progressAnchor == nil { progressAnchor = (e, p) }
		}
		// Fallback: up-front estimate (seeded by model size, calibrated over runs).
		if estimatedTotal > 0 {
			let rem = estimatedTotal - e
			return rem > 2 ? "~\(Self.shortTime(rem)) left" : "finishing…"
		}
		return ""
	}

	// MARK: processing-time estimate (learned per transcription model)

	/// Set the up-front estimate from the audio length and the model's learned
	/// (or seeded) end-to-end processing rate.
	private func beginEstimate(audioSeconds: Double, model: String) {
		let est = audioSeconds * Self.processingRate(forModel: model)
		DispatchQueue.main.async { self.estimatedTotal = est }
	}


	private func stopElapsedTimer() {
		procTimer?.invalidate()
		procTimer = nil
		remaining = ""
		estimatedTotal = 0
	}

	private static func timestamp() -> String {
		let f = DateFormatter()
		f.dateFormat = "yyyy-MM-dd HH-mm-ss"
		return f.string(from: Date())
	}
}