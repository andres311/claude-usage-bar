import Foundation

// Tests for the pure logic: process-table parsing, severity, formatting and the derived
// rows. No XCTest and no test target, for the same reason there is no Xcode project: a
// plain `swiftc` invocation over the two files that hold logic keeps this a one-second
// run. `make test` builds and runs it. Everything here must stay free of AppKit state.

var failures = 0
var checks = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: UInt = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  FAIL \(what)\n       got      \(actual)\n       expected \(expected)  (line \(line))")
    }
}

func suite(_ name: String, _ body: () -> Void) {
    print("• \(name)")
    body()
}

// MARK: - Process table

suite("AgentsMonitor.isClaude") {
    // The IDE extension ships its own binary.
    expect(AgentsMonitor.isClaude(args:
        "/Users/x/.vscode/extensions/anthropic.claude-code-2.1.220-darwin-arm64/resources/native-binary/claude --output-format stream-json"),
        true, "vscode native binary")
    // Native install, run through the symlink and through the resolved version path.
    expect(AgentsMonitor.isClaude(args: "/Users/x/.local/bin/claude"), true, "native symlink")
    expect(AgentsMonitor.isClaude(args: "/Users/x/.local/share/claude/versions/2.0.76 --resume"),
           true, "resolved version binary")
    // npm/bun installs go through an interpreter.
    expect(AgentsMonitor.isClaude(args: "node /opt/homebrew/bin/claude -p hello"), true, "node shim")
    expect(AgentsMonitor.isClaude(args:
        "/usr/local/bin/node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"),
        true, "node entry point")
    expect(AgentsMonitor.isClaude(args: "bun /Users/x/.bun/bin/claude"), true, "bun shim")
    // Neither the desktop app nor this app is an agent.
    expect(AgentsMonitor.isClaude(args: "/Applications/Claude.app/Contents/MacOS/Claude"),
           false, "desktop app")
    expect(AgentsMonitor.isClaude(args:
        "/Users/x/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage"), false, "this app")
    // A file that happens to be called claude is not a session: only a known
    // interpreter's argv[1] counts.
    expect(AgentsMonitor.isClaude(args: "vim claude"), false, "editing a file named claude")
    expect(AgentsMonitor.isClaude(args: "grep -r claude ."), false, "grep")
    expect(AgentsMonitor.isClaude(args: ""), false, "empty args")
    expect(AgentsMonitor.isClaude(args: "/usr/bin/vim notes.txt"), false, "no claude anywhere")

    // `ps` prints argv space-joined and unquoted, so an install path with a space in it
    // looks like two arguments. `exists` decides whether to fold the next token in.
    let nothingExists: (String) -> Bool = { _ in false }
    expect(AgentsMonitor.isClaude(args: "/Users/x/My Code/.local/bin/claude --resume",
                                  exists: nothingExists),
           true, "space in the install path")
    expect(AgentsMonitor.isClaude(args: "node /Users/x/My Code/bin/claude", exists: nothingExists),
           true, "space in the path behind an interpreter")
    // But folding must not invent a match: a real executable is never extended, and a
    // relative argv[0] is never extended at all.
    expect(AgentsMonitor.isClaude(args: "/usr/bin/vim claude", exists: { $0 == "/usr/bin/vim" }),
           false, "editing claude through an absolute path")
    expect(AgentsMonitor.isClaude(args: "/opt/tools/lint claude-code", exists: nothingExists),
           false, "folded candidate that still is not claude")
}

suite("AgentsMonitor.argv0Candidates") {
    let nothingExists: (String) -> Bool = { _ in false }
    expect(AgentsMonitor.argv0Candidates("vim claude", exists: nothingExists),
           ["vim"], "relative argv0 is never extended")
    expect(AgentsMonitor.argv0Candidates("/a/b c/d --flag e", exists: nothingExists),
           ["/a/b", "/a/b c/d"], "folds until a flag")
    expect(AgentsMonitor.argv0Candidates("/bin/ls extra", exists: { $0 == "/bin/ls" }),
           ["/bin/ls"], "stops once the candidate exists")
    expect(AgentsMonitor.argv0Candidates("", exists: nothingExists), [], "empty")
}

suite("AgentsMonitor.hostName") {
    expect(AgentsMonitor.hostName(args: "/Users/x/.vscode/extensions/anthropic.claude-code/claude"),
           "VS Code", "vscode")
    expect(AgentsMonitor.hostName(args: "/Users/x/.cursor/extensions/anthropic.claude-code/claude"),
           "Cursor", "cursor")
    expect(AgentsMonitor.hostName(args: "/Users/x/.local/bin/claude -p 'do a thing'"),
           "Headless", "-p")
    expect(AgentsMonitor.hostName(args: "/Users/x/.local/bin/claude --print"), "Headless", "--print")
    expect(AgentsMonitor.hostName(args: "/Users/x/.local/bin/claude"), "Terminal", "plain")
    // A path containing "-p" is not a headless run.
    expect(AgentsMonitor.hostName(args: "/Users/x/my-project/bin/claude"), "Terminal", "-p in a path")
    expect(AgentsMonitor.hostName(args: "/Users/x/bin/my-print/claude"), "Terminal", "--print in a path")
    // argv[0] itself is skipped, so an executable literally called -p is not a flag.
    expect(AgentsMonitor.hostName(args: "-p"), "Terminal", "argv0 only")
    expect(AgentsMonitor.hostName(args: "/Users/x/.local/bin/claude --resume -p"), "Headless", "trailing -p")
}

suite("AgentsMonitor.elapsedSeconds") {
    expect(AgentsMonitor.elapsedSeconds("03:12"), 192, "mm:ss")
    expect(AgentsMonitor.elapsedSeconds("00:07"), 7, "seconds only")
    expect(AgentsMonitor.elapsedSeconds("03:49:30"), 13_770, "hh:mm:ss")
    expect(AgentsMonitor.elapsedSeconds("2-03:49:30"), 186_570, "dd-hh:mm:ss")
    expect(AgentsMonitor.elapsedSeconds("garbage"), 0, "unparseable")
}

suite("AgentsMonitor.humanElapsed") {
    expect(AgentsMonitor.humanElapsed(192), "3m", "minutes")
    expect(AgentsMonitor.humanElapsed(7), "0m", "under a minute")
    expect(AgentsMonitor.humanElapsed(13_770), "3h 49m", "hours")
    expect(AgentsMonitor.humanElapsed(186_570), "51h 49m", "past a day")
}

suite("AgentsMonitor.precedes") {
    func agent(_ id: Int32, _ folder: String, _ elapsed: TimeInterval) -> AgentProcess {
        AgentProcess(id: id, folder: folder, host: "Terminal", elapsed: elapsed,
                     uptime: AgentsMonitor.humanElapsed(elapsed))
    }
    let sorted = [
        agent(4, "", 900),              // no folder: goes last
        agent(1, "penmark", 600),
        agent(2, "app10", 60),
        agent(3, "Nexus", 60),
        agent(5, "penmark", 4000),      // same folder, running longer: goes first
        agent(6, "app2", 60),
        agent(7, "penmark", 600),       // ties with 1 on both keys: pid breaks it
    ].sorted(by: AgentsMonitor.precedes)

    expect(sorted.map(\.id), [6, 2, 3, 5, 1, 7, 4], "folder, then longest running, then pid")
    // Spelled out: numeric-aware (app2 < app10), case-insensitive (Nexus among lowercase).
    expect(sorted.map(\.folder), ["app2", "app10", "Nexus", "penmark", "penmark", "penmark", ""],
           "folder order")
}

suite("AgentsMonitor.sameOnScreen") {
    func agent(_ id: Int32, _ folder: String, _ elapsed: TimeInterval) -> AgentProcess {
        AgentProcess(id: id, folder: folder, host: "Terminal", elapsed: elapsed,
                     uptime: AgentsMonitor.humanElapsed(elapsed))
    }
    let now = [agent(1, "penmark", 600), agent(2, "nexus", 60)]
    // A second later every `elapsed` has moved, but nothing printed has: this must not
    // publish, or the panel re-runs its body once a second while it is open.
    expect(AgentsMonitor.sameOnScreen(now, [agent(1, "penmark", 601), agent(2, "nexus", 61)]),
           true, "a second of elapsed time alone is not a change")
    // The minute rolling over is a change: "9m" becomes "10m" on screen.
    expect(AgentsMonitor.sameOnScreen(now, [agent(1, "penmark", 660), agent(2, "nexus", 60)]),
           false, "uptime crossing a minute")
    // And an agent starting or ending is the whole point.
    expect(AgentsMonitor.sameOnScreen(now, [agent(1, "penmark", 600)]), false, "one closed")
    expect(AgentsMonitor.sameOnScreen(now, now + [agent(3, "app", 5)]), false, "one opened")
    expect(AgentsMonitor.sameOnScreen(now, [agent(1, "penmark", 600), agent(9, "nexus", 60)]),
           false, "same shape, different pid")
    expect(AgentsMonitor.sameOnScreen([], []), true, "both empty")
}

// MARK: - Severity

suite("Severity.from") {
    expect(Severity.from(apiValue: nil, percent: 10), .normal, "low")
    expect(Severity.from(apiValue: nil, percent: 75), .warning, "warning threshold")
    expect(Severity.from(apiValue: nil, percent: 90), .critical, "critical threshold")
    // The API can escalate early.
    expect(Severity.from(apiValue: "warning", percent: 10), .warning, "api escalates")
    expect(Severity.from(apiValue: "exceeded", percent: 10), .critical, "api exceeded")
    // But it never downgrades what the thresholds already flagged.
    expect(Severity.from(apiValue: "normal", percent: 95), .critical, "api normal at 95%")
    expect(Severity.from(apiValue: "", percent: 80), .warning, "empty api value")
    expect(Severity.from(apiValue: "something-new", percent: 10), .normal, "unknown api value")
}

// MARK: - Formatting

suite("Fmt") {
    expect(Fmt.percent(0), "0%", "zero")
    expect(Fmt.percent(72.4), "72%", "rounds down")
    expect(Fmt.percent(72.6), "73%", "rounds up")

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    expect(Fmt.countdown(to: nil, from: now), "", "no date")
    expect(Fmt.countdown(to: now.addingTimeInterval(-5), from: now), "now", "past")
    expect(Fmt.countdown(to: now.addingTimeInterval(30), from: now), "1m", "under a minute")
    expect(Fmt.countdown(to: now.addingTimeInterval(12 * 60), from: now), "12m", "minutes")
    expect(Fmt.countdown(to: now.addingTimeInterval(3 * 3600 + 49 * 60), from: now), "3h 49m", "hours")
    expect(Fmt.countdown(to: now.addingTimeInterval(2 * 86_400 + 3 * 3600), from: now), "2d 3h", "days")

    // Pinned to en_US rather than the machine's locale: the panel *should* render
    // "US$ 64,20" for a reader in Argentina, so asserting against `.current` would make
    // this pass on one Mac and fail on the next.
    let en = Locale(identifier: "en_US")
    expect(Fmt.money(nil, decimals: 2, currency: "USD", locale: en), nil, "no amount")
    expect(Fmt.money(6420, decimals: 2, currency: "USD", locale: en), "$64.20", "minor units")
    expect(Fmt.money(6420, decimals: nil, currency: nil, locale: en), "$64.20", "defaults")
    // Not spelled out in full: the German form separates the symbol with a non-breaking
    // space, and pinning that byte tests Foundation's CLDR data rather than this code.
    expect(Fmt.money(6420, decimals: 2, currency: "USD",
                     locale: Locale(identifier: "de_DE"))?.contains("64,20"),
           true, "follows the reader's locale")
    // Same arguments twice: the formatter is cached, and a cached one must still be
    // configured (a shared instance reset by a later call would break this).
    expect(Fmt.money(100, decimals: 2, currency: "USD", locale: en), "$1.00", "cached formatter")

    // Both ISO forms the endpoint has been seen to send.
    expect(Fmt.date("2026-07-30T12:00:00Z")?.timeIntervalSince1970, 1_785_412_800, "iso")
    expect(Fmt.date("2026-07-30T12:00:00.000Z")?.timeIntervalSince1970, 1_785_412_800, "iso fractional")
    expect(Fmt.date("nonsense"), nil, "unparseable")
    expect(Fmt.date(nil), nil, "nil")
}

// MARK: - Derived rows

func decode(_ json: String) -> UsageResponse {
    try! JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
}

suite("UsageResponse.rows") {
    let response = decode("""
    {"limits": [
      {"kind": "weekly_scoped", "percent": 30, "scope": {"model": {"id": "opus", "display_name": "Opus"}}},
      {"kind": "weekly_all", "percent": 72},
      {"kind": "session", "percent": 11, "resets_at": "2026-07-30T12:00:00Z"},
      {"kind": "weekly_scoped", "percent": 5, "is_active": false,
       "scope": {"model": {"id": "haiku", "display_name": "Haiku"}}}
    ]}
    """)
    let rows = response.rows
    // `is_active: false` does not hide a limit: the live endpoint sets it on limits that
    // plainly exist, so Haiku here gets a bar like everything else.
    expect(rows.map(\.id),
           ["session", "weekly_all", "weekly_scoped-opus", "weekly_scoped-haiku"],
           "order and identity")
    expect(rows.map(\.title),
           ["Current session", "Weekly (all models)", "Weekly (Opus)", "Weekly (Haiku)"],
           "titles")
    expect(rows[0].resetsAt?.timeIntervalSince1970, 1_785_412_800, "reset date")
    expect(response.session?.percent, 11, "session percent")
    expect(response.weekly?.percent, 72, "weekly percent")

    // Same limits, different order: the ids must not move with the index.
    let shuffled = decode("""
    {"limits": [
      {"kind": "weekly_all", "percent": 72},
      {"kind": "weekly_scoped", "percent": 30, "scope": {"model": {"id": "opus"}}},
      {"kind": "session", "percent": 11}
    ]}
    """)
    expect(shuffled.rows.map(\.id), ["session", "weekly_all", "weekly_scoped-opus"], "stable ids")

    // Two scoped weeklies the API cannot tell apart still get distinct ids.
    let ambiguous = decode("""
    {"limits": [{"kind": "weekly_scoped", "percent": 1}, {"kind": "weekly_scoped", "percent": 2}]}
    """)
    expect(ambiguous.rows.map(\.id), ["weekly_scoped", "weekly_scoped-1"], "deduped ids")

    // Three of them: the invented suffix has to be claimed too, or the entry at offset 1
    // and a later `weekly_scoped-1` could end up sharing an id.
    let ambiguous3 = decode("""
    {"limits": [{"kind": "weekly_scoped", "percent": 1}, {"kind": "weekly_scoped", "percent": 2},
                {"kind": "weekly_scoped", "percent": 3}]}
    """)
    expect(Set(ambiguous3.rows.map(\.id)).count, 3, "three ambiguous entries stay distinct")

    // Fallback shape, used when `limits` is absent.
    let legacy = decode("""
    {"five_hour": {"utilization": 11, "resets_at": "2026-07-30T12:00:00Z"},
     "seven_day": {"utilization": 72}}
    """)
    expect(legacy.rows.map(\.id), ["five_hour", "seven_day"], "legacy rows")
    expect(legacy.session?.percent, 11, "legacy session percent")
    expect(legacy.weekly?.percent, 72, "legacy weekly percent")

    // An empty response degrades to nothing rather than crashing.
    expect(decode("{}").rows.count, 0, "empty response")
    expect(decode("{}").session?.percent, nil, "empty session percent")

    // The shape the live endpoint actually returns, trimmed: `is_active` is true on
    // exactly one entry (the highest), and false on a session and a scoped weekly that
    // both exist. Filtering on it used to collapse this to a single bar.
    let live = decode("""
    {"five_hour": {"utilization": 45, "resets_at": "2026-07-31T01:40:00.105304+00:00"},
     "seven_day": {"utilization": 76},
     "limits": [
      {"kind": "session", "group": "session", "percent": 45, "severity": "normal",
       "resets_at": "2026-07-31T01:40:00.105304+00:00", "scope": null, "is_active": false},
      {"kind": "weekly_all", "group": "weekly", "percent": 76, "severity": "warning",
       "scope": null, "is_active": true},
      {"kind": "weekly_scoped", "group": "weekly", "percent": 65, "severity": "normal",
       "scope": {"model": {"id": null, "display_name": "Fable"}}, "is_active": false}
     ]}
    """)
    expect(live.rows.map(\.title),
           ["Current session", "Weekly (all models)", "Weekly (Fable)"], "every live limit shows")
    expect(live.rows.map(\.id), ["session", "weekly_all", "weekly_scoped-Fable"], "live ids")
    expect(live.rows[2].percent, 65, "fable percent")
    // The live endpoint sends six fractional digits and a numeric offset rather than "Z";
    // pinned to the exact instant, because a countdown that is quietly hours off looks
    // just as plausible as a correct one.
    expect(live.rows[0].resetsAt.map { $0.timeIntervalSince1970.rounded() },
           1_785_462_000, "6-digit offset timestamp")
}

suite("UsageResponse gauges") {
    // The menu bar chip has to carry the API's severity, not re-derive one from the
    // number: this weekly is at 30% and already flagged.
    let escalated = decode("""
    {"limits": [{"kind": "weekly_all", "percent": 30, "severity": "critical"},
                {"kind": "session", "percent": 12, "severity": "normal"}]}
    """)
    expect(escalated.weekly?.severity, .critical, "api severity reaches the chip")
    expect(escalated.session?.severity, .normal, "unflagged stays normal")
    // And the local thresholds still win when the API says nothing.
    let quiet = decode("{\"limits\": [{\"kind\": \"session\", \"percent\": 95}]}")
    expect(quiet.session?.severity, .critical, "threshold without an api severity")
    // Fallback shape has no severity of its own.
    expect(decode("{\"five_hour\": {\"utilization\": 80}}").session?.severity, .warning, "legacy")

    let credits = decode("""
    {"extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 9500,
                     "utilization": 95, "currency": "USD", "decimal_places": 2}}
    """)
    expect(credits.credits?.severity, .critical, "credits gauge")
}

suite("UsageResponse.creditsRow") {
    let en = Locale(identifier: "en_US")
    let on = decode("""
    {"extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 6420,
                     "currency": "USD", "decimal_places": 2}}
    """)
    expect(on.creditsRow(locale: en)?.detail, "$64.20 / $100.00", "spend detail")
    expect(on.creditsRow(locale: en)?.percent, 64.2, "derived percent")
    expect(on.creditsRow(locale: en)?.severity, .normal, "severity")

    let capped = decode("""
    {"extra_usage": {"is_enabled": true, "used_credits": 10000, "utilization": 100,
                     "spend_limit_reached": true}}
    """)
    expect(capped.creditsRow(locale: en)?.severity, .critical, "spend limit reached")

    expect(decode("{\"extra_usage\": {\"is_enabled\": false}}").creditsRow()?.percent, nil, "disabled")
    expect(decode("{}").creditsRow()?.percent, nil, "absent")
}

// MARK: - Result

print(failures == 0
      ? "\n\(checks) checks passed"
      : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
