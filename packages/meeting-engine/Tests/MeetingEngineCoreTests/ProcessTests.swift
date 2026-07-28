// Cooperative cancellation and the two process runners the pipeline shells out
// with (afconvert, whisper-cli, the diarizer).

import XCTest
@testable import MeetingEngineCore

final class CancelTokenTests: XCTestCase {

	func testStartsUncancelled() {
		XCTAssertFalse(CancelToken().isCancelled)
	}

	func testCancelFlipsTheFlagAndIsIdempotent() {
		let token = CancelToken()
		token.cancel()
		token.cancel()
		XCTAssertTrue(token.isCancelled)
	}

	func testCancelTerminatesTheRegisteredProcess() throws {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
		proc.arguments = ["30"]
		try proc.run()

		let token = CancelToken()
		token.register(proc)
		token.cancel()
		proc.waitUntilExit()

		XCTAssertFalse(proc.isRunning)
		XCTAssertNotEqual(proc.terminationStatus, 0)
	}

	func testClearedProcessIsNoLongerTerminated() throws {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
		proc.arguments = ["0.2"]
		try proc.run()

		let token = CancelToken()
		token.register(proc)
		token.clearProcess()
		token.cancel()
		proc.waitUntilExit()

		// Cancelling after the pipeline released the process must not kill it.
		XCTAssertEqual(proc.terminationStatus, 0)
		XCTAssertTrue(token.isCancelled)
	}

	func testConcurrentReadsAndCancelsAreSafe() {
		let token = CancelToken()
		DispatchQueue.concurrentPerform(iterations: 200) { i in
			if i == 100 { token.cancel() } else { _ = token.isCancelled }
		}
		XCTAssertTrue(token.isCancelled)
	}
}

final class ProcessRunnerTests: XCTestCase {

	func testRunProcessSucceedsForAZeroExit() {
		XCTAssertNoThrow(try runProcess("/bin/echo", ["hello"]))
	}

	func testRunProcessThrowsOnANonZeroExit() {
		XCTAssertThrowsError(try runProcess("/bin/sh", ["-c", "echo nope >&2; exit 3"])) { error in
			let message = "\(error)"
			XCTAssertTrue(message.contains("exited 3"), message)
			XCTAssertTrue(message.contains("nope"), message)
		}
	}

	func testRunProcessThrowsWhenTheBinaryIsMissing() {
		XCTAssertThrowsError(try runProcess("/nonexistent/binary", []))
	}

	func testRunCapturingStdoutReturnsStdout() throws {
		let out = try runCapturingStdout("/bin/echo", ["one", "two"], cancel: nil)
		XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "one two")
	}

	func testRunCapturingStdoutDrainsOutputLargerThanAPipeBuffer() throws {
		// A stuck drain would deadlock here rather than fail an assertion.
		let out = try runCapturingStdout("/bin/sh", ["-c", "yes abcdefghij | head -20000"], cancel: nil)
		XCTAssertEqual(out.split(separator: "\n").count, 20_000)
	}

	func testRunCapturingStdoutReportsStderrOnFailure() {
		XCTAssertThrowsError(try runCapturingStdout("/bin/sh", ["-c", "echo bad >&2; exit 2"], cancel: nil)) { error in
			XCTAssertTrue("\(error)".contains("bad"), "\(error)")
		}
	}

	func testCancelledTokenIsReportedAsCancellationNotFailure() {
		let token = CancelToken()
		token.cancel()
		XCTAssertThrowsError(try runCapturingStdout("/bin/sleep", ["5"], cancel: token)) { error in
			XCTAssertTrue(error is CancelledError, "\(error)")
		}
	}
}