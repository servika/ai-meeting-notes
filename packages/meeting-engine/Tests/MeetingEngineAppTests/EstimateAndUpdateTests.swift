// The "time left" estimator (learned per-model rates), the summary-prompt
// catalog, and version comparison for the update banner.

import MeetingEngineCore
import XCTest
@testable import MeetingEngineApp

final class ShortTimeTests: XCTestCase {

	func testFormatsSecondsMinutesAndHours() {
		XCTAssertEqual(RecordingController.shortTime(0), "0s")
		XCTAssertEqual(RecordingController.shortTime(45), "45s")
		XCTAssertEqual(RecordingController.shortTime(125), "2m 05s")
		XCTAssertEqual(RecordingController.shortTime(3780), "1h 03m")
	}

	func testNegativeAndFractionalInputsAreClamped() {
		XCTAssertEqual(RecordingController.shortTime(-10), "0s")
		XCTAssertEqual(RecordingController.shortTime(59.6), "1m 00s")
	}
}

final class ProcessingRateTests: XCTestCase {

	private let model = "/models/ggml-test-\(UUID().uuidString).bin"

	override func tearDown() {
		UserDefaults.standard.removeObject(forKey: RecordingController.rateKey(model))
		super.tearDown()
	}

	func testSeedRatesScaleWithModelSize() {
		XCTAssertEqual(RecordingController.processingRate(forModel: "/m/ggml-tiny.bin"), 0.1)
		XCTAssertEqual(RecordingController.processingRate(forModel: "/m/ggml-small.bin"), 0.5)
		XCTAssertEqual(RecordingController.processingRate(forModel: "/m/ggml-medium.bin"), 1.0)
		XCTAssertEqual(RecordingController.processingRate(forModel: "/m/ggml-large-v3-turbo.bin"), 1.5)
		XCTAssertEqual(RecordingController.processingRate(forModel: "/m/ggml-unknown.bin"), 0.25)
	}

	func testRateKeyIsPerModelFileNotPerPath() {
		XCTAssertEqual(RecordingController.rateKey("/a/b/ggml-base.bin"), "procRate.ggml-base.bin")
		XCTAssertEqual(RecordingController.rateKey("/other/ggml-base.bin"), RecordingController.rateKey("/a/ggml-base.bin"))
	}

	func testTheFirstRunLearnsTheObservedRate() {
		RecordingController.recordRate(audioSeconds: 100, model: model, processingSeconds: 50)
		XCTAssertEqual(RecordingController.processingRate(forModel: model), 0.5, accuracy: 0.0001)
	}

	func testLaterRunsBlendTowardsTheNewRate() {
		RecordingController.recordRate(audioSeconds: 100, model: model, processingSeconds: 50)  // 0.5
		RecordingController.recordRate(audioSeconds: 100, model: model, processingSeconds: 100) // 1.0
		// EMA: 0.5 * 0.6 + 1.0 * 0.4
		XCTAssertEqual(RecordingController.processingRate(forModel: model), 0.7, accuracy: 0.0001)
	}

	func testNonsenseSamplesAreIgnored() {
		RecordingController.recordRate(audioSeconds: 0.5, model: model, processingSeconds: 10)
		RecordingController.recordRate(audioSeconds: 100, model: model, processingSeconds: 0)
		// Nothing learned, so the seeded default still applies.
		XCTAssertEqual(RecordingController.processingRate(forModel: model), 0.25)
	}
}

final class SummaryPromptCatalogTests: XCTestCase {

	func testEachModelFamilyGetsItsTunedPrompt() {
		XCTAssertEqual(SummaryPrompts.defaultPrompt(for: "qwen2.5:7b"), SummaryPrompts.qwen)
		XCTAssertEqual(SummaryPrompts.defaultPrompt(for: "llama3.1:8b"), SummaryPrompts.llama)
		XCTAssertEqual(SummaryPrompts.defaultPrompt(for: "gpt-oss:20b"), SummaryPrompts.gptOss)
	}

	func testMatchingIsCaseInsensitive() {
		XCTAssertEqual(SummaryPrompts.defaultPrompt(for: "Qwen3:8B"), SummaryPrompts.qwen)
	}

	func testUnknownModelsFallBackToTheGenericPrompt() {
		XCTAssertEqual(SummaryPrompts.defaultPrompt(for: "claude-opus-4-8"), Summarizer.defaultPrompt)
		XCTAssertEqual(SummaryPrompts.defaultPrompt(for: ""), Summarizer.defaultPrompt)
	}

	func testEveryPromptAsksForTheFourSectionsAndTakesATranscript() {
		for prompt in [SummaryPrompts.qwen, SummaryPrompts.llama, SummaryPrompts.gptOss, Summarizer.defaultPrompt] {
			XCTAssertTrue(prompt.contains("{{transcript}}"))
			for heading in ["## Short summary", "## Summary", "## Topics discussed", "## Action items"] {
				XCTAssertTrue(prompt.contains(heading), "a prompt is missing \(heading)")
			}
		}
	}
}

@MainActor
final class UpdateVersionTests: XCTestCase {

	func testNewerVersionsCompareGreater() {
		XCTAssertTrue(UpdateChecker.isNewer("0.27.0", than: "0.26.2"))
		XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.99.99"))
		XCTAssertTrue(UpdateChecker.isNewer("0.38.2", than: "0.38.1"))
	}

	func testEqualAndOlderVersionsDoNot() {
		XCTAssertFalse(UpdateChecker.isNewer("0.26.2", than: "0.26.2"))
		XCTAssertFalse(UpdateChecker.isNewer("0.26.1", than: "0.26.2"))
	}

	func testMissingComponentsCountAsZero() {
		XCTAssertTrue(UpdateChecker.isNewer("0.27", than: "0.26.9"))
		XCTAssertFalse(UpdateChecker.isNewer("0.26", than: "0.26.0"))
		XCTAssertTrue(UpdateChecker.isNewer("0.26.1", than: "0.26"))
	}

	func testSuffixesAreIgnored() {
		XCTAssertTrue(UpdateChecker.isNewer("0.27.0-beta", than: "0.26.2"))
		XCTAssertFalse(UpdateChecker.isNewer("0.26.2-rc1", than: "0.26.2"))
	}

	func testGarbageNeverClaimsToBeNewer() {
		XCTAssertFalse(UpdateChecker.isNewer("", than: "0.26.2"))
		XCTAssertFalse(UpdateChecker.isNewer("not-a-version", than: "0.26.2"))
	}

	func testTheRunningVersionIsAlwaysReadable() {
		// Under xctest there's no app bundle, so this exercises the "dev" fallback -
		// what matters is that the note's `app_version:` is never blank.
		XCTAssertFalse(appVersion.isEmpty)
	}
}