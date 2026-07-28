// Experimental multi-speaker diarization for the system (remote) track.
//
// The mic track is already cleanly "You", so only the system track - the remote
// participants - needs diarizing. We shell out to sherpa-onnx's offline speaker
// diarization (segmentation + speaker-embedding + clustering, all native ONNX),
// turn its output into time-stamped speaker spans, then relabel whisper's
// system-track segments by time overlap so each becomes "Them 1 / Them 2 / …".
//
// Self-contained when the binary + the two ONNX models are present (bundled in
// the app, or dropped in ~/models/sherpa); otherwise the feature reports itself
// unavailable and the caller keeps the single "Them" label.

import Foundation

public enum Diarizer {

	/// A contiguous span of one clustered speaker, in seconds from the start.
	/// `speaker` is sherpa's 0-based cluster index (speaker_00 -> 0).
	public struct SpeakerSpan {
		public let start: Double
		public let end: Double
		public let speaker: Int
	}

	/// The diarization CLI we shell out to (k2-fsa/sherpa-onnx prebuilt binary).
	static let binaryName = "sherpa-onnx-offline-speaker-diarization"

	// MARK: availability

	/// True when the binary and both ONNX models are present, so diarization can
	/// actually run. Drives the (otherwise disabled) settings toggle.
	public static func isAvailable() -> Bool {
		resolvedBinary() != nil && models() != nil
	}

	/// Why diarization can't run, for a settings hint - or nil when it's ready.
	public static func unavailableReason() -> String? {
		if resolvedBinary() == nil {
			return "speaker-recognition engine (\(binaryName)) not installed"
		}
		if models() == nil {
			return "speaker models not installed (run scripts/setup-diarization.sh)"
		}
		return nil
	}

	// MARK: diarization

	/// Diarize one WAV into speaker spans. Converts to sherpa's required 16 kHz
	/// mono via `afconvert` (same as whisper), runs the CLI, and parses its
	/// `start -- end speaker_NN` lines. Returns [] for a silent/empty track.
	///
	/// `speakerCount`: when ≥ 2, the number of remote speakers is fixed to that
	/// value (far more reliable than auto-estimation on real meeting audio);
	/// 0 (or 1) lets threshold-based clustering estimate the count.
	public static func diarize(
		wavPath: String,
		speakerCount: Int = 0,
		cancel: CancelToken? = nil,
		log: (String) -> Void
	) throws -> [SpeakerSpan] {
		if cancel?.isCancelled == true { throw CancelledError() }
		guard let bin = resolvedBinary(), let (seg, emb) = models() else {
			throw EngineError(message: "speaker recognition is not installed")
		}
		let src = (wavPath as NSString).expandingTildeInPath
		guard FileManager.default.fileExists(atPath: src) else {
			log("diarization: audio track not found, skipping")
			return []
		}

		let wav16 = NSTemporaryDirectory() + "me-diar-\(UUID().uuidString).16k.wav"
		defer { try? FileManager.default.removeItem(atPath: wav16) }
		log("converting \((src as NSString).lastPathComponent) -> 16 kHz mono for diarization")
		try runProcess("/usr/bin/afconvert",
			["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src, wav16])

		log("identifying speakers on the system track…")
		// A user-set speaker count is far more reliable than auto-estimation on
		// real (mixed, compressed) meeting audio; fall back to threshold-based
		// clustering when the count is left on "Auto".
		var args = [
			"--segmentation.pyannote-model=\(seg)",
			"--embedding.model=\(emb)",
			"--num-threads=2",
		]
		if speakerCount >= 2 {
			args.append("--clustering.num-clusters=\(speakerCount)")
		} else {
			args.append("--clustering.cluster-threshold=0.5")
		}
		args.append(wav16)
		let out = try runCapturingStdout(bin, args, cancel: cancel)
		return parseSpans(out)
	}

	/// Relabel "Them" segments by which clustered speaker span they overlap most.
	/// With 0 or 1 detected speakers, nothing is gained - every segment keeps the
	/// plain `prefix` ("Them"). With ≥2, segments become "Them 1", "Them 2", …,
	/// numbered by order of first appearance. Non-"Them" segments (i.e. "You")
	/// pass through untouched.
	public static func relabel(
		_ segments: [TranscriptSegment],
		using spans: [SpeakerSpan],
		prefix: String = "Them"
	) -> [TranscriptSegment] {
		let clusters = Set(spans.map(\.speaker))
		guard clusters.count >= 2 else { return segments }

		// Stable "Them N" labels in order of first appearance on the timeline.
		var label: [Int: String] = [:]
		var next = 1
		for span in spans.sorted(by: { $0.start < $1.start }) where label[span.speaker] == nil {
			label[span.speaker] = "\(prefix) \(next)"
			next += 1
		}

		return segments.map { seg in
			guard seg.speaker == prefix, let cluster = bestCluster(for: seg, in: spans) else {
				return seg
			}
			return TranscriptSegment(start: seg.start, end: seg.end, text: seg.text,
				speaker: label[cluster] ?? prefix)
		}
	}

	// MARK: parsing

	/// Pull `start -- end speaker_NN` spans out of the CLI's stdout. Tolerant of
	/// the `--` separator being present or absent and of extra log noise.
	static func parseSpans(_ stdout: String) -> [SpeakerSpan] {
		var spans: [SpeakerSpan] = []
		// Split on newlines as scalars: "\r\n" is a *single* Swift Character, so a
		// per-Character check would leave CRLF output as one merged line and parse
		// the whole thing as one bogus span.
		for line in stdout.components(separatedBy: .newlines) {
			// e.g. "0.033 -- 2.041 speaker_00" (the "--" separator is optional).
			let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
			let nums = tokens.compactMap(Double.init)
			guard let start = nums.first, let end = nums.last, end > start else { continue }
			guard let token = tokens.first(where: { $0.lowercased().contains("speaker") }),
				let idx = Int(token.filter(\.isNumber))
			else { continue }
			spans.append(SpeakerSpan(start: start, end: end, speaker: idx))
		}
		return spans
	}

	/// The cluster whose spans overlap `seg` the most; falls back to the nearest
	/// span by midpoint when there's no overlap at all.
	private static func bestCluster(for seg: TranscriptSegment, in spans: [SpeakerSpan]) -> Int? {
		var overlapBy: [Int: Double] = [:]
		for s in spans {
			let overlap = min(seg.end, s.end) - max(seg.start, s.start)
			if overlap > 0 { overlapBy[s.speaker, default: 0] += overlap }
		}
		if let best = overlapBy.max(by: { $0.value < $1.value }) { return best.key }
		let mid = (seg.start + seg.end) / 2
		return spans.min(by: { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) })?.speaker
	}

	// MARK: resolution

	/// Directories searched for the ONNX models: the app bundle, then ~/models
	/// (and ~/models/sherpa) so a model drop needs no app rebuild.
	private static func modelDirs() -> [String] {
		var dirs: [String] = []
		if let res = Bundle.main.resourceURL?.path { dirs.append(res) }
		dirs.append(("~/models/sherpa" as NSString).expandingTildeInPath)
		dirs.append(("~/models" as NSString).expandingTildeInPath)
		return dirs
	}

	/// Locate the (segmentation, embedding) ONNX models by name convention: the
	/// segmentation model's filename contains "segmentation"; the other `.onnx`
	/// is the speaker-embedding model. Returns nil unless both are found.
	private static func models() -> (segmentation: String, embedding: String)? {
		var onnx: [String] = []
		for dir in modelDirs() {
			let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
			for f in files where f.hasSuffix(".onnx") {
				onnx.append((dir as NSString).appendingPathComponent(f))
			}
		}
		let seg = onnx.first { ($0 as NSString).lastPathComponent.lowercased().contains("segmentation") }
		let emb = onnx.first { !($0 as NSString).lastPathComponent.lowercased().contains("segmentation") }
		guard let seg, let emb else { return nil }
		return (seg, emb)
	}

	/// Absolute path to the diarization binary (bundled or on PATH), or nil.
	private static func resolvedBinary() -> String? {
		if let res = Bundle.main.resourceURL {
			let bundled = res.appendingPathComponent(binaryName).path
			if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
		}
		for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
			let candidate = "\(dir)/\(binaryName)"
			if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
		}
		return nil
	}
}

/// Run a process to completion and return its stdout, throwing with stderr on
/// failure. Used by the diarizer, whose result comes on stdout (whereas
/// whisper's progress comes on stderr and its result is a file).
func runCapturingStdout(_ command: String, _ args: [String], cancel: CancelToken?) throws -> String {
	let proc = Process()
	if command.hasPrefix("/") {
		proc.executableURL = URL(fileURLWithPath: command)
		proc.arguments = args
	} else {
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		proc.arguments = [command] + args
	}
	let outPipe = Pipe(), errPipe = Pipe()
	proc.standardOutput = outPipe
	proc.standardError = errPipe
	// Drain pipes concurrently so neither fills and deadlocks the process.
	var outData = Data(), errData = Data()
	let lock = NSLock()
	outPipe.fileHandleForReading.readabilityHandler = { h in
		let c = h.availableData; if c.isEmpty { return }
		lock.lock(); outData.append(c); lock.unlock()
	}
	errPipe.fileHandleForReading.readabilityHandler = { h in
		let c = h.availableData; if c.isEmpty { return }
		lock.lock(); errData.append(c); lock.unlock()
	}
	cancel?.register(proc)
	do {
		try proc.run()
	} catch {
		outPipe.fileHandleForReading.readabilityHandler = nil
		errPipe.fileHandleForReading.readabilityHandler = nil
		cancel?.clearProcess()
		throw EngineError(message: "failed to launch \(command): \(error.localizedDescription)")
	}
	proc.waitUntilExit()
	outPipe.fileHandleForReading.readabilityHandler = nil
	errPipe.fileHandleForReading.readabilityHandler = nil
	cancel?.clearProcess()
	if cancel?.isCancelled == true { throw CancelledError() }
	if proc.terminationStatus != 0 {
		lock.lock(); let err = String(data: errData, encoding: .utf8) ?? ""; lock.unlock()
		throw EngineError(message: "\(command) exited \(proc.terminationStatus): \(String(err.suffix(400)))")
	}
	lock.lock(); let out = String(data: outData, encoding: .utf8) ?? ""; lock.unlock()
	return out
}