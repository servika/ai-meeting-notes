// Vault bookkeeping: listing/ordering meetings, renaming (file + heading), and
// deleting a note together with the audio only it references.

import XCTest
@testable import MeetingEngineApp

final class MeetingStoreTests: XCTestCase {

	private var dir: URL!

	override func setUpWithError() throws {
		dir = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("meeting-store-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: dir)
	}

	@discardableResult
	private func writeNote(_ title: String, date: String, audioBase: String? = nil,
		duration: Int = 60, speakers: Int = 0, body: String = "hello") -> URL {
		let note = RecordingController.buildNote(
			title: title, date: date, audioBase: audioBase ?? "recordings/\(title)",
			durationSeconds: duration, speakerCount: speakers, summary: "", transcript: body)
		let url = dir.appendingPathComponent("\(title).md")
		try? note.write(to: url, atomically: true, encoding: .utf8)
		return url
	}

	private func touchAudio(_ base: String, exts: [String] = ["system.wav", "mic.wav"]) {
		let recordings = dir.appendingPathComponent("recordings")
		try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
		for ext in exts {
			FileManager.default.createFile(
				atPath: dir.appendingPathComponent("\(base).\(ext)").path, contents: Data("x".utf8))
		}
	}

	// MARK: reload

	func testReloadReadsFrontmatterIntoMeetings() {
		writeNote("Meeting A", date: "2026-06-24 10-00-00", duration: 125, speakers: 3)
		let store = MeetingStore()
		store.reload(folder: dir)

		XCTAssertEqual(store.meetings.count, 1)
		let m = store.meetings[0]
		XCTAssertEqual(m.title, "Meeting A")
		XCTAssertEqual(m.durationSeconds, 125)
		XCTAssertEqual(m.speakerCount, 3)
		XCTAssertEqual(m.appVersion, appVersion)
	}

	func testReloadOrdersByFrontmatterDateNewestFirst() {
		// Written oldest-last so file mtime order disagrees with meeting order.
		writeNote("Older", date: "2026-06-20 09-00-00")
		writeNote("Newer", date: "2026-06-24 09-00-00")
		let store = MeetingStore()
		store.reload(folder: dir)
		XCTAssertEqual(store.meetings.map(\.title), ["Newer", "Older"])
	}

	func testReloadIgnoresNonMarkdownFilesAndNilFolder() {
		writeNote("Meeting A", date: "2026-06-24 10-00-00")
		FileManager.default.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data())
		let store = MeetingStore()
		store.reload(folder: dir)
		XCTAssertEqual(store.meetings.count, 1)

		store.reload(folder: nil)
		XCTAssertTrue(store.meetings.isEmpty)
	}

	func testSearchHayCoversTitleAndBodyLowercased() {
		writeNote("Budget Review", date: "2026-06-24 10-00-00", body: "We discussed RUNWAY.")
		let store = MeetingStore()
		store.reload(folder: dir)
		XCTAssertTrue(store.meetings[0].searchHay.contains("budget review"))
		XCTAssertTrue(store.meetings[0].searchHay.contains("runway"))
	}

	// MARK: rename

	func testRenameMovesTheFileAndRewritesTheHeading() throws {
		writeNote("Meeting A", date: "2026-06-24 10-00-00")
		let store = MeetingStore()
		store.reload(folder: dir)

		let renamed = store.rename(store.meetings[0], to: "Budget review")
		XCTAssertEqual(renamed?.title, "Budget review")
		XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Meeting A.md").path))

		let content = try String(contentsOf: dir.appendingPathComponent("Budget review.md"), encoding: .utf8)
		XCTAssertTrue(content.contains("# Budget review"))
		XCTAssertFalse(content.contains("# Meeting A"))
		// The audio link is untouched, so the recording stays attached.
		XCTAssertEqual(RecordingController.frontmatterValue("audio", in: content), "recordings/Meeting A")
	}

	func testRenameSanitizesPathSeparatorsAndColons() {
		writeNote("Meeting A", date: "2026-06-24 10-00-00")
		let store = MeetingStore()
		store.reload(folder: dir)

		let renamed = store.rename(store.meetings[0], to: "Q3/Q4: planning")
		XCTAssertEqual(renamed?.title, "Q3-Q4- planning")
	}

	func testRenameRefusesNoOpsAndCollisions() {
		writeNote("Meeting A", date: "2026-06-24 10-00-00")
		writeNote("Taken", date: "2026-06-23 10-00-00")
		let store = MeetingStore()
		store.reload(folder: dir)
		let a = store.meetings.first { $0.title == "Meeting A" }!

		XCTAssertNil(store.rename(a, to: "Meeting A"))   // same name
		XCTAssertNil(store.rename(a, to: "   "))          // empty after trimming
		XCTAssertNil(store.rename(a, to: "Taken"))        // would overwrite
		XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Meeting A.md").path))
	}

	func testReplacingFirstHeadingOnlyTouchesTheFirstOne() {
		let content = "# One\n\ntext\n\n# Two\n"
		XCTAssertEqual(MeetingStore.replacingFirstHeading(in: content, with: "New"), "# New\n\ntext\n\n# Two\n")
	}

	func testReplacingFirstHeadingLeavesANoteWithoutOneAlone() {
		XCTAssertEqual(MeetingStore.replacingFirstHeading(in: "no heading here", with: "New"), "no heading here")
	}

	// MARK: delete

	func testDeleteRemovesTheNoteAndItsAudio() {
		writeNote("Meeting A", date: "2026-06-24 10-00-00")
		touchAudio("recordings/Meeting A")
		let store = MeetingStore()
		store.reload(folder: dir)

		store.delete(store.meetings[0])
		XCTAssertTrue(store.meetings.isEmpty)
		XCTAssertFalse(FileManager.default.fileExists(
			atPath: dir.appendingPathComponent("recordings/Meeting A.system.wav").path))
	}

	func testDeleteRemovesCompressedTracksToo() {
		writeNote("Meeting A", date: "2026-06-24 10-00-00")
		touchAudio("recordings/Meeting A", exts: ["system.m4a", "mic.m4a"])
		let store = MeetingStore()
		store.reload(folder: dir)

		store.delete(store.meetings[0])
		XCTAssertFalse(FileManager.default.fileExists(
			atPath: dir.appendingPathComponent("recordings/Meeting A.mic.m4a").path))
	}

	func testDeleteKeepsAudioAnotherNoteStillReferences() {
		writeNote("Meeting A", date: "2026-06-24 10-00-00", audioBase: "recordings/shared")
		writeNote("Duplicate of A", date: "2026-06-24 10-00-00", audioBase: "recordings/shared")
		touchAudio("recordings/shared")
		let store = MeetingStore()
		store.reload(folder: dir)

		store.delete(store.meetings.first { $0.title == "Meeting A" }!)
		XCTAssertTrue(FileManager.default.fileExists(
			atPath: dir.appendingPathComponent("recordings/shared.system.wav").path),
			"audio still referenced by the duplicate note must survive")
	}
}

final class NoteLookupTests: XCTestCase {

	private var dir: URL!

	override func setUpWithError() throws {
		dir = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("note-lookup-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: dir)
	}

	/// Directory enumeration hands back the resolved (/private/var) form of a temp
	/// path, so compare canonical paths rather than raw URLs.
	private func same(_ a: URL?, _ b: URL?) -> Bool {
		a?.resolvingSymlinksInPath().path == b?.resolvingSymlinksInPath().path
	}

	@discardableResult
	private func write(_ title: String, audioBase: String) -> URL {
		let url = dir.appendingPathComponent("\(title).md")
		let note = RecordingController.buildNote(
			title: title, date: "2026-06-24 10-00-00", audioBase: audioBase,
			durationSeconds: 1, speakerCount: 0, summary: "", transcript: "x")
		try? note.write(to: url, atomically: true, encoding: .utf8)
		return url
	}

	func testFindsTheNoteThatLinksARecordingEvenAfterARename() {
		let url = write("Renamed during recording", audioBase: "recordings/Meeting 2026-06-24 10-00-00")
		XCTAssertTrue(same(
			RecordingController.existingNoteURL(audioBase: "recordings/Meeting 2026-06-24 10-00-00", in: dir),
			url))
	}

	func testReturnsNilWhenNoNoteLinksTheRecording() {
		write("Other", audioBase: "recordings/something else")
		XCTAssertNil(RecordingController.existingNoteURL(audioBase: "recordings/Meeting X", in: dir))
	}

	func testTargetNotePrefersTheTrackedNote() {
		// Two notes link the same recording; the tracked one must win so finalizing
		// updates the note the user has been watching instead of a stale duplicate.
		let tracked = write("Tracked", audioBase: "recordings/M")
		write("AAA older duplicate", audioBase: "recordings/M")
		XCTAssertTrue(same(
			RecordingController.targetNoteURL(preferredPath: tracked.path, audioBase: "recordings/M", in: dir),
			tracked))
	}

	func testTargetNoteFallsBackToScanningWhenTheTrackedNoteIsGone() {
		let other = write("Other", audioBase: "recordings/M")
		let missing = dir.appendingPathComponent("deleted.md").path
		XCTAssertTrue(same(
			RecordingController.targetNoteURL(preferredPath: missing, audioBase: "recordings/M", in: dir),
			other))
	}

	func testTargetNoteIgnoresATrackedNoteThatLinksADifferentRecording() {
		let unrelated = write("Unrelated", audioBase: "recordings/other")
		XCTAssertNil(
			RecordingController.targetNoteURL(preferredPath: unrelated.path, audioBase: "recordings/M", in: dir))
	}
}