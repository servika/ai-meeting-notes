import SwiftUI
import AppKit

/// Renders a meeting note's markdown as styled sections (Summary, Action items
/// as checkboxes, Transcript with speaker labels).
struct NoteView: View {
	enum Filter { case all, summary, transcript }
	let markdown: String
	var only: Filter = .all

	private var visibleSections: [Section] {
		sections().filter { sec in
			// The Audio section is `![[…]]` embeds for Obsidian; the app hides it.
			if sec.title.lowercased() == "audio" { return false }
			switch only {
			case .all: return true
			case .summary: return sec.title.lowercased() != "transcript"
			case .transcript: return sec.title.lowercased() == "transcript"
			}
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			ForEach(Array(visibleSections.enumerated()), id: \.offset) { _, sec in
				let isCard = sec.title.lowercased() != "transcript"
				VStack(alignment: .leading, spacing: 10) {
					Label(sec.title, systemImage: icon(for: sec.title))
						.font(.headline)
						.foregroundStyle(brand)
					body(for: sec)
				}
				.padding(isCard ? 16 : 0)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background {
					if isCard { RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)) }
				}
			}
		}
		.frame(maxWidth: 780, alignment: .leading)
		.textSelection(.enabled)
	}

	private struct Section { let title: String; let lines: [String] }

	private func icon(for title: String) -> String {
		switch title.lowercased() {
		case "short summary": return "text.quote"
		case "summary": return "text.alignleft"
		case "topics discussed", "topics", "discussion": return "bubble.left.and.bubble.right"
		case "action items": return "checklist"
		case "transcript": return "waveform"
		default: return "doc.text"
		}
	}

	@ViewBuilder
	private func body(for sec: Section) -> some View {
		let title = sec.title.lowercased()
		if title == "action items" {
			VStack(alignment: .leading, spacing: 6) {
				ForEach(Array(sec.lines.enumerated()), id: \.offset) { _, line in actionItem(line) }
			}
		} else if title == "transcript" {
			let lines = sec.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
			VStack(alignment: .leading, spacing: 8) {
				ForEach(Array(lines.enumerated()), id: \.offset) { _, line in transcriptLine(line) }
			}
		} else if title == "topics discussed" || title == "topics" || title == "discussion" {
			topicBlocks(sec.lines)
		} else {
			richText(sec.lines)
		}
	}

	/// Each `### topic` becomes its own prominent block (numbered heading +
	/// accent bar + its paragraphs/bullets), so topics stand apart from the
	/// summary prose.
	@ViewBuilder
	private func topicBlocks(_ lines: [String]) -> some View {
		let blocks = groupTopics(lines)
		VStack(alignment: .leading, spacing: 12) {
			ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
				HStack(alignment: .top, spacing: 12) {
					RoundedRectangle(cornerRadius: 3).fill(brand).frame(width: 4)
					VStack(alignment: .leading, spacing: 8) {
						if !block.title.isEmpty {
							HStack(alignment: .firstTextBaseline, spacing: 8) {
								Text("\(i + 1)")
									.font(.caption.weight(.bold))
									.foregroundStyle(.white)
									.frame(width: 22, height: 22)
									.background(Circle().fill(brand))
								Text(block.title)
									.font(.title3.weight(.semibold))
									.foregroundStyle(.primary)
							}
						}
						richText(block.lines)
							.font(.body)
					}
				}
				.padding(14)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 10).fill(brand.opacity(0.06)))
			}
		}
	}

	private func groupTopics(_ lines: [String]) -> [(title: String, lines: [String])] {
		var result: [(String, [String])] = []
		for raw in lines {
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line.hasPrefix("### ") {
				result.append((String(line.dropFirst(4)), []))
			} else if !line.isEmpty {
				if result.isEmpty { result.append(("", [])) }
				result[result.count - 1].1.append(raw)
			}
		}
		return result
	}

	/// Renders paragraphs, `#`-headings, `- `/`* ` bullets, and `1.` numbered lists.
	@ViewBuilder
	private func richText(_ lines: [String]) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
				let line = raw.trimmingCharacters(in: .whitespaces)
				if let heading = headingText(line) {
					Text(heading)
						.font(.subheadline.weight(.semibold))
						.padding(.top, 4)
				} else if line.hasPrefix("- ") || line.hasPrefix("* ") {
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Text("•").foregroundStyle(.secondary)
						inline(String(line.dropFirst(2)))
					}
				} else if let (num, rest) = numberedItem(line) {
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Text(num).foregroundStyle(.secondary).monospacedDigit()
						inline(rest)
					}
				} else if !line.isEmpty {
					inline(line)
				}
			}
		}
	}

	/// Strip a leading run of `#` (a Markdown heading) and return the text, or nil.
	private func headingText(_ line: String) -> String? {
		guard line.hasPrefix("#") else { return nil }
		let hashes = line.prefix(while: { $0 == "#" })
		let after = line.dropFirst(hashes.count)
		guard after.hasPrefix(" ") else { return nil }
		return String(after).trimmingCharacters(in: .whitespaces)
	}

	/// Parse a `1. text` / `1) text` numbered-list item into (number, text).
	private func numberedItem(_ line: String) -> (String, String)? {
		let digits = line.prefix(while: { $0.isNumber })
		guard !digits.isEmpty else { return nil }
		let after = line.dropFirst(digits.count)
		guard after.hasPrefix(". ") || after.hasPrefix(") ") else { return nil }
		return ("\(digits).", String(after.dropFirst(2)))
	}

	@ViewBuilder
	private func actionItem(_ line: String) -> some View {
		let t = line.trimmingCharacters(in: .whitespaces)
		if t.hasPrefix("- [ ]") || t.hasPrefix("- [x]") || t.hasPrefix("- [X]") {
			let checked = t.hasPrefix("- [x]") || t.hasPrefix("- [X]")
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Image(systemName: checked ? "checkmark.circle.fill" : "circle")
					.foregroundStyle(checked ? .green : .secondary)
				inline(String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces))
			}
		} else if t.hasPrefix("- ") {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text("•").foregroundStyle(.secondary)
				inline(String(t.dropFirst(2)))
			}
		} else {
			inline(t)
		}
	}

	@ViewBuilder
	private func transcriptLine(_ line: String) -> some View {
		let (time, afterTime) = splitTimestamp(line)
		if let (speaker, rest) = speakerSplit(afterTime) {
			HStack(alignment: .top, spacing: 10) {
				VStack(alignment: .leading, spacing: 2) {
					Text(speaker)
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.white)
						.padding(.horizontal, 7).padding(.vertical, 2)
						.background(speaker == "You" ? brand : Color.gray, in: Capsule())
					if let time { Text(time).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
				}
				.frame(width: 54, alignment: .leading)
				inline(rest).frame(maxWidth: .infinity, alignment: .leading)
			}
		} else {
			// Continuation paragraph of the same speaker: timestamp gutter + text.
			HStack(alignment: .top, spacing: 10) {
				Text(time ?? "")
					.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
					.frame(width: 54, alignment: .leading)
				inline(afterTime).frame(maxWidth: .infinity, alignment: .leading)
			}
		}
	}

	private func speakerSplit(_ line: String) -> (String, String)? {
		for s in ["You", "Them"] {
			let p = "**\(s):**"
			if line.hasPrefix(p) { return (s, String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)) }
		}
		return nil
	}

	/// Pull a leading `[m:ss]` / `[h:mm:ss]` timestamp off a transcript line.
	private func splitTimestamp(_ line: String) -> (String?, String) {
		guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return (nil, line) }
		let ts = String(line[line.index(after: line.startIndex)..<close])
		guard ts.contains(":"), ts.allSatisfy({ $0.isNumber || $0 == ":" }) else { return (nil, line) }
		let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
		return (ts, rest)
	}

	private func inline(_ s: String) -> Text {
		if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
			return Text(a)
		}
		return Text(s)
	}

	/// Strip frontmatter + the H1, then split into `## ` sections.
	private func sections() -> [Section] {
		var text = markdown
		if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
			text = String(text[end.upperBound...])
		}
		var result: [Section] = []
		var current: String?
		var buffer: [String] = []
		var preamble: [String] = []
		func trimEdges(_ lines: [String]) -> [String] {
			Array(lines.drop(while: { $0.isEmpty }).reversed().drop(while: { $0.isEmpty }).reversed())
		}
		func flush() {
			if let c = current {
				result.append(Section(title: c, lines: trimEdges(buffer)))
			}
			buffer = []
		}
		for raw in text.components(separatedBy: "\n") {
			if raw.hasPrefix("## ") { flush(); current = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
			else if raw.hasPrefix("# ") { continue }
			else if current != nil { buffer.append(raw) }
			else { preamble.append(raw) } // content before the first "## " heading
		}
		flush()
		// Some models emit the summary as plain text with no "## " headings; that
		// content lands in `preamble` and would otherwise be invisible in the
		// Summary tab. Surface it as a Summary section (only when there isn't a
		// real summary section already).
		let lead = trimEdges(preamble)
		// "transcript" and "audio" aren't summary content, so if those are the only
		// real sections, treat the preamble as the summary.
		let hasSummarySection = result.contains {
			let t = $0.title.lowercased()
			return t != "transcript" && t != "audio"
		}
		if !lead.isEmpty, !hasSummarySection {
			result.insert(Section(title: "Summary", lines: lead), at: 0)
		}
		return result
	}
}