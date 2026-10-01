import Foundation
import Observation
import UserNotifications

/// What `UpdateChecker` needs of the user-notification center. The app passes `SystemUpdateNotifier`; a
/// test passes its own, since the real center needs a bundled app, which the test runner is not, and
/// would put a notification in front of the user.
protocol UpdateNotifying: Sendable {
  /// Asks the user to allow `options`. `UpdateChecker` names them, so what the user is asked to allow is decided
  /// where a test can see it.
  func requestAuthorization(options: UNAuthorizationOptions) async
  func authorizationStatus() async -> UNAuthorizationStatus
  /// Shows `request`. `UpdateChecker` builds it whole, so what the user reads is decided where a test can see it.
  func post(_ request: UNNotificationRequest) async throws
}

/// The user-notification center, as the app uses it.
struct SystemUpdateNotifier: UpdateNotifying {
  func requestAuthorization(options: UNAuthorizationOptions) async {
    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: options)
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }

  func post(_ request: UNNotificationRequest) async throws { try await UNUserNotificationCenter.current().add(request) }
}

/// Checks GitHub Releases for a newer version, remembers the answer, and notifies once per
/// version.
///
/// Runs on its own cadence rather than only at launch and wake: a menu-bar app can stay up for
/// days without either happening, and a check that lands minutes before a release would then be
/// the last one for the rest of the session. The persisted deadline is what keeps the traffic
/// low — restart storms and repeated wakes all collapse onto the same gap.
@Observable @MainActor final class UpdateChecker {
  /// Latest released version (e.g. "0.1.2"), if a check has ever succeeded.
  private(set) var latestVersion: String?

  @ObservationIgnored private let repository = "MilosRandelovic/tokenration"
  /// Minimum spacing between requests. GitHub allows 60 an hour unauthenticated; this uses two.
  @ObservationIgnored private static let checkInterval: TimeInterval = 30 * 60
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let session: URLSession
  @ObservationIgnored private let notifier: any UpdateNotifying
  @ObservationIgnored private let log: @Sendable (_ message: String) -> Void
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var loggedDenial = false
  /// When the last check succeeded. Internal so a test can hold a started checker's loop back, or make it due again.
  @ObservationIgnored static let lastCheckKey = "lastUpdateCheck"
  @ObservationIgnored private static let latestVersionKey = "latestKnownVersion"
  @ObservationIgnored private static let notifiedVersionKey = "notifiedVersion"
  /// What a request for notification permission asks to show: an alert, with its sound. Named once, so the request
  /// made at launch and the one made before an announcement cannot ask for different things.
  @ObservationIgnored private static let notificationOptions: UNAuthorizationOptions = [.alert, .sound]

  /// The running app's version, or nil when run without a bundle (e.g. `swift run`).
  let currentVersion: String?

  /// Stand-ins in tests for each of these:
  /// - Parameters:
  ///   - defaults: Where the last check and the versions seen and announced persist: `.standard` in the app.
  ///   - session: Asks GitHub: `URLSession.shared` in the app.
  ///   - notifier: Tells the user: `SystemUpdateNotifier` in the app.
  ///   - currentVersion: What a release is compared with: the bundle's version in the app.
  ///   - log: Where decisions are recorded: the app's log.
  init(
    defaults: UserDefaults, session: URLSession, notifier: any UpdateNotifying, currentVersion: String?,
    log: @escaping @Sendable (_ message: String) -> Void
  ) {
    self.defaults = defaults
    self.session = session
    self.notifier = notifier
    self.currentVersion = currentVersion
    self.log = log
    latestVersion = defaults.string(forKey: Self.latestVersionKey)
  }

  /// True when GitHub has a version newer than the running one.
  var updateAvailable: Bool {
    guard let current = currentVersion, let latest = latestVersion else { return false }
    return Self.isNewer(latest, than: current)
  }

  var releasesURL: URL { URL(string: "https://github.com/\(repository)/releases/latest")! }

  /// Begin checking, and keep checking for as long as the app is awake.
  func start() {
    guard loop == nil else { return }
    // Ask for notification permission now: the prompt has to be answered before a notification
    // can be posted, and asking at launch puts it in front of someone who is already here,
    // rather than whenever a release happens to land. An unbundled build does not ask: with no
    // version to compare it never announces anything, and the real notification center crashes a
    // process without a bundle.
    if currentVersion != nil { Task { [notifier] in await notifier.requestAuthorization(options: Self.notificationOptions) } }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.check()
        try? await Task.sleep(for: .seconds(Self.checkInterval))
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  /// Whether the spacing since the last successful check has elapsed.
  var isDue: Bool {
    guard let last = defaults.object(forKey: Self.lastCheckKey) as? Date else { return true }
    return Date().timeIntervalSince(last) >= Self.checkInterval
  }

  /// Fetch the latest release tag, unless a check succeeded recently.
  func check() async {
    guard let current = currentVersion else { return }  // unbundled build; nothing to compare
    guard isDue else { return }

    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
    request.timeoutInterval = 10
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("TokenRation", forHTTPHeaderField: "User-Agent")

    guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
      log("[update] check failed: no response")
      return  // offline; try again next window
    }
    guard http.statusCode == 200 else {
      log("[update] check failed: HTTP \(http.statusCode)")
      return  // rate-limited, or no releases yet
    }
    guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
      log("[update] check failed: unreadable release")
      return
    }

    // Record the check only on success, so a failure retries at the next opportunity.
    defaults.set(Date(), forKey: Self.lastCheckKey)
    let version = Self.normalize(release.tagName)
    latestVersion = version
    defaults.set(version, forKey: Self.latestVersionKey)

    guard Self.isNewer(version, than: current) else {
      log("[update] \(current) is current (latest \(version))")
      return
    }
    log("[update] \(version) available (running \(current))")
    await notify(about: version)
  }

  /// Tell the user once per version. Announcing the same release on every launch would train
  /// them to ignore it, so the version announced is persisted rather than held in memory.
  private func notify(about version: String) async {
    guard defaults.string(forKey: Self.notifiedVersionKey) != version else { return }

    var status = await notifier.authorizationStatus()
    if status == .notDetermined {
      // The request made at launch may still be sitting in front of the user. Waiting for their
      // answer here keeps the very first announcement from being dropped on a fresh install.
      await notifier.requestAuthorization(options: Self.notificationOptions)
      status = await notifier.authorizationStatus()
    }
    guard status == .authorized || status == .provisional else {
      // Only once per run: an update stays pending across many checks, and repeating this
      // every half hour would bury the log.
      if !loggedDenial {
        log("[update] notifications not permitted; the panel still shows the update")
        loggedDenial = true
      }
      return
    }

    do {
      try await notifier.post(Self.announcement(of: version))
      defaults.set(version, forKey: Self.notifiedVersionKey)
    } catch { log("[update] could not post notification: \(error.localizedDescription)") }
  }

  /// The notification announcing `version`: shown at once, under an identifier that names the version.
  /// Nonisolated, so the request it returns is not the main actor's and can be sent to the notifier.
  nonisolated private static func announcement(of version: String) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = "TokenRation \(version) is available"
    content.body = "Run brew upgrade tokenration to update."
    return UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)
  }

  private struct Release: Decodable {
    let tagName: String

    enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
  }

  /// "v0.1.2" -> "0.1.2"
  private static func normalize(_ tag: String) -> String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

  /// Numeric component-wise compare, so 0.10 correctly beats 0.9.
  static func isNewer(_ candidate: String, than current: String) -> Bool {
    let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
    let right = current.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(left.count, right.count) {
      let lhs = index < left.count ? left[index] : 0
      let rhs = index < right.count ? right[index] : 0
      if lhs != rhs { return lhs > rhs }
    }
    return false
  }
}
