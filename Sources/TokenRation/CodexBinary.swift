import Foundation
import os

/// Locates the `codex` executable. It ships inside the ChatGPT app and the VS Code extension rather
/// than being installed on `PATH`, so a search checks the known locations first. Launch detection alone
/// then asks the user's login shell, which finds codex on a `PATH` the shell's profile sets; a fetch
/// never asks it.
enum CodexBinary {
  /// How long launch detection's search waits for the login shell before terminating it. The search runs in
  /// the background and the first fetch waits for it, so a profile that blocks delays that first reading by at
  /// most this plus two `loginShellTerminationGrace`s, whichever signal ends what the shell started, rather
  /// than hanging it.
  static let loginShellDeadline: TimeInterval = 5

  /// How long the shell is given to exit after each signal, SIGTERM at the deadline and then SIGKILL, and
  /// how long what it started is given once the shell has gone.
  static let loginShellTerminationGrace: TimeInterval = 1

  /// What precedes the path in the login shell's answer, so a profile that prints on its own, a
  /// greeting or a status line, cannot be mistaken for it.
  static let loginShellAnswerPrefix = "__codex="

  /// The user's own login shell: `SHELL` from the environment TokenRation starts with, which macOS sets
  /// from the account, or zsh, macOS's default, when that is missing.
  static func userLoginShell(environment: [String: String]) -> URL { URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh") }

  /// What the login shell runs. The answer starts a line of its own, so output a profile leaves without
  /// a trailing newline cannot run into it, and ends its line, so nothing the shell prints as it exits, an
  /// `EXIT` trap or a `zshexit` hook, can land on it. A codex that is not found leaves the bare prefix, and
  /// the closing `printf` exits 0, so the miss is logged as not found. It needs only `printf`, `command -v`
  /// and `;`, with no command substitution, so it asks little more of the login shell than a bare
  /// `command -v codex` would; `command -v` prints the path itself, so a path with a space comes back whole.
  static let loginShellCommand = #"printf '\n\#(loginShellAnswerPrefix)'; command -v codex; printf '\n'"#

  /// Where a search looks: `thisMac` in production, a fixture directory in tests. `home` is also where
  /// detection looks for Codex's `.codex/auth.json`, so one fixture root covers both. No field has a
  /// default and none can be changed, so a test names every location it searches.
  struct Roots: Sendable, Equatable {
    let applications: URL
    let home: URL
    let binDirectories: [URL]

    /// This Mac's locations: `/Applications`, the user's home, and Homebrew's bin directories on Apple
    /// silicon and Intel.
    static let thisMac = Roots(
      applications: URL(fileURLWithPath: "/Applications"), home: FileManager.default.homeDirectoryForCurrentUser,
      binDirectories: [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")])
  }

  /// Resolves the binary against one set of roots, and logs what it decides.
  ///
  /// Detection and every fetch must hold the same instance, `shared`: what the login shell answered at
  /// launch reaches a fetch only through it, since a fetch never asks the shell itself. Its configuration
  /// is fixed when it is built. Its state sits behind locks rather than in an actor because launch
  /// detection's search reads it synchronously on a dispatch thread; AGENTS.md records that departure.
  final class Resolver: Sendable {
    let roots: Roots
    /// The shell launch detection asks as a last resort, and how long it waits for the answer.
    let loginShell: URL
    let shellDeadline: TimeInterval
    /// Where decisions are recorded: the app's log in production, a capture in tests.
    let log: @Sendable (_ message: String) -> Void
    /// The last path found, kept while it is still launchable so that a path that works stays in use: an
    /// update that installs its replacement alongside it, such as a new versioned VS Code extension
    /// directory, is not launched while it is still being installed. Only a hit is kept: a miss is searched
    /// again on the next attempt, which the caller's backoff already spaces.
    let cache = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// What the login shell answered at launch. Unlike `cache` it survives a miss, so a fetch can check
    /// it again: a shell-found codex that is briefly absent, mid-reinstall, is found once it returns.
    let shellAnswer = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// Where launch detection's search stands, and the fetches waiting for it to finish.
    private let detection = OSAllocatedUnfairLock<DetectionState>(initialState: .notStarted)

    private enum DetectionState {
      case notStarted
      case running(waiting: [CheckedContinuation<Void, Never>])
      case finished
    }

    init(
      roots: Roots, loginShell: URL, shellDeadline: TimeInterval = CodexBinary.loginShellDeadline,
      log: @escaping @Sendable (_ message: String) -> Void
    ) {
      self.roots = roots
      self.loginShell = loginShell
      self.shellDeadline = shellDeadline
      self.log = log
    }

    /// The one production resolver, `CodexUsageProvider`'s default: this Mac's locations, the user's own
    /// login shell and the app's log.
    static let shared = Resolver(
      roots: .thisMac, loginShell: CodexBinary.userLoginShell(environment: ProcessInfo.processInfo.environment), log: { Log.write($0) })

    /// Starts launch detection's search, `forDetection()`, and returns at once, so launch never waits on the
    /// login shell. The search runs on a GCD thread rather than one from the cooperative pool,
    /// since it blocks while the shell answers. Only the first call starts it.
    func startDetection() {
      let starts = detection.withLock { state in
        guard case .notStarted = state else { return false }
        state = .running(waiting: [])
        return true
      }
      guard starts else { return }
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        _ = forDetection()
        let waiting = detection.withLock { state in
          defer { state = .finished }
          guard case .running(let waiting) = state else { return [CheckedContinuation<Void, Never>]() }
          return waiting
        }
        for continuation in waiting { continuation.resume() }
      }
    }

    /// Returns once launch detection's search has finished, or at once if it has or was never started. A fetch
    /// waits here, so the first one after launch starts from what the search found, the login shell's answer
    /// included. The wait is bounded as the search is, within what `loginShellDeadline` documents, and
    /// cancelling the fetch does not cut it short.
    func detectionFinished() async {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let waits = detection.withLock { state in
          guard case .running(let waiting) = state else { return false }
          state = .running(waiting: waiting + [continuation])
          return true
        }
        if !waits { continuation.resume() }
      }
    }

    /// For launch detection: the known locations, then the login shell.
    func forDetection() -> String? {
      let found = revalidate(search: {
        CodexBinary.search(
          in: roots,
          fallback: { [self] in
            let answer = CodexBinary.loginShellLookup(shell: loginShell, deadline: shellDeadline, log: log)
            if let answer { shellAnswer.withLock { $0 = answer } }
            return answer
          })
      })
      log(found.map { "[codex] detection: using \($0)" } ?? "[codex] detection: no codex at a known location or through the login shell")
      return found
    }

    /// For a fetch: the known locations, then what the login shell answered at launch, rechecked rather
    /// than asked again. Asking runs the user's login profile, so a fetch that asked would rerun it on
    /// every failed attempt while codex is gone; and even bounded, the lookup blocks its thread while it
    /// waits, a thread that on the polling path belongs to the cooperative pool. The price is that a
    /// shell-found codex that moves to a new path is not found again until a relaunch; when detection
    /// found codex at a known location, and so never asked the shell, a codex on a profile-set `PATH` is
    /// not found once that one goes; and a Mac whose launch lookup found no codex misses one that later
    /// appears only on a profile-set `PATH` until a relaunch.
    func forFetch() -> String? {
      // An empty cache means the last search missed, detection's included: the Codex tab is shown
      // whenever Codex's credentials exist, found binary or not. Log the path found now, or the log's
      // last word on codex is that miss.
      let followsAMiss = cache.withLock { $0 } == nil
      let found = revalidate(search: {
        CodexBinary.search(
          in: roots, fallback: { [self] in shellAnswer.withLock { $0 }.flatMap { CodexBinary.isLaunchable($0) ? $0 : nil } })
      })
      if followsAMiss, let found { log("[codex] now using \(found)") }
      return found
    }

    private func revalidate(search: () -> String?) -> String? {
      CodexBinary.revalidated(cache: cache, search: search) { stale, replacement in
        log("[codex] \(stale) is no longer an executable file; " + (replacement.map { "now using \($0)" } ?? "no replacement found"))
      }
    }
  }

  /// The revalidation rule on its own, with the cache and the search supplied so it can be tested.
  ///
  /// A found path is only as good as the file behind it. App and extension updates move the binary —
  /// as of ChatGPT 26.924 it lives under `codex-cli/`, and each VS Code extension update installs it
  /// under a new versioned directory — while a menu-bar app outlives several of them. A path that is no
  /// longer launchable is therefore searched for again rather than launched and failed on, and
  /// `onStale` hears about it with whatever replaced it, if anything, since that is the moment a later
  /// diagnosis will need.
  static func revalidated(
    cache: OSAllocatedUnfairLock<String?>, search: () -> String?, onStale: (_ stale: String, _ replacement: String?) -> Void = { _, _ in }
  ) -> String? {
    let cached = cache.withLock { $0 }
    if let cached, isLaunchable(cached) { return cached }
    let found = search()
    cache.withLock { $0 = found }
    if let cached { onStale(cached, found) }
    return found
  }

  /// Whether `path` is an executable regular file, following symlinks: the type is read from what the path
  /// resolves to, since a symlink is never a regular file itself. `isExecutableFile` alone is true of a
  /// directory, whose execute bit means it can be searched, and a directory at a candidate path would
  /// otherwise be handed out, fail to launch and stay cached.
  static func isLaunchable(_ path: String) -> Bool {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let isRegularFile = (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    return isRegularFile && FileManager.default.isExecutableFile(atPath: resolved.path)
  }

  /// The first launchable known location; failing that, `fallback`, when one is given.
  static func search(in roots: Roots, fallback: (() -> String?)?) -> String? {
    for path in candidates(in: roots) where isLaunchable(path) { return path }
    return fallback?()
  }

  /// Every known location, in the order a search tries them.
  static func candidates(in roots: Roots) -> [String] {
    let chatGPT = roots.applications.appendingPathComponent("ChatGPT.app/Contents/Resources")
    var candidates = [
      // The ChatGPT layout as of 26.924: the entry point `codex-cli/codex-package.json` declares, a shell
      // wrapper that execs the binary inside `codex-cli/CodexCLI.app`. Launching the entry point survives a
      // change behind it, and since it execs, the process a fetch spawns becomes codex and terminating it
      // still terminates codex.
      chatGPT.appendingPathComponent("codex-cli/bin/codex").path,
      // The layout before it.
      chatGPT.appendingPathComponent("codex").path,
    ]

    // VS Code extension: openai.chatgpt-<version>-darwin-<arch>/bin/macos-<arch>/codex, newest first.
    // Versions compare numerically: as text, 26.1015 would sort below 26.908.
    let manager = FileManager.default
    let extensionsDir = roots.home.appendingPathComponent(".vscode/extensions")
    if let entries = try? manager.contentsOfDirectory(atPath: extensionsDir.path) {
      let newestFirst = entries.filter { $0.hasPrefix("openai.chatgpt-") }.sorted {
        $0.compare($1, options: .numeric) == .orderedDescending
      }
      for entry in newestFirst {
        let base = extensionsDir.appendingPathComponent(entry).appendingPathComponent("bin")
        if let archDirs = try? manager.contentsOfDirectory(atPath: base.path) {
          for arch in archDirs where arch.hasPrefix("macos-") {
            candidates.append(base.appendingPathComponent(arch).appendingPathComponent("codex").path)
          }
        }
      }
    }

    candidates.append(contentsOf: roots.binDirectories.map { $0.appendingPathComponent("codex").path })
    return candidates
  }

  /// Asks `shell`, as a non-interactive login shell (`-lc`), where `command -v codex` points.
  ///
  /// For zsh, that reads `.zshenv`, `.zprofile` and `.zlogin` but not `.zshrc`, so it misses a tool that
  /// initialises in `.zshrc`, which is where asdf's setup puts it, and where nvm's installer does whenever a
  /// `.zshrc` exists. For bash, it reads `/etc/profile` and then the first of `.bash_profile`, `.bash_login`
  /// and `.profile`, and `.bashrc` only when one of those sources it. Either way it finds codex on a `PATH`
  /// set during login, such as a custom npm prefix or a Homebrew outside its default prefixes. tcsh, which
  /// is also macOS's `csh`, rejects `-lc` before any command runs, so a lookup through it always comes back
  /// empty.
  ///
  /// Gives up after `deadline`, signalling the shell's process group rather than waiting on it. The shell
  /// writes to a temporary file rather than a pipe: a write to a file never blocks, however much a profile
  /// prints or however small the system's pipes have become, and reading it once the shell has exited never
  /// waits for end-of-file, which a background process left holding the shell's output would withhold
  /// indefinitely.
  ///
  /// The prefix tells the answer apart from whatever those files print, and since every one of them runs
  /// before the command, the answer is the last prefixed line, even if one of them prints a prefixed line
  /// too. Every way the lookup comes back empty is logged.
  static func loginShellLookup(shell: URL, deadline: TimeInterval, log: (_ message: String) -> Void) -> String? {
    let process = Process()
    process.executableURL = shell
    process.arguments = ["-lc", loginShellCommand]
    let outputFile = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-login-shell-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: outputFile.path, contents: nil, attributes: [.posixPermissions: 0o600]),
      let output = try? FileHandle(forWritingTo: outputFile)
    else {
      log("[codex] could not create the login shell's output file in \(outputFile.deletingLastPathComponent().path)")
      return nil
    }
    // Removed once read; a background process still holding it keeps writing to a file no one can open.
    defer {
      try? output.close()
      try? FileManager.default.removeItem(at: outputFile)
    }
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch {
      log("[codex] could not start login shell \(shell.path): \(error.localizedDescription)")
      return nil
    }
    guard exited.wait(timeout: .now() + deadline) == .success else {
      // A profile that hangs is usually stuck in a command it ran, which is in the shell's group.
      let pid = process.processIdentifier
      send(SIGTERM, toGroupLedBy: pid)
      var ending = "terminated"
      if exited.wait(timeout: .now() + loginShellTerminationGrace) == .timedOut {
        send(SIGKILL, toGroupLedBy: pid)
        _ = exited.wait(timeout: .now() + loginShellTerminationGrace)
        ending = "killed"
      } else if groupOutlives(pid, by: loginShellTerminationGrace) {
        // The shell went, but something it started ignored SIGTERM and keeps the group alive. A group's id
        // is not reused while it has members, so this reaches only what the lookup started. It calls `kill`
        // itself: `send` would fall back to the shell's pid, which is free once the shell is reaped.
        kill(-pid, SIGKILL)
        ending = "terminated, and killed what it left running"
      }
      log("[codex] login shell \(shell.path) gave no answer within \(String(format: "%g", deadline))s; \(ending)")
      return nil
    }
    guard process.terminationStatus == 0 else {
      // After an uncaught signal `terminationStatus` holds the signal's number, not an exit status.
      let ending = process.terminationReason == .uncaughtSignal ? "was ended by signal" : "exited with status"
      log("[codex] login shell \(shell.path) \(ending) \(process.terminationStatus)")
      return nil
    }
    // Split on every newline, CRLF included: as one `Character`, "\r\n" never matches a "\n" separator.
    let written = (try? Data(contentsOf: outputFile)) ?? Data()
    let lines = String(decoding: written, as: UTF8.self).split(whereSeparator: \.isNewline)
    guard let answerLine = lines.last(where: { $0.hasPrefix(loginShellAnswerPrefix) }) else {
      log("[codex] login shell \(shell.path) gave no answer")
      return nil
    }
    let path = String(answerLine.dropFirst(loginShellAnswerPrefix.count))
    guard !path.isEmpty else {
      log("[codex] login shell \(shell.path) found no codex on its PATH")
      return nil
    }
    guard isLaunchable(path) else {
      log("[codex] login shell \(shell.path) answered \(path), which is not an executable file")
      return nil
    }
    return path
  }

  /// Sends `signalNumber` to the process group `pid` leads (`Process` makes each child a group leader),
  /// so the commands the shell started get it too. A negative pid names a group, whose id is its leader's
  /// pid, and `pid` must be a process TokenRation launched, which can never lead TokenRation's own group.
  /// A pid of 1 or less, which no launched process has, traps before anything is signalled: `kill(2)`
  /// reads 0 as the caller's own group and -1 as every process the user owns, and 0 is what a `Process`
  /// reports until it launches. When `pid` leads no group the signal goes to the process alone, a defence
  /// should `Process` stop making its children leaders. Internal so a test can aim it at a process that
  /// leads none.
  static func send(_ signalNumber: Int32, toGroupLedBy pid: pid_t) {
    precondition(pid > 1, "not a launched process's pid: \(pid)")
    if kill(-pid, signalNumber) != 0 { kill(pid, signalNumber) }
  }

  /// Whether the group `pid` led still has members once `grace` has passed. Waiting out the grace keeps
  /// members already on their way out after SIGTERM from being taken for ones that ignored it, and polling
  /// returns as soon as they have gone. Internal so a test can pin the polling.
  static func groupOutlives(_ pid: pid_t, by grace: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(grace)
    while kill(-pid, 0) == 0 {
      if Date() >= deadline { return true }
      usleep(20_000)
    }
    return false
  }
}
