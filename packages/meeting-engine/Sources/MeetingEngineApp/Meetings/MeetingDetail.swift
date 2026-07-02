import SwiftUI
import AppKit

struct MeetingDetail: View {
	let meeting: Meeting
	let content: String
	let busy: Bool
	let progress: Double
	let status: String
	let eta: String
	let onRename: (String) -> Void
	let onRegenerate: (Int?) -> Void
	let onCompress: () -> Void
	let onDelete: () -> Void
	let onCancel: () -> Void
	@EnvironmentObject var settings: AppSettings

	/// True when this meeting still has uncompressed WAV tracks on disk.
	private var hasUncompressedAudio: Bool {
		guard let dir = settings.meetingsDirURL else { return false }
		let base = RecordingController.frontmatterValue("audio", in: content) ?? "recordings/\(meeting.title)"
		return ["mic.wav", "system.wav"].contains {
			FileManager.default.fileExists(atPath: dir.appendingPathComponent(base + "." + $0).path)
		}
	}
	@State private var titleField = ""
	@State private var confirmingDelete = false
	@State private var copied = false
	@State private var tab = 0
	/// Per-meeting remote-speaker count (experimental); seeded from the note.
	@State private var speakerCount = 0
	@StateObject private var player = MeetingAudioPlayer()

	/// The meeting's playable tracks (mic + system), preferring the uncompressed
	/// WAVs but falling back to the compressed m4a after the audio was shrunk.
	private var audioURLs: [URL] {
		guard let dir = settings.meetingsDirURL else { return [] }
		let base = RecordingController.frontmatterValue("audio", in: content) ?? "recordings/\(meeting.title)"
		return ["mic", "system"].compactMap { part -> URL? in
			for ext in ["wav", "m4a"] {
				let u = dir.appendingPathComponent("\(base).\(part).\(ext)")
				if FileManager.default.fileExists(atPath: u.path) { return u }
			}
			return nil
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 8) {
				TextField("Title", text: $titleField)
					.textFieldStyle(.plain)
					.font(.title2.weight(.semibold))
					.onSubmit { onRename(titleField) }
				Spacer()
				Button {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(copyText(for: tab), forType: .string)
					copied = true
					DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
				} label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
					.help(tab == 0 ? "Copy summary" : tab == 1 ? "Copy transcript" : "Copy full note as Markdown")
				Button { onRename(titleField) } label: { Image(systemName: "pencil") }
					.help("Rename")
					.disabled(titleField.trimmingCharacters(in: .whitespaces).isEmpty || titleField == meeting.title)
				Button { onRegenerate(settings.speakerRecognitionEnabled ? speakerCount : nil) } label: { Image(systemName: "arrow.clockwise") }
					.help("Re-transcribe & summarize")
					.disabled(busy)
				if hasUncompressedAudio {
					Button { onCompress() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
						.help("Compress audio to save space (no re-transcribing)")
						.disabled(busy)
				}
				Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
					.help("Delete meeting")
					.disabled(busy)
			}
			.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
			.confirmationDialog("Delete “\(meeting.title)”?", isPresented: $confirmingDelete) {
				Button("Delete meeting & recording", role: .destructive, action: onDelete)
				Button("Cancel", role: .cancel) {}
			} message: {
				Text("This removes the note and its audio recordings. This can't be undone.")
			}

			if meeting.durationSeconds > 0 {
				Label("Duration \(durationLabel(meeting.durationSeconds))", systemImage: "clock")
					.font(.caption).foregroundStyle(.secondary)
					.padding(.horizontal, 20).padding(.bottom, 8)
			}

			// Listen to the meeting: both tracks mixed into one transport.
			if !audioURLs.isEmpty {
				AudioPlayerView(player: player)
			}

			if settings.speakerRecognitionEnabled && !busy {
				HStack(spacing: 6) {
					Image(systemName: "person.2").foregroundStyle(.secondary)
					Picker("Speakers", selection: $speakerCount) {
						Text("Auto-detect").tag(0)
						ForEach(2...8, id: \.self) { Text("\($0)").tag($0) }
					}
					.labelsHidden().fixedSize()
					Text("remote speakers · Re-generate to apply")
						.font(.caption).foregroundStyle(.secondary)
				}
				.font(.caption)
				.padding(.horizontal, 20).padding(.bottom, 8)
			}

			if noteIsOutdated(meeting.appVersion) && !busy {
				HStack(spacing: 10) {
					Image(systemName: "sparkles").foregroundStyle(.orange)
					VStack(alignment: .leading, spacing: 2) {
						Text("Generated with an older version" + (meeting.appVersion.isEmpty ? "" : " (\(meeting.appVersion))"))
							.font(.caption.weight(.semibold))
						Text("This app (\(appVersion)) improves the summary structure & quality. Re-generate to refresh this note.")
							.font(.caption).foregroundStyle(.secondary)
					}
					Spacer(minLength: 8)
					Button("Re-generate") { onRegenerate(settings.speakerRecognitionEnabled ? speakerCount : nil) }
						.controlSize(.small)
				}
				.padding(12)
				.background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
				.padding(.horizontal, 20).padding(.bottom, 8)
			}

			if busy {
				HStack(spacing: 12) {
					VStack(alignment: .leading, spacing: 4) {
						ProgressView(value: progress).progressViewStyle(.linear)
						Text(eta.isEmpty ? status : "\(status)  ·  \(eta)")
							.font(.caption).foregroundStyle(.secondary)
					}
					Button("Stop", role: .destructive) { onCancel() }
						.controlSize(.small)
				}
				.padding(.horizontal, 20).padding(.bottom, 10)
			}

			Divider()

			TabView(selection: $tab) {
				ScrollView {
					NoteView(markdown: content, only: .summary)
						.frame(maxWidth: .infinity, alignment: .leading).padding(20)
				}
				.tabItem { Label("Summary", systemImage: "text.alignleft") }
				.tag(0)

				ScrollView {
					NoteView(markdown: content, only: .transcript)
						.frame(maxWidth: .infinity, alignment: .leading).padding(20)
				}
				.tabItem { Label("Transcript", systemImage: "waveform") }
				.tag(1)

				ScrollView {
					Text(content)
						.font(.system(.body, design: .monospaced))
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading).padding(20)
				}
				.tabItem { Label("Markdown", systemImage: "curlybraces") }
				.tag(2)
			}
			.padding(8)
		}
		.onAppear {
			titleField = meeting.title; speakerCount = meeting.speakerCount
			let urls = audioURLs
			Task { await player.load(urls: urls) }
		}
		.onChange(of: meeting.id) {
			titleField = meeting.title; speakerCount = meeting.speakerCount
			let urls = audioURLs
			Task { await player.load(urls: urls) }
		}
		.onDisappear { player.teardown() }
	}

	/// Markdown to copy for the active tab: summary, transcript, or the full note.
	private func copyText(for tab: Int) -> String {
		switch tab {
		case 0: return Self.summaryMarkdown(content)
		case 1: return Self.transcriptMarkdown(content)
		default: return content
		}
	}

	private static func stripFrontmatter(_ content: String) -> String {
		guard content.hasPrefix("---"),
			let end = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex)
		else { return content }
		return String(content[end.upperBound...])
	}

	/// Title + summary sections (everything before the Transcript), no frontmatter.
	private static func summaryMarkdown(_ content: String) -> String {
		var s = stripFrontmatter(content)
		if let r = s.range(of: "\n## Transcript") { s = String(s[..<r.lowerBound]) }
		return s.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Just the Transcript section body (between `## Transcript` and `## Audio`).
	private static func transcriptMarkdown(_ content: String) -> String {
		let s = stripFrontmatter(content)
		guard let start = s.range(of: "## Transcript") else { return "" }
		var t = String(s[start.upperBound...])
		if let audio = t.range(of: "\n## Audio") { t = String(t[..<audio.lowerBound]) }
		return t.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
