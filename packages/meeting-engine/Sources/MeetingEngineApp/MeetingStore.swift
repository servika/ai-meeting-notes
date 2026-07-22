import Foundation

struct Meeting: Identifiable, Hashable {
	let id: String
	let url: URL
	let title: String
	let modified: Date
	/// The meeting's own date/time (from frontmatter), used for stable ordering.
	let date: Date
	let durationSeconds: Int
	/// The app version that generated this note (empty for pre-versioning notes).
	let appVersion: String
	/// Fixed remote-speaker count for diarization (`speakers:` frontmatter);
	/// 0 means Auto-estimate.
	let speakerCount: Int
	/// Lowercased title + body, for searching.
	let searchHay: String
}

/// Lists meeting notes (`*.md`) in the configured vault folder.
final class MeetingStore: ObservableObject {
	@Published var meetings: [Meeting] = []

	/// Recording-timestamp format used in note frontmatter (`date:`).
	private static let dateFormatter: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "yyyy-MM-dd HH-mm-ss"
		return f
	}()

	func reload(folder: URL?) {
		guard let folder = folder else { meetings = []; return }
		let fm = FileManager.default
		let items = (try? fm.contentsOfDirectory(
			at: folder,
			includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles])) ?? []
		meetings = items
			.filter { $0.pathExtension.lowercased() == "md" }
			.map { url in
				let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
				let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
				let dur = Int(RecordingController.frontmatterValue("duration", in: content) ?? "") ?? 0
				let ver = RecordingController.frontmatterValue("app_version", in: content) ?? ""
				let speakers = Int(RecordingController.frontmatterValue("speakers", in: content) ?? "") ?? 0
				let title = url.deletingPathExtension().lastPathComponent
				// Order by the meeting's own timestamp so re-transcribing (which
				// touches the file's mtime) never reorders the list.
				let dateStr = RecordingController.frontmatterValue("date", in: content) ?? ""
				let date = Self.dateFormatter.date(from: dateStr) ?? mod
				let hay = (title + "\n" + content).lowercased()
				return Meeting(id: url.path, url: url, title: title, modified: mod, date: date, durationSeconds: dur, appVersion: ver, speakerCount: speakers, searchHay: hay)
			}
			.sorted { $0.date > $1.date }
	}

	func content(of meeting: Meeting) -> String {
		(try? String(contentsOf: meeting.url, encoding: .utf8)) ?? ""
	}

	/// Replace the first top-level Markdown heading (`# …`) with `# title`, leaving
	/// the rest of the note untouched. Returns the input unchanged if there's no
	/// such heading (e.g. a note the user stripped it from).
	static func replacingFirstHeading(in content: String, with title: String) -> String {
		var lines = content.components(separatedBy: "\n")
		for i in lines.indices where lines[i].hasPrefix("# ") {
			lines[i] = "# \(title)"
			return lines.joined(separator: "\n")
		}
		return content
	}

	/// Rename a meeting note's file. Audio stays linked via the note's frontmatter.
	/// Returns the renamed Meeting (for reselection), or nil on no-op/failure.
	@discardableResult
	func rename(_ meeting: Meeting, to newName: String) -> Meeting? {
		let safe = newName
			.replacingOccurrences(of: "/", with: "-")
			.replacingOccurrences(of: ":", with: "-")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !safe.isEmpty, safe != meeting.title else { return nil }
		let dir = meeting.url.deletingLastPathComponent()
		let newURL = dir.appendingPathComponent(safe + ".md")
		guard !FileManager.default.fileExists(atPath: newURL.path) else { return nil }
		do { try FileManager.default.moveItem(at: meeting.url, to: newURL) } catch { return nil }
		// Keep the note's `# H1` heading in step with the filename. Without this the
		// body keeps the old title (e.g. "Meeting <stamp>"), which then leaks back
		// into a re-generated note's title and makes duplicates hard to tell apart.
		if let content = try? String(contentsOf: newURL, encoding: .utf8) {
			let updated = Self.replacingFirstHeading(in: content, with: safe)
			if updated != content { try? updated.write(to: newURL, atomically: true, encoding: .utf8) }
		}
		reload(folder: dir)
		return meetings.first { $0.url == newURL }
	}

	/// Delete a meeting: the note and its linked audio tracks. Audio is kept if
	/// another note still references the same recording (guards against wiping
	/// shared audio, e.g. from an older duplicate note).
	func delete(_ meeting: Meeting) {
		let dir = meeting.url.deletingLastPathComponent()
		let content = (try? String(contentsOf: meeting.url, encoding: .utf8)) ?? ""
		let audioBase = RecordingController.frontmatterValue("audio", in: content) ?? "recordings/\(meeting.title)"
		try? FileManager.default.removeItem(at: meeting.url)
		if RecordingController.existingNoteURL(audioBase: audioBase, in: dir) == nil {
			for ext in ["system.wav", "mic.wav", "system.m4a", "mic.m4a"] {
				try? FileManager.default.removeItem(at: dir.appendingPathComponent(audioBase + "." + ext))
			}
		}
		reload(folder: dir)
	}
}