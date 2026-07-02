import SwiftUI

/// Settings → About: version, update check, and project links.
struct AboutSection: View {
	@EnvironmentObject var updates: UpdateChecker

	var body: some View {
		Section("About") {
			VStack(spacing: 10) {
				Text("AI Meeting Notes").font(.headline)
				Text("Version \(appBundleVersion)")
					.font(.caption).foregroundStyle(.secondary)

				if updates.updateAvailable, let v = updates.latestVersion, let url = updates.releaseURL {
					Link(destination: url) {
						Label("Update available: \(v) - Download", systemImage: "arrow.down.circle.fill")
					}
					.buttonStyle(.borderedProminent).controlSize(.small).tint(brand)
				} else {
					HStack(spacing: 8) {
						Button(updates.checking ? "Checking…" : "Check for updates") { updates.check() }
							.controlSize(.small).disabled(updates.checking)
						if !updates.status.isEmpty {
							Text(updates.status).font(.caption).foregroundStyle(.secondary)
						}
					}
				}

				HStack(spacing: 18) {
					Link(destination: URL(string: "https://github.com/servika/ai-meeting-notes")!) {
						Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
					}
					.help("Project on GitHub")
					Link(destination: URL(string: "https://github.com/servika/ai-meeting-notes/blob/main/THIRD-PARTY-NOTICES.md")!) {
						Label("Credits & licenses", systemImage: "doc.text")
					}
					.help("Open-source components this app is built on")
				}
				.buttonStyle(.borderless)
				.tint(brand)
				.padding(.top, 4)
				Text("Made by Serg Bataev")
					.font(.caption2).foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 8)
		}
	}
}