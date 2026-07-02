import SwiftUI
import AppKit
import MeetingEngineCore

/// Settings → Summary: the summary stage - engine choice (Ollama/Claude), local
/// model management, and the per-model prompt. Owns the Ollama status state.
struct SummarySection: View {
	@EnvironmentObject var settings: AppSettings

	@State private var ollamaModels: [String] = []
	@State private var ollamaState: OllamaState?   // nil = checking
	@State private var pulling = false
	@State private var pullProgress: Double = 0
	@State private var pullStatus = ""
	@State private var ollamaModelToPull = ""

	/// Curated local summary models, recommended size for this Mac first.
	private var ollamaSuggestedModels: [String] {
		let recommended = recommendedOllamaModel(ramGB: systemRAMGB)
		var list = ["qwen2.5:3b", "qwen2.5:7b", "qwen2.5:14b", "qwen2.5:32b", "llama3.1:8b", "gpt-oss:20b"]
		list.removeAll { $0 == recommended }
		return [recommended] + list
	}

	var body: some View {
		Section("Summary & action items") {
			Toggle("Generate summary & action items", isOn: $settings.summarizeMeetings)
				.disabled(!settings.transcribeMeetings || !settings.summaryAvailable)
			if !settings.transcribeMeetings {
				stageNote("Turn on transcription first (Transcription tab) - the summary is generated from the transcript.")
			} else if settings.summarizeMeetings, let reason = settings.summaryUnavailableReason {
				stageNote(reason)
			}
			Text("When on, each transcript is summarized into a short summary, topics, and action items.")
				.font(.caption).foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			Picker("Engine", selection: $settings.summaryEngine) {
				Text("Local (Ollama)").tag("ollama")
				Text("Claude API").tag("claude")
			}

			if settings.summaryEngine == "ollama" { ollamaControls }
			if settings.summaryEngine == "claude" { claudeControls }
			if settings.summaryEngine != "none" { promptEditor }
		}
		.onAppear(perform: refreshOllama)
		.onChange(of: settings.summaryEngine) { refreshOllama() }
	}

	@ViewBuilder private var ollamaControls: some View {
		TextField("Ollama URL", text: $settings.ollamaURL)
		switch ollamaState {
		case .running:
			Label("Ollama is running", systemImage: "checkmark.circle.fill")
				.font(.caption).foregroundStyle(.green)
			HStack {
				TextField("Model (e.g. llama3.1)", text: $settings.ollamaModel)
				if !ollamaModels.isEmpty {
					Picker("", selection: $settings.ollamaModel) {
						Text("-").tag("")
						ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
					}
					.labelsHidden().frame(width: 170)
				}
				Button("Refresh", action: refreshOllama)
			}
			if pulling {
				ProgressView(value: pullProgress >= 0 ? pullProgress : nil) {
					Text(pullStatus).font(.caption)
				}
				.progressViewStyle(.linear)
			} else {
				HStack {
					Picker("Download model", selection: $ollamaModelToPull) {
						ForEach(ollamaSuggestedModels, id: \.self) { Text($0).tag($0) }
					}
					Button("Download") { pullOllamaModel(ollamaModelToPull) }
						.disabled(ollamaModelToPull.isEmpty)
				}
				Label("Recommended for your \(systemRAMGB) GB Mac: \(recommendedOllamaModel(ramGB: systemRAMGB))", systemImage: "sparkles")
					.font(.caption).foregroundStyle(brand)
				if !pullStatus.isEmpty, pullStatus.hasPrefix("Download failed") {
					Text(pullStatus).font(.caption).foregroundStyle(.orange)
				}
			}
			if systemRAMGB < 12 {
				Text("On low-RAM Macs, Claude (above) gives the best quality without local memory limits.")
					.font(.caption).foregroundStyle(.secondary)
			}

		case .installedNotRunning:
			Label("Ollama is installed but not running", systemImage: "exclamationmark.triangle.fill")
				.font(.caption).foregroundStyle(.orange)
			HStack {
				Button("Open Ollama", action: openOllamaApp)
				Button("Re-check", action: refreshOllama)
			}
			Text("Start the Ollama app (it runs in the menu bar), then click Re-check. Or use the Claude engine above.")
				.font(.caption).foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

		case .notInstalled:
			Label("Ollama isn't installed", systemImage: "exclamationmark.triangle.fill")
				.font(.caption).foregroundStyle(.orange)
			HStack {
				Link(destination: URL(string: "https://ollama.com/download")!) {
					Label("Download Ollama", systemImage: "arrow.down.circle")
				}
				.buttonStyle(.borderedProminent).tint(brand)
				Button("Re-check", action: refreshOllama)
			}
			Text("Ollama is a free local model runner. Install it, then click Re-check - or use the Claude engine above (no install, uses your API key).")
				.font(.caption).foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

		case nil:
			HStack(spacing: 6) {
				ProgressView().controlSize(.small)
				Text("Checking Ollama…").font(.caption).foregroundStyle(.secondary)
			}
		}
	}

	@ViewBuilder private var claudeControls: some View {
		SecureField("API key (sk-ant-…)", text: $settings.claudeAPIKey)
		TextField("Model", text: $settings.claudeModel)
		Text("The transcript text is sent to Anthropic when summarizing.")
			.font(.caption).foregroundStyle(.secondary)
	}

	@ViewBuilder private var promptEditor: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Text("Prompt for **\(settings.activeSummaryModel.isEmpty ? "(set a model)" : settings.activeSummaryModel)**")
					.font(.caption)
				Spacer()
				Button("Reset to default") { settings.resetCurrentPrompt() }
					.font(.caption)
					.disabled(!settings.currentPromptIsCustom)
			}
			TextEditor(text: Binding(
				get: { settings.currentPrompt() },
				set: { settings.setCurrentPrompt($0) }))
				.font(.system(.caption, design: .monospaced))
				.frame(minHeight: 300)
				.border(Color.gray.opacity(0.3))
			Text("Each model can have its own prompt. {{transcript}} is replaced.")
				.font(.caption).foregroundStyle(.secondary)
		}
	}

	// MARK: Ollama actions

	private func refreshOllama() {
		guard settings.summaryEngine == "ollama" else { return }
		if ollamaModelToPull.isEmpty { ollamaModelToPull = recommendedOllamaModel(ramGB: systemRAMGB) }
		ollamaState = nil // checking…
		let url = settings.ollamaURL
		DispatchQueue.global().async {
			let state = Ollama.status(url: url)
			let models: [String] = { if case let .running(m) = state { return m } else { return [] } }()
			DispatchQueue.main.async { ollamaState = state; ollamaModels = models }
		}
	}

	/// Download an Ollama model in-app (no terminal) via the pull API, with progress.
	private func pullOllamaModel(_ model: String) {
		guard !pulling, !model.isEmpty else { return }
		pulling = true; pullProgress = 0; pullStatus = "Starting download…"
		let url = settings.ollamaURL
		Task {
			do {
				try await Ollama.pull(model: model, url: url) { p, s in
					Task { @MainActor in pullProgress = p; pullStatus = s }
				}
				await MainActor.run { settings.ollamaModel = model; pulling = false; refreshOllama() }
			} catch {
				await MainActor.run { pulling = false; pullStatus = "Download failed: \(error)" }
			}
		}
	}

	/// Launch the installed Ollama app, then re-check shortly after.
	private func openOllamaApp() {
		let paths = ["/Applications/Ollama.app",
			(NSHomeDirectory() as NSString).appendingPathComponent("Applications/Ollama.app")]
		if let p = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
			NSWorkspace.shared.open(URL(fileURLWithPath: p))
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: refreshOllama)
	}
}