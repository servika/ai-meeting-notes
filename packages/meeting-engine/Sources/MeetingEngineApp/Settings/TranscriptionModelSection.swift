import SwiftUI
import MeetingEngineCore

/// Settings → Transcription → Transcription: default model, language, vocab hint,
/// and in-app model download.
struct TranscriptionModelSection: View {
	@EnvironmentObject var settings: AppSettings
	@StateObject private var downloader = ModelDownloader()
	@State private var modelToDownload = "base"

	private var modelExists: Bool { modelFileExists(settings.whisperModelPath) }

	var body: some View {
		Section("Transcription") {
			HStack {
				Picker("Default model", selection: $settings.whisperModelPath) {
					ForEach(whisperModelOptions(including: settings.whisperModelPath), id: \.path) {
						Text($0.name).tag($0.path)
					}
				}
				Image(systemName: modelExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
					.foregroundStyle(modelExists ? .green : .orange)
			}
			if !modelExists {
				Text("No model downloaded yet. Download one below.")
					.font(.caption).foregroundStyle(.orange)
			}
			TextField("Language (auto, en, uk, de, ua, …)", text: $settings.language)
			Text("Auto-detect / non-English needs a multilingual model (not the .en variant).")
				.font(.caption).foregroundStyle(.secondary)

			TextField("Vocabulary hint (optional)", text: $settings.transcriptionPrompt, axis: .vertical)
				.lineLimit(2...4)
			Text("Helps spelling of names and terms. List participant names, product/company names, and any jargon - e.g. \"Зустріч українською. Сергій, Олег, Keystone, Acme, whisper.\"")
				.font(.caption).foregroundStyle(.secondary)

			HStack {
				Picker("Download model", selection: $modelToDownload) {
					ForEach(ModelDownloader.available, id: \.self) { Text($0).tag($0) }
				}
				Button("Download") {
					downloader.download(model: modelToDownload) { url in
						if let url = url { settings.whisperModelPath = url.path }
					}
				}
				.disabled(downloader.isDownloading)
			}
			Text(whisperModelInfo(modelToDownload))
				.font(.caption).foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			Label("Recommended for your \(systemRAMGB) GB Mac: \(recommendedWhisperModel(ramGB: systemRAMGB))", systemImage: "sparkles")
				.font(.caption).foregroundStyle(brand)
			if downloader.isDownloading {
				ProgressView(value: downloader.progress).progressViewStyle(.linear)
				Text("\(downloader.message)  \(Int(downloader.progress * 100))%")
					.font(.caption).foregroundStyle(.secondary)
			} else if !downloader.message.isEmpty {
				Text(downloader.message).font(.caption).foregroundStyle(.secondary)
			}
		}
	}
}