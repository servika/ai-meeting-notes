import SwiftUI

/// Settings → Transcription → Model per language: optional per-language whisper
/// model overrides (e.g. large-v3 for Ukrainian).
struct ModelPerLanguageSection: View {
	@EnvironmentObject var settings: AppSettings
	@State private var overrideLang = "uk"

	/// Language codes that currently have an override, sorted.
	private var overrideLanguages: [String] { settings.modelByLanguage.keys.sorted() }

	/// Languages selectable to add (excluding "auto" and already-overridden ones).
	private var unsetLanguages: [(code: String, name: String)] {
		meetingLanguages.filter { $0.code != "auto" && settings.modelByLanguage[$0.code] == nil }
	}

	var body: some View {
		Section("Model per language (optional)") {
			Text("Pick a downloaded model per language - e.g. large-v3 for Ukrainian. Meetings in any language without an override use the default model above. Download models in the Transcription tab first.")
				.font(.caption).foregroundStyle(.secondary)

			ForEach(overrideLanguages, id: \.self) { lang in
				let current = settings.modelByLanguage[lang] ?? ""
				HStack {
					Text(meetingLanguageName(lang)).frame(width: 90, alignment: .leading)
					Picker("", selection: Binding(
						get: { current },
						set: { v in
							var m = settings.modelByLanguage
							m[lang] = v
							settings.modelByLanguage = m
						})) {
						ForEach(whisperModelOptions(including: current), id: \.path) { Text($0.name).tag($0.path) }
					}
					.labelsHidden()
					Image(systemName: modelFileExists(current) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
						.foregroundStyle(modelFileExists(current) ? .green : .orange)
					Button { settings.removeModel(for: lang) } label: { Image(systemName: "trash") }
						.buttonStyle(.borderless)
				}
			}

			HStack {
				Picker("Add override for", selection: $overrideLang) {
					ForEach(unsetLanguages, id: \.code) { Text($0.name).tag($0.code) }
				}
				Button("Add") {
					settings.setModel(settings.whisperModelPath, for: overrideLang)
					overrideLang = unsetLanguages.first?.code ?? "uk"
				}
				.disabled(unsetLanguages.isEmpty)
			}
		}
	}
}