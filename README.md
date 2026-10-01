# TokenRation

A native macOS menu-bar app that shows your **Claude** and **Codex** usage at a glance — session and weekly windows, per-model limits (e.g. Fable, Codex-Spark), and spend/credits.

Pin one metric for a single icon, or several to stack them. Each provider uses a distinct icon family so you can tell them apart at a glance, and all icons are template images, so they look right on light and dark menu bars. When both providers are set up, the panel gets a tab each.

<img src="docs/panel-claude.png" alt="Panel on the Claude tab: session, weekly, per-model and spend meters, with three metrics pinned to the menu bar above" width="49%"> <img src="docs/panel-codex.png" alt="Panel on the Codex tab: weekly window and a per-model limit" width="49%">

## Install

Requires macOS 14+ and at least one of the Claude Code or Codex CLIs, signed in. Whichever are present are detected automatically.

```sh
brew tap MilosRandelovic/tokenration
brew trust MilosRandelovic/tokenration
brew install tokenration
```

On first launch, click **Always Allow** on the one-time Keychain prompt — that lets TokenRation read the access token the Claude Code CLI saved there. There's no separate sign-in.

## Agent access (MCP)

TokenRation bundles an MCP server so coding agents can check your remaining quota — e.g. before starting expensive work — without anyone hitting a usage API a second time. Register it once:

```sh
claude mcp add tokenration -- tokenration-mcp     # Claude Code
codex mcp add tokenration -- tokenration-mcp      # Codex
```

One tool, **`get_usage`** — takes no arguments and returns every limit, kept separate per provider (`claude` and `codex` each with their own status, metrics and reset times), plus how old the reading is. Poll it as often as you like: it reads a local file, so calling it costs nothing upstream.

It **only reads** the app's published reading (`~/Library/Application Support/TokenRation/usage.json`) and never calls a usage API itself — MCP servers are spawned per session, so a fetching server would multiply request load across every concurrent agent. Results carry `ageSeconds` and `stale` so a caller can judge freshness; if the app isn't running, the data is simply old.

## Build from source

macOS 14+, Swift 6 (Xcode 16+):

```sh
make build                      # compile
make test                       # run the test suite
make format                     # format the sources (CI fails on unformatted code)
make app                        # TokenRation.app, ad-hoc signed (local use)
make release                    # distributable build; notarized with a Developer ID cert
swift run                       # run from source (dies with the shell — fine for a quick check)
```

Launch the built app with `open TokenRation.app`, or copy it to `/Applications` and start it from Finder/Spotlight. **Don't run `TokenRation.app/Contents/MacOS/TokenRation &` from a terminal** — that makes the app a child of the shell, so it is killed the moment the shell exits (silently, with no crash report). `open` detaches it properly. For a menu-bar app you want running all the time, add it to **System Settings ▸ General ▸ Login Items**.

## How it works

- **Claude data:** `GET https://api.anthropic.com/api/oauth/usage` — the same endpoint Claude Code's `/usage` uses. Polled every ~5 minutes, paused while the Mac sleeps or is offline, with exponential backoff and a long hold-off after a rate limit (all persisted, so restarts and wakes can't bypass it).
- **Codex data:** JSON-RPC `account/rateLimits/read` against a local `codex app-server` subprocess. The ChatGPT HTTP backend rejects non-client callers (403 bot protection), and going through the local CLI means no credential handling of our own and no model quota consumed.
- **Auth:** the Claude Code CLI stores an OAuth access token in your login Keychain (`Claude Code-credentials`); TokenRation reads that token via `/usr/bin/security` to authenticate the Claude request. Codex needs nothing — its own CLI is already signed in. Credentials are **never written or refreshed**; the CLIs stay the only things that manage them.
- **Independence:** each provider polls on its own schedule with its own persisted backoff, so one being throttled or signed out never stalls the other.
- **Diagnostics:** every attempt and its outcome is logged to `~/Library/Logs/TokenRation.log` (rotated at 512 KB) for troubleshooting.

## Architecture

```
Sources/TokenRation/
├── Main.swift · AppDelegate.swift   entry point; wires providers + prefs + status bar
├── Provider.swift                   the two providers: detection + per-provider icon family
├── ProvidersModel.swift             one UsageModel per provider shown; tab selection
├── UsageModel.swift                 polling loop + state (per-provider, persisted backoff)
├── ClaudeUsageProvider.swift        /api/oauth/usage → DisplayMetrics
├── CodexUsageProvider.swift         codex app-server JSON-RPC → DisplayMetrics
├── CodexBinary.swift                locates the codex executable
├── UsageProviding.swift             the provider protocol and UsageError
├── KeychainToken.swift              reads the Claude token via /usr/bin/security
├── Preferences.swift                which metrics are pinned
├── StatusBarController.swift        menu-bar item + the custom dropdown panel
├── UsagePanelView.swift             SwiftUI panel: tabs, meters, pins, states, About
├── UpdateChecker.swift              the GitHub release check
├── Log.swift                        the diagnostics log
├── RestoredSnapshot.swift           the last published reading, shown at a cold start
└── UsageSnapshot.swift              value types the UI renders

Sources/UsageState/                  shared state file format (app writes, MCP server reads)
Sources/TokenRationMCP/              the bundled stdio MCP server
```

## Releasing

Bump `SHORT_VERSION` in `scripts/common.sh` and push to `main`. The release workflow tests, builds, tags, publishes the GitHub release with `TokenRation.zip`, and opens a pull request against the [tap](https://github.com/MilosRandelovic/homebrew-tokenration) updating the cask's version and checksum. Merging that PR makes the release installable.

The job **fails if the version is already tagged**, so every push to `main` either publishes a release or goes red — a green run always means something shipped.

### Signing and notarization

Releases are ad-hoc signed unless signing credentials are configured, in which case they are signed with the hardened runtime, notarized and stapled. Ad-hoc builds install fine but are quarantined by Gatekeeper on first launch, which is why the cask carries a caveat.

Signing requires a paid [Apple Developer Program](https://developer.apple.com/programs/) membership and a **Developer ID Application** certificate (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates; an "Apple Development" certificate is not valid for distribution). For local runs, store notary credentials once with an [app-specific password](https://appleid.apple.com):

```sh
xcrun notarytool store-credentials "TokenRation-notary" \
  --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
```

In CI the same is supplied via the `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` secrets. `HOMEBREW_TOKENRATION_PAT` (a token with write access to the tap repo) lets the release workflow open the cask pull request.

Distributed as a Homebrew cask via the [homebrew-tokenration](https://github.com/MilosRandelovic/homebrew-tokenration) tap.

## License

MIT — see [LICENSE](LICENSE).
