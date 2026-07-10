// Transcription + "You vs. Them" diarization.
//
// Each captured track is transcribed separately with whisper.cpp, then the two
// segment lists are merged by timestamp into one speaker-labeled transcript.
// Because mic and system audio are already separate tracks, "who spoke" comes
// for free - no diarization model needed.

import Foundation

public struct TranscriptSegment {
	public let start: Double // seconds
	public let end: Double
	public let text: String
	public let speaker: String
}

public enum Transcriber {

	/// Transcribe one WAV (any format) and tag every segment with `speaker`.
	/// Converts to whisper's required 16 kHz mono 16-bit via `afconvert`, then
	/// runs `whisper-cli -oj` and parses the JSON segments.
	public static func transcribe(
		wavPath: String,
		model: String,
		whisperBin: String = "whisper-cli",
		language: String = "auto",
		prompt: String = "",
		speaker: String,
		progress: ((Double) -> Void)? = nil,
		cancel: CancelToken? = nil,
		log: (String) -> Void
	) throws -> [TranscriptSegment] {
		if cancel?.isCancelled == true { throw CancelledError() }
		let modelPath = (model as NSString).expandingTildeInPath
		guard FileManager.default.fileExists(atPath: modelPath) else {
			throw EngineError(message: "whisper model not found: \(modelPath)")
		}
		let src = (wavPath as NSString).expandingTildeInPath
		guard FileManager.default.fileExists(atPath: src) else {
			log("\(speaker): audio track not found, skipping")
			return []
		}

		let base = NSTemporaryDirectory() + "me-tx-\(UUID().uuidString)"
		let wav16 = base + ".16k.wav"
		defer { try? FileManager.default.removeItem(atPath: wav16) }

		log("converting \((src as NSString).lastPathComponent) -> 16 kHz mono")
		try runProcess("/usr/bin/afconvert",
			["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src, wav16])

		log("transcribing \(speaker) track…")
		var args = ["-m", modelPath, "-f", wav16, "-l", language, "-oj", "-pp", "-of", base]
		// Suppress non-speech tokens, and use VAD when the bundled Silero model is
		// present - together these avoid hallucinations on silence (e.g. repeated
		// "Дякую за перегляд!") and improve accuracy by skipping non-speech.
		args += ["--suppress-nst"]
		// Don't condition each window on previously decoded text (-mc 0). With the
		// default unlimited context, one repeated sentence feeds back into the
		// decoder and locks long recordings into an hour-long repetition loop.
		args += ["-mc", "0"]
		if let vad = bundledVADModel() {
			args += ["--vad", "--vad-model", vad]
		}
		let hint = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		if !hint.isEmpty {
			// Bias spelling/vocabulary across the whole recording, not just the start.
			args += ["--prompt", hint, "--carry-initial-prompt"]
		}
		try runWhisper(resolveBinary(whisperBin), args, cancel: cancel, progress: progress)

		let jsonPath = base + ".json"
		defer { try? FileManager.default.removeItem(atPath: jsonPath) }
		// A silent/empty track produces no JSON - treat that as zero segments
		// rather than failing the whole transcription.
		guard FileManager.default.fileExists(atPath: jsonPath) else {
			log("\(speaker): no speech detected")
			return []
		}
		let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
		guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			let rawSegs = root["transcription"] as? [[String: Any]]
		else { throw EngineError(message: "could not parse whisper JSON output") }

		var segments: [TranscriptSegment] = []
		for seg in rawSegs {
			let text = (seg["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
			if text.isEmpty { continue }
			let offsets = seg["offsets"] as? [String: Any]
			let from = numberMS(offsets?["from"])
			let to = numberMS(offsets?["to"])
			segments.append(TranscriptSegment(start: from / 1000, end: to / 1000, text: text, speaker: speaker))
		}
		return segments
	}

	/// Remove cross-track echo before merging. In an in-person or speakerphone
	/// meeting the mic ("You") and the system-loopback ("Them") tracks pick up the
	/// same room, so every utterance is transcribed on *both* tracks and the merged
	/// transcript comes out doubled and mislabeled (the same words alternating
	/// You/Them with overlapping timestamps).
	///
	/// This drops a segment only when its words are largely already covered by the
	/// segments we're *keeping* from the other speaker at the same time. Segments
	/// are considered richest-first, so each echo cluster's most complete copy is
	/// always kept and the thinner duplicates fall away against it - a duplicate is
	/// never dropped unless a surviving segment carries its words, so no content is
	/// lost. Genuine remote meetings are untouched: dedup needs both high word
	/// overlap *and* time overlap, which separate-audio remote speakers don't make.
	public static func removeCrossTalkEchoes(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
		// Nothing to cross-compare unless two speakers are present.
		guard Set(segments.map { $0.speaker }).count >= 2 else { return segments }

		// Echo/bleed lands near-simultaneously, but whisper segments the two tracks
		// differently, so allow a few seconds of slack when matching in time.
		let window = 6.0
		// A segment must be mostly covered by the other track to count as an echo.
		let containmentThreshold = 0.75
		// Skip tiny segments ("yeah", "okay") - too easy to match by accident and
		// not worth the risk of dropping a real short reply.
		let minTokens = 4

		let tokens = segments.map { normalizedTokens($0.text) }
		// Position by start time so each segment only scans nearby ones, not all N.
		let byStart = segments.indices.sorted { segments[$0].start < segments[$1].start }
		var pos = [Int](repeating: 0, count: segments.count)
		for (p, i) in byStart.enumerated() { pos[i] = p }
		// Decide keep/drop richest-first (more tokens, then earlier, then speaker);
		// the fullest copy of any duplicated utterance is therefore decided first.
		let byRichness = segments.indices.sorted { a, b in
			if tokens[a].count != tokens[b].count { return tokens[a].count > tokens[b].count }
			if segments[a].start != segments[b].start { return segments[a].start < segments[b].start }
			return segments[a].speaker < segments[b].speaker
		}

		var kept = Set<Int>()
		var dropped = Set<Int>()
		for i in byRichness {
			if tokens[i].count < minTokens { kept.insert(i); continue }
			let si = segments[i]

			// Pool tokens from already-KEPT opposite-speaker segments overlapping i.
			var pool: [String: Int] = [:]
			for dir in [-1, 1] {
				var p = pos[i] + dir
				while p >= 0 && p < byStart.count {
					let j = byStart[p]
					let sj = segments[j]
					// Sorted by start: once a forward neighbor starts past our window
					// (or a backward neighbor ends before it), no closer ones remain.
					if dir == 1 && sj.start > si.end + window { break }
					if dir == -1 && sj.end < si.start - window { break }
					p += dir
					if sj.speaker == si.speaker || !kept.contains(j) { continue }
					if !(sj.start <= si.end + window && sj.end >= si.start - window) { continue }
					for t in tokens[j] { pool[t, default: 0] += 1 }
				}
			}

			// Multiset containment of i's words within the kept other-track tokens.
			var matched = 0
			for t in tokens[i] where (pool[t] ?? 0) > 0 { pool[t]! -= 1; matched += 1 }
			if Double(matched) / Double(tokens[i].count) >= containmentThreshold {
				dropped.insert(i)
			} else {
				kept.insert(i)
			}
		}
		return segments.enumerated().filter { !dropped.contains($0.offset) }.map { $0.element }
	}

	/// Lowercased alphanumeric word tokens (Unicode-aware, so Cyrillic counts).
	private static func normalizedTokens(_ text: String) -> [String] {
		text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
	}

	/// Merge segments from all speakers into a chronological, labeled transcript.
	/// Consecutive segments from the same speaker are collapsed into one line.
	public static func diarizedMarkdown(_ segments: [TranscriptSegment]) -> String {
		let sorted = segments.sorted { $0.start < $1.start }
		var blocks: [String] = []
		var speaker = ""
		var paragraph = ""
		var firstOfTurn = true
		var lastEnd = 0.0
		var paragraphStart = 0.0

		// Emit the current paragraph, prefixed with its start time. The first
		// paragraph of a turn also carries the speaker label; later paragraphs of
		// the same turn are unlabeled continuations (rendered under the speaker).
		func endParagraph() {
			let t = paragraph.trimmingCharacters(in: .whitespaces)
			if !t.isEmpty {
				let label = firstOfTurn ? "**\(speaker):** " : ""
				blocks.append("[\(timestamp(paragraphStart))] \(label)\(t)")
				firstOfTurn = false
			}
			paragraph = ""
		}

		for seg in sorted {
			let text = seg.text.trimmingCharacters(in: .whitespaces)
			if text.isEmpty { continue }
			if seg.speaker != speaker {
				endParagraph()
				speaker = seg.speaker
				firstOfTurn = true
			} else if !paragraph.isEmpty {
				// Break a long monologue into paragraphs: on a noticeable pause,
				// or once a paragraph is long and ends a sentence.
				let gap = seg.start - lastEnd
				let endsSentence = [".", "!", "?", "…"].contains { paragraph.hasSuffix($0) }
				if gap > 1.5 || (paragraph.count > 320 && endsSentence) {
					endParagraph()
				}
			}
			if paragraph.isEmpty { paragraphStart = seg.start }
			paragraph += (paragraph.isEmpty ? "" : " ") + text
			lastEnd = seg.end
		}
		endParagraph()
		return blocks.joined(separator: "\n\n")
	}

	/// Format a time offset (seconds from the start) as `m:ss`, or `h:mm:ss` past
	/// an hour.
	private static func timestamp(_ seconds: Double) -> String {
		let s = max(0, Int(seconds.rounded()))
		let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
		return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
	}

	/// Resolve a bare command to an absolute path. The app, launched via
	/// LaunchServices, has a minimal PATH that omits Homebrew, so `whisper-cli`
	/// wouldn't be found via `env`.
	///
	/// Resolution order: an explicit absolute path, then the copy bundled inside
	/// the app (`Contents/Resources/<name>`, self-contained - no Homebrew
	/// needed), then Homebrew/system locations for CLI and dev use.
	/// Path to the Silero VAD model bundled in the app, if present.
	private static func bundledVADModel() -> String? {
		guard let resources = Bundle.main.resourceURL else { return nil }
		let path = resources.appendingPathComponent("ggml-silero-v5.1.2.bin").path
		return FileManager.default.fileExists(atPath: path) ? path : nil
	}

	private static func resolveBinary(_ name: String) -> String {
		if name.hasPrefix("/") { return name }
		if let resources = Bundle.main.resourceURL {
			let bundled = resources.appendingPathComponent(name).path
			if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
		}
		for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
			let candidate = "\(dir)/\(name)"
			if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
		}
		return name // fall back to PATH via /usr/bin/env
	}

	private static func numberMS(_ value: Any?) -> Double {
		if let d = value as? Double { return d }
		if let i = value as? Int { return Double(i) }
		if let s = value as? String, let d = Double(s) { return d }
		return 0
	}
}

/// Run a process to completion, throwing with stderr on failure. A bare command
/// (no leading "/") is resolved via PATH using /usr/bin/env.
func runProcess(_ command: String, _ args: [String]) throws {
	let proc = Process()
	if command.hasPrefix("/") {
		proc.executableURL = URL(fileURLWithPath: command)
		proc.arguments = args
	} else {
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		proc.arguments = [command] + args
	}
	let errPipe = Pipe()
	proc.standardError = errPipe
	proc.standardOutput = Pipe()
	do {
		try proc.run()
	} catch {
		throw EngineError(message: "failed to launch \(command): \(error.localizedDescription)")
	}
	proc.waitUntilExit()
	if proc.terminationStatus != 0 {
		let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
		let errStr = String(data: errData, encoding: .utf8) ?? ""
		throw EngineError(message: "\(command) exited \(proc.terminationStatus): \(String(errStr.suffix(400)))")
	}
}

/// Run whisper-cli, streaming its stderr to report progress (0…1) parsed from
/// its `progress = NN%` lines. stdout is discarded so it can't fill the pipe.
func runWhisper(_ command: String, _ args: [String], cancel: CancelToken?, progress: ((Double) -> Void)?) throws {
	let proc = Process()
	if command.hasPrefix("/") {
		proc.executableURL = URL(fileURLWithPath: command)
		proc.arguments = args
	} else {
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		proc.arguments = [command] + args
	}
	proc.standardOutput = FileHandle.nullDevice
	let errPipe = Pipe()
	proc.standardError = errPipe
	let handle = errPipe.fileHandleForReading
	let lock = NSLock()
	var errBuffer = Data()
	handle.readabilityHandler = { h in
		let chunk = h.availableData
		if chunk.isEmpty { return }
		lock.lock(); errBuffer.append(chunk); lock.unlock()
		if let s = String(data: chunk, encoding: .utf8), let p = lastProgressFraction(in: s) {
			progress?(p)
		}
	}
	cancel?.register(proc)
	do {
		try proc.run()
	} catch {
		handle.readabilityHandler = nil
		cancel?.clearProcess()
		throw EngineError(message: "failed to launch \(command): \(error.localizedDescription)")
	}
	proc.waitUntilExit()
	handle.readabilityHandler = nil
	cancel?.clearProcess()
	if cancel?.isCancelled == true { throw CancelledError() }
	if proc.terminationStatus != 0 {
		lock.lock(); let s = String(data: errBuffer, encoding: .utf8) ?? ""; lock.unlock()
		throw EngineError(message: "\(command) exited \(proc.terminationStatus): \(String(s.suffix(400)))")
	}
}

/// Parse the last "progress = NN%" value from a chunk of whisper output.
private func lastProgressFraction(in s: String) -> Double? {
	var result: Double?
	for tail in s.components(separatedBy: "progress = ").dropFirst() {
		let digits = tail.prefix { $0.isNumber }
		if let n = Double(digits) { result = n / 100.0 }
	}
	return result
}