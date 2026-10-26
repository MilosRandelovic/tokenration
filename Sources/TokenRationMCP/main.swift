import Foundation
import UsageState

/// TokenRation's MCP server: exposes the app's cached Claude/Codex usage to agents over stdio.
///
/// It is a **reader only**. MCP servers are spawned per client session, so a server that
/// fetched usage itself would multiply request load across every concurrent agent — the exact
/// pattern that gets an account throttled. Everything here comes from `usage.json`, which the
/// TokenRation app writes after each of its own (rate-limit-disciplined) polls. Freshness is
/// reported rather than chased, so callers can decide whether the reading is good enough.

/// Reported to clients on `initialize`. Read from the bundle the binary ships inside, so it
/// tracks the app's version instead of being a literal that has to be remembered each release.
///
/// `Bundle.main` is resolved from the path used to launch the process, and the cask puts this
/// binary on `PATH` as a symlink into the app — so launched that way it would look for an
/// `Info.plist` next to the symlink and find none. Resolving the link first lands inside
/// `TokenRation.app/Contents/MacOS`, whose bundle is three levels up.
let serverVersion: String = {
  let key = "CFBundleShortVersionString"
  if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
    let bundleURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if let bundle = Bundle(url: bundleURL), let version = bundle.object(forInfoDictionaryKey: key) as? String { return version }
  }
  return Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "0.0.0"
}()

// MARK: - JSON-RPC plumbing

/// Minimal dynamic JSON so we can echo arbitrary client values without modelling them.
enum JSON: Codable {
  case null, bool(Bool), number(Double), string(String)
  case array([JSON]), object([String: JSON])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSON].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSON].self) {
      self = .object(value)
    } else {
      self = .null
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  var stringValue: String? {
    if case .string(let value) = self { return value };
    return nil
  }
  subscript(key: String) -> JSON? {
    if case .object(let dictionary) = self { return dictionary[key] }
    return nil
  }
}

struct Request: Decodable {
  let id: JSON?
  let method: String
  let params: JSON?
}

/// Write one JSON-RPC message per line to stdout.
func emit(_ object: [String: Any]) {
  var message = object
  message["jsonrpc"] = "2.0"
  guard let data = try? JSONSerialization.data(withJSONObject: message), let line = String(data: data, encoding: .utf8) else { return }
  print(line)
  fflush(stdout)
}

func respond(id: JSON, result: [String: Any]) {
  guard let encoded = try? JSONEncoder().encode(id),
    let idValue = try? JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
  else { return }
  emit(["id": idValue, "result": result])
}

func respondError(id: JSON, code: Int, message: String) {
  guard let encoded = try? JSONEncoder().encode(id),
    let idValue = try? JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
  else { return }
  emit(["id": idValue, "error": ["code": code, "message": message]])
}

/// Wrap a payload as an MCP tool result: human-readable text plus the raw JSON.
func toolResult(summary: String, payload: [String: Any]) -> [String: Any] {
  let json =
    (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])).flatMap {
      String(data: $0, encoding: .utf8)
    } ?? "{}"
  return ["content": [["type": "text", "text": "\(summary)\n\n\(json)"]]]
}

// MARK: - Reading the published state

/// A function rather than a shared formatter: top-level bindings are main-actor isolated in
/// Swift 6, and these helpers are nonisolated.
func isoString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

func stateOrNil() -> UsageState? { UsageStateStore.read() }

func missingStateResult() -> [String: Any] {
  toolResult(
    summary: "No usage data available. TokenRation has not written a reading yet — " + "is the app installed and running? (It publishes to "
      + "~/Library/Application Support/TokenRation/usage.json)", payload: ["available": false])
}

/// Flatten the state into plain dictionaries, adding derived freshness/countdown fields as of `now`.
func snapshotPayload(_ state: UsageState, now: Date) -> [String: Any] {
  let fileAge = Int(now.timeIntervalSince(state.writtenAt))
  var providers: [[String: Any]] = []
  for provider in state.providers {
    var metrics: [[String: Any]] = []
    for metric in provider.metrics {
      var entry: [String: Any] = [
        "id": metric.id, "title": metric.title, "value": metric.value, "detail": metric.detail, "severity": metric.severity,
      ]
      if let percent = metric.usedPercent { entry["usedPercent"] = percent }
      if let resets = metric.resetsAt {
        entry["resetsAt"] = isoString(resets)
        entry["resetsInSeconds"] = max(Int(resets.timeIntervalSince(now)), 0)
      }
      metrics.append(entry)
    }
    var entry: [String: Any] = [
      "provider": provider.provider, "displayName": provider.displayName, "status": provider.status, "metrics": metrics,
    ]
    if let error = provider.error { entry["error"] = error }
    // Freshness is per provider: the file is rewritten on any observable change, so its
    // age would overstate how current these numbers are.
    if let updated = provider.updatedAt {
      entry["updatedAt"] = isoString(updated)
      entry["ageSeconds"] = Int(provider.readingAge(now: now) ?? 0)
    }
    entry["stale"] = provider.isStale(pollIntervalSeconds: state.pollIntervalSeconds, now: now)
    if let until = provider.rateLimitedUntil { entry["rateLimitedUntil"] = isoString(until) }
    providers.append(entry)
  }
  // Provider entries carry the age that matters; these describe the file itself.
  return [
    "available": true, "writtenAt": isoString(state.writtenAt), "stateFileAgeSeconds": fileAge,
    "pollIntervalSeconds": state.pollIntervalSeconds, "providers": providers,
  ]
}

// MARK: - Tools

let tools: [[String: Any]] = [
  [
    "name": "get_usage",
    "description": """
    Current Claude and Codex usage limits (session/weekly windows, per-model limits, \
    spend) as most recently read by the TokenRation menu-bar app. Includes how old the \
    reading is. Use this to see how much quota is left before doing expensive work.
    """, "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
  ]
]

func callGetUsage() -> [String: Any] {
  guard let state = stateOrNil() else { return missingStateResult() }
  // One moment for both, so the line a caller quotes and the payload beside it give the same ages and countdowns.
  let now = Date()
  return toolResult(summary: UsageSummary.text(for: state, now: now), payload: snapshotPayload(state, now: now))
}

// MARK: - Serve

while let line = readLine(strippingNewline: true) {
  guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let data = line.data(using: .utf8),
    let request = try? JSONDecoder().decode(Request.self, from: data)
  else { continue }

  switch request.method {
  case "initialize":
    guard let id = request.id else { break }
    // Echo the client's protocol version when it sends one — most compatible behaviour.
    let version = request.params?["protocolVersion"]?.stringValue ?? "2025-06-18"
    respond(
      id: id,
      result: [
        "protocolVersion": version, "capabilities": ["tools": [:] as [String: Any]],
        "serverInfo": ["name": "tokenration", "version": serverVersion],
      ])

  case "tools/list":
    guard let id = request.id else { break }
    respond(id: id, result: ["tools": tools])

  case "tools/call":
    guard let id = request.id else { break }
    let name = request.params?["name"]?.stringValue ?? ""
    switch name {
    case "get_usage": respond(id: id, result: callGetUsage())
    default: respondError(id: id, code: -32602, message: "Unknown tool: \(name)")
    }

  case "ping": if let id = request.id { respond(id: id, result: [:]) }

  default:
    // Notifications (no id) need no reply — e.g. notifications/initialized.
    if let id = request.id { respondError(id: id, code: -32601, message: "Unknown method: \(request.method)") }
  }
}
