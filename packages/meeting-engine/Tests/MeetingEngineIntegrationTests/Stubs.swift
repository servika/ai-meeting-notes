// Test doubles for the two things the pipeline shells out to: the whisper CLI
// (a real child process, launched with the real arguments) and the summary
// engine (a real HTTP server on loopback). Everything between them is the
// shipping code path.

import AVFoundation
import Foundation
import XCTest

// MARK: - stub whisper CLI

enum StubWhisper {

	/// A script that behaves like `whisper-cli`: it finds `-of <base>` in its
	/// arguments and writes `<base>.json`.
	///
	/// It answers by call order - system track first, then mic, as the pipeline
	/// transcribes them. (It can't key off the audio path: by then the track has
	/// been converted to a temp 16 kHz copy, exactly as the real CLI sees it.)
	static func emitting(
		in dir: URL,
		system: [(start: Double, end: Double, text: String)],
		mic: [(start: Double, end: Double, text: String)]
	) throws -> String {
		let id = UUID().uuidString
		let systemJSON = dir.appendingPathComponent("stub-system-\(id).json")
		let micJSON = dir.appendingPathComponent("stub-mic-\(id).json")
		let counter = dir.appendingPathComponent("stub-calls-\(id)").path
		try json(for: system).write(to: systemJSON, atomically: true, encoding: .utf8)
		try json(for: mic).write(to: micJSON, atomically: true, encoding: .utf8)
		return try script(in: dir, body: """
			N=$(cat "\(counter)" 2>/dev/null || echo 0)
			N=$((N + 1))
			echo "$N" > "\(counter)"
			if [ "$N" = "1" ]; then SRC="\(systemJSON.path)"; else SRC="\(micJSON.path)"; fi
			cp "$SRC" "$OF.json"
			exit 0
			""")
	}

	/// Exits 0 without writing JSON, the way a silent track comes back.
	static func silent(in dir: URL) throws -> String {
		try script(in: dir, body: "exit 0")
	}

	/// Fails the way a broken model or binary would.
	static func failing(in dir: URL, message: String = "whisper: model load failed") throws -> String {
		try script(in: dir, body: "echo '\(message)' >&2\nexit 1")
	}

	/// Blocks until killed, so cancellation has something to terminate.
	static func hanging(in dir: URL) throws -> String {
		try script(in: dir, body: "sleep 30\nexit 0")
	}

	private static func script(in dir: URL, body: String) throws -> String {
		let path = dir.appendingPathComponent("stub-whisper-\(UUID().uuidString).sh")
		let text = """
			#!/bin/sh
			OF=""
			F=""
			while [ $# -gt 0 ]; do
			  if [ "$1" = "-of" ]; then OF="$2"; fi
			  if [ "$1" = "-f" ]; then F="$2"; fi
			  shift
			done
			\(body)
			"""
		try text.write(to: path, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
		return path.path
	}

	/// whisper's `-oj` output: segments with millisecond offsets.
	static func json(for segments: [(start: Double, end: Double, text: String)]) -> String {
		let items = segments.map { seg in
			"""
			    {
			      "timestamps": { "from": "00:00:00,000", "to": "00:00:00,000" },
			      "offsets": { "from": \(Int(seg.start * 1000)), "to": \(Int(seg.end * 1000)) },
			      "text": \(quoted(seg.text))
			    }
			"""
		}
		return """
			{
			  "systeminfo": "stub",
			  "result": { "language": "en" },
			  "transcription": [
			\(items.joined(separator: ",\n"))
			  ]
			}
			"""
	}

	private static func quoted(_ s: String) -> String {
		let data = try! JSONSerialization.data(withJSONObject: [s])
		let array = String(data: data, encoding: .utf8)!
		return String(array.dropFirst().dropLast())
	}
}

// MARK: - stub summary engine

/// A local HTTP server that answers Ollama's `/api/generate`, so the summary
/// stage runs its real request/response handling. Backed by python3 (present on
/// macOS and on the CI images); tests skip themselves if it's unavailable.
final class StubSummaryServer {

	let url: String
	private let process = Process()
	private let requestLog: URL

	/// Requests the engine received, newest last.
	var requests: [String] {
		(try? String(contentsOf: requestLog, encoding: .utf8))?
			.components(separatedBy: "\u{0}")
			.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
	}

	/// Returns `summary` as an Ollama response.
	static func returning(_ summary: String, in dir: URL) throws -> StubSummaryServer {
		let body = try jsonString(["model": "stub", "response": summary, "done": true])
		return try StubSummaryServer(dir: dir, status: 200, body: body)
	}

	/// Reports a model error the way Ollama does (HTTP 200 with an `error` field).
	static func failing(_ error: String, in dir: URL) throws -> StubSummaryServer {
		try StubSummaryServer(dir: dir, status: 200, body: try jsonString(["error": error]))
	}

	/// Returns an HTTP error status.
	static func erroring(_ status: Int, in dir: URL) throws -> StubSummaryServer {
		try StubSummaryServer(dir: dir, status: status, body: "{\"error\":\"upstream\"}")
	}

	private init(dir: URL, status: Int, body: String) throws {
		guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
			throw XCTSkip("python3 is required for the stub summary server")
		}
		requestLog = dir.appendingPathComponent("summary-requests-\(UUID().uuidString).log")
		FileManager.default.createFile(atPath: requestLog.path, contents: Data())

		let port = Int.random(in: 49_152...65_000)
		url = "http://127.0.0.1:\(port)"
		let scriptURL = dir.appendingPathComponent("stub-summary-\(UUID().uuidString).py")
		try Self.pythonSource.write(to: scriptURL, atomically: true, encoding: .utf8)

		process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
		process.arguments = [scriptURL.path, "\(port)", "\(status)", body, requestLog.path]
		process.standardOutput = Pipe()
		process.standardError = Pipe()
		try process.run()
		try waitUntilReady()
	}

	/// Poll the port until the server answers (any status means it's listening).
	private func waitUntilReady() throws {
		let deadline = Date().addingTimeInterval(10)
		while Date() < deadline {
			var reachable = false
			let sem = DispatchSemaphore(value: 0)
			var req = URLRequest(url: URL(string: url)!, timeoutInterval: 1)
			req.httpMethod = "GET"
			URLSession.shared.dataTask(with: req) { _, response, _ in
				reachable = response != nil
				sem.signal()
			}.resume()
			_ = sem.wait(timeout: .now() + 2)
			if reachable { return }
			Thread.sleep(forTimeInterval: 0.05)
		}
		throw XCTSkip("stub summary server did not come up")
	}

	func stop() {
		process.terminate()
	}

	deinit { if process.isRunning { process.terminate() } }

	private static func jsonString(_ object: [String: Any]) throws -> String {
		String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
	}

	private static let pythonSource = """
		import http.server, sys

		port, status, body, log = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]

		class Handler(http.server.BaseHTTPRequestHandler):
		    def do_POST(self):
		        n = int(self.headers.get('Content-Length', 0))
		        data = self.rfile.read(n)
		        with open(log, 'ab') as f:
		            f.write(data + b'\\x00')
		        payload = body.encode()
		        self.send_response(status)
		        self.send_header('Content-Type', 'application/json')
		        self.send_header('Content-Length', str(len(payload)))
		        self.end_headers()
		        self.wfile.write(payload)

		    def log_message(self, *args):
		        pass

		http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()
		"""
}

// MARK: - settings isolation

/// AppSettings persists to UserDefaults, so a flow test starts from a clean set
/// of keys rather than inheriting whatever the previous test left behind.
func clearSettingsDefaults() {
	for key in [
		"vaultPath", "meetingsFolder", "whisperModelPath", "language", "suggestOnMeetingDetected",
		"autoStopForgotten", "autoStopSilenceMinutes", "useCalendarForMeetings", "transcriptionPrompt",
		"experimentalMode", "featureFlags", "speakerCount", "transcribeMeetings", "summarizeMeetings",
		"audioRetention", "summaryEngine", "ollamaURL", "ollamaModel", "claudeAPIKey", "claudeModel",
		"promptOverrides", "modelByLanguage", "recognizeSpeakers", "summaryPrompt",
	] {
		UserDefaults.standard.removeObject(forKey: key)
	}
}

// MARK: - audio fixtures

enum TestAudio {

	/// Write a real 16 kHz mono WAV of `seconds` so afconvert has something to convert.
	static func writeWAV(at path: String, seconds: Double = 1.0) throws {
		let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
		let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
		let frames = AVAudioFrameCount(seconds * format.sampleRate)
		let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
		buffer.frameLength = frames
		for i in 0..<Int(frames) {
			buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3
		}
		try file.write(from: buffer)
	}
}
