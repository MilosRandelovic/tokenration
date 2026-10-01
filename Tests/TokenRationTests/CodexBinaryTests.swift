import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

// MARK: - Finding the codex binary

final class CodexBinaryTests: XCTestCase {
  /// A fresh fixture directory, removed when the test ends.
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-binary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  /// Search roots entirely inside `root`, so no assertion depends on what this Mac has installed.
  private func roots(under root: URL) -> CodexBinary.Roots {
    CodexBinary.Roots(
      applications: root.appendingPathComponent("Applications"), home: root.appendingPathComponent("home"),
      binDirectories: [root.appendingPathComponent("opt/homebrew/bin"), root.appendingPathComponent("usr/local/bin")])
  }

  /// A resolver over `roots` whose decisions go to `logged` rather than the app's real log. Its login
  /// shell is `shell`, by default one that does not exist, so no test can reach this Mac's.
  private func resolver(
    roots: CodexBinary.Roots, shell: URL = URL(fileURLWithPath: "/nonexistent-login-shell"), logged: Box<[String]> = Box([]),
    shellDeadline: TimeInterval = CodexBinary.loginShellDeadline
  ) -> CodexBinary.Resolver {
    CodexBinary.Resolver(roots: roots, loginShell: shell, shellDeadline: shellDeadline, log: { logged.value.append($0) })
  }

  /// Runs `work` off the test's thread and reports whether it returned within `seconds`, so a lookup that
  /// ignores its own deadline fails the test rather than hanging the suite.
  private func returns(within seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Bool {
    let returned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      work()
      returned.signal()
    }
    return returned.wait(timeout: .now() + seconds) == .success
  }

  /// Writes `script` as an executable file at `relativePath` under `root` and returns its path.
  private func makeExecutable(_ relativePath: String, under root: URL, script: String = "#!/bin/sh\n") throws -> String {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
  }

  /// Codex's credentials file, which detection requires before it looks for a binary. A plain file: only
  /// its existence matters.
  private func makeCredentials(under root: URL) throws {
    let url = root.appendingPathComponent("home/.codex/auth.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: url)
  }

  /// A login shell that records each argument, bracketed so their boundaries show, and answers with the
  /// prefixed path of a fixture codex, which leaves `answerRan` behind when run. A test can then tell
  /// whether a resolution asked the shell, and how, and whether anything ran the codex it answered.
  /// `answeringAfter` makes the shell wait that many seconds before it answers, as a slow profile would.
  private func makeMarkerShell(under root: URL, answeringAfter delay: TimeInterval = 0, file: StaticString = #filePath, line: UInt = #line)
    throws -> (shell: URL, marker: URL, answer: String, answerRan: URL)
  {
    let answerRan = root.appendingPathComponent("shell-installed-codex-ran")
    let answer = try makeExecutable("shell-installed/codex", under: root, script: "#!/bin/sh\ntouch '\(answerRan.path)'\n")
    let marker = root.appendingPathComponent("shell-was-asked")
    let shell = try makeExecutable(
      "marker-shell", under: root,
      script: "#!/bin/sh\nprintf '[%s]' \"$@\" > '\(marker.path)'\n\(delay > 0 ? "sleep \(delay)\n" : "")echo '__codex=\(answer)'\n")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: shell), "the marker shell must be runnable, or its absence proves nothing", file: file,
      line: line)
    return (URL(fileURLWithPath: shell), marker, answer, answerRan)
  }

  // The revalidation rule

  /// The regression: the path found at launch was kept for the life of the process, so once an app
  /// update moved the binary every fetch launched a file that was no longer there.
  func testMovedBinaryIsFoundAgain() throws {
    let root = try makeRoot()
    let cache = OSAllocatedUnfairLock<String?>(initialState: nil)
    let original = try makeExecutable("old/codex", under: root)
    XCTAssertEqual(CodexBinary.revalidated(cache: cache, search: { original }), original)

    try FileManager.default.removeItem(atPath: original)
    let moved = try makeExecutable("new/codex", under: root)
    var replaced: (stale: String, replacement: String?)?
    XCTAssertEqual(
      CodexBinary.revalidated(cache: cache, search: { moved }, onStale: { replaced = (stale: $0, replacement: $1) }), moved,
      "a path that has gone must be searched for again")
    let report = try XCTUnwrap(replaced, "the replacement is reported")
    XCTAssertEqual(report.stale, original)
    XCTAssertEqual(report.replacement, moved)
    XCTAssertEqual(
      CodexBinary.revalidated(
        cache: cache,
        search: {
          XCTFail("the path found again must be kept")
          return nil
        }), moved)
  }

  /// A leftover file that lost its execute bit is as gone as a deleted one: launching it would fail
  /// every time, so the recheck asks whether the path is executable, not merely whether it exists.
  func testPathThatLostItsExecuteBitIsSearchedForAgain() throws {
    let root = try makeRoot()
    let cache = OSAllocatedUnfairLock<String?>(initialState: nil)
    let original = try makeExecutable("old/codex", under: root)
    XCTAssertEqual(CodexBinary.revalidated(cache: cache, search: { original }), original)

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: original)
    let moved = try makeExecutable("new/codex", under: root)
    XCTAssertEqual(CodexBinary.revalidated(cache: cache, search: { moved }), moved)
  }

  /// A cached path an update turned into a directory is as gone as a deleted one: a directory's search
  /// bit reads as executable, so only the launchable check sends the recheck to search again.
  func testPathThatBecameADirectoryIsSearchedForAgain() throws {
    let root = try makeRoot()
    let cache = OSAllocatedUnfairLock<String?>(initialState: nil)
    let original = try makeExecutable("old/codex", under: root)
    XCTAssertEqual(CodexBinary.revalidated(cache: cache, search: { original }), original)

    try FileManager.default.removeItem(atPath: original)
    try FileManager.default.createDirectory(atPath: original, withIntermediateDirectories: true)
    let moved = try makeExecutable("new/codex", under: root)
    XCTAssertEqual(CodexBinary.revalidated(cache: cache, search: { moved }), moved, "a directory at the cached path must be searched past")
  }

  /// A path that still works is reused rather than searched for again, so a poll keeps the install it
  /// found while an update puts a replacement alongside it.
  func testFoundPathIsNotSearchedForAgain() throws {
    let root = try makeRoot()
    let cache = OSAllocatedUnfairLock<String?>(initialState: nil)
    let found = try makeExecutable("codex", under: root)
    let replacement = try makeExecutable("replacement/codex", under: root)
    var searches = 0
    for _ in 0..<3 {
      let resolved = CodexBinary.revalidated(
        cache: cache,
        search: {
          searches += 1
          return searches == 1 ? found : replacement
        })
      XCTAssertEqual(resolved, found, "the install found first stays in use while it still works")
    }
    XCTAssertEqual(searches, 1, "a path that still works must be reused, not searched for on every poll")
  }

  /// A miss is not kept. A search that lands mid-update, with neither the old nor the new path in
  /// place yet, would otherwise leave Codex disabled until the app was relaunched.
  func testMissIsSearchedForAgain() throws {
    let root = try makeRoot()
    let cache = OSAllocatedUnfairLock<String?>(initialState: nil)
    XCTAssertNil(CodexBinary.revalidated(cache: cache, search: { nil }, onStale: { _, _ in XCTFail("a first search replaces nothing") }))
    let arrived = try makeExecutable("codex", under: root)
    XCTAssertEqual(CodexBinary.revalidated(cache: cache, search: { arrived }), arrived, "a miss must not stick")
  }

  /// A path that goes with nothing to replace it is still reported, so the log shows where codex was.
  func testStalePathWithNoReplacementIsReported() throws {
    let root = try makeRoot()
    let cache = OSAllocatedUnfairLock<String?>(initialState: nil)
    let original = try makeExecutable("codex", under: root)
    _ = CodexBinary.revalidated(cache: cache, search: { original })

    try FileManager.default.removeItem(atPath: original)
    var replaced: (stale: String, replacement: String?)?
    XCTAssertNil(CodexBinary.revalidated(cache: cache, search: { nil }, onStale: { replaced = (stale: $0, replacement: $1) }))
    let report = try XCTUnwrap(replaced, "a stale path is reported even with no replacement")
    XCTAssertEqual(report.stale, original)
    XCTAssertNil(report.replacement)
  }

  // Where a search looks

  /// The order a search tries, all taken from the roots: ChatGPT's current layout, its earlier one, the
  /// VS Code extension (none here), then the bin directories.
  func testCandidatesAreTriedInOrder() throws {
    let root = try makeRoot()
    XCTAssertEqual(
      CodexBinary.candidates(in: roots(under: root)),
      [
        "Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "Applications/ChatGPT.app/Contents/Resources/codex",
        "opt/homebrew/bin/codex", "usr/local/bin/codex",
      ].map { root.appendingPathComponent($0).path })
  }

  /// `Roots.thisMac` is this Mac's real locations, with the extension between ChatGPT and Homebrew, and the
  /// production resolver searches it. Only the extensions directory is read from disk, so a fixture home
  /// keeps this deterministic.
  func testThisMacRootsAreTheRealLocations() throws {
    let root = try makeRoot()
    let extensionBinary = try makeExecutable(
      "home/.vscode/extensions/openai.chatgpt-1.0.0-darwin-arm64/bin/macos-aarch64/codex", under: root)
    let thisMacWithAFixtureHome = CodexBinary.Roots(
      applications: CodexBinary.Roots.thisMac.applications, home: root.appendingPathComponent("home"),
      binDirectories: CodexBinary.Roots.thisMac.binDirectories)
    XCTAssertEqual(
      CodexBinary.candidates(in: thisMacWithAFixtureHome),
      [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "/Applications/ChatGPT.app/Contents/Resources/codex",
        extensionBinary, "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
      ])
    XCTAssertEqual(
      CodexBinary.Roots.thisMac.home, FileManager.default.homeDirectoryForCurrentUser, "detection reads Codex's credentials under it")
    XCTAssertEqual(CodexBinary.Resolver.shared.roots, .thisMac, "the production resolver searches this Mac")
  }

  /// Every supported install is found, and where both ChatGPT layouts exist the current one wins. The
  /// earlier layout stays a candidate for installs that have not updated.
  func testEachInstallIsFound() throws {
    let current = "Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
    let earlier = "Applications/ChatGPT.app/Contents/Resources/codex"
    let extensionBinary = "home/.vscode/extensions/openai.chatgpt-1.0.0-darwin-arm64/bin/macos-aarch64/codex"
    let cases: [(name: String, installed: [String], expected: String)] = [
      ("ChatGPT as of 26.924", [current], current), ("ChatGPT before 26.924", [earlier], earlier),
      ("both ChatGPT layouts", [earlier, current], current), ("VS Code extension", [extensionBinary], extensionBinary),
      ("Homebrew", ["opt/homebrew/bin/codex"], "opt/homebrew/bin/codex"),
    ]
    for testCase in cases {
      let root = try makeRoot()
      for path in testCase.installed { _ = try makeExecutable(path, under: root) }
      XCTAssertEqual(
        CodexBinary.search(in: roots(under: root), fallback: nil), root.appendingPathComponent(testCase.expected).path, testCase.name)
    }
  }

  /// A leftover that is not executable does not count: the search goes on to a later install rather than
  /// handing out a path that cannot be launched.
  func testUnexecutableLeftoverDoesNotShadowALaterInstall() throws {
    let root = try makeRoot()
    let leftover = root.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
    try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: leftover)
    let homebrew = try makeExecutable("opt/homebrew/bin/codex", under: root)
    XCTAssertEqual(CodexBinary.search(in: roots(under: root), fallback: nil), homebrew)
  }

  /// `isLaunchable` accepts an executable regular file and a symlink to one, and nothing else. The search,
  /// the cached path's recheck, the shell answer's recheck and the answer's own check all go through it.
  func testLaunchableMeansAnExecutableRegularFile() throws {
    let root = try makeRoot()
    let executable = try makeExecutable("executable", under: root)
    let unexecutable = root.appendingPathComponent("unexecutable").path
    try Data().write(to: URL(fileURLWithPath: unexecutable))
    let directory = root.appendingPathComponent("directory").path
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let namedPipe = root.appendingPathComponent("named-pipe").path
    XCTAssertEqual(mkfifo(namedPipe, 0o755), 0, "the named pipe must exist, or its row proves nothing")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: namedPipe),
      "the pipe's execute bits must survive the umask, or its row passes for the wrong reason")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: directory),
      "a directory's search bit must read as executable, or its row passes for the wrong reason")
    func link(_ name: String, to target: String) throws -> String {
      let path = root.appendingPathComponent(name).path
      try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
      return path
    }
    let cases: [(name: String, path: String, launchable: Bool)] = [
      ("an executable file", executable, true), ("an unexecutable file", unexecutable, false), ("a directory", directory, false),
      ("a named pipe with its execute bits set", namedPipe, false),
      ("a symlink to an executable", try link("to-executable", to: executable), true),
      ("a symlink to a directory", try link("to-directory", to: directory), false),
      ("a dangling symlink", try link("dangling", to: root.appendingPathComponent("gone").path), false),
    ]
    for testCase in cases { XCTAssertEqual(CodexBinary.isLaunchable(testCase.path), testCase.launchable, testCase.name) }
  }

  /// A directory at a candidate path is not a codex, though its execute bit makes `isExecutableFile` say
  /// yes: handed out, it would fail to launch and stay cached, so the search goes on to a later install.
  func testDirectoryAtACandidatePathIsSkipped() throws {
    let root = try makeRoot()
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"), withIntermediateDirectories: true)
    let homebrew = try makeExecutable("opt/homebrew/bin/codex", under: root)
    XCTAssertEqual(CodexBinary.search(in: roots(under: root), fallback: nil), homebrew)
  }

  /// Extension versions compare numerically. As text, 26.1015 sorts below 26.908, so while VS Code kept
  /// the older folder a search would launch the older codex.
  func testNewestExtensionIsTriedFirst() throws {
    let root = try makeRoot()
    _ = try makeExecutable("home/.vscode/extensions/openai.chatgpt-26.908.31748-darwin-arm64/bin/macos-aarch64/codex", under: root)
    let newer = try makeExecutable("home/.vscode/extensions/openai.chatgpt-26.1015.2-darwin-arm64/bin/macos-aarch64/codex", under: root)
    // Neither a foreign extension nor a codex outside a `macos-` directory counts, however they sort.
    _ = try makeExecutable("home/.vscode/extensions/vscode.other-99.0.0-darwin-arm64/bin/macos-aarch64/codex", under: root)
    _ = try makeExecutable("home/.vscode/extensions/openai.chatgpt-99.0.0-darwin-arm64/bin/linux-x86_64/codex", under: root)
    XCTAssertEqual(CodexBinary.search(in: roots(under: root), fallback: nil), newer)
  }

  /// The fallback is a last resort, asked only when no known location has codex.
  func testFallbackIsOnlyALastResort() throws {
    let root = try makeRoot()
    let searchRoots = roots(under: root)
    XCTAssertEqual(CodexBinary.search(in: searchRoots, fallback: { "/from/the/fallback" }), "/from/the/fallback", "nothing installed: ask")
    XCTAssertNil(CodexBinary.search(in: searchRoots, fallback: nil), "no fallback: a miss stays a miss")

    let installed = try makeExecutable("opt/homebrew/bin/codex", under: root)
    XCTAssertEqual(
      CodexBinary.search(
        in: searchRoots,
        fallback: {
          XCTFail("a known location must win without asking")
          return nil
        }), installed)
  }

  // The login shell

  /// Asked as a login shell with `loginShellCommand` as one argument: `-l` is what makes the shell read its
  /// login profile (which files, `loginShellLookup` says), and a split argument would run only its first
  /// word.
  func testLoginShellIsAskedAsALoginShell() throws {
    let root = try makeRoot()
    let fixture = try makeMarkerShell(under: root)
    XCTAssertEqual(CodexBinary.loginShellLookup(shell: fixture.shell, deadline: 5, log: { _ in }), fixture.answer)
    XCTAssertEqual(try String(contentsOf: fixture.marker, encoding: .utf8), "[-lc][\(CodexBinary.loginShellCommand)]")
  }

  /// The command itself, run where a profile leaves it: after output with no trailing newline, on the
  /// `PATH` the profile set. This test puts that output ahead of the command, gives that `PATH` a directory
  /// whose name has a space, which a command that substituted the path unquoted would split, and runs the
  /// command through `sh` and through `zsh -f`, a zsh that reads only `/etc/zshenv`, with codex on that
  /// `PATH` and without it. The fixture runs `$2`, which is the command because the lookup passes `-lc`
  /// first. It sets `PATH` in the string it passes to `-c`, ahead of `$2`, rather than before its `exec`,
  /// so that `/etc/zshenv`, which `zsh -f` still reads before running that string, cannot replace it. Other
  /// tests run the command too: through a login zsh and a login bash on fixture profiles, and through `sh`
  /// with an `EXIT` trap that prints.
  func testCommandFindsCodexOnThePathAProfileSets() throws {
    let root = try makeRoot()
    let profileBin = root.appendingPathComponent("profile bin")
    try FileManager.default.createDirectory(at: profileBin, withIntermediateDirectories: true)
    let cases: [(name: String, shell: String)] = [("sh", "/bin/sh -c"), ("zsh reading only /etc/zshenv", "/bin/zsh -f -c")]
    for testCase in cases {
      let shell = try makeExecutable(
        "profile-shell-\(UUID().uuidString)", under: root,
        script: "#!/bin/sh\nprintf 'Welcome back'\nexec \(testCase.shell) \"PATH='\(profileBin.path)'; $2\"\n")
      let codex = try makeExecutable("profile bin/codex", under: root)
      XCTAssertEqual(CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 5, log: { _ in }), codex, testCase.name)

      try FileManager.default.removeItem(atPath: codex)
      let logged = Box<[String]>([])
      XCTAssertNil(
        CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 5, log: { logged.value.append($0) }), testCase.name)
      XCTAssertEqual(logged.value.count, 1, "\(testCase.name): \(logged.value)")
      XCTAssertTrue(logged.value.first?.contains("found no codex on its PATH") == true, "\(testCase.name): \(logged.value)")
    }
  }

  /// A shell that prints as it exits, as an `EXIT` trap in a profile does, cannot land that output on a
  /// miss: the command ends its own answer line, so the miss is still logged as one.
  func testOutputAtExitDoesNotLandOnAMiss() throws {
    let root = try makeRoot()
    let emptyBin = root.appendingPathComponent("empty-bin")
    try FileManager.default.createDirectory(at: emptyBin, withIntermediateDirectories: true)
    let shell = try makeExecutable(
      "trapping-shell", under: root, script: "#!/bin/sh\nPATH='\(emptyBin.path)'\ntrap 'echo bye' EXIT\neval \"$2\"\n")
    let logged = Box<[String]>([])
    XCTAssertNil(CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 5, log: { logged.value.append($0) }))
    XCTAssertEqual(logged.value.count, 1, "logged: \(logged.value)")
    XCTAssertTrue(logged.value.first?.contains("found no codex on its PATH") == true, "logged: \(logged.value)")
  }

  /// The command uses no command substitution, as 1.0.4's did not, so a login shell that cannot parse
  /// `$(…)` or backticks can still answer.
  func testCommandUsesNoCommandSubstitution() {
    XCTAssertFalse(CodexBinary.loginShellCommand.contains("$("), CodexBinary.loginShellCommand)
    XCTAssertFalse(CodexBinary.loginShellCommand.contains("`"), CodexBinary.loginShellCommand)
  }

  /// Whatever a profile prints cannot be mistaken for the answer or hide it: lines around it, a prefixed
  /// line before it (the answer is the last one), CRLF lines, which a split on "\n" alone would leave
  /// joined, and more output than a pipe holds, which the shell writes to a file without blocking.
  func testAnswerIsFoundPastProfileOutput() throws {
    let root = try makeRoot()
    let answer = try makeExecutable("codex", under: root)
    let cases: [(name: String, script: String)] = [
      ("lines around the answer", "#!/bin/sh\necho 'Welcome back'\necho '__codex=\(answer)'\necho 'bye'\n"),
      ("a prefixed line before the answer", "#!/bin/sh\necho '__codex=/decoy'\necho '__codex=\(answer)'\n"),
      ("CRLF lines", "#!/bin/sh\nprintf 'Welcome back\\r\\n__codex=%s\\r\\n' '\(answer)'\n"),
      ("a greeting that is not UTF-8", "#!/bin/sh\nprintf 'Gr\\374\\337e\\n'\necho '__codex=\(answer)'\n"),
      ("more output than a pipe holds", "#!/bin/sh\nprintf '%262144s\\n' ''\necho '__codex=\(answer)'\n"),
    ]
    let outputFiles = {
      ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter {
        $0.hasPrefix("tokenration-login-shell-")
      }.count
    }
    let before = outputFiles()
    for testCase in cases {
      let shell = try makeExecutable("chatty-shell-\(UUID().uuidString)", under: root, script: testCase.script)
      XCTAssertEqual(CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 5, log: { _ in }), answer, testCase.name)
    }
    XCTAssertEqual(outputFiles(), before, "each lookup removes the file its shell wrote to")
  }

  /// A profile that never finishes is given up on and the shell terminated: the first Codex fetch waits for
  /// the search, so an unbounded wait would leave that reading waiting forever.
  func testLoginShellThatNeverAnswersIsAbandoned() throws {
    let fixture = try HangingFixture()
    addTeardownBlock {
      fixture.killSurvivors()
      fixture.cleanUp()
    }
    let logged = Box<[String]>([])
    let found = Box<String?>("not returned")
    XCTAssertTrue(
      returns(within: 3) {
        found.value = CodexBinary.loginShellLookup(shell: fixture.url, deadline: 0.5, log: { logged.value.append($0) })
      }, "a shell that never answers must be given up on, not waited out")
    XCTAssertNil(found.value)
    XCTAssertEqual(fixture.liveProcessCount(), 0, "the abandoned shell must be terminated and reaped")
    XCTAssertEqual(logged.value, ["[codex] login shell \(fixture.url.path) gave no answer within 0.5s; terminated"])
  }

  /// A shell whose profile ignores SIGTERM is killed: the deadline has to hold even then.
  func testShellThatIgnoresTerminationIsKilled() throws {
    let fixture = try HangingFixture(ignoringTermination: true)
    addTeardownBlock {
      fixture.killSurvivors()
      fixture.cleanUp()
    }
    let logged = Box<[String]>([])
    let found = Box<String?>("not returned")
    XCTAssertTrue(
      returns(within: 3.5) {
        found.value = CodexBinary.loginShellLookup(shell: fixture.url, deadline: 0.5, log: { logged.value.append($0) })
      }, "the deadline plus a termination grace per signal, with slack")
    XCTAssertNil(found.value)
    XCTAssertEqual(fixture.liveProcessCount(), 0, "a shell that ignores SIGTERM must still be killed and reaped")
    XCTAssertEqual(logged.value, ["[codex] login shell \(fixture.url.path) gave no answer within 0.5s; killed"])
  }

  /// A profile that ignores SIGTERM passes the ignore to the command it is stuck in, so both outlive the
  /// deadline's SIGTERM. The SIGKILL that follows goes to the whole group, or that command would be left
  /// running with no owner.
  func testCommandOfAShellThatIgnoresTerminationIsKilledWithIt() throws {
    let root = try makeRoot()
    let ready = root.appendingPathComponent("command-ready")
    let command = try HangingFixture(ignoringTermination: true, prelude: "touch '\(ready.path)'\n")
    addTeardownBlock {
      command.killSurvivors()
      command.cleanUp()
    }
    let shell = try makeExecutable("ignoring-shell", under: root, script: "#!/bin/sh\ntrap '' TERM\n'\(command.url.path)' &\nwait\n")
    let logged = Box<[String]>([])
    XCTAssertTrue(
      returns(within: 5) {
        _ = CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 1.5, log: { logged.value.append($0) })
      })
    XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "the command must have been running with its trap set")
    XCTAssertEqual(command.waitForExit(), 0, "the command the shell was stuck in must be killed with it")
    XCTAssertEqual(logged.value, ["[codex] login shell \(shell) gave no answer within 1.5s; killed"])
  }

  /// A profile that hangs is usually stuck in a command it ran. Signalling the shell alone would leave that
  /// command running after the lookup gives up, so the shell's whole process group is signalled.
  func testHungProfileCommandIsEndedWithTheShell() throws {
    let root = try makeRoot()
    let ready = root.appendingPathComponent("command-ready")
    let command = try HangingFixture(prelude: "touch '\(ready.path)'\n")
    addTeardownBlock {
      command.killSurvivors()
      command.cleanUp()
    }
    let shell = try makeWaitingShell(for: command, under: root)
    let logged = Box<[String]>([])
    XCTAssertTrue(
      returns(within: 4) {
        _ = CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 1.5, log: { logged.value.append($0) })
      })
    XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "the command must have been running, or its end proves nothing")
    XCTAssertEqual(command.waitForExit(), 0, "the command the profile was stuck in must end with the shell")
    XCTAssertEqual(logged.value, ["[codex] login shell \(shell) gave no answer within 1.5s; terminated"])
  }

  /// A login shell that starts `command` in the background and waits on it. The group tests give the lookup
  /// a 1.5 s deadline and assert the command's ready marker, so a command still starting when the deadline
  /// falls fails the test rather than passing without testing anything.
  private func makeWaitingShell(for command: HangingFixture, under root: URL) throws -> String {
    try makeExecutable("waiting-shell", under: root, script: "#!/bin/sh\n'\(command.url.path)' &\nwait\n")
  }

  /// A process that leads no group still gets the signal, sent to it alone, the defence should `Process`
  /// ever stop making its children group leaders. The target is a background process whose shell has
  /// exited, so it belongs to a group it does not lead. `send`'s trap on a pid of 1 or less has no test: a
  /// trap would take the test process down with it.
  func testSignalReachesAProcessThatLeadsNoGroup() throws {
    let root = try makeRoot()
    let holder = try HangingFixture()
    addTeardownBlock {
      holder.killSurvivors()
      holder.cleanUp()
    }
    let pidFile = root.appendingPathComponent("holder.pid")
    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
    launcher.arguments = ["-c", "'\(holder.url.path)' & echo $! > '\(pidFile.path)'"]
    try launcher.run()
    launcher.waitUntilExit()
    let pid = try XCTUnwrap(pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertEqual(getpgid(pid), launcher.processIdentifier, "the holder must be alive, in the launcher's group, which it does not lead")
    CodexBinary.send(SIGTERM, toGroupLedBy: pid)
    XCTAssertEqual(holder.waitForExit(), 0, "a process that leads no group must still be signalled")
  }

  /// The shell's stdin is the null device, so a profile that reads it gets end-of-file at once instead of
  /// waiting on whatever stdin TokenRation has. The test holds its own stdin open on a pipe during the
  /// lookup, so the result does not depend on how the test runner was started.
  func testProfileReadingStandardInputIsStillAnswered() throws {
    let root = try makeRoot()
    let answer = try makeExecutable("codex", under: root)
    let shell = try makeExecutable("reading-shell", under: root, script: "#!/bin/sh\nread line\necho '__codex=\(answer)'\n")
    let heldOpen = Pipe()
    let savedStandardInput = dup(STDIN_FILENO)
    dup2(heldOpen.fileHandleForReading.fileDescriptor, STDIN_FILENO)
    defer {
      dup2(savedStandardInput, STDIN_FILENO)
      close(savedStandardInput)
    }
    let found = Box<String?>(nil)
    XCTAssertTrue(
      returns(within: 4) { found.value = CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 2, log: { _ in }) },
      "the lookup must return")
    XCTAssertEqual(found.value, answer, "a profile that reads stdin must get end-of-file, not wait for the deadline")
  }

  /// A command that ignores SIGTERM outlives a shell that exits on it; once the grace has passed with the
  /// group still alive, the group is killed, so nothing the lookup started is left running without an owner.
  func testCommandThatIgnoresTerminationIsKilledWithTheGroup() throws {
    let root = try makeRoot()
    let ready = root.appendingPathComponent("command-ready")
    let command = try HangingFixture(ignoringTermination: true, prelude: "touch '\(ready.path)'\n")
    addTeardownBlock {
      command.killSurvivors()
      command.cleanUp()
    }
    let shell = try makeWaitingShell(for: command, under: root)
    let logged = Box<[String]>([])
    XCTAssertTrue(
      returns(within: 5) {
        _ = CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 1.5, log: { logged.value.append($0) })
      })
    XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "the command must have been running with its trap set")
    XCTAssertEqual(command.waitForExit(), 0, "a command that ignored SIGTERM must still end with the group")
    XCTAssertEqual(logged.value, ["[codex] login shell \(shell) gave no answer within 1.5s; terminated, and killed what it left running"])
  }

  /// A command that stops on SIGTERM, though not at once, is on its way out rather than ignoring it: the
  /// group check waits up to a grace for it, so the command is left to finish and the log says terminated.
  func testCommandSlowToStopIsNotTakenForOneThatIgnoredTermination() throws {
    let root = try makeRoot()
    let ready = root.appendingPathComponent("command-ready")
    let command = try HangingFixture(prelude: "trap 'sleep 0.3; exit 0' TERM\ntouch '\(ready.path)'\n")
    addTeardownBlock {
      command.killSurvivors()
      command.cleanUp()
    }
    let shell = try makeWaitingShell(for: command, under: root)
    let logged = Box<[String]>([])
    XCTAssertTrue(
      returns(within: 5) {
        _ = CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 1.5, log: { logged.value.append($0) })
      })
    XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "the command must have been running with its trap set")
    XCTAssertEqual(command.waitForExit(), 0)
    XCTAssertEqual(logged.value, ["[codex] login shell \(shell) gave no answer within 1.5s; terminated"])
  }

  /// The group check returns as soon as the group has emptied rather than at the end of its grace, which
  /// would add a whole grace to the first Codex reading whenever a profile's command takes a moment to stop. The group's
  /// leader exits at once and its one member a second later, well inside the grace.
  func testGroupCheckReturnsOnceTheGroupHasGone() throws {
    let leader = Process()
    leader.executableURL = URL(fileURLWithPath: "/bin/sh")
    leader.arguments = ["-c", "sleep 1 & exit 0"]
    try leader.run()
    leader.waitUntilExit()
    let group = leader.processIdentifier
    XCTAssertEqual(kill(-group, 0), 0, "the member must still be running when the check starts")
    let started = Date()
    XCTAssertFalse(CodexBinary.groupOutlives(group, by: 10), "the member leaves inside the grace")
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the check must return once the group has gone, not at the end of its grace")
  }

  /// A non-interactive login zsh, the kind the lookup starts, reads `.zprofile` and never `.zshrc`, so the
  /// lookup finds a codex a `.zprofile` puts on `PATH` and not one only `.zshrc` does. It runs a real zsh on
  /// a fixture `ZDOTDIR` whose files set `PATH` outright, so nothing installed on this Mac can answer.
  func testLoginZshFindsCodexOnTheProfilePathOnly() throws {
    let root = try makeRoot()
    let zdotdir = root.appendingPathComponent("zdotdir")
    try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
    let codex = try makeExecutable("profile-bin/codex", under: root)
    _ = try makeExecutable("rc-bin/codex", under: root)
    let shell = URL(
      fileURLWithPath: try makeExecutable("fixture-zsh", under: root, script: "#!/bin/sh\nZDOTDIR='\(zdotdir.path)' exec /bin/zsh \"$@\"\n")
    )
    let profile = zdotdir.appendingPathComponent(".zprofile")
    // `/etc/zshenv` runs before any fixture file; turning GLOBAL_RCS off here keeps `/etc/zprofile` and
    // `/etc/zlogin`, which run around the fixture's `.zprofile`, from setting `PATH` on this Mac.
    try "unsetopt GLOBAL_RCS\n".write(to: zdotdir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
    try "PATH='\(root.appendingPathComponent("rc-bin").path)'\n".write(
      to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

    try "PATH='\(root.appendingPathComponent("profile-bin").path)'\n".write(to: profile, atomically: true, encoding: .utf8)
    XCTAssertEqual(CodexBinary.loginShellLookup(shell: shell, deadline: 5, log: { _ in }), codex, "found on the PATH .zprofile sets")

    try "PATH='\(root.appendingPathComponent("empty-bin").path)'\n".write(to: profile, atomically: true, encoding: .utf8)
    let logged = Box<[String]>([])
    XCTAssertNil(CodexBinary.loginShellLookup(shell: shell, deadline: 5, log: { logged.value.append($0) }), "never the PATH .zshrc sets")
    XCTAssertTrue(logged.value.first?.contains("found no codex on its PATH") == true, "logged: \(logged.value)")
  }

  /// A login bash reads `.bash_profile` under `HOME` and never `.bashrc` on its own, so the lookup finds a
  /// codex a `.bash_profile` puts on `PATH` and not one only `.bashrc` does. It runs a real bash on a fixture
  /// `HOME` whose files set `PATH` outright, after `/etc/profile`.
  func testLoginBashFindsCodexOnTheProfilePathOnly() throws {
    let root = try makeRoot()
    let home = root.appendingPathComponent("bash-home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let codex = try makeExecutable("profile-bin/codex", under: root)
    _ = try makeExecutable("rc-bin/codex", under: root)
    try "PATH='\(root.appendingPathComponent("rc-bin").path)'\n".write(
      to: home.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
    let profile = home.appendingPathComponent(".bash_profile")
    let shell = URL(
      fileURLWithPath: try makeExecutable("fixture-bash", under: root, script: "#!/bin/sh\nHOME='\(home.path)' exec /bin/bash \"$@\"\n"))

    try "PATH='\(root.appendingPathComponent("profile-bin").path)'\n".write(to: profile, atomically: true, encoding: .utf8)
    XCTAssertEqual(CodexBinary.loginShellLookup(shell: shell, deadline: 5, log: { _ in }), codex, "found on the PATH .bash_profile sets")

    try "PATH='\(root.appendingPathComponent("empty-bin").path)'\n".write(to: profile, atomically: true, encoding: .utf8)
    let logged = Box<[String]>([])
    XCTAssertNil(CodexBinary.loginShellLookup(shell: shell, deadline: 5, log: { logged.value.append($0) }), "never the PATH .bashrc sets")
    XCTAssertTrue(logged.value.first?.contains("found no codex on its PATH") == true, "logged: \(logged.value)")
  }

  /// tcsh, which macOS also ships as `csh`, rejects `-lc` before running anything, so a lookup through it
  /// comes back empty and the log says the shell exited; README tells tcsh and csh users that only the
  /// other locations are searched.
  func testTcshAndCshCannotBeAsked() throws {
    let root = try makeRoot()
    for shellPath in ["/bin/tcsh", "/bin/csh"] {
      let shell = try makeExecutable(
        "fixture-\(URL(fileURLWithPath: shellPath).lastPathComponent)", under: root,
        script: "#!/bin/sh\nHOME='\(root.path)' exec \(shellPath) \"$@\"\n")
      let logged = Box<[String]>([])
      XCTAssertNil(
        CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 5, log: { logged.value.append($0) }), shellPath)
      XCTAssertEqual(logged.value, ["[codex] login shell \(shell) exited with status 1"], shellPath)
    }
  }

  /// A background process the profile starts inherits the shell's output and keeps it open after the
  /// shell exits. Waiting for end-of-file would wait on that process instead of the shell.
  func testBackgroundProcessDoesNotHoldTheLookupOpen() throws {
    let root = try makeRoot()
    let holder = try HangingFixture()
    addTeardownBlock {
      holder.killSurvivors()
      holder.cleanUp()
    }
    let answer = try makeExecutable("codex", under: root)
    let shell = try makeExecutable("forking-shell", under: root, script: "#!/bin/sh\n'\(holder.url.path)' &\necho '__codex=\(answer)'\n")
    let found = Box<String?>(nil)
    XCTAssertTrue(
      returns(within: 2) { found.value = CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 4, log: { _ in }) },
      "the lookup must return when the shell exits, not when its output closes")
    XCTAssertGreaterThan(
      holder.liveProcessCount(), 0, "the holder must still hold the output when the lookup returns, or this proves nothing")
    XCTAssertEqual(found.value, answer)
  }

  /// The shell's stderr goes nowhere rather than to a pipe nobody reads, where a profile that writes
  /// more than a pipe buffer would block until the deadline.
  func testProfileWritingAPipeBufferToStandardErrorIsStillAnswered() throws {
    let root = try makeRoot()
    let answer = try makeExecutable("codex", under: root)
    let shell = try makeExecutable(
      "noisy-shell", under: root, script: "#!/bin/sh\nhead -c 262144 /dev/zero >&2\necho '__codex=\(answer)'\n")
    let found = Box<String?>(nil)
    XCTAssertTrue(
      returns(within: 2) { found.value = CodexBinary.loginShellLookup(shell: URL(fileURLWithPath: shell), deadline: 4, log: { _ in }) },
      "a profile's stderr must never hold the lookup up")
    XCTAssertEqual(found.value, answer)
  }

  /// Every way the lookup can come back empty is logged, so a Codex tab with no codex, which then says
  /// "Couldn't find or start the Codex CLI.", has a reason in the log.
  func testEachEmptyOutcomeIsLogged() throws {
    let root = try makeRoot()
    let answer = try makeExecutable("codex", under: root)
    let notExecutable = root.appendingPathComponent("not-executable").path
    try Data().write(to: URL(fileURLWithPath: notExecutable))
    let directory = root.appendingPathComponent("a-directory").path
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let cases: [(name: String, script: String?, logged: String)] = [
      ("exits non-zero", "#!/bin/sh\necho '__codex=\(answer)'\nexit 3\n", "exited with status 3"),
      ("killed by a signal", "#!/bin/sh\necho '__codex=\(answer)'\nkill -KILL $$\n", "ended by signal 9"),
      ("no codex on its PATH", "#!/bin/sh\necho '__codex='\n", "found no codex on its PATH"),
      ("no prefixed answer", "#!/bin/sh\necho 'something else'\n", "gave no answer"),
      (
        "answer not executable", "#!/bin/sh\necho '__codex=\(notExecutable)'\n",
        "answered \(notExecutable), which is not an executable file"
      ), ("answer is a directory", "#!/bin/sh\necho '__codex=\(directory)'\n", "answered \(directory), which is not an executable file"),
      ("cannot be started", nil, "could not start login shell"),
    ]
    for testCase in cases {
      let shell =
        try testCase.script.map { URL(fileURLWithPath: try makeExecutable("shell-\(UUID().uuidString)", under: root, script: $0)) }
        ?? root.appendingPathComponent("no-such-shell")
      let logged = Box<[String]>([])
      XCTAssertNil(CodexBinary.loginShellLookup(shell: shell, deadline: 5, log: { logged.value.append($0) }), testCase.name)
      XCTAssertEqual(logged.value.count, 1, testCase.name)
      XCTAssertTrue(logged.value.first?.contains(testCase.logged) == true, "\(testCase.name): \(logged.value)")
    }
  }

  // The production wiring

  /// Guards the rule that a fetch never reaches the login-shell lookup, through the provider's own
  /// resolution: pointing a fetch at detection's search runs the marker shell and fails this.
  func testFetchNeverAsksTheLoginShell() async throws {
    let root = try makeRoot()
    let fixture = try makeMarkerShell(under: root)
    do {
      _ = try await CodexUsageProvider(binaryResolver: resolver(roots: roots(under: root), shell: fixture.shell)).fetch()
      XCTFail("with nothing at the known locations a fetch must find no codex")
    } catch UsageError.codexUnavailable {} catch { XCTFail("expected codexUnavailable, got \(error)") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path), "a fetch must never start the login shell")
  }

  /// Codex detection keeps the login-shell fallback for a codex no known location has.
  func testDetectionAsksTheLoginShell() async throws {
    let root = try makeRoot()
    let fixture = try makeMarkerShell(under: root)
    try makeCredentials(under: root)
    let logged = Box<[String]>([])
    let shared = resolver(roots: roots(under: root), shell: fixture.shell, logged: logged)
    XCTAssertTrue(CodexUsageProvider(binaryResolver: shared).detectSetUp())
    await shared.detectionFinished()
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.marker.path), "detection asks the shell when nothing else has codex")
    XCTAssertEqual(logged.value, ["[codex] detection: using \(fixture.answer)"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.answerRan.path), "detection must not run the codex the shell answered")
  }

  /// Without Codex's credentials a Mac is not set up for Codex, and detection must not start the login
  /// shell to find that out: every Claude-only launch would pay for it.
  func testNoCredentialsMeansTheShellIsNeverAsked() async throws {
    let root = try makeRoot()
    let fixture = try makeMarkerShell(under: root)
    let shared = resolver(roots: roots(under: root), shell: fixture.shell)
    XCTAssertFalse(CodexUsageProvider(binaryResolver: shared).detectSetUp())
    // Returns at once when no search was started; a search started anyway would leave the marker by then.
    await shared.detectionFinished()
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path), "no credentials, no shell")
  }

  /// A Mac signed in to Codex shows the Codex tab even when no codex is found at launch, so the tab says
  /// what is wrong rather than falling back to Claude's sign-in wording, and a codex installed later where a
  /// fetch looks is found without a relaunch.
  func testCodexIsShownWhenSignedInWithoutABinary() async throws {
    let root = try makeRoot()
    try makeCredentials(under: root)
    let logged = Box<[String]>([])
    let shared = resolver(roots: roots(under: root), logged: logged)
    XCTAssertTrue(CodexUsageProvider(binaryResolver: shared).detectSetUp(), "signed in to Codex, so its tab is shown")
    await shared.detectionFinished()
    XCTAssertEqual(logged.value.last, "[codex] detection: no codex at a known location or through the login shell")

    let poller = CodexUsageProvider(timeout: 5, binaryResolver: shared)
    do {
      _ = try await poller.fetch()
      XCTFail("with no codex anywhere, a fetch must find none")
    } catch UsageError.codexUnavailable {} catch { XCTFail("expected codexUnavailable, got \(error)") }

    let installed = try makeExecutable("opt/homebrew/bin/codex", under: root)
    do {
      _ = try await poller.fetch()
      XCTFail("the fixture codex answers nothing, so the fetch must fail")
    } catch UsageError.badResponse {
      // Reached the fixture: the codex installed after launch was found and launched.
    } catch { XCTFail("expected the installed codex to be launched, got \(error)") }
    XCTAssertTrue(logged.value.contains("[codex] now using \(installed)"), "logged: \(logged.value)")
  }

  /// A profile that hangs costs the launch nothing: detection returns on the credentials alone and the search
  /// runs in the background, where it gives the shell its deadline and then ends it. The Codex tab is shown
  /// without a codex rather than the app stalled.
  func testDetectionGivesUpOnAShellThatNeverAnswers() async throws {
    let root = try makeRoot()
    let fixture = try HangingFixture()
    addTeardownBlock {
      fixture.killSurvivors()
      fixture.cleanUp()
    }
    try makeCredentials(under: root)
    let logged = Box<[String]>([])
    let shared = resolver(roots: roots(under: root), shell: fixture.url, logged: logged, shellDeadline: 1)
    let provider = CodexUsageProvider(binaryResolver: shared)
    let installed = Box<Bool?>(nil)
    XCTAssertTrue(returns(within: 0.5) { installed.value = provider.detectSetUp() }, "detection must not wait for the shell")
    XCTAssertEqual(installed.value, true, "signed in to Codex, so its tab is shown")
    let started = Date()
    await shared.detectionFinished()
    XCTAssertLessThan(Date().timeIntervalSince(started), 1 + 2 * CodexBinary.loginShellTerminationGrace + 1, "the search gives up in time")
    XCTAssertEqual(fixture.liveProcessCount(), 0, "and reaps the shell")
    XCTAssertEqual(
      logged.value,
      [
        "[codex] login shell \(fixture.url.path) gave no answer within 1s; terminated",
        "[codex] detection: no codex at a known location or through the login shell",
      ])
  }

  /// The first fetch waits for launch detection's search, so a codex only a slow login shell finds is there for
  /// it, rather than the tab saying "Couldn't find or start the Codex CLI." until a later retry.
  func testFirstFetchWaitsForDetection() async throws {
    let root = try makeRoot()
    let fixture = try makeMarkerShell(under: root, answeringAfter: 1)
    try makeCredentials(under: root)
    let shared = resolver(roots: roots(under: root), shell: fixture.shell)
    XCTAssertTrue(CodexUsageProvider(binaryResolver: shared).detectSetUp())
    do {
      _ = try await CodexUsageProvider(timeout: 5, binaryResolver: shared).fetch()
      XCTFail("the fixture codex answers nothing, so the fetch must fail")
    } catch UsageError.badResponse {
      // Reached the fixture: the fetch waited for the shell's answer and launched it.
    } catch { XCTFail("expected the shell-found codex to be launched, got \(error)") }
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.answerRan.path), "the fetch ran what the shell found")
  }

  /// The shared resolver waits `loginShellDeadline`, which stays a few seconds: long enough for a profile
  /// that does real work, such as running Homebrew's `shellenv`, and short enough for the first Codex reading,
  /// which waits for it. The CHANGELOG promises a lookup that gives up after a few seconds.
  func testProductionShellDeadlineIsAFewSeconds() {
    XCTAssertEqual(CodexBinary.Resolver.shared.shellDeadline, CodexBinary.loginShellDeadline)
    XCTAssertGreaterThanOrEqual(CodexBinary.loginShellDeadline, 2, "long enough for a profile that does real work")
    XCTAssertLessThanOrEqual(CodexBinary.loginShellDeadline + 2 * CodexBinary.loginShellTerminationGrace, 10)
    XCTAssertEqual(
      CodexBinary.Resolver.shared.loginShell, CodexBinary.userLoginShell(environment: ProcessInfo.processInfo.environment),
      "the user's own login shell")
  }

  /// The production login shell is the account's own: `SHELL` when TokenRation starts with one, zsh,
  /// macOS's default, when it does not.
  func testUserLoginShellComesFromTheEnvironment() {
    XCTAssertEqual(CodexBinary.userLoginShell(environment: ["SHELL": "/bin/bash"]).path, "/bin/bash")
    XCTAssertEqual(CodexBinary.userLoginShell(environment: [:]).path, "/bin/zsh")
  }

  /// What the shell answered at launch reaches a fetch, which never asks the shell itself. Production
  /// builds one provider for detection and another for polling, sharing only the resolver, so this does.
  func testShellFoundPathReachesAFetch() async throws {
    let root = try makeRoot()
    let fixture = try makeMarkerShell(under: root)
    try makeCredentials(under: root)
    let shared = resolver(roots: roots(under: root), shell: fixture.shell)
    XCTAssertTrue(CodexUsageProvider(binaryResolver: shared).detectSetUp())
    await shared.detectionFinished()
    try FileManager.default.removeItem(at: fixture.marker)

    let poller = CodexUsageProvider(timeout: 5, binaryResolver: shared)
    do {
      _ = try await poller.fetch()
      XCTFail("the fixture codex answers nothing, so the fetch must fail")
    } catch UsageError.badResponse {
      // Reached the fixture: the fetch launched the path detection found through the shell.
    } catch { XCTFail("expected badResponse from the launched fixture, got \(error)") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path), "the fetch reused the path without asking the shell")
  }

  /// A shell-found codex that is briefly absent, mid-reinstall, is found again once it returns, without
  /// a relaunch and without asking the shell: a fetch rechecks what the shell answered at launch. As in
  /// production, detection and polling are separate providers over one resolver.
  func testShellFoundPathThatReturnsIsPickedUpAgain() async throws {
    let root = try makeRoot()
    let fixture = try makeMarkerShell(under: root)
    try makeCredentials(under: root)
    let logged = Box<[String]>([])
    let shared = resolver(roots: roots(under: root), shell: fixture.shell, logged: logged)
    XCTAssertTrue(CodexUsageProvider(binaryResolver: shared).detectSetUp())
    await shared.detectionFinished()
    try FileManager.default.removeItem(at: fixture.marker)

    let poller = CodexUsageProvider(timeout: 5, binaryResolver: shared)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.answer)
    do {
      _ = try await poller.fetch()
      XCTFail("with the shell-found codex gone, a fetch must find none")
    } catch UsageError.codexUnavailable {} catch { XCTFail("expected codexUnavailable while it is gone, got \(error)") }
    // The recheck turns the unexecutable answer away before any launch. Handed out, it would fail to start
    // with the same error, so only the log tells the two apart.
    XCTAssertTrue(
      logged.value.contains("[codex] \(fixture.answer) is no longer an executable file; no replacement found"), "logged: \(logged.value)")
    XCTAssertFalse(logged.value.contains { $0.contains("could not start") }, "logged: \(logged.value)")

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.answer)
    do {
      _ = try await poller.fetch()
      XCTFail("the fixture codex answers nothing, so the fetch must fail")
    } catch UsageError.badResponse {
      // Reached the fixture again: the returned path was picked up.
    } catch { XCTFail("expected the returned codex to be launched, got \(error)") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path), "found again without asking the shell")
  }

  /// A shell answer an update turned into a directory is not handed to a fetch: its search bit reads as
  /// executable, so only the launchable check turns it away before a launch that would fail. Launched, it
  /// would fail with the same error, so only the log tells the two apart.
  func testShellAnswerThatBecameADirectoryIsNotLaunched() async throws {
    let root = try makeRoot()
    let fixture = try makeMarkerShell(under: root)
    try makeCredentials(under: root)
    let logged = Box<[String]>([])
    let shared = resolver(roots: roots(under: root), shell: fixture.shell, logged: logged)
    XCTAssertTrue(CodexUsageProvider(binaryResolver: shared).detectSetUp())
    await shared.detectionFinished()

    try FileManager.default.removeItem(atPath: fixture.answer)
    try FileManager.default.createDirectory(atPath: fixture.answer, withIntermediateDirectories: true)
    do {
      _ = try await CodexUsageProvider(timeout: 5, binaryResolver: shared).fetch()
      XCTFail("a directory where the shell-found codex was must not be launched")
    } catch UsageError.codexUnavailable {} catch { XCTFail("expected codexUnavailable, got \(error)") }
    XCTAssertTrue(
      logged.value.contains("[codex] \(fixture.answer) is no longer an executable file; no replacement found"), "logged: \(logged.value)")
    XCTAssertFalse(logged.value.contains { $0.contains("could not start") }, "turned away before any launch; logged: \(logged.value)")
  }

  /// Detection and every fetch share one resolver because both go through a provider built with its
  /// default, `detectSetUp()` for detection and `fetch()` for polling. That default is the one place
  /// the production resolver is named, so this pins it. Detection's own construction, in `AppDelegate`,
  /// cannot be evaluated without running real detection, so this and
  /// `testProvidersModelBuildsCodexOnTheSharedResolver` are as close as the suite gets to it.
  func testProviderResolvesThroughTheSharedResolverByDefault() {
    XCTAssertTrue(CodexUsageProvider().binaryResolver === CodexBinary.Resolver.shared)
  }

  /// The reported scenario end to end, through the real search: ChatGPT moves codex into `codex-cli/`,
  /// the next fetch finds it there, and each change is logged, a codex that goes altogether and one that
  /// comes back included. A miss is reported once, not on every attempt while codex stays gone.
  func testMoveIntoCodexCLIIsFoundAndLogged() throws {
    let root = try makeRoot()
    let logged = Box<[String]>([])
    let shared = resolver(roots: roots(under: root), logged: logged)
    let earlier = try makeExecutable("Applications/ChatGPT.app/Contents/Resources/codex", under: root)
    XCTAssertEqual(shared.forDetection(), earlier)

    try FileManager.default.removeItem(atPath: earlier)
    let current = try makeExecutable("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", under: root)
    XCTAssertEqual(shared.forFetch(), current)

    try FileManager.default.removeItem(atPath: current)
    XCTAssertNil(shared.forFetch())
    XCTAssertNil(shared.forFetch())

    _ = try makeExecutable("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", under: root)
    XCTAssertEqual(shared.forFetch(), current)
    XCTAssertEqual(
      logged.value,
      [
        "[codex] detection: using \(earlier)", "[codex] \(earlier) is no longer an executable file; now using \(current)",
        "[codex] \(current) is no longer an executable file; no replacement found", "[codex] now using \(current)",
      ])
  }

  /// The fetches ProvidersModel builds use the shared resolver, the one detection used, so a path only the
  /// login shell found reaches them.
  @MainActor func testProvidersModelBuildsCodexOnTheSharedResolver() {
    XCTAssertTrue((ProvidersModel.makeProvider(.codex) as? CodexUsageProvider)?.binaryResolver === CodexBinary.Resolver.shared)
  }

  /// Detection only looks for codex and never runs the one it finds, so the login shell stays the one
  /// process it may start.
  func testDetectionNeverRunsTheCodexItFinds() async throws {
    let root = try makeRoot()
    let ran = root.appendingPathComponent("codex-ran")
    let codex = try makeExecutable("opt/homebrew/bin/codex", under: root, script: "#!/bin/sh\ntouch '\(ran.path)'\n")
    try makeCredentials(under: root)
    let logged = Box<[String]>([])
    let shared = resolver(roots: roots(under: root), logged: logged)
    XCTAssertTrue(CodexUsageProvider(binaryResolver: shared).detectSetUp())
    await shared.detectionFinished()
    XCTAssertEqual(logged.value, ["[codex] detection: using \(codex)"], "detection finds the codex it must not run")
    XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path), "detection must not run the codex it found")
  }

  /// Detection reports each provider set up: Claude by Claude Code's `.claude` directory under the home it
  /// is given, Codex by the provider's own check, its credentials under its resolver's roots, after which
  /// the search may ask the login shell. The two homes differ, so a check that looked in the other's would
  /// fail.
  func testDetectionReportsEachProviderSetUp() async throws {
    let root = try makeRoot()
    let home = root.appendingPathComponent("claude-home")
    let claude = home.appendingPathComponent(".claude")
    let fixture = try makeMarkerShell(under: root)
    let logged = Box<[String]>([])
    let codex = CodexUsageProvider(binaryResolver: resolver(roots: roots(under: root), shell: fixture.shell, logged: logged))
    XCTAssertEqual(Provider.detectAll(home: home, codex: codex), [], "nothing set up")
    await codex.binaryResolver.detectionFinished()
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path), "without Codex's credentials the shell is never asked")

    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    XCTAssertEqual(Provider.detectAll(home: home, codex: codex), [.claude])

    try makeCredentials(under: root)
    XCTAssertEqual(Provider.detectAll(home: home, codex: codex), [.claude, .codex])
    await codex.binaryResolver.detectionFinished()
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.marker.path), "with Codex's credentials the shell is asked")
    XCTAssertEqual(logged.value, ["[codex] detection: using \(fixture.answer)"], "found through the login shell")

    try FileManager.default.removeItem(at: claude)
    XCTAssertEqual(Provider.detectAll(home: home, codex: codex), [.codex])
  }

  // The child's PATH

  /// npm installs codex as a launcher, `#!/usr/bin/env node`, and launchd gives TokenRation a `PATH` with
  /// no Homebrew or npm directory in it, so a fetch runs codex with the binary's own directory and
  /// Homebrew's on `PATH`, ahead of the environment it inherits. Each row fails when one of those is lost:
  /// - the extension row without the binary's own directory: an nvm-shaped install placed where a fetch
  ///   looks, outside Homebrew's directories. Its launcher is a relative symlink shaped like the one npm
  ///   installs, and its interpreter sits beside the link rather than its target, as nvm's `node` sits
  ///   beside codex;
  /// - the `usr/local/bin` row without Homebrew's directories, which alone hold its interpreter, as for a
  ///   custom npm prefix, or without the inherited environment: it runs `dirname`, as ChatGPT's own wrapper
  ///   does, and needs `HOME`, which launchd sets and a child given only `PATH` would lose;
  /// - the `opt/homebrew/bin` row, Homebrew's node, only without both the binary's directory and
  ///   Homebrew's, since there they coincide.
  func testLauncherFindsItsInterpreterOnTheSearchPath() async throws {
    let answer = #"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":10080}}}}"#
    let extensionBinaryDirectory = "home/.vscode/extensions/openai.chatgpt-1.0.0-darwin-arm64/bin/macos-aarch64"
    let cases: [(name: String, launcher: String, interpreterDirectory: String, prelude: String, linkTarget: String?)] = [
      ("beside its interpreter in opt/homebrew/bin", "opt/homebrew/bin/codex", "opt/homebrew/bin", "", nil),
      (
        "away from its interpreter, running dirname", "usr/local/bin/codex", "opt/homebrew/bin",
        "set -e\ndirname \"$0\" >/dev/null\n: \"${HOME:?}\"\n", nil
      ),
      (
        "a link beside its interpreter in the extension's directory", "\(extensionBinaryDirectory)/codex", extensionBinaryDirectory, "",
        "../../lib/node_modules/@openai/codex/bin/codex.js"
      ),
    ]
    for testCase in cases {
      let root = try makeRoot()
      let interpreterDirectory = root.appendingPathComponent(testCase.interpreterDirectory)
      try FileManager.default.createDirectory(at: interpreterDirectory, withIntermediateDirectories: true)
      let interpreter = try HangingFixture(directory: interpreterDirectory, prelude: testCase.prelude + "printf '%s\\n' '\(answer)'\n")
      addTeardownBlock {
        interpreter.killSurvivors()
        interpreter.cleanUp()
      }
      let launcher = root.appendingPathComponent(testCase.launcher)
      let script = "#!/usr/bin/env \(interpreter.url.lastPathComponent)\n"
      if let linkTarget = testCase.linkTarget {
        _ = try makeExecutable(linkTarget, under: launcher.deletingLastPathComponent(), script: script)
        try FileManager.default.createSymbolicLink(atPath: launcher.path, withDestinationPath: linkTarget)
      } else {
        _ = try makeExecutable(testCase.launcher, under: root, script: script)
      }
      do {
        let snapshot = try await CodexUsageProvider(timeout: 5, binaryResolver: resolver(roots: roots(under: root))).fetch()
        XCTAssertFalse(snapshot.metrics.isEmpty, "\(testCase.name): the launcher ran its interpreter and the reading came back")
      } catch { XCTFail("\(testCase.name): expected a reading, got \(error)") }
      XCTAssertEqual(interpreter.waitForExit(), 0, "\(testCase.name): the interpreter must be reaped")
    }
  }

  /// The binary's directory comes first, then Homebrew's, then TokenRation's own `PATH`, each once.
  func testSearchPathPutsTheBinaryAndHomebrewFirst() {
    let bins = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
    XCTAssertEqual(
      CodexUsageProvider.searchPath(
        for: "/Users/me/.npm-global/bin/codex", binDirectories: bins, inherited: "/usr/bin:/bin:/opt/homebrew/bin"),
      "/Users/me/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    XCTAssertEqual(
      CodexUsageProvider.searchPath(for: "/opt/homebrew/bin/codex", binDirectories: bins, inherited: nil),
      "/opt/homebrew/bin:/usr/local/bin")
  }

  // The provider's and the exchange's errors

  /// No codex anywhere reports Codex, not a sign-in.
  func testNoBinaryFoundIsReportedAsCodexUnavailable() async throws {
    let root = try makeRoot()
    do {
      _ = try await CodexUsageProvider(binaryResolver: resolver(roots: roots(under: root))).fetch()
      XCTFail("a fetch with no codex must throw")
    } catch UsageError.codexUnavailable {} catch { XCTFail("expected codexUnavailable, got \(error)") }
  }

  /// A codex whose answer holds nothing TokenRation can show is a bad response, so the last numbers stay and the
  /// error says why, rather than a reading with nothing in it.
  func testAnAnswerWithNothingToShowIsABadResponse() async throws {
    let root = try makeRoot()
    let binDirectory = root.appendingPathComponent("opt/homebrew/bin")
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    let answer = #"{"jsonrpc":"2.0","id":2,"result":{}}"#
    let answering = root.appendingPathComponent("answering")
    let interpreter = try HangingFixture(directory: binDirectory, prelude: "touch '\(answering.path)'\nprintf '%s\\n' '\(answer)'\n")
    addTeardownBlock {
      interpreter.killSurvivors()
      interpreter.cleanUp()
    }
    _ = try makeExecutable("opt/homebrew/bin/codex", under: root, script: "#!/usr/bin/env \(interpreter.url.lastPathComponent)\n")
    let started = Date()
    do {
      _ = try await CodexUsageProvider(timeout: 5, binaryResolver: resolver(roots: roots(under: root))).fetch()
      XCTFail("an answer with nothing to show must throw")
    } catch UsageError.badResponse {} catch { XCTFail("expected badResponse, got \(error)") }
    // A fixture that never answered would also end in `badResponse`, at the timeout. The marker, left just before
    // the answer, and the quick end show the answer arrived and the guard, not the watchdog, rejected it.
    XCTAssertTrue(FileManager.default.fileExists(atPath: answering.path), "the fixture reached its answer")
    XCTAssertLessThan(Date().timeIntervalSince(started), 4, "the answer ended the exchange, not the timeout")
    XCTAssertEqual(interpreter.waitForExit(), 0, "the fixture must be reaped")
  }

  /// The regression: a stale cached path reached `run()`, which threw `notSignedIn`, and the Codex tab
  /// asked for a Claude sign-in. Every way a launch can fail is a codex that could not start: a path that
  /// has gone, a script whose interpreter is missing, and a binary caught mid-update. The last two fail
  /// inside the spawn, which closes the pipes. The catch logs before it calls `finish`, and this sink
  /// sleeps, so a reader installed before `run()` would take the spawn's EOF and report `badResponse`
  /// every time rather than now and then. The launch error is logged with the path, since a diagnosis
  /// needs both.
  func testBinaryThatCannotStartIsReportedAsCodexUnavailable() async throws {
    let root = try makeRoot()
    let binaries = [
      root.appendingPathComponent("gone/codex").path,
      try makeExecutable("missing-interpreter/codex", under: root, script: "#!/nonexistent-interpreter\n"),
      try makeExecutable("mid-update/codex", under: root, script: "\u{0}\u{1}\u{2}truncated"),
    ]
    for binary in binaries {
      let logged = Box<[String]>([])
      let pausingSink: @Sendable (_ message: String) -> Void = {
        logged.value.append($0)
        Thread.sleep(forTimeInterval: 0.2)
      }
      do {
        _ = try await CodexUsageProvider.readRateLimits(binary: binary, timeout: 5, log: pausingSink)
        XCTFail("\(binary) cannot be started, so the read must throw")
      } catch UsageError.codexUnavailable {} catch { XCTFail("\(binary): expected codexUnavailable, got \(error)") }
      XCTAssertEqual(logged.value.count, 1, "\(binary): \(logged.value)")
      XCTAssertTrue(logged.value.first?.hasPrefix("[codex] could not start \(binary): ") == true, "logged: \(logged.value)")
    }
  }

  /// The reported symptom through the real provider and model: a codex the search finds but that cannot
  /// be launched must reach the menu bar as a Codex problem — no sign-in warning, no Claude wording — and
  /// the sink the provider hands the exchange, its resolver's, must carry the reason.
  @MainActor func testUnlaunchableCodexReachesTheModelAsACodexProblem() async throws {
    let root = try makeRoot()
    _ = try makeExecutable("opt/homebrew/bin/codex", under: root, script: "#!/nonexistent-interpreter\n")
    let logged = Box<[String]>([])
    let model = UsageModel(
      provider: CodexUsageProvider(binaryResolver: resolver(roots: roots(under: root), logged: logged)), defaults: makeDefaults(),
      restoring: nil, network: StubNetwork(), log: discardLog)
    await model.refresh(trigger: "test")

    XCTAssertFalse(model.needsSignIn, "a codex that cannot start is not a sign-in problem")
    let message = model.lastError ?? ""
    XCTAssertTrue(message.contains("Codex") && !message.contains("Claude"), "the Codex tab names Codex: \(message)")
    XCTAssertEqual(logged.value.filter { $0.contains("could not start") }.count, 1, "logged: \(logged.value)")
  }

  /// A wrapper whose exec target is missing still launches, so the failure arrives as an exit with no
  /// answer — a `badResponse`, which AGENTS.md records as the cost of launching the entry point.
  func testWrapperWithMissingTargetSurfacesAsBadResponse() async throws {
    let root = try makeRoot()
    let wrapper = try makeExecutable(
      "codex-cli/bin/codex", under: root, script: "#!/bin/sh\nexec '\(root.path)/codex-cli/CodexCLI.app/Contents/MacOS/codex' \"$@\"\n")
    let started = Date()
    do {
      _ = try await CodexUsageProvider.readRateLimits(binary: wrapper, timeout: 30, log: { _ in })
      XCTFail("a wrapper with nothing to exec must fail")
    } catch UsageError.badResponse {} catch { XCTFail("expected badResponse, got \(error)") }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the wrapper exits at once, not at the watchdog")
  }
}
