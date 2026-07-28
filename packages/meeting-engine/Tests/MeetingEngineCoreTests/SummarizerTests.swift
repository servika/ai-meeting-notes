// Summarizer plumbing that runs without a model: prompt filling, the map-reduce
// chunker for long meetings, and the guard rails that fail fast (with a useful
// message) instead of firing a doomed HTTP request.

import XCTest
@testable import MeetingEngineCore

final class SummarizerPromptTests: XCTestCase {

	func testDefaultPromptCarriesTheTranscriptPlaceholderAndFourSections() {
		let p = Summarizer.defaultPrompt
		XCTAssertTrue(p.contains("{{transcript}}"))
		for heading in ["## Short summary", "## Summary", "## Topics discussed", "## Action items"] {
			XCTAssertTrue(p.contains(heading), "default prompt is missing \(heading)")
		}
	}

	func testFillSubstitutesThePlaceholder() {
		XCTAssertEqual(Summarizer.fill("before {{transcript}} after", with: "TEXT"), "before TEXT after")
	}

	func testFillAppendsWhenThePromptHasNoPlaceholder() {
		XCTAssertEqual(Summarizer.fill("Summarize this.", with: "TEXT"), "Summarize this.\n\nTEXT")
	}

	func testFillReplacesEveryPlaceholderOccurrence() {
		XCTAssertEqual(Summarizer.fill("{{transcript}}/{{transcript}}", with: "X"), "X/X")
	}
}

final class SummarizerChunkTests: XCTestCase {

	func testShortTextStaysOneChunk() {
		XCTAssertEqual(Summarizer.chunkText("one paragraph", maxChars: 100), ["one paragraph"])
	}

	func testBreaksOnBlankLinesAndKeepsEveryChunkWithinTheLimit() {
		let para = String(repeating: "a", count: 40)
		let text = [para, para, para].joined(separator: "\n\n")
		let chunks = Summarizer.chunkText(text, maxChars: 100)
		XCTAssertGreaterThan(chunks.count, 1)
		for c in chunks { XCTAssertLessThanOrEqual(c.count, 100) }
	}

	func testHardSplitsASingleOversizedParagraph() {
		let chunks = Summarizer.chunkText(String(repeating: "x", count: 250), maxChars: 100)
		XCTAssertEqual(chunks.count, 3)
		XCTAssertEqual(chunks.map(\.count), [100, 100, 50])
	}

	func testNoContentIsLostWhileChunking() {
		let text = (0..<20).map { "paragraph number \($0)" }.joined(separator: "\n\n")
		let rejoined = Summarizer.chunkText(text, maxChars: 60)
			.joined()
			.replacingOccurrences(of: "\n\n", with: "")
		XCTAssertEqual(rejoined, text.replacingOccurrences(of: "\n\n", with: ""))
	}

	func testEmptyTextProducesNoChunks() {
		XCTAssertTrue(Summarizer.chunkText("", maxChars: 100).isEmpty)
	}

	func testMapReduceThresholdIsAboveTheChunkSize() {
		// Otherwise a transcript could trip map-reduce yet fit in a single chunk.
		XCTAssertGreaterThan(Summarizer.mapReduceThresholdChars, Summarizer.chunkChars)
	}
}

final class SummarizerEngineGuardTests: XCTestCase {

	func testOllamaWithoutAModelFailsBeforeAnyRequest() {
		XCTAssertThrowsError(try Summarizer.summarize(
			transcript: "hi", prompt: "p", engine: .ollama(url: "http://localhost:11434", model: "")
		)) { error in
			XCTAssertEqual((error as? SummaryError)?.description, "no Ollama model set")
		}
	}

	func testClaudeWithoutAnAPIKeyFailsBeforeAnyRequest() {
		XCTAssertThrowsError(try Summarizer.summarize(
			transcript: "hi", prompt: "p", engine: .claude(apiKey: "", model: "claude-opus-4-8")
		)) { error in
			XCTAssertEqual((error as? SummaryError)?.description, "no Claude API key set")
		}
	}

	func testSummaryErrorDescribesItselfWithItsMessage() {
		XCTAssertEqual("\(SummaryError("boom"))", "boom")
	}

	func testOllamaStatusIsNotInstalledOrRunningForAnUnreachableURL() {
		// Port 1 is never a live Ollama; the result depends only on whether the
		// binary/app exists on this machine, never on `.running`.
		let state = Ollama.status(url: "http://127.0.0.1:1")
		XCTAssertNotEqual(state, .running(models: []))
		XCTAssertTrue(Ollama.installedModels(url: "http://127.0.0.1:1").isEmpty)
	}
}