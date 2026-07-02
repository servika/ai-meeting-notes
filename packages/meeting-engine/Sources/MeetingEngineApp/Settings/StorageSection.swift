import SwiftUI
import AppKit

/// Settings → General → Storage: where notes are saved.
struct StorageSection: View {
	@EnvironmentObject var settings: AppSettings

	var body: some View {
		Section("Storage") {
			HStack {
				TextField("Notes folder", text: $settings.vaultPath)
				Button("Choose…", action: chooseVault)
			}
			TextField("Meetings subfolder", text: $settings.meetingsFolder)
			Text("Meetings are saved as Markdown in this folder. Any folder works.")
				.font(.caption).foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private func chooseVault() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.allowsMultipleSelection = false
		panel.prompt = "Choose Folder"
		if panel.runModal() == .OK, let url = panel.url { settings.vaultPath = url.path }
	}
}