import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

// MARK: - The Codex exchange: timeout, cancellation and its readers

/// The exchange: its watchdog, cancellation, readers and teardown, mostly against a real child. The
/// launch-failure tests sit with `CodexBinaryTests`, whose fixture helpers they use.
final class CodexExchangeTests: XCTestCase {
  /// A child that never writes must hit the watchdog — and be terminated by it. The watchdog ended it, so no
  /// exit is logged for it.
  func testHangingSubprocessTimesOutAndIsTerminated() async throws {
    let fixture = try HangingFixture()
    addTeardownBlock {
      fixture.killSurvivors()
      fixture.cleanUp()
    }
    let timeout: TimeInterval = 2
    let logged = Box<[String]>([])

    let started = Date()
    do {
      _ = try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: timeout, log: { logged.value.append($0) })
      XCTFail("a hanging child must not return a result")
    } catch {
      let elapsed = Date().timeIntervalSince(started)
      // Proves the watchdog fired rather than the child dying on its own.
      XCTAssertGreaterThanOrEqual(elapsed, timeout - 0.5, "should have waited for the watchdog")
      XCTAssertLessThan(elapsed, timeout + 8, "must not block indefinitely")
      if case UsageError.badResponse = error {} else { XCTFail("expected a badResponse timeout, got \(error)") }
    }
    XCTAssertEqual(fixture.waitForExit(), 0, "the child must be terminated on timeout")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(logged.value, [], "a child the watchdog ended did not exit before answering on its own")
  }

  /// A codex that ends before answering has its exit logged: a launcher whose interpreter is missing exits
  /// 127, and without this line the log would say only that the response could not be read.
  func testExitBeforeAnsweringIsLogged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-exit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cases = [("exit 127", "exited with status 127 before answering"), ("kill -9 $$", "was ended by signal 9 before answering")]
    for (index, testCase) in cases.enumerated() {
      let codex = root.appendingPathComponent("codex-\(index)")
      try "#!/bin/sh\n\(testCase.0)\n".write(to: codex, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
      let logged = Box<[String]>([])
      do {
        _ = try await CodexUsageProvider.readRateLimits(binary: codex.path, timeout: 5, log: { logged.value.append($0) })
        XCTFail("\(testCase.0): a codex that ends must not return a result")
      } catch UsageError.badResponse {} catch { XCTFail("\(testCase.0): expected badResponse, got \(error)") }
      // The exit can be logged once the child is reaped, just after the exchange has finished.
      for _ in 0..<200 where logged.value.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertEqual(logged.value, ["[codex] \(codex.path) \(testCase.1)"])
    }
  }

  /// Cancelling must unblock immediately and tear the child down.
  func testCancellationTerminatesTheChild() async throws {
    let fixture = try HangingFixture()
    addTeardownBlock {
      fixture.killSurvivors()
      fixture.cleanUp()
    }

    let task = Task { try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: 120, log: discardLog) }
    // Let it actually launch, so cancellation races a live process.
    let launchDeadline = Date().addingTimeInterval(5)
    while fixture.liveProcessCount() == 0, Date() < launchDeadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertGreaterThan(fixture.liveProcessCount(), 0, "the child must be running when the cancellation lands")
    let started = Date()
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("cancellation should surface an error")
    } catch is CancellationError {
      XCTAssertLessThan(Date().timeIntervalSince(started), 10, "cancellation must not wait out the 120s timeout")
    } catch { XCTFail("expected the cancellation, got \(error)") }
    XCTAssertEqual(fixture.waitForExit(), 0, "the child must be terminated on cancellation")
  }

  /// A cancel that lands between the exchange's setup and `process.run()` must not leak the child launched
  /// after it: `finish` found no running process to terminate, so `start()`'s re-check after the launch is
  /// what reaps it. The hook cancels at exactly that point, which no timing could steer.
  func testCancellationDuringLaunchDoesNotLeak() async throws {
    let fixture = try HangingFixture()
    addTeardownBlock {
      fixture.killSurvivors()
      fixture.cleanUp()
    }

    let logged = Box<[String]>([])
    let runningAtTheHook = Box(-1)
    let task = Task {
      try await CodexUsageProvider.readRateLimits(
        binary: fixture.url.path, timeout: 120, log: { logged.value.append($0) },
        beforeLaunch: {
          runningAtTheHook.value = fixture.liveProcessCount()
          withUnsafeCurrentTask { $0?.cancel() }
        })
    }
    do {
      _ = try await task.value
      XCTFail("the cancellation should surface")
    } catch is CancellationError {} catch { XCTFail("expected the cancellation, got \(error)") }
    XCTAssertEqual(runningAtTheHook.value, 0, "the hook runs before the launch, or the re-check is not what reaps the child")
    XCTAssertFalse(logged.value.contains { $0.contains("could not start") }, "the child was launched; logged: \(logged.value)")
    XCTAssertEqual(fixture.waitForExit(), 0, "a child launched after the cancellation landed must still be reaped")
  }

  /// A read whose task is cancelled before it starts ends at once, as the cancellation, and launches
  /// nothing: `finish` ran before there was a continuation to resume, so `start()`'s opening check is what
  /// resumes it. Without that check the read would never return, so the test waits with a timeout.
  func testReadCancelledBeforeItStartsEndsWithoutLaunching() async throws {
    let ran = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-ran-\(UUID().uuidString)")
    let fixture = try HangingFixture(prelude: "touch '\(ran.path)'\n")
    addTeardownBlock {
      fixture.killSurvivors()
      fixture.cleanUp()
      try? FileManager.default.removeItem(at: ran)
    }
    let ended = expectation(description: "the read ends")
    let outcome = Box<Error?>(nil)
    Task {
      withUnsafeCurrentTask { $0?.cancel() }
      do { _ = try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: 120, log: discardLog) } catch {
        outcome.value = error
      }
      ended.fulfill()
    }
    await fulfillment(of: [ended], timeout: 5)
    XCTAssertTrue(outcome.value is CancellationError, "expected the cancellation, got \(String(describing: outcome.value))")
    XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path), "nothing was launched")
  }

  /// A child that closes its stderr and keeps running must not spin the drain. At end-of-file a
  /// `readabilityHandler` is called again and again until it is cleared, so a drain that never clears
  /// itself burns a core until the exchange finishes.
  func testClosedStandardErrorDoesNotSpin() async throws {
    let fixture = try HangingFixture(closingStandardError: true)
    addTeardownBlock {
      fixture.killSurvivors()
      fixture.cleanUp()
    }
    let started = Date()
    let before = processCPUSeconds()
    do {
      _ = try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: 1.5, log: discardLog)
      XCTFail("a child that never answers must not return a result")
    } catch UsageError.badResponse {} catch { XCTFail("expected a badResponse timeout, got \(error)") }
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1, "a closed stderr must not end the exchange before its timeout")
    XCTAssertLessThan(processCPUSeconds() - before, 0.5, "a drain at end-of-file must stop reading, not spin until the timeout")
    XCTAssertEqual(fixture.waitForExit(), 0, "the child must be terminated on timeout")
  }

  /// A child that writes more than a pipe buffer to stderr before it answers still answers: the drain
  /// keeps stderr moving, where an unread pipe would block the child mid-write until the watchdog fired.
  func testChattyStandardErrorDoesNotBlockTheAnswer() async throws {
    let fixture = try HangingFixture(prelude: "head -c 262144 /dev/zero >&2\nprintf '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\\n'\n")
    addTeardownBlock {
      fixture.killSurvivors()
      fixture.cleanUp()
    }
    _ = try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: 5, log: discardLog)
    XCTAssertEqual(fixture.waitForExit(), 0, "the child must be terminated once it has answered")
  }

  /// A child that closes its stdout and stays up ends the exchange at that end-of-file, as a bad response,
  /// well inside its timeout: it has not exited, so nothing else ends the exchange before the watchdog. The
  /// SIGTERM that then ends it is TokenRation's, so no exit is logged for it.
  func testClosedStandardOutputEndsTheExchange() async throws {
    let fixture = try HangingFixture(closingStandardOutput: true)
    addTeardownBlock {
      fixture.killSurvivors()
      fixture.cleanUp()
    }
    let logged = Box<[String]>([])
    let started = Date()
    do {
      _ = try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: 30, log: { logged.value.append($0) })
      XCTFail("a child whose stdout has closed must not return a result")
    } catch UsageError.badResponse {} catch { XCTFail("expected badResponse, got \(error)") }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10, "end-of-file on stdout must end the exchange without waiting for the timeout")
    XCTAssertEqual(fixture.waitForExit(), 0, "the child must be terminated once the exchange ends")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(logged.value.contains { $0.contains("before answering") }, "logged: \(logged.value)")
  }

  /// A child that exits while a process it started holds its stdout open ends the exchange at its exit, as a
  /// bad response, well inside the timeout: its stdout never reaches end-of-file, so only the termination
  /// handler can end the exchange before the watchdog.
  func testChildExitingWhileItsStdoutIsHeldEndsTheExchange() async throws {
    let holder = try HangingFixture()
    let launcher = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-exits-\(UUID().uuidString).sh")
    try "#!/bin/sh\n'\(holder.url.path)' &\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
    addTeardownBlock {
      holder.killSurvivors()
      holder.cleanUp()
      try? FileManager.default.removeItem(at: launcher)
    }
    let started = Date()
    do {
      _ = try await CodexUsageProvider.readRateLimits(binary: launcher.path, timeout: 30, log: discardLog)
      XCTFail("a child that exits without answering must not return a result")
    } catch UsageError.badResponse {} catch { XCTFail("expected badResponse, got \(error)") }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the child's exit must end the exchange without waiting for the timeout")
    XCTAssertGreaterThan(holder.liveProcessCount(), 0, "the holder must still be running, or nothing held the child's stdout open")
  }

  /// Each reader clears itself at end-of-file and reports the end once: a `readabilityHandler` left
  /// installed there is called again and again, about a million times a second.
  func testReaderClearsItselfAtEndOfFile() throws {
    let pipe = Pipe()
    let ends = Box(0)
    let ended = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = CodexUsageProvider.reader(
      onChunk: { _ in },
      onEnd: {
        ends.value += 1
        ended.signal()
      })
    try pipe.fileHandleForWriting.close()
    XCTAssertEqual(ended.wait(timeout: .now() + 2), .success, "end-of-file is reported")
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertEqual(ends.value, 1, "and only once")
    XCTAssertNil(pipe.fileHandleForReading.readabilityHandler, "the reader cleared itself")
  }

  /// CPU time this process has used, user and system, in seconds.
  private func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
  }

  /// A child that exits without answering ends the exchange promptly, at its stdout's end-of-file or its
  /// exit, whichever lands first, rather than at the watchdog, and as a bad response: it started, so it is
  /// not a codex that could not start.
  func testProcessExitingWithoutAnswerFailsPromptly() async {
    let started = Date()
    do {
      _ = try await CodexUsageProvider.readRateLimits(binary: "/usr/bin/true", timeout: 30, log: discardLog)
      XCTFail("a child that exits without answering must not return a result")
    } catch UsageError.badResponse {} catch { XCTFail("expected badResponse, got \(error)") }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10, "EOF should resolve the exchange without waiting for the timeout")
  }
}
