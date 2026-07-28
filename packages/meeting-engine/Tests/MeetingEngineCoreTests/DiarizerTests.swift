// The parts of speaker recognition that don't need the sherpa-onnx binary:
// parsing its stdout into spans, and relabeling "Them" by span overlap.

import XCTest
@testable import MeetingEngineCore

final class DiarizerParseTests: XCTestCase {

	func testParsesSpansWithTheDashSeparator() {
		let spans = Diarizer.parseSpans("0.033 -- 2.041 speaker_00\n2.500 -- 4.000 speaker_01\n")
		XCTAssertEqual(spans.count, 2)
		XCTAssertEqual(spans[0].start, 0.033, accuracy: 0.0001)
		XCTAssertEqual(spans[0].end, 2.041, accuracy: 0.0001)
		XCTAssertEqual(spans[0].speaker, 0)
		XCTAssertEqual(spans[1].speaker, 1)
	}

	func testParsesSpansWithoutTheDashSeparator() {
		let spans = Diarizer.parseSpans("1.0 3.0 speaker_02")
		XCTAssertEqual(spans.count, 1)
		XCTAssertEqual(spans[0].speaker, 2)
	}

	func testIgnoresLogNoiseAndMalformedLines() {
		let spans = Diarizer.parseSpans("""
		loading model…
		0.0 -- 1.0 speaker_00
		not a span at all
		5.0 -- 5.0 speaker_01
		3.0 -- 2.0 speaker_01
		done
		""")
		// Only the one well-formed line with end > start survives.
		XCTAssertEqual(spans.count, 1)
		XCTAssertEqual(spans[0].speaker, 0)
	}

	func testEmptyOutputProducesNoSpans() {
		XCTAssertTrue(Diarizer.parseSpans("").isEmpty)
	}

	func testHandlesCarriageReturnLineEndings() {
		XCTAssertEqual(Diarizer.parseSpans("0.0 -- 1.0 speaker_00\r\n1.0 -- 2.0 speaker_01\r\n").count, 2)
	}
}

final class DiarizerRelabelTests: XCTestCase {

	private func seg(_ start: Double, _ end: Double, _ speaker: String) -> TranscriptSegment {
		TranscriptSegment(start: start, end: end, text: "text", speaker: speaker)
	}

	private func span(_ start: Double, _ end: Double, _ speaker: Int) -> Diarizer.SpeakerSpan {
		Diarizer.SpeakerSpan(start: start, end: end, speaker: speaker)
	}

	func testFewerThanTwoClustersLeavesEverythingAlone() {
		let segments = [seg(0, 1, "Them"), seg(1, 2, "Them")]
		let relabeled = Diarizer.relabel(segments, using: [span(0, 2, 0)])
		XCTAssertEqual(relabeled.map(\.speaker), ["Them", "Them"])
	}

	func testNumbersSpeakersByFirstAppearanceOnTheTimeline() {
		// Cluster 7 speaks first, so it becomes "Them 1" even though 3 sorts lower.
		let spans = [span(10, 20, 3), span(0, 5, 7)]
		let relabeled = Diarizer.relabel([seg(0, 5, "Them"), seg(10, 20, "Them")], using: spans)
		XCTAssertEqual(relabeled.map(\.speaker), ["Them 1", "Them 2"])
	}

	func testAssignsTheClusterWithTheMostOverlap() {
		let spans = [span(0, 10, 0), span(10, 20, 1)]
		// Straddles both, but 8s of it lands in cluster 1.
		let relabeled = Diarizer.relabel([seg(8, 18, "Them")], using: spans)
		XCTAssertEqual(relabeled[0].speaker, "Them 2")
	}

	func testFallsBackToTheNearestSpanWhenNothingOverlaps() {
		let spans = [span(0, 10, 0), span(100, 110, 1)]
		let relabeled = Diarizer.relabel([seg(90, 95, "Them")], using: spans)
		XCTAssertEqual(relabeled[0].speaker, "Them 2")
	}

	func testYourOwnTrackIsNeverRelabeled() {
		let spans = [span(0, 5, 0), span(5, 10, 1)]
		let relabeled = Diarizer.relabel([seg(0, 5, "You"), seg(5, 10, "Them")], using: spans)
		XCTAssertEqual(relabeled[0].speaker, "You")
		XCTAssertEqual(relabeled[1].speaker, "Them 2")
	}

	func testCustomPrefixIsHonored() {
		let spans = [span(0, 5, 0), span(5, 10, 1)]
		let relabeled = Diarizer.relabel([seg(0, 5, "Guest")], using: spans, prefix: "Guest")
		XCTAssertEqual(relabeled[0].speaker, "Guest 1")
	}

	func testSegmentTextAndTimesSurviveRelabeling() {
		let spans = [span(0, 5, 0), span(5, 10, 1)]
		let original = TranscriptSegment(start: 1, end: 2, text: "hello world", speaker: "Them")
		let relabeled = Diarizer.relabel([original], using: spans)[0]
		XCTAssertEqual(relabeled.text, "hello world")
		XCTAssertEqual(relabeled.start, 1)
		XCTAssertEqual(relabeled.end, 2)
	}
}