// The transcription stage as it actually runs: real WAV on disk → real afconvert
// → real child process with the real argument list → whisper JSON parsed back
// into segments → merged transcript.

import XCTest
@testable import MeetingEngineCore

final class TranscriptionFlowTests: XCTestCase {

	private var dir: URL!
	private var systemWav: String { dir.appendingPathComponent("M.system.wav").path }
	private var micWav: String { dir.appendingPathComponent("M.mic.wav").path }
	private var model: String { dir.appendingPathComponent("ggml-stub.bin").path }

	override func setUpWithError() throws {
		dir = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("transcribe-flow-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try TestAudio.writeWAV(at: systemWav)
		try TestAudio.writeWAV(at: micWav)
		// The stub CLI never opens the model; it only has to exist.
		FileManager.default.createFile(atPath: model, contents: Data("stub".utf8))
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: dir)
	}

	private func transcribe(_ binary: String, track: String, speaker: String) throws -> [TranscriptSegment] {
		try Transcriber.transcribe(
			wavPath: track, model: model, whisperBin: binary,
			language: "en", speaker: speaker, log: { _ in })
	}

	func testATrackIsConvertedRunThroughWhisperAndParsedBack() throws {
		let whisper = try StubWhisper.emitting(in: dir,
			system: [(0, 2, "Hello from the other side."), (3, 4, "Second line.")],
			mic: [])

		let segments = try transcribe(whisper, track: systemWav, speaker: "Them")

		XCTAssertEqual(segments.count, 2)
		XCTAssertEqual(segments[0].text, "Hello from the other side.")
		XCTAssertEqual(segments[0].start, 0, accuracy: 0.001)
		XCTAssertEqual(segments[0].end, 2, accuracy: 0.001)
		XCTAssertEqual(segments[0].speaker, "Them")
	}

	func testBothTracksMergeIntoOneLabeledTranscript() throws {
		let whisper = try StubWhisper.emitting(in: dir,
			system: [(0, 2, "Remote speaking first.")],
			mic: [(3, 5, "Local answering after.")])

		let them = try transcribe(whisper, track: systemWav, speaker: "Them")
		let you = try transcribe(whisper, track: micWav, speaker: "You")
		let transcript = Transcriber.diarizedMarkdown(
			Transcriber.removeCrossTalkEchoes(them + you))

		XCTAssertEqual(transcript, """
			[0:00] **Them:** Remote speaking first.

			[0:03] **You:** Local answering after.
			""")
	}

	func testTheSameRoomHeardOnBothTracksIsNotDoubled() throws {
		let line = "let us go over the quarterly numbers before we finish"
		let whisper = try StubWhisper.emitting(in: dir,
			system: [(0, 4, line)], mic: [(0, 4, line)])

		let them = try transcribe(whisper, track: systemWav, speaker: "Them")
		let you = try transcribe(whisper, track: micWav, speaker: "You")
		let transcript = Transcriber.diarizedMarkdown(
			Transcriber.removeCrossTalkEchoes(them + you))

		XCTAssertEqual(transcript.components(separatedBy: "quarterly numbers").count - 1, 1, transcript)
	}

	func testASilentTrackYieldsNoSegmentsRatherThanAnError() throws {
		let segments = try transcribe(try StubWhisper.silent(in: dir), track: systemWav, speaker: "Them")
		XCTAssertTrue(segments.isEmpty)
	}

	func testAMissingTrackIsSkippedNotFatal() throws {
		let whisper = try StubWhisper.emitting(in: dir, system: [(0, 1, "x")], mic: [])
		let segments = try transcribe(whisper, track: dir.appendingPathComponent("gone.wav").path, speaker: "You")
		XCTAssertTrue(segments.isEmpty)
	}

	func testAMissingModelIsReportedBeforeAnythingRuns() throws {
		XCTAssertThrowsError(try Transcriber.transcribe(
			wavPath: systemWav, model: dir.appendingPathComponent("nope.bin").path,
			whisperBin: try StubWhisper.silent(in: dir), speaker: "You", log: { _ in })
		) { error in
			XCTAssertTrue("\(error)".contains("model not found"), "\(error)")
		}
	}

	func testAFailingBinarySurfacesItsStderrAndLeavesTheRecordingAlone() throws {
		let whisper = try StubWhisper.failing(in: dir, message: "whisper: model load failed")

		XCTAssertThrowsError(try transcribe(whisper, track: systemWav, speaker: "Them")) { error in
			XCTAssertTrue("\(error)".contains("model load failed"), "\(error)")
		}
		XCTAssertTrue(FileManager.default.fileExists(atPath: systemWav))
	}

	func testCancellingStopsAHangingRunPromptly() throws {
		let whisper = try StubWhisper.hanging(in: dir)
		let token = CancelToken()
		let started = Date()

		DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { token.cancel() }
		XCTAssertThrowsError(try Transcriber.transcribe(
			wavPath: systemWav, model: model, whisperBin: whisper,
			speaker: "Them", cancel: token, log: { _ in })
		) { error in
			XCTAssertTrue(error is CancelledError, "\(error)")
		}
		XCTAssertLessThan(Date().timeIntervalSince(started), 10, "cancel should not wait for the child to finish")
	}

	func testTemporaryConversionFilesAreCleanedUp() throws {
		let whisper = try StubWhisper.emitting(in: dir, system: [(0, 1, "x")], mic: [])
		_ = try transcribe(whisper, track: systemWav, speaker: "Them")

		let leftovers = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
			.filter { $0.hasPrefix("me-tx-") }
		XCTAssertEqual(leftovers, [], "conversion scratch files must not accumulate")
	}
}
