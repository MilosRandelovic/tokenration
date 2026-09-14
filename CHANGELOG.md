# Changelog

## [1.0.4]

- The refresh button's tooltip counts down in seconds under a minute. It previously allowed no unit below a minute, which suits a window that resets in hours but not a button whose commonest wait is the two-minute gap between attempts — so the last minute of every hold read "Next attempt in 0m". Reset countdowns are unchanged.

## [1.0.3]

- Signing in again re-enables the refresh button immediately, instead of leaving it disabled for the rest of the auth backoff. A refresh asked for at that point already worked — `refresh` cuts an auth hold short as soon as the credentials behind it change — but the button had no way to know that and went on refusing the click for up to a quarter of an hour.
- Opening the panel re-reads both providers' credentials, so a sign-in made since the last attempt clears the warning triangle and the "Session expired" message without waiting for a fetch.

## [1.0.2]

- The bundled MCP server puts any warning at the front of `get_usage`'s summary line, bracketed,
  ahead of the numbers it qualifies:
  `Claude: [⚠ Session expired — open Claude Code to refresh; stale] Session (5-hour) 46% (resets in 3h 29m) · read 4h 0m ago`
  Callers are told to report that line rather than the payload beside it, so an expired session
  used to reach them as percentages that read as current. A status is named in words rather than
  as the wire token it arrived as, a provider that has never read is not also called stale, and a
  reading's age is written as `4h 0m` rather than `14400s`. The structured payload is unchanged.

## [1.0.1]

- A provider whose credentials have lapsed shows a warning triangle in the menu bar in place of
  its own glyph. Being throttled does not raise it: waiting is the whole remedy there, while an
  expired session needs a sign-in. The state is read from the credentials at start-up, so a
  relaunch does not hide it behind a restored backoff until the next attempt fails.
- The refresh button turns while a fetch is in flight, and is disabled while a provider is
  held off — with a tooltip saying when the next attempt is allowed. Previously it accepted
  the click and did nothing, which reads as a broken control rather than a deliberate wait.
- A window whose reset has passed keeps showing the time that was remaining when its reading was
  taken, rather than an empty line. The figure is frozen, alongside a percentage from that same
  reading.
- Menu-bar segments keep a common baseline, so a segment without a second line no longer centres
  its percentage while its neighbours sit on the two-line baseline.

## [1.0.0]

- Releases are signed with a Developer ID certificate, notarized and stapled, so macOS opens the
  app without a Gatekeeper prompt and no quarantine flag has to be cleared by hand.

## [0.1.8]

- An expired access token is reported as an expired session instead of being sent. The endpoint
  answers 429 to a stale token, so the app used to call it a rate limit and back off for hours over
  a sign-in problem — while still making the requests that earn a real throttle.
- A menu-bar metric whose reset has already passed no longer repeats its own percentage on the
  second line.
- Reset countdowns refresh on their own half-minute tick in both the panel and the menu bar. They
  are relative, so previously they froze at whatever the view last drew — which could be hours
  earlier for a provider that is held off, and left the panel disagreeing with the menu bar.

## [0.1.7]

- The repository moved to `MilosRandelovic/tokenration`. The update check and the About view's
  link now address it directly rather than relying on GitHub's redirect from the old name.

## [0.1.6]

- Codex monthly credit caps are shown, on plans that have one. The cap carries a used/total pair,
  a percentage and a reset, so it reads like Claude's extra usage rather than a bare figure.
- A credit balance now reports the approximate local and cloud messages it covers, and turns
  critical when a spend control has stopped usage — a balance alone has no total to measure against.
- Credit and cap fields are accepted as either strings or numbers, so an unexpected shape cannot
  fail the whole payload and take the working windows with it.

## [0.1.5]

- Codex rate-limit windows are named, ordered and iconed by their own duration rather than by
  which slot they arrive in. Plans differ in whether the short window is `primary` or `secondary`,
  and some have no short window at all, so a plan with a 5-hour limit no longer shows it below the
  weekly one wearing the weekly icon.
- Codex metric ids name the window's role (`codex:session`, `codex:window`) instead of its
  transport slot. A pinned Codex metric needs pinning again once.

## [0.1.4]

- Empty credentials are reported as signed out. The CLI writes the credential back with empty
  strings when its refresh token has expired, and an empty bearer token earns an HTTP 429 — so the
  app used to report a throttle, and back off for hours, over a sign-in problem. Signing back in
  now clears the hold immediately.
- A cold start shows the last known reading immediately instead of a spinner. The app was
  already writing it to disk for the MCP server; now it reads it back, and the footer reports the
  reading's real age.
- The provider tabs use the system segmented control, so they follow the current macOS design
  rather than a hand-drawn imitation of one release's appearance.

## [0.1.3]

- The bundle identifier is now `com.milosrandelovic.tokenration`, a reverse-DNS name under an
  owned domain. Preferences are keyed by it, so pinned metrics start from the default again.
- Adds an app icon, shown in the panel header, Finder, Spotlight and on update notifications.
- The update check runs on its own half-hourly cadence and when the panel is opened, so a
  long-running app notices a release instead of relying on a launch or a wake.
- A new version is announced once with a notification, alongside the panel's banner.
- Update checks are logged, so a failed or skipped check can be seen.

## [0.1.2]

- Replacing rejected credentials ends the hold they caused, so signing in again through the CLI
  restores readings on the next refresh rather than at the end of the interval.
- A rate-limit hold is unaffected: a 429 asks for quiet regardless of which credentials are used.

## [0.1.1]

- A rejected access token is retried within a few minutes, so one the CLI rotates mid-session is
  picked up promptly instead of parking usage readings for a quarter of an hour. A token that stays
  rejected still settles onto the long interval, since only signing in again will fix it.
- Missing credentials and a rejected token are reported separately, in both the panel and the log.

## [0.1.0]

- Initial release: native macOS menu-bar app showing **Claude and Codex** usage — session and
  weekly windows, per-model limits (e.g. Fable, Codex-Spark), and spend/credits.
- Claude is read from `/api/oauth/usage`; Codex from a local `codex app-server` over JSON-RPC.
- Providers are detected automatically; the panel shows a tab per provider when both are set up,
  and each polls independently with its own backoff.
- Pin one or more metrics as menu-bar icons; theme-adaptive template rendering.
- Dropdown panel with per-metric gauges, loading and rate-limited states, and an About view.
- Authenticates with the access token the Claude Code CLI already stores in the Keychain;
  never writes or refreshes it.
- Bundled MCP server (`tokenration-mcp`) exposing `get_usage`, so agents can check remaining
  quota mid-session. Reads the app's published reading; never calls an API itself.
- Distributed as a Homebrew cask (`MilosRandelovic/tokenration`), which also symlinks
  `tokenration-mcp` onto the PATH.
