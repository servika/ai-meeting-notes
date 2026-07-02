// Shared helpers for the Settings sections (each section lives in its own file
// under Settings/). Only things used by more than one section belong here; section-
// specific state and helpers stay inside their section view.

import SwiftUI
import MeetingEngineCore

extension View {
	/// An orange "unavailable / dependency" note shown under a stage toggle.
	func stageNote(_ text: String) -> some View {
		Label(text, systemImage: "exclamationmark.triangle.fill")
			.font(.caption).foregroundStyle(.orange)
			.fixedSize(horizontal: false, vertical: true)
	}
}

/// Installed physical memory, rounded to GB. Drives the model recommendations.
var systemRAMGB: Int {
	Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
}

/// Recommended whisper model for this Mac's RAM (multilingual; balances accuracy
/// vs. memory/speed).
func recommendedWhisperModel(ramGB: Int) -> String {
	if ramGB >= 24 { return "large-v3" }
	if ramGB >= 12 { return "large-v3-turbo" }
	return "small"
}

/// Recommended local (Ollama) summary model for this Mac's RAM.
func recommendedOllamaModel(ramGB: Int) -> String {
	if ramGB >= 48 { return "qwen2.5:32b" }
	if ramGB >= 24 { return "qwen2.5:14b" }
	if ramGB >= 12 { return "qwen2.5:7b" }
	return "qwen2.5:3b"
}

/// Whether a whisper model file exists at `path` (tilde-expanded).
func modelFileExists(_ path: String) -> Bool {
	let p = (path as NSString).expandingTildeInPath
	return !p.isEmpty && FileManager.default.fileExists(atPath: p)
}

/// Whisper ggml models present in ~/models, as (display name, full path),
/// e.g. ("large-v3", "/Users/me/models/ggml-large-v3.bin").
func localWhisperModels() -> [(name: String, path: String)] {
	let dir = ("~/models" as NSString).expandingTildeInPath
	let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
	return files
		.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
		.map { (name: String($0.dropFirst(5).dropLast(4)),
			path: (dir as NSString).appendingPathComponent($0)) }
		.sorted { $0.name < $1.name }
}

/// Dropdown options for a model: the downloaded models, plus the currently-stored
/// path if it isn't among them (so a missing model still shows).
func whisperModelOptions(including current: String) -> [(name: String, path: String)] {
	var opts = localWhisperModels()
	if !current.isEmpty, !opts.contains(where: { $0.path == current }) {
		opts.insert((name: (current as NSString).lastPathComponent + " (missing)", path: current), at: 0)
	}
	return opts
}

/// Human-readable size / speed / accuracy guidance for a downloadable model.
/// `.en` variants are English-only and shouldn't be used for Ukrainian/auto.
func whisperModelInfo(_ model: String) -> String {
	switch model {
	case "tiny":      return "≈75 MB · fastest, lowest accuracy. Multilingual."
	case "tiny.en":   return "≈75 MB · fastest, lowest accuracy. English only."
	case "base":      return "≈142 MB · fast, basic accuracy. Multilingual. Good default."
	case "base.en":   return "≈142 MB · fast, basic accuracy. English only."
	case "small":     return "≈466 MB · good balance of speed and accuracy. Multilingual."
	case "small.en":  return "≈466 MB · good balance of speed and accuracy. English only."
	case "medium":    return "≈1.5 GB · high accuracy, slower. Multilingual."
	case "medium.en": return "≈1.5 GB · high accuracy, slower. English only."
	case "large-v3":  return "≈3.1 GB · best accuracy, slowest. Multilingual - best for Ukrainian."
	case "large-v3-turbo": return "≈1.6 GB · near-large accuracy, much faster. Multilingual - great Ukrainian/speed balance."
	default:          return "Whisper ggml model."
	}
}

/// Display name for a language code, from the shared `meetingLanguages` list.
func meetingLanguageName(_ code: String) -> String {
	meetingLanguages.first { $0.code == code }?.name ?? code
}

/// The app's short version string (CFBundleShortVersionString), or "dev".
var appBundleVersion: String {
	Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}