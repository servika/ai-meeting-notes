// Trimming a recording rewrites the user's only copy of the audio, so these
// tests exercise the real files: the shortened track must be shorter, a failed
// trim must leave the original untouched, and the note's duration must follow.

import AVFoundation
import XCTest
@testable import MeetingEngineApp

final class TrimTests: XCTestCase {

	private var dir: URL!

	override func setUpWithError() throws {
		dir = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("trim-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: dir)
	}

	private func duration(of path: String) throws -> Double {
		let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
		return Double(f.length) / f.processingFormat.sampleRate
	}

	func testTrimShortensAWAVToTheChosenEnd() throws {
		let path = dir.appendingPathComponent("track.wav").path
		try makeTestWAV(at: path, seconds: 4)

		XCTAssertTrue(RecordingController.trimTrack(path: path, endSeconds: 1))
		XCTAssertEqual(try duration(of: path), 1, accuracy: 0.05)
	}

	func testACutPastTheEndIsASuccessfulNoOp() throws {
		let path = dir.appendingPathComponent("track.wav").path
		try makeTestWAV(at: path, seconds: 2)

		XCTAssertTrue(RecordingController.trimTrack(path: path, endSeconds: 60))
		XCTAssertEqual(try duration(of: path), 2, accuracy: 0.05)
	}

	func testAZeroLengthCutIsRejectedAndLeavesTheTrackAlone() throws {
		let path = dir.appendingPathComponent("track.wav").path
		try makeTestWAV(at: path, seconds: 2)

		XCTAssertFalse(RecordingController.trimTrack(path: path, endSeconds: 0))
		XCTAssertEqual(try duration(of: path), 2, accuracy: 0.05)
	}

	func testTrimmingAMissingOrUnreadableTrackFailsWithoutCreatingFiles() {
		let missing = dir.appendingPathComponent("nope.wav").path
		XCTAssertFalse(RecordingController.trimTrack(path: missing, endSeconds: 1))
		XCTAssertFalse(FileManager.default.fileExists(atPath: missing + ".trim.tmp.wav"))

		let junk = dir.appendingPathComponent("junk.wav").path
		FileManager.default.createFile(atPath: junk, contents: Data("not audio".utf8))
		XCTAssertFalse(RecordingController.trimTrack(path: junk, endSeconds: 1))
		XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: junk)), Data("not audio".utf8))
	}

	func testTrimShortensACompressedTrackToo() throws {
		let wav = dir.appendingPathComponent("track.wav").path
		let m4a = dir.appendingPathComponent("track.m4a").path
		try makeTestWAV(at: wav, seconds: 4)
		XCTAssertTrue(RecordingController.compressToM4A(wav: wav, m4a: m4a))

		XCTAssertTrue(RecordingController.trimTrack(path: m4a, endSeconds: 1))
		XCTAssertLessThan(try duration(of: m4a), 2)
	}

	func testTrimLeavesNoTemporaryFilesBehind() throws {
		let path = dir.appendingPathComponent("track.wav").path
		try makeTestWAV(at: path, seconds: 3)
		XCTAssertTrue(RecordingController.trimTrack(path: path, endSeconds: 1))

		let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
			.filter { $0.contains("trim.tmp") }
		XCTAssertEqual(leftovers, [])
	}

	func testFrontmatterDurationIsRewrittenAfterATrim() throws {
		let url = dir.appendingPathComponent("note.md")
		let note = RecordingController.buildNote(
			title: "T", date: "D", audioBase: "recordings/T",
			durationSeconds: 3600, speakerCount: 0, summary: "", transcript: "x")
		try note.write(to: url, atomically: true, encoding: .utf8)

		RecordingController.updateFrontmatterDuration(noteURL: url, seconds: 95)
		let updated = try String(contentsOf: url, encoding: .utf8)
		XCTAssertEqual(RecordingController.frontmatterValue("duration", in: updated), "95")
		// Only that line changed.
		XCTAssertEqual(RecordingController.frontmatterValue("audio", in: updated), "recordings/T")
		XCTAssertTrue(updated.contains("## Transcript"))
	}

	func testANoteWithoutADurationLineIsLeftUnchanged() throws {
		let url = dir.appendingPathComponent("note.md")
		let note = RecordingController.buildNote(
			title: "T", date: "D", audioBase: "recordings/T",
			durationSeconds: 0, speakerCount: 0, summary: "", transcript: "x")
		try note.write(to: url, atomically: true, encoding: .utf8)

		RecordingController.updateFrontmatterDuration(noteURL: url, seconds: 95)
		XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), note)
	}
}