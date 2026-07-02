import SwiftUI

/// Settings → Transcription → Quick setup: one-click "best quality for Ukrainian".
struct QuickSetupSection: View {
	@EnvironmentObject var settings: AppSettings
	@StateObject private var downloader = ModelDownloader()
	@State private var presetMessage = ""

	var body: some View {
		Section("Quick setup") {
			HStack {
				Button(action: applyUkrainianPreset) {
					Label("Best quality for Ukrainian", systemImage: "star.fill")
				}
				.disabled(downloader.isDownloading)
				if !presetMessage.isEmpty {
					Text(presetMessage).font(.caption).foregroundStyle(.secondary)
				}
			}
			Text("Sets the meeting language to Ukrainian and uses the large-v3 model for it (downloads it first if needed). Best accuracy; slower than base.")
				.font(.caption).foregroundStyle(.secondary)
		}
	}

	/// language = uk and large-v3 pinned to Ukrainian (downloaded first if absent).
	private func applyUkrainianPreset() {
		settings.language = "uk"
		let path = ("~/models/ggml-large-v3.bin" as NSString).expandingTildeInPath
		if FileManager.default.fileExists(atPath: path) {
			settings.setModel(path, for: "uk")
			presetMessage = "Ukrainian → large-v3 ✓"
			return
		}
		presetMessage = "Downloading large-v3…"
		downloader.download(model: "large-v3") { url in
			if let url = url {
				settings.setModel(url.path, for: "uk")
				presetMessage = "Ukrainian → large-v3 ✓"
			} else {
				presetMessage = "Download failed - try again."
			}
		}
	}
}