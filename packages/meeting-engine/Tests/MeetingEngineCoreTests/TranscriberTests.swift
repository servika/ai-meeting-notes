// Merge/format half of the transcription pipeline: turning whisper's per-track
// segments into the labeled Markdown transcript, and dropping the cross-track
// echo an in-person meeting produces. (Running whisper itself needs a model and
// real audio, so it stays out of the unit suite.)

import XCTest
@testable import MeetingEngineCore

final class TranscriberMarkdownTests: XCTestCase {

	private func seg(_ start: Double, _ end: Double, _ text: String, _ speaker: String) -> TranscriptSegment {
		TranscriptSegment(start: start, end: end, text: text, speaker: speaker)
	}

	func testLabelsEachTurnAndSortsByTime() {
		let md = Transcriber.diarizedMarkdown([
			seg(5, 6, "Hi there.", "You"),
			seg(0, 1, "Hello.", "Them"),
		])
		XCTAssertEqual(md, "[0:00] **Them:** Hello.\n\n[0:05] **You:** Hi there.")
	}

	func testConsecutiveSegmentsOfOneSpeakerJoinIntoOneParagraph() {
		let md = Transcriber.diarizedMarkdown([
			seg(0, 1, "First part", "You"),
			seg(1.2, 2, "second part", "You"),
		])
		XCTAssertEqual(md, "[0:00] **You:** First part second part")
	}

	func testLongPauseStartsAnUnlabeledContinuationParagraph() {
		let md = Transcriber.diarizedMarkdown([
			seg(0, 1, "Before the pause.", "You"),
			seg(10, 11, "After the pause.", "You"),
		])
		// Same turn, so only the first paragraph carries the speaker label.
		XCTAssertEqual(md, "[0:00] **You:** Before the pause.\n\n[0:10] After the pause.")
	}

	func testSpeakerChangeAlwaysRelabels() {
		let md = Transcriber.diarizedMarkdown([
			seg(0, 1, "One.", "You"),
			seg(1.1, 2, "Two.", "Them"),
			seg(2.1, 3, "Three.", "You"),
		])
		XCTAssertEqual(md.components(separatedBy: "**You:**").count - 1, 2)
		XCTAssertEqual(md.components(separatedBy: "**Them:**").count - 1, 1)
	}

	func testEmptyAndWhitespaceSegmentsAreSkipped() {
		let md = Transcriber.diarizedMarkdown([
			seg(0, 1, "   ", "You"),
			seg(2, 3, "Real text.", "You"),
		])
		XCTAssertEqual(md, "[0:02] **You:** Real text.")
	}

	func testTimestampsPastAnHourUseHoursMinutesSeconds() {
		let md = Transcriber.diarizedMarkdown([seg(3665, 3666, "Late.", "You")])
		XCTAssertTrue(md.hasPrefix("[1:01:05]"), md)
	}

	func testEmptyInputProducesEmptyTranscript() {
		XCTAssertEqual(Transcriber.diarizedMarkdown([]), "")
	}
}

final class TranscriberEchoTests: XCTestCase {

	private func seg(_ start: Double, _ end: Double, _ text: String, _ speaker: String) -> TranscriptSegment {
		TranscriptSegment(start: start, end: end, text: text, speaker: speaker)
	}

	func testDropsTheThinnerCopyOfAnEchoedUtterance() {
		// Same room on both tracks: the mic hears the full sentence, the loopback a
		// subset of it at the same moment.
		let full = "let us go over the quarterly numbers before we finish"
		let segments = [
			seg(10, 14, full, "You"),
			seg(10.5, 13.5, "go over the quarterly numbers before we finish", "Them"),
		]
		let kept = Transcriber.removeCrossTalkEchoes(segments)
		XCTAssertEqual(kept.count, 1)
		XCTAssertEqual(kept[0].speaker, "You")
		XCTAssertEqual(kept[0].text, full)
	}

	func testKeepsGenuineRemoteConversation() {
		let segments = [
			seg(0, 4, "how did the migration go last night", "You"),
			seg(5, 9, "we finished around three with no rollbacks", "Them"),
		]
		XCTAssertEqual(Transcriber.removeCrossTalkEchoes(segments).count, 2)
	}

	func testKeepsShortRepliesEvenWhenTheyLookLikeEchoes() {
		let segments = [
			seg(0, 1, "yeah okay", "You"),
			seg(0.2, 1.2, "yeah okay", "Them"),
		]
		XCTAssertEqual(Transcriber.removeCrossTalkEchoes(segments).count, 2)
	}

	func testKeepsIdenticalTextSpokenFarApartInTime() {
		let line = "let us go over the quarterly numbers again"
		let segments = [
			seg(0, 4, line, "You"),
			seg(600, 604, line, "Them"),
		]
		XCTAssertEqual(Transcriber.removeCrossTalkEchoes(segments).count, 2)
	}

	func testSingleSpeakerTranscriptIsUntouched() {
		let line = "the same sentence transcribed twice in a row"
		let segments = [seg(0, 4, line, "You"), seg(4.1, 8, line, "You")]
		XCTAssertEqual(Transcriber.removeCrossTalkEchoes(segments).count, 2)
	}

	func testEchoDedupIsIdempotent() {
		let segments = [
			seg(10, 14, "let us go over the quarterly numbers before we finish", "You"),
			seg(10.5, 13.5, "go over the quarterly numbers before we finish", "Them"),
		]
		let once = Transcriber.removeCrossTalkEchoes(segments)
		let twice = Transcriber.removeCrossTalkEchoes(once)
		XCTAssertEqual(once.count, twice.count)
	}
}