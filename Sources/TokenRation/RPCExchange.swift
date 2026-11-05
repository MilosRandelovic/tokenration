import Foundation

/// What one exchange with a provider's CLI sends and expects: the CLI is spawned, sent an `initialize` request
/// (id 1) and a query (id 2) as newline-delimited JSON-RPC, and the exchange resumes on the reply to the query.
struct RPCRequest: Sendable {
  /// Names the CLI in log lines, as `[label]`.
  let label: String
  let arguments: [String]
  /// Variables set in the child's environment on top of TokenRation's own.
  let environment: [String: String]
  /// The `initialize` request, id 1.
  let initialize: String
  /// The query, id 2.
  let query: String
  /// Whether the query waits for the reply to `initialize`. A CLI that sets up its sign-in while it initializes
  /// would otherwise answer a query sent with it from credentials it has not yet renewed.
  let queryAfterInitialize: Bool
  /// What a CLI that cannot be started reports.
  let unavailable: UsageError
  /// What an error reply to either request reports.
  let rejection: @Sendable (_ error: RPCError) -> UsageError
}

/// The `error` member of a JSON-RPC reply.
struct RPCError: Decodable, Sendable {
  let code: Int?
  let message: String?
  /// Free-form detail, kept only when it is a string, which is how the CLIs here explain themselves.
  let data: String?

  enum CodingKeys: String, CodingKey {
    case code
    case message
    case data
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try? container.decode(Int.self, forKey: .code)
    message = try? container.decode(String.self, forKey: .message)
    data = try? container.decode(String.self, forKey: .data)
  }

  /// The message and its detail, for the log.
  var summary: String { [message, data].compactMap { $0 }.joined(separator: ": ") }
}

/// Runs one exchange with a CLI over stdio: spawn, initialize, query, resume.
///
/// Reads are driven by `readabilityHandler` rather than `FileHandle.availableData` in a loop.
/// `availableData` blocks until data or EOF, so a hung child that never writes anything would
/// park the reader forever: the deadline is never re-checked, the continuation never resumes,
/// the child is never reaped, and the provider stays stuck "refreshing".
/// Here a watchdog fires independently of any output, and every exit path terminates and reaps
/// the child exactly once.
///
/// `@unchecked Sendable` because its callbacks run on Foundation's queues: `continuation`, `buffer`, `isFinished`
/// and `querySent` are read and written only under `lock`, and `finish` resumes the continuation at most once.
/// Nothing but discipline holds that: the compiler stops checking this type, so an access added outside `lock`
/// compiles, and no test reliably catches the race it opens.
final class RPCExchange<Answer: Decodable & Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let errors = Pipe()
  private let request: RPCRequest
  private var continuation: CheckedContinuation<Answer, Error>?
  private var buffer = Data()
  private var isFinished = false
  private var querySent = false
  private let log: @Sendable (_ message: String) -> Void
  private let beforeLaunch: (@Sendable () -> Void)?

  /// `searchPath`, when given, replaces the child's `PATH`; the child otherwise inherits TokenRation's.
  /// `beforeLaunch`, nil in production, runs just before the child is launched, so a test can cancel there.
  init(
    binary: String, request: RPCRequest, searchPath: String?, log: @escaping @Sendable (_ message: String) -> Void,
    beforeLaunch: (@Sendable () -> Void)?
  ) {
    self.request = request
    self.log = log
    self.beforeLaunch = beforeLaunch
    _ = RPCPipes.ignoreBrokenPipes
    process.executableURL = URL(fileURLWithPath: binary)
    if searchPath != nil || !request.environment.isEmpty {
      var environment = ProcessInfo.processInfo.environment
      if let searchPath { environment["PATH"] = searchPath }
      environment.merge(request.environment) { _, set in set }
      process.environment = environment
    }
    process.arguments = request.arguments
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
  }

  /// Runs the exchange to its end: an answer, or the error that ended it, including a cancellation.
  func run(timeout: TimeInterval) async throws -> Answer {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in start(timeout: timeout, continuation: continuation) }
    } onCancel: {
      finish(.failure(CancellationError()))
    }
  }

  private func start(timeout: TimeInterval, continuation: CheckedContinuation<Answer, Error>) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    lock.unlock()

    process.terminationHandler = { [weak self] _ in self?.finish(.failure(UsageError.badResponse), childEnded: true) }

    beforeLaunch?()
    do { try process.run() } catch {
      log("[\(request.label)] could not start \(process.executableURL?.path ?? request.label): \(error.localizedDescription)")
      finish(.failure(request.unavailable))
      return
    }

    // Cancellation can land while `run()` is in flight: `finish` would have seen a process
    // that wasn't running yet and skipped termination, leaving this child unmonitored.
    // Re-check now that it definitely exists, and clean up if cancellation won the race.
    lock.lock()
    let alreadyFinished = isFinished
    lock.unlock()
    if alreadyFinished {
      terminateAndReap()
      return
    }

    // The readers are installed only once the child exists. A launch that fails inside the
    // spawn (a missing interpreter, a truncated binary) closes the pipes' write ends, and a
    // reader already in place takes that EOF for a child that answered nothing, reporting a bad
    // response instead of a CLI that could not start. Each reader clears itself at EOF, where
    // it would otherwise be called again and again. `finish` clears them too, but a `finish`
    // that runs between the `isFinished` re-check after `run()` and this install finds none to clear, so each reader
    // must clear itself. That self-clear is what makes this race safe, and a test pins it directly,
    // so unlike a cancellation before `run()`, which `beforeLaunch` steers, this race gets no hook.
    output.fileHandleForReading.readabilityHandler = RPCPipes.reader(
      onChunk: { [weak self] in self?.consume($0) },
      onEnd: { [weak self] in self?.finish(.failure(UsageError.badResponse), childEnded: true) })
    // Drain stderr so a chatty child can't fill the pipe buffer and deadlock.
    errors.fileHandleForReading.readabilityHandler = RPCPipes.reader(onChunk: { _ in }, onEnd: {})

    send(request.initialize)
    if !request.queryAfterInitialize { sendQuery() }

    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
      self?.finish(.failure(UsageError.badResponse))
    }
  }

  private func send(_ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else { return }
    try? input.fileHandleForWriting.write(contentsOf: data)
  }

  /// Sends the query once, whichever reply or path asks first.
  private func sendQuery() {
    lock.lock()
    let first = !querySent
    querySent = true
    lock.unlock()
    if first { send(request.query) }
  }

  /// Accumulate newline-delimited JSON and resume on the id=2 reply. The child may also emit
  /// unsolicited notifications, so match on id rather than arrival order.
  private func consume(_ chunk: Data) {
    lock.lock()
    buffer.append(chunk)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      lines.append(Data(buffer[buffer.startIndex..<newline]))
      buffer.removeSubrange(buffer.startIndex...newline)
    }
    lock.unlock()

    for line in lines {
      guard let reply = try? JSONDecoder().decode(Reply.self, from: line) else { continue }
      // An error reply to `initialize` ends the exchange only when the query waits on it; otherwise the query
      // was sent regardless, and its own reply decides.
      if let error = reply.error, reply.id == 2 || (reply.id == 1 && request.queryAfterInitialize) {
        log("[\(request.label)] request \(reply.id ?? 0) refused: \(error.summary)")
        finish(.failure(request.rejection(error)))
        return
      }
      if reply.id == 1, request.queryAfterInitialize { sendQuery() }
      guard reply.id == 2 else { continue }
      if let answer = try? JSONDecoder().decode(Answered.self, from: line).result {
        finish(.success(answer))
      } else {
        finish(.failure(UsageError.badResponse))
      }
      return
    }
  }

  /// Resume the continuation at most once, then tear the child down. `childEnded` says the child exited or closed
  /// its output before answering, rather than timing out, being cancelled or answering: its exit is then logged.
  func finish(_ result: Result<Answer, Error>, childEnded: Bool = false) {
    lock.lock()
    if isFinished {
      lock.unlock()
      return
    }
    isFinished = true
    let pending = continuation
    continuation = nil
    lock.unlock()

    output.fileHandleForReading.readabilityHandler = nil
    errors.fileHandleForReading.readabilityHandler = nil
    process.terminationHandler = nil
    try? input.fileHandleForWriting.close()

    terminateAndReap(reportingExit: childEnded)
    pending?.resume(with: result)
  }

  /// Terminate the child if it ever started, and reap it off the caller's thread so a slow
  /// exit can't stall the continuation. Safe to call more than once.
  ///
  /// With `reportingExit`, a child that ended on its own before answering has its exit logged. Without that
  /// line the log would say only that the response could not be read, for a launcher whose interpreter is
  /// missing (it exits 127) as for a wrapper whose target has gone.
  private func terminateAndReap(reportingExit: Bool = false) {
    let label = request.label
    let report: @Sendable (Process) -> Void = { [log, path = process.executableURL?.path ?? label] ended in
      switch ended.terminationReason {
      case .exit: log("[\(label)] \(path) exited with status \(ended.terminationStatus) before answering")
      case .uncaughtSignal: log("[\(label)] \(path) was ended by signal \(ended.terminationStatus) before answering")
      @unknown default: log("[\(label)] \(path) ended before answering")
      }
    }
    guard process.isRunning else {
      // A process that was never launched has no pid, and no exit to report.
      if reportingExit, process.processIdentifier != 0 { report(process) }
      return
    }
    process.terminate()
    DispatchQueue.global(qos: .utility).async { [process] in
      process.waitUntilExit()
      // Its end-of-file can arrive before its exit is noticed, so a child reaped here may have died on its own,
      // by an exit or a signal of its own; only the SIGTERM just sent is TokenRation's.
      if reportingExit, !(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM) { report(process) }
    }
  }

  /// A reply's id and error, read before its result so a result of another shape doesn't hide either.
  private struct Reply: Decodable {
    let id: Int?
    let error: RPCError?
  }

  private struct Answered: Decodable { let result: Answer? }
}

/// What every exchange shares regardless of the answer it decodes.
enum RPCPipes {
  /// Writing to a child that has already exited raises SIGPIPE, which terminates this process
  /// by default instead of returning an error. Ignoring it once turns a dead child into a
  /// failed write that the timeout and EOF paths already handle.
  static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

  /// A reader for a pipe: `onChunk` gets each chunk as it arrives, and at end-of-file the reader clears
  /// itself before calling `onEnd`, because a `readabilityHandler` left installed there is called again and
  /// again. Called only when bytes are ready or at end-of-file, so it never blocks.
  static func reader(onChunk: @escaping @Sendable (_ chunk: Data) -> Void, onEnd: @escaping @Sendable () -> Void)
    -> @Sendable (_ handle: FileHandle) -> Void
  {
    { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        onEnd()
        return
      }
      onChunk(chunk)
    }
  }
}
