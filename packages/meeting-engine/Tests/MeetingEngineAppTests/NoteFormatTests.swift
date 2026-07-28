// The note on disk is the product: its frontmatter and section layout have to
// stay byte-compatible with the Windows app (NOTE-FORMAT.md) and round-trip
// through the readers that re-generate from it.

import XCTest
@testable import MeetingEngineApp

final class BuildNoteTests: XCTestCase {

	func testFullNoteLayout() {
		let note = RecordingController.buildNote(
			title: "Meeting 2026-06-24 10-00-00",
			date: "2026-06-24 10-00-00",
			audioBase: "recordings/Meeting 2026-06-24 10-00-00",
			durationSeconds: 1800,
			speakerCount: 3,
			summary: "## Short summary\nWe shipped it.",
			transcript: "[0:00] **You:** Hello.",
			audioExt: "m4a",
			model: "large-v3-turbo")

		XCTAssertEqual(note, """
		---
		type: meeting
		tags: [meeting]
		date: 2026-06-24 10-00-00
		audio: recordings/Meeting 2026-06-24 10-00-00
		duration: 1800
		speakers: 3
		model: large-v3-turbo
		app_version: \(appVersion)
		---

		# Meeting 2026-06-24 10-00-00

		## Short summary
		We shipped it.

		## Transcript

		[0:00] **You:** Hello.

		## Audio

		**You (microphone)**

		![[Meeting 2026-06-24 10-00-00.mic.m4a]]

		**Them (system audio)**

		![[Meeting 2026-06-24 10-00-00.system.m4a]]

		""")
	}

	func testOptionalFrontmatterIsOmittedWhenUnset() {
		let note = RecordingController.buildNote(
			title: "T", date: "D", audioBase: "recordings/T",
			durationSeconds: 0, speakerCount: 1, summary: "", transcript: "x")
		XCTAssertFalse(note.contains("duration:"))
		XCTAssertFalse(note.contains("speakers:"))  // 1 speaker == the plain "Them"
		XCTAssertFalse(note.contains("model:"))
	}

	func testEmptyTranscriptGetsThePlaceholderNotAnEmptySection() {
		let note = RecordingController.buildNote(
			title: "T", date: "D", audioBase: "recordings/T",
			durationSeconds: 10, speakerCount: 0, summary: "", transcript: "")
		XCTAssertTrue(note.contains("## Transcript\n\n_(no speech detected)_\n"))
	}

	func testDeletedAudioReplacesTheEmbedsWithAnExplanation() {
		let note = RecordingController.buildNote(
			title: "T", date: "D", audioBase: "recordings/T",
			durationSeconds: 10, speakerCount: 0, summary: "", transcript: "x", audioExt: nil)
		XCTAssertTrue(note.contains("_Audio removed after transcription to save space._"))
		XCTAssertFalse(note.contains("![["))
	}

	func testEmbedsUseTheAudioFileNameNotItsFolderPath() {
		let note = RecordingController.buildNote(
			title: "T", date: "D", audioBase: "recordings/nested/Meeting X",
			durationSeconds: 1, speakerCount: 0, summary: "", transcript: "x")
		XCTAssertTrue(note.contains("![[Meeting X.mic.wav]]"))
		XCTAssertTrue(note.contains("audio: recordings/nested/Meeting X"))
	}

	func testFrontmatterReadsBackWhatBuildNoteWrote() {
		let note = RecordingController.buildNote(
			title: "T", date: "2026-06-24 10-00-00", audioBase: "recordings/T",
			durationSeconds: 42, speakerCount: 2, summary: "", transcript: "x")
		XCTAssertEqual(RecordingController.frontmatterValue("date", in: note), "2026-06-24 10-00-00")
		XCTAssertEqual(RecordingController.frontmatterValue("audio", in: note), "recordings/T")
		XCTAssertEqual(RecordingController.frontmatterValue("duration", in: note), "42")
		XCTAssertEqual(RecordingController.frontmatterValue("speakers", in: note), "2")
		XCTAssertEqual(RecordingController.frontmatterValue("app_version", in: note), appVersion)
	}
}

final class FrontmatterValueTests: XCTestCase {

	func testMissingKeyAndMissingFrontmatterBothReturnNil() {
		XCTAssertNil(RecordingController.frontmatterValue("nope", in: "---\ndate: x\n---\n"))
		XCTAssertNil(RecordingController.frontmatterValue("date", in: "# Just a note\ndate: x\n"))
	}

	func testBodyLinesAfterTheBlockAreNotRead() {
		let content = "---\ntype: meeting\n---\n\n# Title\n\naudio: not-frontmatter\n"
		XCTAssertNil(RecordingController.frontmatterValue("audio", in: content))
	}

	func testValueIsTrimmedAndKeepsInnerColons() {
		let content = "---\nurl: http://localhost:11434   \n---\n"
		XCTAssertEqual(RecordingController.frontmatterValue("url", in: content), "http://localhost:11434")
	}

	func testEmptyValueReadsAsEmptyStringNotNil() {
		XCTAssertEqual(RecordingController.frontmatterValue("model", in: "---\nmodel:\n---\n"), "")
	}
}

final class ExistingSummaryBlockTests: XCTestCase {

	private func note(summary: String) -> String {
		RecordingController.buildNote(
			title: "T", date: "D", audioBase: "recordings/T",
			durationSeconds: 1, speakerCount: 0, summary: summary, transcript: "[0:00] **You:** hi")
	}

	func testExtractsEverySummarySectionAndStopsAtTheTranscript() {
		let summary = "## Short summary\nOne line.\n\n## Action items\n- [ ] Do it"
		XCTAssertEqual(RecordingController.existingSummaryBlock(in: note(summary: summary)), summary)
	}

	func testANoteWithoutASummaryYieldsEmpty() {
		XCTAssertEqual(RecordingController.existingSummaryBlock(in: note(summary: "")), "")
	}

	func testTheTitleHeadingIsNotMistakenForASummary() {
		let block = RecordingController.existingSummaryBlock(in: note(summary: ""))
		XCTAssertFalse(block.contains("# T"))
	}

	func testWorksOnANoteWithNoFrontmatter() {
		let content = "# Title\n\n## Summary\nBody.\n\n## Transcript\n\nx\n"
		XCTAssertEqual(RecordingController.existingSummaryBlock(in: content), "## Summary\nBody.")
	}

	func testAudioSectionIsNotTreatedAsSummaryWhenTheTranscriptIsAbsent() {
		let content = "---\ntype: meeting\n---\n\n# T\n\n## Summary\nBody.\n\n## Audio\n\n![[x.wav]]\n"
		XCTAssertEqual(RecordingController.existingSummaryBlock(in: content), "## Summary\nBody.")
	}
}