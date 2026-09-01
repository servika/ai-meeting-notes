// Whole-app flows over a temp vault: re-generate a meeting from its saved audio
// (transcribe → summarize → write the note), trim then re-generate, and stop a
// run in flight. The only substitutes are the whisper CLI and the summary engine;
// the controller, settings, note writing and vault bookkeeping are the shipping
// code.

import XCTest
@testable import MeetingEngineApp
@testable import MeetingEngineCore

final class MeetingFlowTests: XCTestCase {

	private var vault: URL!
	private var meetings: URL!
	private var settings: AppSettings!
	private var store: MeetingStore!
	private var controller: RecordingController!
	private var server: StubSummaryServer?

	private let title = "Meeting 2026-06-24 10-00-00"
	private var audioBase: String { "recordings/\(title)" }
	private var systemWav: String { meetings.appendingPathComponent("\(audioBase).system.wav").path }
	private var micWav: String { meetings.appendingPathComponent("\(audioBase).mic.wav").path }
	private var systemM4A: String { meetings.appendingPathComponent("\(audioBase).system.m4a").path }
	private var micM4A: String { meetings.appendingPathComponent("\(audioBase).mic.m4a").path }
	private var notePath: URL { meetings.appendingPathComponent("\(title).md") }

	override func setUpWithError() throws {
		vault = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("meeting-flow-\(UUID().uuidString)")
		meetings = vault.appendingPathComponent("Meetings")
		try FileManager.default.createDirectory(
			at: meetings.appendingPathComponent("recordings"), withIntermediateDirectories: true)

		clearSettingsDefaults()
		settings = AppSettings()
		settings.vaultPath = vault.path
		settings.meetingsFolder = "Meetings"
		settings.language = "en"
		settings.transcribeMeetings = true
		settings.summarizeMeetings = true
		settings.summaryEngine = "ollama"
		settings.ollamaModel = "stub-model"
		settings.audioRetention = "original"
		// The stub CLI never reads the model; it only has to exist.
		let model = vault.appendingPathComponent("ggml-stub.bin")
		FileManager.default.createFile(atPath: model.path, contents: Data("stub".utf8))
		settings.whisperModelPath = model.path

		store = MeetingStore()
		controller = RecordingController(settings: settings, store: store)

		try TestAudio.writeWAV(at: systemWav, seconds: 1)
		try TestAudio.writeWAV(at: micWav, seconds: 1)
		try writeNote(duration: 60)
	}

	override func tearDownWithError() throws {
		server?.stop()
		unsetenv("MEETING_ENGINE_WHISPER_BIN")
		clearSettingsDefaults()
		try? FileManager.default.removeItem(at: vault)
	}

	// MARK: helpers

	private func writeNote(duration: Int, transcript: String = "_Recording in progress…_") throws {
		let note = RecordingController.buildNote(
			title: title, date: "2026-06-24 10-00-00", audioBase: audioBase,
			durationSeconds: duration, speakerCount: 0, summary: "", transcript: transcript)
		try note.write(to: notePath, atomically: true, encoding: .utf8)
	}

	private func useWhisper(_ path: String) {
		setenv("MEETING_ENGINE_WHISPER_BIN", path, 1)
	}

	private func useSummaryEngine(_ stub: StubSummaryServer) {
		server = stub
		settings.ollamaURL = stub.url
	}

	private func meeting() -> Meeting {
		store.reload(folder: meetings)
		return store.meetings.first { $0.title == title }!
	}

	/// Drive a controller job to completion, pumping the main run loop as the app does.
	private func runToCompletion(timeout: TimeInterval = 60, _ start: () -> Void) {
		start()
		let done = expectation(description: "controller finished")
		let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
			guard let self, !self.controller.busy else { return }
			t.invalidate()
			done.fulfill()
		}
		RunLoop.main.add(timer, forMode: .common)
		wait(for: [done], timeout: timeout)
	}

	private func noteContent() throws -> String {
		try String(contentsOf: notePath, encoding: .utf8)
	}

	// MARK: flows

	func testRegeneratingWritesATranscriptAndSummaryIntoTheNote() throws {
		useWhisper(try StubWhisper.emitting(in: vault,
			system: [(0, 2, "Remote side speaking here.")],
			mic: [(3, 5, "Local side answering now.")]))
		useSummaryEngine(try StubSummaryServer.returning("## Short summary\nWe agreed to ship.", in: vault))

		let m = meeting()
		runToCompletion { controller.regenerate(m) }

		let note = try noteContent()
		XCTAssertTrue(note.contains("## Short summary\nWe agreed to ship."), note)
		XCTAssertTrue(note.contains("[0:00] **Them:** Remote side speaking here."), note)
		XCTAssertTrue(note.contains("[0:03] **You:** Local side answering now."), note)
		XCTAssertEqual(RecordingController.frontmatterValue("duration", in: note), "60")
		XCTAssertEqual(RecordingController.frontmatterValue("audio", in: note), audioBase)
		XCTAssertTrue(controller.status.hasPrefix("✅"), controller.status)
	}

	func testRenamingWhileProcessingUpdatesTheRenamedNoteInsteadOfDuplicatingIt() throws {
		useWhisper(try StubWhisper.emitting(in: vault,
			system: [(0, 2, "Transcribed after the rename.")], mic: [], delay: 1))
		useSummaryEngine(try StubSummaryServer.returning("## Short summary\nDone.", in: vault))

		let m = meeting()
		runToCompletion {
			controller.regenerate(m)
			// The user renames the note while transcription is still running - the app
			// keeps the controller pointed at the renamed note (see ContentView).
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
				guard let renamed = self.store.rename(m, to: "Budget review") else {
					return XCTFail("rename failed")
				}
				self.controller.activeID = renamed.id
			}
		}

		let notes = try FileManager.default.contentsOfDirectory(atPath: meetings.path)
			.filter { $0.hasSuffix(".md") }
		XCTAssertEqual(notes, ["Budget review.md"], "the run must not resurrect the old filename")
		let note = try String(
			contentsOf: meetings.appendingPathComponent("Budget review.md"), encoding: .utf8)
		XCTAssertTrue(note.contains("Transcribed after the rename."), note)
		XCTAssertTrue(note.contains("# Budget review"), note)
		XCTAssertEqual(RecordingController.frontmatterValue("audio", in: note), audioBase)
	}

	func testTheTranscriptIsWhatGetsSentToTheSummaryEngine() throws {
		useWhisper(try StubWhisper.emitting(in: vault,
			system: [(0, 2, "Quarterly numbers look fine.")], mic: []))
		let stub = try StubSummaryServer.returning("## Short summary\nDone.", in: vault)
		useSummaryEngine(stub)

		let m = meeting()
		runToCompletion { controller.regenerate(m) }

		XCTAssertEqual(stub.requests.count, 1)
		XCTAssertTrue(stub.requests[0].contains("Quarterly numbers look fine."), stub.requests[0])
	}

	func testAFailedSummaryKeepsTheTranscriptAndSaysSo() throws {
		useWhisper(try StubWhisper.emitting(in: vault,
			system: [(0, 2, "This must not be lost.")], mic: []))
		useSummaryEngine(try StubSummaryServer.failing("model not found", in: vault))

		let m = meeting()
		runToCompletion { controller.regenerate(m) }

		let note = try noteContent()
		XCTAssertTrue(note.contains("This must not be lost."), note)
		XCTAssertTrue(controller.status.contains("⚠️"), controller.status)
	}

	func testAFailedSummaryDoesNotWipeTheSummaryAlreadyInTheNote() throws {
		try writeNote(duration: 60, transcript: "old transcript")
		var note = try noteContent()
		note = note.replacingOccurrences(
			of: "# \(title)\n\n", with: "# \(title)\n\n## Short summary\nPrevious summary.\n\n")
		try note.write(to: notePath, atomically: true, encoding: .utf8)

		useWhisper(try StubWhisper.emitting(in: vault, system: [(0, 2, "Fresh transcript.")], mic: []))
		useSummaryEngine(try StubSummaryServer.erroring(500, in: vault))

		let m = meeting()
		runToCompletion { controller.regenerate(m) }

		let updated = try noteContent()
		XCTAssertTrue(updated.contains("## Short summary\nPrevious summary."), updated)
		XCTAssertTrue(updated.contains("Fresh transcript."), updated)
	}

	func testASilentRecordingProducesANoteWithoutCallingTheEngine() throws {
		useWhisper(try StubWhisper.silent(in: vault))
		let stub = try StubSummaryServer.returning("unused", in: vault)
		useSummaryEngine(stub)

		let m = meeting()
		runToCompletion { controller.regenerate(m) }

		XCTAssertTrue(try noteContent().contains("_(no speech detected)_"))
		XCTAssertTrue(stub.requests.isEmpty)
	}

	func testAFailingWhisperLeavesTheNoteAndAudioIntact() throws {
		useWhisper(try StubWhisper.failing(in: vault))
		useSummaryEngine(try StubSummaryServer.returning("unused", in: vault))
		let before = try noteContent()

		let m = meeting()
		runToCompletion { controller.regenerate(m) }

		XCTAssertEqual(try noteContent(), before, "a failed run must not rewrite the note")
		XCTAssertTrue(FileManager.default.fileExists(atPath: systemWav))
		XCTAssertTrue(controller.status.hasPrefix("Failed:"), controller.status)
	}

	func testStoppingARunLeavesTheMeetingRegeneratable() throws {
		useWhisper(try StubWhisper.hanging(in: vault))
		useSummaryEngine(try StubSummaryServer.returning("unused", in: vault))
		let before = try noteContent()

		runToCompletion {
			let m = meeting()
			controller.regenerate(m)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.controller.cancelProcessing() }
		}

		XCTAssertEqual(try noteContent(), before)
		XCTAssertTrue(FileManager.default.fileExists(atPath: systemWav))
		XCTAssertTrue(controller.status.contains("Stopped"), controller.status)
	}

	func testRegeneratingWithoutSavedAudioReportsItInsteadOfWritingAnEmptyNote() throws {
		try FileManager.default.removeItem(atPath: systemWav)
		try FileManager.default.removeItem(atPath: micWav)
		useWhisper(try StubWhisper.silent(in: vault))
		let before = try noteContent()

		let m = meeting()
		runToCompletion { controller.regenerate(m) }

		XCTAssertEqual(try noteContent(), before)
		XCTAssertTrue(controller.status.contains("No saved audio"), controller.status)
	}

	// MARK: audio retention + trim

	func testCompressingAMeetingSwapsTheFilesAndTheNoteLinks() throws {
		useWhisper(try StubWhisper.emitting(in: vault, system: [(0, 2, "Something said.")], mic: []))
		useSummaryEngine(try StubSummaryServer.returning("## Short summary\nOk.", in: vault))
		let m = meeting()
		runToCompletion { controller.regenerate(m) }

		runToCompletion { controller.compressAudio(meeting()) }

		XCTAssertFalse(FileManager.default.fileExists(atPath: systemWav))
		XCTAssertTrue(FileManager.default.fileExists(atPath: systemM4A))
		let note = try noteContent()
		XCTAssertTrue(note.contains("![[\(title).system.m4a]]"), note)
		XCTAssertFalse(note.contains(".system.wav]]"), note)
	}

	func testRegeneratingACompressedMeetingKeepsItsAudio() throws {
		// The Windows 0.5.0 data-loss scenario, run against the macOS pipeline.
		useWhisper(try StubWhisper.emitting(in: vault, system: [(0, 2, "First pass.")], mic: []))
		useSummaryEngine(try StubSummaryServer.returning("## Short summary\nOk.", in: vault))
		runToCompletion { controller.regenerate(meeting()) }
		runToCompletion { controller.compressAudio(meeting()) }
		XCTAssertTrue(FileManager.default.fileExists(atPath: systemM4A))

		useWhisper(try StubWhisper.emitting(in: vault, system: [(0, 2, "Second pass.")], mic: []))
		runToCompletion { controller.regenerate(meeting()) }

		XCTAssertTrue(FileManager.default.fileExists(atPath: systemM4A),
			"re-generating a compressed meeting must not remove its audio")
		XCTAssertTrue(try noteContent().contains("Second pass."))
	}

	func testCompressingAgainIsHarmless() throws {
		useWhisper(try StubWhisper.emitting(in: vault, system: [(0, 2, "x")], mic: []))
		useSummaryEngine(try StubSummaryServer.returning("## Short summary\nOk.", in: vault))
		runToCompletion { controller.regenerate(meeting()) }
		runToCompletion { controller.compressAudio(meeting()) }
		let size = try FileManager.default.attributesOfItem(atPath: systemM4A)[.size] as? Int

		runToCompletion { controller.compressAudio(meeting()) }

		XCTAssertTrue(FileManager.default.fileExists(atPath: systemM4A))
		XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: systemM4A)[.size] as? Int, size)
	}

	func testTrimmingShortensTheAudioUpdatesTheDurationAndReTranscribes() throws {
		try TestAudio.writeWAV(at: systemWav, seconds: 4)
		try TestAudio.writeWAV(at: micWav, seconds: 4)
		try writeNote(duration: 4)
		useWhisper(try StubWhisper.emitting(in: vault, system: [(0, 1, "Kept part.")], mic: []))
		useSummaryEngine(try StubSummaryServer.returning("## Short summary\nTrimmed.", in: vault))

		let m = meeting()
		runToCompletion { controller.trimAudio(m, endSeconds: 2) }

		XCTAssertEqual(RecordingController.audioDurationSeconds(systemWav: systemWav, micWav: micWav), 2)
		let note = try noteContent()
		XCTAssertEqual(RecordingController.frontmatterValue("duration", in: note), "2")
		XCTAssertTrue(note.contains("Kept part."), note)
	}

	func testATrimShorterThanASecondIsRefusedRatherThanDestroyingTheRecording() throws {
		try TestAudio.writeWAV(at: systemWav, seconds: 4)
		try writeNote(duration: 4)

		controller.trimAudio(meeting(), endSeconds: 0.5)

		XCTAssertFalse(controller.busy)
		XCTAssertEqual(RecordingController.audioDurationSeconds(systemWav: systemWav, micWav: micWav), 4)
	}

	func testDeletingAMeetingRemovesItsNoteAndAudio() throws {
		store.reload(folder: meetings)
		store.delete(meeting())

		XCTAssertFalse(FileManager.default.fileExists(atPath: notePath.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: systemWav))
		XCTAssertFalse(FileManager.default.fileExists(atPath: micWav))
	}

	func testRenamingAMeetingKeepsItsAudioAttached() throws {
		store.reload(folder: meetings)
		let renamed = store.rename(meeting(), to: "Budget review")

		XCTAssertNotNil(renamed)
		let content = try String(contentsOf: renamed!.url, encoding: .utf8)
		XCTAssertEqual(RecordingController.frontmatterValue("audio", in: content), audioBase)
		XCTAssertTrue(content.contains("# Budget review"))
		XCTAssertTrue(FileManager.default.fileExists(atPath: systemWav))
	}
}
