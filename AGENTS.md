# Agent Notes — TokenRation

## What this is

A native macOS **menu-bar app** (SwiftUI + AppKit, Swift 6, macOS 14+) that shows Claude and Codex usage. No Xcode project — it builds with Swift Package Manager (`swift build` / `swift run`).

## Architecture

- `Main.swift` — `@main`; starts the AppKit menu-bar app.
- `AppDelegate.swift` — wires providers + prefs + status bar; sleep/wake handling.
- `Provider.swift` — the closed two-provider set: detection (filesystem only, never prompts) and each provider's **distinct icon family**, which is how the menu bar disambiguates them.
- `ProvidersModel.swift` — one `UsageModel` per detected provider + the panel's selected tab.
- `UsageModel.swift` — `@Observable @MainActor`; polling loop, rate-limit backoff, holds the snapshot. One instance per provider; **persisted keys are provider-suffixed** so budgets and backoffs never collide.
- `ClaudeUsageProvider.swift` — `GET /api/oauth/usage` → decode → `[DisplayMetric]`.
- `CodexUsageProvider.swift` — spawns `codex app-server` and calls `account/rateLimits/read` over JSON-RPC. Don't switch this to HTTP: `chatgpt.com/backend-api/codex/usage` returns 403 from a bot-protection page even with a valid token, and the local CLI costs no quota.
- `KeychainToken.swift` — reads the token by shelling out to `/usr/bin/security`.
- `UsageSnapshot.swift` — value types the UI renders (`DisplayMetric`, `Severity`).
- `StatusBarController.swift` — one `NSStatusItem` (all pinned metrics composited into one template image) plus a custom `NSPanel` dropdown it positions and dismisses itself.
- `UsagePanelView.swift` — SwiftUI panel (gauges, pin toggles, loading/rate-limited states, About).
- `Preferences.swift` — `@Observable`; which metrics are pinned (UserDefaults).
- `Sources/UsageState/` — shared library: the `usage.json` schema plus atomic read/write. Both the app and the MCP server depend on it; keep it free of app types.
- `Sources/TokenRationMCP/` — the bundled stdio MCP server (one tool: `get_usage`).
- `Makefile` — the entry point CI uses (`make test`, `make app`, `make release`).
- `scripts/` — `common.sh` (shared bundle assembly + `SHORT_VERSION`), `build-app.sh` (ad-hoc local build), `release.sh` (distributable build + cask update). Nothing but the Makefile lives at the repo root.
- `Tests/TokenRationTests/` — XCTest suite (run by CI on every push and before release signing). **Subprocess tests must use the hanging fixture, not `/bin/sleep`**: the exchange always appends `app-server`, so `sleep app-server` dies instantly with "invalid time interval" and the timeout/cancellation tests pass without exercising anything. The fixture is a uniquely-named script that ignores its arguments and runs until signalled, so `pgrep -f` can also assert the child was reaped. `UsageModel` and `Preferences` take an injectable `UserDefaults` so persistence across "relaunch" can be exercised without touching the real domain; `CodexUsageProvider.readRateLimits` is internal so the timeout path is testable.

## Conventions / gotchas

- **Auth is read-only.** Read the token via `/usr/bin/security`, never `SecItem` — the Keychain grant then attaches to Apple's stable binary and survives app rebuilds. Never write/refresh credentials (don't risk the user's Claude Code login).
- **Be a good citizen with the usage endpoint.** It's shared with Claude Code and throttles hard. Keep the slow base poll, exponential backoff on failure, a long floor after a 429 (honouring `Retry-After`), a rare auth-failure retry, jitter, and the sleep/wake pause. A constant-interval retry on failure issues thousands of requests a day against an endpoint that is already refusing them — never introduce one.
- **Every request goes through `refresh(trigger:)`.** Its three guards — an active backoff deadline, minimum gap since the last attempt, network availability — are what make repeated launches and system wakes safe: without them, every wake fetches immediately and bypasses the backoff. `nextAttemptAt` is persisted for **every** failure type, not just 429s — a backoff held only in the polling task's sleep is lost on stop/start or relaunch, silently downgrading a 15–30 minute hold-off to the 120s minimum gap. Never add a code path that fetches without these guards.
- **A hold the UI reports must be one `refresh` would actually refuse.** `heldUntil` exists to stop the refresh button offering a click that cannot act, so it has to model the guards exactly — including their escape hatch. An auth hold ends the moment the credentials behind it change, and `heldUntil` reads a fingerprint cached by `refreshCredentialState()` to see that; a 429 or an ordinary error backoff records no fingerprint and is never escapable. Report a hold that `refresh` would have escaped and a sign-in is followed by a dead button for the rest of the interval.
- **Honour deadlines written by older builds.** The guard takes the later of `nextAttemptAt` and the legacy `rateLimitedUntil.<provider>`, and init migrates the legacy value forward. Without it, upgrading mid-throttle silently drops an active 429 hold-off to the 120s minimum gap.
- **`Retry-After` is a hard lower bound.** Jitter the local floor only (`max(retryAfter, jittered(floor))`); jittering the combined value allows −10% to schedule a request earlier than the server asked for.
- **Never block in the Codex exchange.** `FileHandle.availableData` in a deadline loop cannot time out — a hung `codex app-server` that writes nothing parks the reader forever, the continuation never resumes and the child is never reaped. `CodexExchange` uses `readabilityHandler` plus an independent watchdog, honours task cancellation, drains stderr, and terminates + reaps on every path, resuming exactly once. `start()` re-checks `isFinished` immediately after `process.run()`: cancellation can land mid-launch, when `finish` sees a process that isn't running yet and skips termination, leaking an unmonitored `codex app-server`.
- **Pins are reconciled against successful snapshots.** Provider-level sanitising can't catch a per-model metric that is renamed or retired: the id vanishes while its provider stays available, leaving a menu-bar placeholder with no panel row to unpin. `Preferences.reconcile` drops those, but only for providers that have actually reported, and always keeps one pin.
- **Freshness is per provider.** Derive age from each `ProviderUsage.updatedAt`, never from the state file's `writtenAt` — the file is rewritten on refresh starts, errors and connectivity changes, so file age makes old quota numbers look current. File age is exposed separately as `stateFileAgeSeconds`.
- **The MCP server must never fetch.** It is spawned per client session, so a server that called a usage API itself would multiply load across every concurrent agent — the exact way an account gets throttled. It reads only what the app published, and reports `ageSeconds`/`stale` instead of chasing freshness.
- **Log decisions, not just errors.** `Log.write` records each attempt, skip (with the reason) and outcome to `~/Library/Logs/TokenRation.log`; pass a meaningful `trigger` so bursts can be traced to their source.
- **Menu-bar icons must be template images** (`isTemplate = true`, drawn black) so macOS tints them for light/dark. No hardcoded colours there; severity colour lives in the panel gauges.
- **Don't use `NSPopover`** for the dropdown — it can't reposition as the item resizes and its transient dismissal fights the status-item click. Use the owned `NSPanel` instead (smooth `setFrame` re-centering + explicit click-outside monitor).
- **Metric ids are provider-namespaced** (`claude:session`, `codex:model:…`); `Preferences` has a one-shot migration for pre-Codex ids. Keep new ids namespaced or pinning breaks.
- **The update check is self-spaced.** It runs on a 30-minute persisted gap, driven by its own loop plus panel opens, and announces a version once. Launch and wake alone are not enough: a menu-bar app can stay up for days, so a check landing just before a release would otherwise be the last one of the session.
- **A system control's appearance follows the linked SDK, not the running OS.** `LC_BUILD_VERSION`'s sdk field is what AppKit reads, and SwiftPM does not pass the SDK version to the linker — so ld stamps the deployment target and a plain `swift build` claims macOS 14. `assemble_bundle` passes `-platform_version` explicitly to record the real SDK; without it `make app` shows older styling than any release, and judging UI from such a build is misleading.
- Off-main work returns `Sendable` types; UI types are `@MainActor`.
- Full descriptive names; comment intent, not change history.

## Build / test

```sh
make build
make test                       # pinning, reconciliation, backoff, timeouts, freshness
make format                     # CI fails on unformatted sources
make app                        # TokenRation.app (ad-hoc, local)
open TokenRation.app            # launch it detached — see below
make release                    # notarized (Developer ID) + updates the Homebrew cask
```

Formatting is enforced by `swift format` against `.swift-format` (2-space indent, stated explicitly there rather than left to the tool default). Wire types map snake_case JSON via `CodingKeys` rather than snake_case property names, so the `AlwaysUseLowerCamelCase` rule stays on.

**Launch the bundle with `open`, not the executable inside it.** Running `TokenRation.app/Contents/MacOS/TokenRation &` makes the app a child of the invoking shell, so it gets SIGHUP and dies when that shell exits — silently, with no crash report and no `app terminating` log line, which looks exactly like a crash. `open` hands it to launchd (PPID 1) so it survives. Also note `build-app.sh` does `rm -rf` on the bundle, so rebuilding while an instance runs can invalidate the running code signature; quit it first.

## Distribution

Homebrew cask in the [homebrew-tokenration](https://github.com/MilosRandelovic/homebrew-tokenration) tap. `release.sh` builds the notarized zip and rewrites the cask's `version` + `sha256`.

CI (`.github/workflows/`): `ci.yml` runs on pull requests — formatting (`swift format lint`), tests, and bundle assembly. `release.yml` runs on every push to `main`, takes the version from `SHORT_VERSION` in `scripts/common.sh`, and **fails if that version is already tagged**, so releasing is just bumping that constant and a green run always means something shipped. It tests → builds → tags → creates the GitHub release with `TokenRation.zip` → opens a PR against the tap updating the cask (`peter-evans/create-pull-request`). The tap's `cask-ci.yml` styles and installs the cask on that PR, so `main` only ever sees a verified cask.

Signing and notarization are skipped when the Apple secrets are absent, so a release still publishes ad-hoc. That condition reads a job-level `env` boolean because `secrets` is not an available context in a step's `if:` — testing it there stops GitHub creating the run at all. `HOMEBREW_TOKENRATION_PAT` is required: it checks out the tap and opens the cask PR.

Merging the cask PR touches only the tap, so it cannot re-trigger this workflow — the head-commit guard bump needs (its formula lives in the same repo) is unnecessary here.
