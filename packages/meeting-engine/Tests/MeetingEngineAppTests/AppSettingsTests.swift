// Settings resolution: which whisper model a language gets, when a stage is
// available, and how per-model prompt overrides behave. AppSettings persists to
// UserDefaults, so each test starts from a cleared set of keys.

import XCTest
@testable import MeetingEngineApp

/// Keys AppSettings owns; cleared between tests so one test can't leak into another.
private let settingsKeys = [
	"vaultPath", "meetingsFolder", "whisperModelPath", "language", "suggestOnMeetingDetected",
	"autoStopForgotten", "autoStopSilenceMinutes", "useCalendarForMeetings", "transcriptionPrompt",
	"experimentalMode", "featureFlags", "speakerCount", "transcribeMeetings", "summarizeMeetings",
	"audioRetention", "summaryEngine", "ollamaURL", "ollamaModel", "claudeAPIKey", "claudeModel",
	"promptOverrides", "modelByLanguage", "recognizeSpeakers", "summaryPrompt",
]

func clearSettingsDefaults() {
	for key in settingsKeys { UserDefaults.standard.removeObject(forKey: key) }
}

final class AppSettingsDefaultsTests: XCTestCase {

	override func setUp() { super.setUp(); clearSettingsDefaults() }
	override func tearDown() { clearSettingsDefaults(); super.tearDown() }

	func testFreshInstallDefaults() {
		let s = AppSettings()
		XCTAssertEqual(s.meetingsFolder, "Meetings")
		XCTAssertEqual(s.language, "auto")
		XCTAssertEqual(s.audioRetention, "compressed")
		XCTAssertEqual(s.summaryEngine, "ollama")
		XCTAssertTrue(s.transcribeMeetings)
		XCTAssertTrue(s.summarizeMeetings)
		XCTAssertFalse(s.experimentalMode)
	}

	func testValuesPersistAcrossInstances() {
		let s = AppSettings()
		s.vaultPath = "/tmp/vault"
		s.meetingsFolder = "Calls"
		XCTAssertEqual(AppSettings().vaultPath, "/tmp/vault")
		XCTAssertEqual(AppSettings().meetingsFolder, "Calls")
	}

	func testMeetingsDirIsNilUntilAVaultIsChosen() {
		let s = AppSettings()
		XCTAssertNil(s.meetingsDirURL)
		s.vaultPath = "/tmp/vault"
		XCTAssertEqual(s.meetingsDirURL?.path, "/tmp/vault/Meetings")
	}

	func testMeetingsDirExpandsATilde() {
		let s = AppSettings()
		s.vaultPath = "~/vault"
		XCTAssertEqual(s.meetingsDirURL?.path, NSHomeDirectory() + "/vault/Meetings")
	}

	func testLegacyNoneEngineMigratesToTheSummarizeToggle() {
		UserDefaults.standard.set("none", forKey: "summaryEngine")
		let s = AppSettings()
		XCTAssertFalse(s.summarizeMeetings, "a legacy \"none\" engine means the user wanted no summary")
		XCTAssertEqual(s.summaryEngine, "ollama")
	}

	func testLegacySpeakerToggleMigratesIntoTheFeatureFlags() {
		UserDefaults.standard.set(true, forKey: "recognizeSpeakers")
		let s = AppSettings()
		XCTAssertTrue(s.flagValue(.speakerRecognition))
		XCTAssertNil(UserDefaults.standard.object(forKey: "recognizeSpeakers"), "the legacy key is consumed")
	}
}

final class AppSettingsModelResolutionTests: XCTestCase {

	override func setUp() { super.setUp(); clearSettingsDefaults() }
	override func tearDown() { clearSettingsDefaults(); super.tearDown() }

	func testFallsBackToTheDefaultModelWithoutOverrides() {
		let s = AppSettings()
		s.whisperModelPath = "~/models/ggml-base.bin"
		XCTAssertEqual(s.modelPath(for: "uk"), "~/models/ggml-base.bin")
	}

	func testAPerLanguageOverrideWins() {
		let s = AppSettings()
		s.whisperModelPath = "~/models/ggml-base.bin"
		s.setModel("~/models/ggml-large-v3-turbo.bin", for: "uk")
		XCTAssertEqual(s.modelPath(for: "uk"), "~/models/ggml-large-v3-turbo.bin")
		XCTAssertEqual(s.modelPath(for: "en"), "~/models/ggml-base.bin")
	}

	func testAutoUsesTheOnlyOverrideWhenThereIsExactlyOne() {
		let s = AppSettings()
		s.whisperModelPath = "~/models/ggml-base.bin"
		s.setModel("~/models/ggml-large-v3-turbo.bin", for: "uk")
		XCTAssertEqual(s.modelPath(for: "auto"), "~/models/ggml-large-v3-turbo.bin")
		XCTAssertEqual(s.modelPath(for: ""), "~/models/ggml-large-v3-turbo.bin")
	}

	func testAutoKeepsTheDefaultWhenSeveralOverridesCompete() {
		let s = AppSettings()
		s.whisperModelPath = "~/models/ggml-base.bin"
		s.setModel("~/models/a.bin", for: "uk")
		s.setModel("~/models/b.bin", for: "en")
		XCTAssertEqual(s.modelPath(for: "auto"), "~/models/ggml-base.bin")
	}

	func testSettingAnEmptyPathClearsTheOverride() {
		let s = AppSettings()
		s.whisperModelPath = "~/models/ggml-base.bin"
		s.setModel("~/models/a.bin", for: "uk")
		s.setModel("   ", for: "uk")
		XCTAssertEqual(s.modelPath(for: "uk"), "~/models/ggml-base.bin")

		s.setModel("~/models/a.bin", for: "uk")
		s.removeModel(for: "uk")
		XCTAssertEqual(s.modelPath(for: "uk"), "~/models/ggml-base.bin")
	}

	func testTranscriptionIsUnavailableWhenTheModelFileIsMissing() {
		let s = AppSettings()
		s.whisperModelPath = "/definitely/not/here.bin"
		XCTAssertFalse(s.transcriptionAvailable)
		XCTAssertNotNil(s.transcriptionUnavailableReason)
	}

	func testTranscriptionIsAvailableWhenTheModelFileExists() throws {
		let path = NSTemporaryDirectory() + "model-\(UUID().uuidString).bin"
		FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
		defer { try? FileManager.default.removeItem(atPath: path) }

		let s = AppSettings()
		s.whisperModelPath = path
		XCTAssertTrue(s.transcriptionAvailable)
		XCTAssertNil(s.transcriptionUnavailableReason)
	}
}

final class AppSettingsSummaryTests: XCTestCase {

	override func setUp() { super.setUp(); clearSettingsDefaults() }
	override func tearDown() { clearSettingsDefaults(); super.tearDown() }

	func testOllamaNeedsAModelAndClaudeNeedsAKey() {
		let s = AppSettings()
		s.summaryEngine = "ollama"
		XCTAssertFalse(s.summaryAvailable)
		s.ollamaModel = "qwen2.5:7b"
		XCTAssertTrue(s.summaryAvailable)

		s.summaryEngine = "claude"
		XCTAssertFalse(s.summaryAvailable)
		s.claudeAPIKey = "sk-test"
		XCTAssertTrue(s.summaryAvailable)
	}

	func testAnUnknownEngineIsReportedAsUnconfigured() {
		let s = AppSettings()
		s.summaryEngine = "mystery"
		XCTAssertFalse(s.summaryAvailable)
		XCTAssertNotNil(s.summaryUnavailableReason)
	}

	func testActiveModelFollowsTheEngine() {
		let s = AppSettings()
		s.ollamaModel = "qwen2.5:7b"
		s.claudeModel = "claude-opus-4-8"
		s.summaryEngine = "ollama"
		XCTAssertEqual(s.activeSummaryModel, "qwen2.5:7b")
		s.summaryEngine = "claude"
		XCTAssertEqual(s.activeSummaryModel, "claude-opus-4-8")
	}

	func testPromptOverridesAreScopedToTheActiveModel() {
		let s = AppSettings()
		s.summaryEngine = "ollama"
		s.ollamaModel = "qwen2.5:7b"
		XCTAssertFalse(s.currentPromptIsCustom)
		XCTAssertEqual(s.currentPrompt(), SummaryPrompts.defaultPrompt(for: "qwen2.5:7b"))

		s.setCurrentPrompt("my prompt")
		XCTAssertTrue(s.currentPromptIsCustom)
		XCTAssertEqual(s.currentPrompt(), "my prompt")

		// Another model keeps its own (default) prompt.
		s.ollamaModel = "llama3.1:8b"
		XCTAssertFalse(s.currentPromptIsCustom)
		XCTAssertEqual(s.currentPrompt(), SummaryPrompts.defaultPrompt(for: "llama3.1:8b"))
	}

	func testResettingAPromptRestoresTheBakedDefault() {
		let s = AppSettings()
		s.summaryEngine = "ollama"
		s.ollamaModel = "qwen2.5:7b"
		s.setCurrentPrompt("my prompt")
		s.resetCurrentPrompt()
		XCTAssertFalse(s.currentPromptIsCustom)
		XCTAssertEqual(s.currentPrompt(), SummaryPrompts.defaultPrompt(for: "qwen2.5:7b"))
	}
}

final class FeatureFlagTests: XCTestCase {

	override func setUp() { super.setUp(); clearSettingsDefaults() }
	override func tearDown() { clearSettingsDefaults(); super.tearDown() }

	func testFlagsDefaultOffAndPersist() {
		let s = AppSettings()
		XCTAssertFalse(s.flagValue(.speakerRecognition))
		s.setFlag(.speakerRecognition, true)
		XCTAssertTrue(AppSettings().flagValue(.speakerRecognition))
	}

	func testAFlagOnlyTakesEffectWithTheMasterExperimentalSwitch() {
		let s = AppSettings()
		s.setFlag(.speakerRecognition, true)
		XCTAssertFalse(s.isEnabled(.speakerRecognition), "experimental mode is off")
		XCTAssertFalse(s.speakerRecognitionEnabled)

		s.experimentalMode = true
		XCTAssertTrue(s.isEnabled(.speakerRecognition))
		XCTAssertTrue(s.speakerRecognitionEnabled)

		s.setFlag(.speakerRecognition, false)
		XCTAssertFalse(s.speakerRecognitionEnabled, "master switch alone doesn't enable an off flag")
	}

	func testFlagBindingReadsAndWritesTheStoredState() {
		let s = AppSettings()
		let binding = s.flagBinding(.speakerRecognition)
		XCTAssertFalse(binding.wrappedValue)
		binding.wrappedValue = true
		XCTAssertTrue(s.flagValue(.speakerRecognition))
	}

	func testEveryFlagHasUIMetadataAndAStableStorageKey() {
		for flag in FeatureFlag.allCases {
			XCTAssertFalse(flag.title.isEmpty)
			XCTAssertFalse(flag.details.isEmpty)
			XCTAssertEqual(flag.storageKey, "ff.\(flag.rawValue)")
			XCTAssertEqual(flag.id, flag.rawValue)
		}
	}
}