import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

/// A provider stub that returns whatever the test asks for. Its `provider` namespaces the persisted keys
/// and log lines and picks which restored reading applies. `UsageModel`'s error
/// handling treats every provider alike, so a model test may pair it with any error, whichever provider
/// could throw that error in production.
struct StubProvider: UsageProviding {
  let provider: Provider
  let outcome: @Sendable () throws -> UsageSnapshot
  /// Stands in for credentials that are missing or expired without an attempt being made.
  var credentialFault: UsageError? = nil
  /// Stands in for the credentials on disk; read through a box so a test can swap them
  /// mid-flight the way the CLI rewriting the Keychain does.
  var credentials: Box<String>? = nil

  func fetch() async throws -> UsageSnapshot { try outcome() }
  func credentialFingerprint() async -> String? { credentials?.value }
  func credentialProblem() async -> UsageError? { credentialFault }
}

/// A value a `@Sendable` provider can read and a test can change.
final class Box<T: Sendable>: Sendable {
  private let stored: OSAllocatedUnfairLock<T>
  init(_ value: T) { stored = OSAllocatedUnfairLock(initialState: value) }
  var value: T {
    get { stored.withLock { $0 } }
    set { stored.withLock { $0 = newValue } }
  }
}

/// Mutable flag usable from a `@Sendable` closure.
final class Flag: Sendable {
  private let value = OSAllocatedUnfairLock(initialState: false)
  func set() { value.withLock { $0 = true } }
  var isSet: Bool { value.withLock { $0 } }
}

/// Where the models and preferences under test log: nowhere, so the suite never writes the user's log.
let discardLog: @Sendable (_ message: String) -> Void = { _ in }

/// A network a test controls, so a model under test never sees the network of the Mac that runs it: online
/// until the test reports otherwise.
@MainActor final class StubNetwork: NetworkMonitoring {
  private var update: (@MainActor (_ offline: Bool) async -> Void)?

  func start(reporting update: @escaping @MainActor (_ offline: Bool) async -> Void) { self.update = update }

  /// Reports a change as the system would, and returns once the model has acted on it.
  func report(offline: Bool) async { await update?(offline) }
}

/// Where the defaults suites `makeDefaults` creates are kept: a directory of this run's own under the
/// temporary directory. A defaults suite named by an absolute path is stored at that path with `.plist`
/// appended rather than in the user's `~/Library/Preferences`, where a defaults suite per test per run would
/// otherwise stay for good: removing a domain leaves its file there, and the preferences daemon can rewrite
/// one it has just lost. The directory goes when the run ends.
let defaultsSuitesDirectory: URL = {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-test-defaults-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  DefaultsSuitesCleanup.install(removing: directory)
  return directory
}()

/// A defaults suite of its own for one test, kept in `defaultsSuitesDirectory`, so persisted state cannot
/// leak between tests or into the user's preferences. A test that simulates a relaunch reuses the defaults
/// suite it was given.
func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
  let path = defaultsSuitesDirectory.appendingPathComponent(name).path
  let defaults = UserDefaults(suiteName: path)!
  defaults.removePersistentDomain(forName: path)
  return defaults
}

/// Removes `defaultsSuitesDirectory` when the run ends. A test sees the removal on a scratch directory; the
/// registration, `install(removing:)`, cannot be tested from inside the run it observes, which ends only
/// after its last test.
final class DefaultsSuitesCleanup: NSObject, XCTestObservation {
  private let directory: URL

  init(directory: URL) { self.directory = directory }

  static func install(removing directory: URL) {
    let add: @Sendable () -> Void = { XCTestObservationCenter.shared.addTestObserver(DefaultsSuitesCleanup(directory: directory)) }
    // Registered on the main thread, where XCTest runs its tests, since `XCTestObservationCenter` documents
    // no thread safety for registering an observer: neither its header nor XCTest's API notes carry an
    // actor or thread annotation.
    if Thread.isMainThread { add() } else { DispatchQueue.main.sync(execute: add) }
  }

  func testBundleDidFinish(_ testBundle: Bundle) { try? FileManager.default.removeItem(at: directory) }
}

func snapshot(_ id: String) -> UsageSnapshot {
  UsageSnapshot(
    metrics: [
      DisplayMetric(
        id: id, provider: .codex, title: "T", symbolName: "clock", barText: "1%", valueText: "1% used", fraction: 0.01, severity: .normal,
        resetsAt: nil)
    ], updatedAt: Date())
}

// MARK: - Stubbed network

/// Serves every request of every session `session(answering:)` makes, so no test reaches the network. One
/// process-wide handler serves them all, the one the latest `session(answering:)` call installed, so it
/// serves one test at a time, which is how `swift test` runs them; each test installs its own before it
/// asks anything.
final class StubURLProtocol: URLProtocol {
  typealias Handler = @Sendable (_ request: URLRequest) -> Result<(HTTPURLResponse, Data), Error>
  private static let handler = OSAllocatedUnfairLock<Handler?>(initialState: nil)

  /// A session whose every request `answer` serves.
  static func session(answering answer: @escaping Handler) -> URLSession {
    handler.withLock { $0 = answer }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  /// An answer of `status`, with `headers` and `body`, to whatever was asked.
  static func respond(_ status: Int, headers: [String: String] = [:], body: String = "") -> Handler {
    { request in
      .success((HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, Data(body.utf8)))
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    guard let answer = Self.handler.withLock({ $0 }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    switch answer(request) {
    case .success(let (response, data)):
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
    }
  }
}

// MARK: - Hanging fixture

/// A real hanging child. `/bin/sleep` was useless here: `CodexExchange` always appends
/// `app-server`, so `sleep app-server` died instantly with "invalid time interval" and the
/// tests passed without ever reaching the watchdog or the cancellation path.
struct HangingFixture {
  let url: URL
  /// Unique, so `pgrep -f` can prove the child is gone afterwards.
  var marker: String { url.lastPathComponent }

  /// `directory` is where the script is written, for a test that needs it in a particular directory on a
  /// `PATH`; `ignoringTermination` makes it ignore SIGTERM, so of the signals the suite sends only SIGKILL ends it; `closingStandardOutput`
  /// and `closingStandardError` make it close that stream first and stay up regardless; `prelude` is shell it
  /// runs after all of these, so a prelude that reports the fixture ready does so with its trap already set.
  init(
    directory: URL = FileManager.default.temporaryDirectory, ignoringTermination: Bool = false, closingStandardOutput: Bool = false,
    closingStandardError: Bool = false, prelude: String = ""
  ) throws {
    url = directory.appendingPathComponent("tokenration-hang-\(UUID().uuidString).sh")
    // Ignores its arguments and stdin, and stays alive until signalled.
    let preamble =
      (ignoringTermination ? "trap '' TERM\n" : "") + (closingStandardOutput ? "exec 1>&-\n" : "")
      + (closingStandardError ? "exec 2>&-\n" : "") + prelude
    try "#!/bin/sh\n\(preamble)while :; do sleep 0.2; done\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: url) }

  /// Kills anything still running this fixture, so a test that fails part-way cannot leak it.
  func killSurvivors() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = ["-KILL", "-f", marker]
    guard (try? process.run()) != nil else { return }
    process.waitUntilExit()
  }

  /// How many live processes still match this fixture.
  func liveProcessCount() -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", marker]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return -1 }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n").filter { !$0.isEmpty }.count
  }

  /// pgrep also matches this test process's own argv in some setups; poll for it to settle.
  func waitForExit(timeout: TimeInterval = 5) -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    var count = liveProcessCount()
    while count > 0, Date() < deadline {
      usleep(100_000)
      count = liveProcessCount()
    }
    return count
  }
}
