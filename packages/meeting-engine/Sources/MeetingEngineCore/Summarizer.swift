// Meeting summary + action items, from a transcript, via a local Ollama model
// or the Claude API. Both are synchronous (call off the main thread).

import Foundation

public enum SummaryEngine {
	case ollama(url: String, model: String)
	case claude(apiKey: String, model: String)

	/// `provider/model` - recorded in the note so a summary can be traced back to
	/// what produced it (the engine and model are both settings the user changes
	/// over time, so the note is the only place that knows). Never contains the
	/// API key.
	public var label: String {
		switch self {
		case let .ollama(_, model): return "ollama/\(model)"
		case let .claude(_, model): return "claude/\(model)"
		}
	}
}

public enum Summarizer {
	public static let defaultPrompt = """
	You are summarizing a meeting transcript (lines are labeled You/Them). Respond in clean Markdown with EXACTLY these four sections, in this order, and nothing else. Never ask for clarification, refuse, or add any preamble or closing remarks:

	## Short summary
	One or two sentences with the single most important outcome.

	## Summary
	One or two short paragraphs: who met, the main topics, key decisions, and the outcome.

	## Topics discussed
	For each distinct topic or block raised, a "### " subheading naming the topic, then 1-3 short paragraphs and bullet points describing what was said or decided about it.

	## Action items
	- [ ] Each task, with the owner if mentioned. If there are none, write "- None identified."

	Transcript:
	{{transcript}}
	"""

	/// Transcripts longer than this (chars) are summarized via map-reduce instead
	/// of one pass. Set near what fits a 32k-token context (~3.4 chars/token for
	/// Cyrillic, ~110k chars; we leave headroom), so map-reduce only kicks in for
	/// genuinely long meetings - triggering it earlier hurts coverage vs one pass.
	static let mapReduceThresholdChars = 90_000
	/// Per-chunk size in the map phase (~18k tokens - comfortably fits 32k models).
	static let chunkChars = 60_000

	public static func summarize(transcript: String, prompt: String, engine: SummaryEngine) throws -> String {
		// Short/medium meetings: one pass (fast).
		if transcript.count <= mapReduceThresholdChars {
			return try run(fill(prompt, with: transcript), engine: engine, keepAlive: 0)
		}

		// Long meetings: map-reduce. Summarize each chunk into partial notes (model
		// kept loaded between chunks), then combine those into the final summary.
		let chunks = chunkText(transcript, maxChars: chunkChars)
		var partials: [String] = []
		for (i, chunk) in chunks.enumerated() {
			let mapped = try run(mapPrompt(chunk: chunk, part: i + 1, total: chunks.count),
				engine: engine, keepAlive: 300)
			if !mapped.isEmpty { partials.append("## Part \(i + 1) of \(chunks.count)\n\(mapped)") }
		}
		let combined = partials.joined(separator: "\n\n")
		return try run(fill(prompt, with: combined), engine: engine, keepAlive: 0)
	}

	/// Substitute the transcript/notes into a prompt (or append if no placeholder).
	/// Internal rather than private so the tests can exercise it directly.
	static func fill(_ prompt: String, with text: String) -> String {
		prompt.contains("{{transcript}}")
			? prompt.replacingOccurrences(of: "{{transcript}}", with: text)
			: "\(prompt)\n\n\(text)"
	}

	private static func run(_ prompt: String, engine: SummaryEngine, keepAlive: Int) throws -> String {
		switch engine {
		case let .ollama(url, model): return try ollama(prompt, url: url, model: model, keepAlive: keepAlive)
		case let .claude(apiKey, model): return try claude(prompt, apiKey: apiKey, model: model)
		}
	}

	/// Concise per-chunk extraction prompt for the map phase.
	private static func mapPrompt(chunk: String, part: Int, total: Int) -> String {
		"""
		This is part \(part) of \(total) of a meeting transcript (lines labeled You/Them; speech-recognition output). Extract the notable content from THIS part only, as concise Markdown bullet points: key discussion points, decisions, concrete numbers/amounts/dates/limits, named owners, and any action items (with owner and deadline if stated). No intro or conclusion. Write in the same language as the transcript.

		Transcript part:
		\(chunk)
		"""
	}

	/// Split text into <= maxChars chunks, breaking on blank lines where possible.
	/// Internal rather than private so the tests can exercise it directly.
	static func chunkText(_ text: String, maxChars: Int) -> [String] {
		var chunks: [String] = []
		var current = ""
		for para in text.components(separatedBy: "\n\n") {
			if current.isEmpty {
				current = para
			} else if current.count + para.count + 2 <= maxChars {
				current += "\n\n" + para
			} else {
				chunks.append(current)
				current = para
			}
			// A single oversized paragraph: hard-split it.
			while current.count > maxChars {
				let idx = current.index(current.startIndex, offsetBy: maxChars)
				chunks.append(String(current[..<idx]))
				current = String(current[idx...])
			}
		}
		if !current.isEmpty { chunks.append(current) }
		return chunks
	}

	// MARK: Ollama

	private static func ollama(_ prompt: String, url: String, model: String, keepAlive: Int = 0) throws -> String {
		guard !model.isEmpty else { throw SummaryError("no Ollama model set") }
		let endpoint = url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/generate"
		guard let u = URL(string: endpoint) else { throw SummaryError("bad Ollama URL: \(url)") }
		// temperature 0 → deterministic output, so the model reliably emits every
		// required section instead of occasionally dropping one.
		//
		// num_ctx: Ollama defaults to a tiny context (~2k tokens) and silently
		// truncates the prompt to the *end*, which drops the start of long
		// transcripts (summaries then only cover the last part). Size the window
		// to fit the whole prompt - estimate ~2.5 chars/token (conservative for
		// Cyrillic) plus headroom for the output, clamped to a sane range.
		let estTokens = prompt.count / 2 + 2048
		let numCtx = min(32768, max(8192, estTokens))
		let body: [String: Any] = [
			"model": model,
			"prompt": prompt,
			"stream": false,
			"options": ["temperature": 0, "num_ctx": numCtx],
			// Unload the model after use (keep_alive 0) so it doesn't sit in RAM and
			// heat up the machine; during map-reduce we pass a short keep_alive to
			// keep it loaded between chunks, then 0 on the final call.
			"keep_alive": keepAlive,
		]
		let data: Data
		do {
			data = try post(u, headers: ["Content-Type": "application/json"], json: body)
		} catch let e as URLError where [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost].contains(e.code) {
			let hint = Ollama.isInstalled()
				? "Ollama is installed but not running - open the Ollama app to start it."
				: "Ollama isn't installed - download it from ollama.com."
			throw SummaryError("Can't reach Ollama at \(url). \(hint) Or switch the Summary engine to Claude or None in Settings.")
		}
		guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw SummaryError("unexpected Ollama response")
		}
		if let err = obj["error"] as? String { throw SummaryError("Ollama: \(err)") }
		return (obj["response"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// MARK: Claude

	private static func claude(_ prompt: String, apiKey: String, model: String) throws -> String {
		guard !apiKey.isEmpty else { throw SummaryError("no Claude API key set") }
		guard let u = URL(string: "https://api.anthropic.com/v1/messages") else {
			throw SummaryError("bad Claude URL")
		}
		let body: [String: Any] = [
			"model": model,
			"max_tokens": 2048,
			"messages": [["role": "user", "content": prompt]],
		]
		let data = try post(u, headers: [
			"Content-Type": "application/json",
			"x-api-key": apiKey,
			"anthropic-version": "2023-06-01",
		], json: body)
		guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw SummaryError("unexpected Claude response")
		}
		if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
			throw SummaryError("Claude: \(msg)")
		}
		if (obj["stop_reason"] as? String) == "refusal" {
			throw SummaryError("Claude declined to summarize this content")
		}
		let blocks = obj["content"] as? [[String: Any]] ?? []
		let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
		return text.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// MARK: HTTP

	private static func post(_ url: URL, headers: [String: String], json: [String: Any]) throws -> Data {
		var req = URLRequest(url: url, timeoutInterval: 300)
		req.httpMethod = "POST"
		for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
		req.httpBody = try JSONSerialization.data(withJSONObject: json)

		let sem = DispatchSemaphore(value: 0)
		var result: Data?
		var failure: Error?
		var status = 0
		URLSession.shared.dataTask(with: req) { data, response, error in
			if let error = error { failure = error }
			else {
				status = (response as? HTTPURLResponse)?.statusCode ?? 0
				result = data
			}
			sem.signal()
		}.resume()
		sem.wait()

		if let failure = failure { throw failure }
		guard let result = result else { throw SummaryError("no response") }
		if status >= 400 {
			let snippet = String(data: result, encoding: .utf8)?.prefix(300) ?? ""
			throw SummaryError("HTTP \(status): \(snippet)")
		}
		return result
	}
}

public struct SummaryError: Error, CustomStringConvertible {
	public let message: String
	public init(_ message: String) { self.message = message }
	public var description: String { message }
}

/// Local Ollama server state, so the UI can guide install vs. start vs. pull.
public enum OllamaState: Equatable {
	case running(models: [String])  // reachable; lists installed models (may be empty)
	case installedNotRunning        // binary/app present but the server isn't up
	case notInstalled               // no Ollama found on this Mac
}

public enum Ollama {
	/// Installed model names (empty if Ollama isn't reachable).
	public static func installedModels(url: String) -> [String] {
		reachableModels(url: url) ?? []
	}

	/// Detect whether Ollama is running, merely installed, or absent.
	public static func status(url: String) -> OllamaState {
		if let models = reachableModels(url: url) { return .running(models: models) }
		return isInstalled() ? .installedNotRunning : .notInstalled
	}

	/// Whether the Ollama app or CLI exists on this Mac (even if not running).
	public static func isInstalled() -> Bool {
		let fm = FileManager.default
		let home = NSHomeDirectory()
		return [
			"/usr/local/bin/ollama", "/opt/homebrew/bin/ollama", "/usr/bin/ollama",
			"/Applications/Ollama.app",
			(home as NSString).appendingPathComponent("Applications/Ollama.app"),
		].contains { fm.fileExists(atPath: $0) }
	}

	/// nil when unreachable; otherwise the (possibly empty) installed-model list.
	private static func reachableModels(url: String) -> [String]? {
		let endpoint = url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/tags"
		guard let u = URL(string: endpoint) else { return nil }
		let sem = DispatchSemaphore(value: 0)
		var result: [String]?
		URLSession.shared.dataTask(with: u) { data, response, _ in
			defer { sem.signal() }
			guard let data = data, (response as? HTTPURLResponse)?.statusCode == 200,
				let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
			let models = obj["models"] as? [[String: Any]] ?? []
			result = models.compactMap { $0["name"] as? String }.sorted()
		}.resume()
		_ = sem.wait(timeout: .now() + 3)
		return result
	}

	/// Download a model via `POST /api/pull`, reporting fractional progress (0…1,
	/// or negative for an indeterminate phase) plus the current status string.
	public static func pull(model: String, url: String,
		progress: @escaping (Double, String) -> Void) async throws {
		let endpoint = url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/pull"
		guard let u = URL(string: endpoint) else { throw SummaryError("bad Ollama URL: \(url)") }
		var req = URLRequest(url: u, timeoutInterval: 3600)
		req.httpMethod = "POST"
		req.setValue("application/json", forHTTPHeaderField: "Content-Type")
		req.httpBody = try JSONSerialization.data(withJSONObject: ["name": model, "stream": true])

		let (bytes, response) = try await URLSession.shared.bytes(for: req)
		guard (response as? HTTPURLResponse)?.statusCode == 200 else {
			throw SummaryError("Couldn't reach Ollama to download \(model).")
		}
		// Ollama streams newline-delimited JSON: {"status":…, "completed":N, "total":M}.
		for try await line in bytes.lines {
			guard let d = line.data(using: .utf8),
				let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
			if let err = obj["error"] as? String { throw SummaryError("Ollama: \(err)") }
			let status = obj["status"] as? String ?? ""
			if let total = obj["total"] as? Double, let done = obj["completed"] as? Double, total > 0 {
				progress(done / total, status)
			} else {
				progress(-1, status)
			}
		}
		progress(1, "done")
	}
}