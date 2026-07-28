// What happens to the recordings after transcription. These tests write real
// (short) WAVs and run the real afconvert/AVFoundation paths, because the whole
// point of the policy is which files exist on disk afterwards.

import AVFoundation
import XCTest
@testable import MeetingEngineApp

/// Write `seconds` of a quiet tone as a 16 kHz mono WAV. Returns the path.
func makeTestWAV(at path: String, seconds: Double = 0.5) throws {
	let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
	let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
	let frames = AVAudioFrameCount(seconds * format.sampleRate)
	let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
	buffer.frameLength = frames
	for i in 0..<Int(frames) {
		buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.25
	}
	try file.write(from: buffer)
}

final class AudioRetentionTests: XCTestCase {

	private var dir: URL!
	private var systemWav: String { dir.appendingPathComponent("M.system.wav").path }
	private var micWav: String { dir.appendingPathComponent("M.mic.wav").path }
	private var systemM4A: String { dir.appendingPathComponent("M.system.m4a").path }
	private var micM4A: String { dir.appendingPathComponent("M.mic.m4a").path }

	override func setUpWithError() throws {
		dir = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("retention-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try makeTestWAV(at: systemWav)
		try makeTestWAV(at: micWav)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: dir)
	}

	private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

	func testOriginalKeepsBothWAVs() {
		XCTAssertEqual(RecordingController.finalizeAudio(systemWav: systemWav, micWav: micWav, policy: "original"), "wav")
		XCTAssertTrue(exists(systemWav))
		XCTAssertTrue(exists(micWav))
	}

	func testUnknownPolicyIsTreatedAsOriginal() {
		XCTAssertEqual(RecordingController.finalizeAudio(systemWav: systemWav, micWav: micWav, policy: "whatever"), "wav")
		XCTAssertTrue(exists(systemWav))
	}

	func testDeleteRemovesBothTracksAndReportsNoExtension() {
		XCTAssertNil(RecordingController.finalizeAudio(systemWav: systemWav, micWav: micWav, policy: "delete"))
		XCTAssertFalse(exists(systemWav))
		XCTAssertFalse(exists(micWav))
	}

	func testCompressedReplacesTheWAVsWithM4As() {
		XCTAssertEqual(RecordingController.finalizeAudio(systemWav: systemWav, micWav: micWav, policy: "compressed"), "m4a")
		XCTAssertFalse(exists(systemWav))
		XCTAssertFalse(exists(micWav))
		XCTAssertTrue(exists(systemM4A))
		XCTAssertTrue(exists(micM4A))
		XCTAssertGreaterThan((try? FileManager.default.attributesOfItem(atPath: systemM4A)[.size] as? Int) ?? 0, 0)
	}

	func testCompressedIsANoOpWhenTheTracksAreAlreadyM4A() throws {
		// Re-running the pipeline on a compressed meeting must not feed an .m4a back
		// into the encoder: that would destroy the only copy of the recording.
		XCTAssertEqual(RecordingController.finalizeAudio(systemWav: systemWav, micWav: micWav, policy: "compressed"), "m4a")
		let sizeBefore = try FileManager.default.attributesOfItem(atPath: systemM4A)[.size] as? Int

		let again = RecordingController.finalizeAudio(systemWav: systemM4A, micWav: micM4A, policy: "compressed")
		XCTAssertEqual(again, "m4a")
		XCTAssertTrue(exists(systemM4A), "the compressed system track must survive a second pass")
		XCTAssertTrue(exists(micM4A), "the compressed mic track must survive a second pass")
		XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: systemM4A)[.size] as? Int, sizeBefore)
	}

	func testCompressToM4ARefusesToWriteOntoItsOwnSource() throws {
		XCTAssertFalse(RecordingController.compressToM4A(wav: systemWav, m4a: systemWav))
		XCTAssertTrue(exists(systemWav))
	}

	func testCompressToM4AFailsOnAFileThatIsNotAudio() {
		let junk = dir.appendingPathComponent("junk.wav").path
		FileManager.default.createFile(atPath: junk, contents: Data("not audio".utf8))
		XCTAssertFalse(RecordingController.compressToM4A(wav: junk, m4a: dir.appendingPathComponent("junk.m4a").path))
	}

	func testCompressedTolueratesAMissingTrack() throws {
		try FileManager.default.removeItem(atPath: micWav)
		XCTAssertEqual(RecordingController.finalizeAudio(systemWav: systemWav, micWav: micWav, policy: "compressed"), "m4a")
		XCTAssertTrue(exists(systemM4A))
		XCTAssertFalse(exists(micM4A))
	}

	func testDeleteToleratesAlreadyMissingTracks() {
		XCTAssertNil(RecordingController.finalizeAudio(
			systemWav: dir.appendingPathComponent("gone.system.wav").path,
			micWav: dir.appendingPathComponent("gone.mic.wav").path,
			policy: "delete"))
	}

	func testStatusSuffixMatchesThePolicy() {
		XCTAssertEqual(RecordingController.audioStatusSuffix("compressed"), " · audio compressed")
		XCTAssertEqual(RecordingController.audioStatusSuffix("delete"), " · audio removed")
		XCTAssertEqual(RecordingController.audioStatusSuffix("original"), "")
	}

	func testDurationComesFromWhicheverTrackExists() throws {
		try FileManager.default.removeItem(atPath: systemWav)
		try makeTestWAV(at: micWav, seconds: 3)
		XCTAssertEqual(RecordingController.audioDurationSeconds(systemWav: systemWav, micWav: micWav), 3)
	}

	func testDurationIsZeroWhenNoTrackIsReadable() {
		XCTAssertEqual(RecordingController.audioDurationSeconds(
			systemWav: dir.appendingPathComponent("nope.wav").path,
			micWav: dir.appendingPathComponent("nope2.wav").path), 0)
	}
}