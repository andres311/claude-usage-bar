import AppKit
import Foundation

// Tests for everything that can be decided without a running app: the process-table
// rules, severity, formatting, the derived rows, the menu bar chips, the 429 backoff
// arithmetic, the status image, the credentials parser and the login-item rule. No XCTest
// and no test target, for the same reason there is no Xcode project: one `swiftc`
// invocation over every source but `App.swift` keeps this a one-second run. `make test`
// builds and runs it.
//
// The line between what is tested here and what is not is the main actor and the outside
// world. Anything needing an `NSStatusItem`, a socket or the real process table stays
// out, which is why the decisions inside `UsageModel` are reached through `nonisolated
// static` functions that take their inputs rather than read them off a published model.
// AppKit is imported but never started: `StatusIcon` only measures and draws into an
// `NSImage`, which needs no `NSApplication`.

var failures = 0
var checks = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: UInt = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  FAIL \(what)\n       got      \(actual)\n       expected \(expected)  (line \(line))")
    }
}

func expectTrue(_ actual: Bool, _ what: String, line: UInt = #line) {
    expect(actual, true, what, line: line)
}

func suite(_ name: String, _ body: () -> Void) {
    print("• \(name)")
    body()
}

// MARK: - Process table

suite("AgentsMonitor.isAgent") {
    // `execPath` is what the kernel ran, already symlink-resolved; argv is the vector as
    // it was stored at exec. Both come straight from libproc, so neither is reconstructed
    // from text and neither can be ambiguous.
    func agent(_ exec: String, _ argv: [String] = []) -> Bool {
        AgentsMonitor.isAgent(execPath: exec, argv: argv.isEmpty ? [exec] : argv)
    }
    // The IDE extension ships its own binary.
    expect(agent("/Users/x/.vscode/extensions/anthropic.claude-code-2.1.220-darwin-arm64/resources/native-binary/claude"),
           true, "vscode native binary")
    // Native install: the symlink resolves to the versioned binary before we see it, so
    // both spellings have to match.
    expect(agent("/Users/x/.local/bin/claude"), true, "native install")
    expect(agent("/Users/x/.local/share/claude/versions/2.0.76"), true, "resolved version binary")
    // npm/bun installs go through an interpreter, and only there does argv count.
    expect(agent("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/claude", "-p", "hello"]),
           true, "node shim")
    expect(agent("/usr/local/bin/node",
                 ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]),
           true, "node entry point")
    expect(agent("/Users/x/.bun/bin/bun", ["bun", "/Users/x/.bun/bin/claude"]), true, "bun shim")
    // Flags in front of the script must not hide it.
    expect(agent("/usr/local/bin/node", ["node", "--enable-source-maps", "/opt/bin/claude"]),
           true, "interpreter flags before the script")
    // Nor may a flag that takes a *value*, which lands exactly where "the first argument
    // without a dash" expects to find the script. These used to be missed outright.
    expect(agent("/usr/local/bin/node", ["node", "-r", "./polyfill.js", "/opt/bin/claude"]),
           true, "value-taking flag before the script")
    expect(agent("/usr/local/bin/node",
                 ["node", "--import", "./hook.mjs", "--enable-source-maps", "/opt/bin/claude"]),
           true, "several flags, one of them with a value")
    expect(agent("/usr/local/bin/node", ["node", "-r", "./polyfill.js", "/opt/tools/lint"]),
           false, "value-taking flag and no claude anywhere")
    // Neither the desktop app nor this app is an agent (`Claude` is not `claude`).
    expect(agent("/Applications/Claude.app/Contents/MacOS/Claude"), false, "desktop app")
    expect(agent("/Users/x/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage"),
           false, "this app")
    // A file that happens to be called claude is not a session: the executable decides,
    // and only a known interpreter's script argument gets a second look.
    expect(agent("/usr/bin/vim", ["vim", "claude"]), false, "editing a file named claude")
    expect(agent("/usr/bin/grep", ["grep", "-r", "claude", "."]), false, "grep")
    expect(agent("", []), false, "no executable")
    expect(agent("/usr/bin/vim", ["vim", "notes.txt"]), false, "no claude anywhere")
    // An interpreter with nothing to run, and one running something else.
    expect(agent("/usr/local/bin/node", ["node"]), false, "bare interpreter")
    expect(agent("/usr/local/bin/node", ["node", "--eval", "--"]), false, "interpreter, flags only")
    expect(agent("/usr/local/bin/node", ["node", "/opt/tools/lint", "claude-code"]),
           false, "interpreter running something else")
    // `cli.js` only counts inside the package: it is the most generic name in npm.
    expect(agent("/usr/local/bin/node", ["node", "/opt/other/cli.js"]), false, "unrelated cli.js")
    // A path with a space in it is just a path: the executable arrives as its own string,
    // so there is no joined line to split and no quoting to recover.
    expect(agent("/Users/x/My Code/.local/bin/claude"), true, "space in the install path")
    expect(agent("/usr/local/bin/node", ["node", "/Users/x/My Code/bin/claude"]),
           true, "space in the path behind an interpreter")
    // A shell wrapper named `claude` arrives as the shell, with argv[0] naming the shell
    // too (verified against a live `#!/bin/sh` script), so it does not match.
    expect(agent("/bin/bash", ["/bin/sh", "./claude"]), false, "shell wrapper named claude")
}

suite("AgentsMonitor.hostName") {
    func host(_ exec: String, _ argv: [String] = []) -> String {
        AgentsMonitor.hostName(execPath: exec, argv: argv.isEmpty ? [exec] : argv)
    }
    let cli = "/Users/x/.local/bin/claude"
    expect(host("/Users/x/.vscode/extensions/anthropic.claude-code/claude"), "VS Code", "vscode")
    expect(host("/Users/x/.vscode-server/bin/claude"), "VS Code", "vscode remote")
    expect(host("/Users/x/.cursor/extensions/anthropic.claude-code/claude"), "Cursor", "cursor")
    expect(host("/Users/x/Library/Application Support/JetBrains/plugin/claude"),
           "JetBrains", "jetbrains")
    expect(host(cli, [cli, "--ide", "/Users/x/project/.idea"]), "JetBrains", "idea from argv")
    expect(host(cli, [cli, "-p", "do a thing"]), "Headless", "-p")
    expect(host(cli, [cli, "--print"]), "Headless", "--print")
    expect(host(cli), "Terminal", "plain")
    // A path containing "-p" is not a headless run.
    expect(host("/Users/x/my-project/bin/claude"), "Terminal", "-p in a path")
    expect(host("/Users/x/bin/my-print/claude"), "Terminal", "--print in a path")
    // argv[0] itself is skipped, so an executable literally called -p is not a flag.
    expect(host("-p"), "Terminal", "argv0 only")
    expect(host(cli, [cli, "--resume", "-p"]), "Headless", "trailing -p")
    // A prompt that merely contains " -p " is one argv entry, never a flag: the vector
    // is matched entry by entry rather than flattened into a line.
    expect(host(cli, [cli, "fix the -p flag"]), "Terminal", "-p inside a prompt")
    // The IDE markers get the same treatment. A prompt is an argv entry like any other, so
    // matching them against the flattened line made talking about VS Code a VS Code
    // session; only entries that look like a path (a slash, no whitespace) are searched.
    expect(host(cli, [cli, "-p", "fix the .vscode/extensions loader"]), "Headless",
           "a prompt naming an extensions folder is not an IDE session")
    expect(host(cli, [cli, "rename .idea/workspace.xml and move on"]), "Terminal",
           "a prompt naming .idea is not JetBrains")
    // But a real path argument still counts, spaces in the *executable* included: it is a
    // path by definition, so it is searched whatever it contains.
    expect(host(cli, [cli, "--add-dir", "/Users/x/.cursor/extensions/anthropic.claude-code"]),
           "Cursor", "path argument still identifies the host")
    expect(host("/Users/x/My Apps/JetBrains/plugin/claude"), "JetBrains",
           "space in the executable path")
}

suite("AgentsMonitor: the Claude desktop app") {
    let vmHost = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
        + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/"
        + "com.apple.Virtualization.VirtualMachine"

    // A desktop session runs in a guest, so nothing about the host process names Claude:
    // the executable is Apple's, argv is bare and the ordinary rules must not match it.
    expectTrue(AgentsMonitor.isVirtualizationHost(vmHost), "the VM host process")
    expect(AgentsMonitor.isAgent(execPath: vmHost, argv: [vmHost]), false,
           "and it is not an agent by the `claude` rules")
    expect(AgentsMonitor.isVirtualizationHost("/Users/x/.local/bin/claude"), false, "a CLI is not a VM")
    expect(AgentsMonitor.isVirtualizationHost("/Applications/UTM.app/Contents/MacOS/UTM"),
           false, "another virtualizer's own binary")
    expect(AgentsMonitor.isVirtualizationHost(""), false, "no executable")

    // Which is why matching the executable settles nothing: every Virtualization.framework
    // client on the machine runs that same system binary. The guest disk image is what
    // separates Claude's VM from Docker's.
    let bundle = "/Users/x/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
    expectTrue(AgentsMonitor.namesClaudeVMBundle(bundle + "/rootfs.img"), "the guest root disk")
    expectTrue(AgentsMonitor.namesClaudeVMBundle(bundle + "/sessiondata.img"), "the session disk")
    expectTrue(AgentsMonitor.namesClaudeVMBundle(bundle + "/efivars.fd"), "the firmware vars")
    // Sandboxed, the same directory moves into the app's container. Matching a substring
    // rather than an absolute path is what survives that.
    expectTrue(AgentsMonitor.namesClaudeVMBundle(
        "/Users/x/Library/Containers/com.anthropic.claudefordesktop/Data/Library/"
        + "Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img"),
        "the sandboxed container path")
    // Near misses: another app's VM, and a file that merely sits under the app's support
    // directory, which every Electron cache does.
    expect(AgentsMonitor.namesClaudeVMBundle(
        "/Users/x/Library/Application Support/OtherVM/vm_bundles/disk.img"), false,
        "another app's guest disk")
    expect(AgentsMonitor.namesClaudeVMBundle(
        "/Users/x/Library/Application Support/Claude/Cache/data_0"), false,
        "an ordinary file of the desktop app")
    expect(AgentsMonitor.namesClaudeVMBundle("/Users/x/vm_bundles/claudevm.bundle/rootfs.img"),
           false, "a bundle outside the app's support directory")

    // The app's *other* local mode is not a VM at all, and needs none of this: its binary
    // is called `claude`, so the ordinary rule already finds it.
    expectTrue(AgentsMonitor.isAgent(
        execPath: "/Users/x/Library/Application Support/Claude/claude-code/2.1.219/"
            + "claude.app/Contents/MacOS/claude", argv: []),
        "the desktop app's non-VM local binary is an ordinary session")

    // What the row says. A guest has no host-side working directory, so "unknown folder"
    // would be a wrong answer rather than a missing one.
    func row(_ kind: AgentProcess.Kind, folder: String) -> AgentProcess {
        AgentProcess(id: 1, folder: folder, host: "Terminal", elapsed: 60, uptime: "1m", kind: kind)
    }
    expect(row(.desktopVM, folder: "").label, "Desktop session", "a VM with no folder")
    expect(row(.cli, folder: "").label, "unknown folder", "a CLI whose cwd could not be read")
    expect(row(.cli, folder: "penmark").label, "penmark", "an ordinary session")
    expect(row(.desktopVM, folder: "penmark").label, "penmark",
           "a folder, if there ever is one, still wins")
    expect(AgentProcess(id: 1, folder: "p", host: "Terminal", elapsed: 1, uptime: "0m").kind,
           .cli, "the default kind is the ordinary one")

    // It goes to the bottom of the list, like anything else without a folder, rather than
    // interleaving with real directories.
    let sorted = [row(.desktopVM, folder: ""),
                  AgentProcess(id: 2, folder: "penmark", host: "VS Code", elapsed: 60, uptime: "1m")]
        .sorted(by: AgentsMonitor.precedes)
    expect(sorted.map(\.id), [2, 1], "the desktop session sorts last")
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
    // The working directory can read empty on the scan that first sees a process and
    // resolve on the next one, so it has to count as a change under a stable pid.
    expect(AgentsMonitor.sameOnScreen(now, [agent(1, "", 600), agent(2, "nexus", 60)]),
           false, "folder resolved late")
    expect(AgentsMonitor.sameOnScreen([], []), true, "both empty")

    // The two new columns follow the same rule as `elapsed`/`uptime`: the raw number moves
    // on every scan and must not publish, the string drawn from it must.
    func sized(_ id: Int32, _ bytes: UInt64, active: Bool = false) -> AgentProcess {
        AgentProcess(id: id, folder: "penmark", host: "Terminal", elapsed: 600,
                     uptime: "10m", cpuNanos: 0, memoryBytes: bytes,
                     memoryText: Fmt.memory(bytes, locale: Locale(identifier: "en_US")),
                     isActive: active)
    }
    let mb200 = UInt64(200 * 1_048_576)
    expect(AgentsMonitor.sameOnScreen([sized(1, mb200)], [sized(1, mb200 + 4096)]),
           true, "memory moving a few pages does not move the string")
    expect(AgentsMonitor.sameOnScreen([sized(1, mb200)], [sized(1, mb200 + 3_000_000)]),
           false, "memory crossing a megabyte")
    expect(AgentsMonitor.sameOnScreen([sized(1, mb200)], [sized(1, mb200, active: true)]),
           false, "a session starting work")
    // cpuNanos climbs on every single scan and is not drawn anywhere.
    let a = AgentProcess(id: 1, folder: "p", host: "Terminal", elapsed: 600, uptime: "10m",
                         cpuNanos: 1_000_000, memoryBytes: mb200, memoryText: "200 MB")
    let b = AgentProcess(id: 1, folder: "p", host: "Terminal", elapsed: 601, uptime: "10m",
                         cpuNanos: 9_999_999_999, memoryBytes: mb200, memoryText: "200 MB")
    expect(AgentsMonitor.sameOnScreen([a], [b]), true, "cpu counter alone is not a change")
}

suite("AgentsMonitor.classify") {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let oneCore = 1_000_000_000.0    // nanoseconds of CPU per second of wall clock
    /// A sample: pid, CPU burned since it started, how long it has been up.
    func at(_ id: Int32, cpu: Double, elapsed: TimeInterval = 3600) -> AgentProcess {
        AgentProcess(id: id, folder: "penmark", host: "Terminal", elapsed: elapsed,
                     uptime: "1h 0m", cpuNanos: UInt64(cpu), memoryBytes: 0, memoryText: "0 MB")
    }
    /// Burn `fraction` of a core for `dt` seconds on top of `from`.
    func burning(_ id: Int32, from: AgentProcess, fraction: Double, dt: TimeInterval) -> AgentProcess {
        at(id, cpu: Double(from.cpuNanos) + fraction * oneCore * dt, elapsed: from.elapsed + dt)
    }
    let idleSeed = at(1, cpu: 0)      // lifetime average 0, so the seed says idle

    // The threshold itself: below, above, and exactly on it.
    for (fraction, expected, what) in [(0.005, false, "well under the threshold"),
                                       (AgentsMonitor.activeThreshold - 0.001, false, "just under"),
                                       (AgentsMonitor.activeThreshold, true, "exactly on it"),
                                       (0.40, true, "clearly working")] {
        let next = burning(1, from: idleSeed, fraction: fraction, dt: 10)
        let out = AgentsMonitor.classify(previous: [idleSeed], current: [next], dt: 10,
                                         activeSince: [:], now: t0)
        expect(out.agents.first?.isActive, expected, what)
    }

    // Hysteresis: bursty token streaming, and a session waiting on a long `bash`, must not
    // flicker between "working" and "idle" every time a scan lands in a quiet moment.
    let burst = burning(1, from: idleSeed, fraction: 0.5, dt: 10)
    let marked = AgentsMonitor.classify(previous: [idleSeed], current: [burst], dt: 10,
                                        activeSince: [:], now: t0)
    expect(marked.agents.first?.isActive, true, "burst marks it active")
    expect(marked.activeSince[1], t0, "and records when")
    // Now nothing at all for a while.
    let quiet = burning(1, from: burst, fraction: 0, dt: 10)
    let inGrace = AgentsMonitor.classify(previous: [burst], current: [quiet], dt: 10,
                                         activeSince: marked.activeSince,
                                         now: t0.addingTimeInterval(AgentsMonitor.activeGrace - 1))
    expect(inGrace.agents.first?.isActive, true, "still active inside the grace period")
    let afterGrace = AgentsMonitor.classify(previous: [burst], current: [quiet], dt: 10,
                                            activeSince: marked.activeSince,
                                            now: t0.addingTimeInterval(AgentsMonitor.activeGrace + 1))
    expect(afterGrace.agents.first?.isActive, false, "idle once the grace period is spent")

    // First scan of all: no previous sample, so the verdict comes from the lifetime
    // average rather than from nothing. A session that has burned 30 minutes of CPU in the
    // hour it has been up is working; one that has burned a second is not.
    let busyLife = at(2, cpu: 1800 * oneCore, elapsed: 3600)
    let idleLife = at(3, cpu: 1 * oneCore, elapsed: 3600)
    let first = AgentsMonitor.classify(previous: [], current: [busyLife, idleLife], dt: nil,
                                       activeSince: [:], now: t0)
    expect(first.agents.first(where: { $0.id == 2 })?.isActive, true, "first scan, busy lifetime")
    expect(first.agents.first(where: { $0.id == 3 })?.isActive, false, "first scan, idle lifetime")
    // A process too young to divide by.
    let newborn = at(4, cpu: 5 * oneCore, elapsed: 0)
    expect(AgentsMonitor.classify(previous: [], current: [newborn], dt: nil,
                                  activeSince: [:], now: t0).agents.first?.isActive,
           false, "a process with no elapsed time yet is not classified")

    // A window that cannot be trusted is discarded, and discarded has to mean nothing is
    // concluded - not "substitute the lifetime average", which is a different measurement
    // over a different span. The spike below would otherwise read as 50 cores.
    let spike = burning(1, from: idleSeed, fraction: 50, dt: 0.01)
    for (dt, what) in [(0.0, "dt of zero"), (-5.0, "negative dt"),
                       (0.01, "dt below the floor"), (86_400.0, "dt across a machine sleep")] {
        let out = AgentsMonitor.classify(previous: [idleSeed], current: [spike], dt: dt,
                                         activeSince: [:], now: t0)
        expect(out.agents.first?.isActive, false, "\(what) is discarded, not turned into a percentage")
    }
    // The pair that tells "discarded" apart from "fall back to the lifetime average" - the
    // one above passes either way, because its seed happens to average ~0. This is the case
    // a laptop waking from sleep walks into every time: a session that worked hard this
    // morning and has burned nothing since. Its lifetime average is half a core; the two
    // samples say it used no CPU whatsoever.
    let workedThisMorning = at(1, cpu: 1800 * oneCore, elapsed: 3600)
    let stillParked = at(1, cpu: 1800 * oneCore, elapsed: 3600 + 7200)
    let woke = AgentsMonitor.classify(previous: [workedThisMorning], current: [stillParked],
                                      dt: 7200, activeSince: [:], now: t0)
    expect(woke.agents.first?.isActive, false, "an untrusted window concludes nothing at all")
    expect(woke.activeSince[1], nil, "and starts no grace period")
    let measured = AgentsMonitor.classify(previous: [workedThisMorning], current: [stillParked],
                                          dt: 10, activeSince: [:], now: t0)
    expect(measured.agents.first?.isActive, false, "a window worth dividing by agrees")
    // No baseline at all is a different case, and an untrusted `dt` must not take the
    // lifetime average away from it: one sample supports nothing else.
    expect(AgentsMonitor.classify(previous: [], current: [at(5, cpu: 1800 * oneCore)],
                                  dt: 86_400, activeSince: [:], now: t0).agents.first?.isActive,
           true, "a pid seen for the first time still gets its lifetime average")

    // Sessions come and go between scans, and the lists are sorted independently, so
    // nothing may be matched up by position.
    let p1 = at(1, cpu: 0), p2 = at(2, cpu: 0), p3 = at(3, cpu: 0)
    let after = [burning(3, from: p3, fraction: 0.5, dt: 10), at(9, cpu: 0)]
    let shuffled = AgentsMonitor.classify(previous: [p1, p2, p3], current: after, dt: 10,
                                          activeSince: [:], now: t0)
    expect(shuffled.agents.first(where: { $0.id == 3 })?.isActive, true, "matched by pid, not index")
    expect(shuffled.agents.first(where: { $0.id == 9 })?.isActive, false, "a pid seen for the first time")
    // A dead pid must not keep its verdict warm for whoever inherits the number.
    expect(shuffled.activeSince[1], nil, "hysteresis entry dropped with the process")
    let reused = AgentsMonitor.classify(previous: [burst], current: [at(1, cpu: 0, elapsed: 2)],
                                        dt: 10, activeSince: [:], now: t0)
    expect(reused.agents.first?.isActive, false, "a counter that went backwards is a new process")

    expect(AgentsMonitor.classify(previous: [], current: [], dt: 10,
                                  activeSince: [:], now: t0).agents.count, 0, "empty scan")

    // A desktop session is a whole guest rather than a process, so it is measured against
    // its own threshold. A list holds both kinds at once, and each row has to be judged by
    // the rule that was measured for it.
    func vm(_ id: Int32, cpu: Double, elapsed: TimeInterval = 3600) -> AgentProcess {
        AgentProcess(id: id, folder: "", host: AgentsMonitor.desktopVMHost, elapsed: elapsed,
                     uptime: "1h 0m", kind: .desktopVM, cpuNanos: UInt64(cpu),
                     memoryBytes: 0, memoryText: "0 MB")
    }
    let vmSeed = vm(20, cpu: 0)
    let vmIdle = vm(20, cpu: (AgentsMonitor.vmActiveThreshold - 0.001) * oneCore * 10,
                    elapsed: 3610)
    let vmBusy = vm(20, cpu: (AgentsMonitor.vmActiveThreshold + 0.001) * oneCore * 10,
                    elapsed: 3610)
    expect(AgentsMonitor.classify(previous: [vmSeed], current: [vmIdle], dt: 10,
                                  activeSince: [:], now: t0).agents.first?.isActive,
           false, "a guest ticking over below its threshold is idle")
    expect(AgentsMonitor.classify(previous: [vmSeed], current: [vmBusy], dt: 10,
                                  activeSince: [:], now: t0).agents.first?.isActive,
           true, "and working above it")
    // Both kinds in one scan, each against its own rule.
    let mixed = AgentsMonitor.classify(previous: [idleSeed, vmSeed],
                                       current: [burning(1, from: idleSeed, fraction: 0.5, dt: 10),
                                                 vmIdle],
                                       dt: 10, activeSince: [:], now: t0)
    expect(mixed.agents.first(where: { $0.id == 1 })?.isActive, true, "the CLI is working")
    expect(mixed.agents.first(where: { $0.id == 20 })?.isActive, false, "the guest is not")
    // The hysteresis and the untrusted-window rules are shared, not per kind: a guest that
    // spent the machine's sleep doing nothing must not light up on a lifetime average
    // either. (This is the case that put 3 of 15 CLI sessions on screen; a VM that has been
    // up for hours has an even longer average to be wrong about.)
    let vmWorkedEarlier = vm(20, cpu: 1800 * oneCore, elapsed: 3600)
    let vmStillParked = vm(20, cpu: 1800 * oneCore, elapsed: 3600 + 7200)
    expect(AgentsMonitor.classify(previous: [vmWorkedEarlier], current: [vmStillParked],
                                  dt: 7200, activeSince: [:], now: t0).agents.first?.isActive,
           false, "an untrusted window concludes nothing for a guest either")
}

suite("AgentsMonitor.totalMemory") {
    func held(_ id: Int32, _ bytes: UInt64) -> AgentProcess {
        AgentProcess(id: id, folder: "p", host: "Terminal", elapsed: 60, uptime: "1m",
                     memoryBytes: bytes, memoryText: Fmt.memory(bytes))
    }
    expect(AgentsMonitor.totalMemory([]), 0, "no sessions")
    expect(AgentsMonitor.totalMemory([held(1, 100), held(2, 250)]), 350, "summed")
    // Twelve sessions of a few hundred megabytes each is the real case, and it has to stay
    // exact rather than overflow or round on the way to the footer.
    let real = (1...12).map { held(Int32($0), 220 * 1_048_576) }
    expect(AgentsMonitor.totalMemory(real), 12 * 220 * 1_048_576, "twelve live sessions")
    expect(Fmt.memory(AgentsMonitor.totalMemory(real), locale: Locale(identifier: "en_US")),
           "2.6 GB", "and formatted for the footer")
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
    // `Int(_: Double)` traps rather than saturating, and this number comes off an
    // undocumented endpoint: `1e30` is valid JSON, decodes into an ordinary `Double` and
    // used to kill the app on the next menu bar redraw. None of these may crash.
    expect(Fmt.percent(.nan), "0%", "NaN")
    expect(Fmt.percent(.infinity), "9999%", "infinity")
    expect(Fmt.percent(-.infinity), "0%", "negative infinity")
    expect(Fmt.percent(1e30), "9999%", "far past anything printable")
    expect(Fmt.percent(-5), "0%", "negative")
    expect(Fmt.percent(Double(Int.max) * 2), "9999%", "past Int's range")
    // A real overage is a number, not a fault, and still reads as one.
    expect(Fmt.percent(150), "150%", "over the limit")
    expect(Fmt.clampPercent(42.5), 42.5, "an ordinary value passes through untouched")

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    expect(Fmt.countdown(to: nil, from: now), "", "no date")
    expect(Fmt.countdown(to: now.addingTimeInterval(-5), from: now), "now", "past")
    expect(Fmt.countdown(to: now.addingTimeInterval(30), from: now), "1m", "under a minute")
    expect(Fmt.countdown(to: now.addingTimeInterval(12 * 60), from: now), "12m", "minutes")
    expect(Fmt.countdown(to: now.addingTimeInterval(3 * 3600 + 49 * 60), from: now), "3h 49m", "hours")
    expect(Fmt.countdown(to: now.addingTimeInterval(2 * 86_400 + 3 * 3600), from: now), "2d 3h", "days")
    // The last fraction of a second still reads "now" rather than rounding up to "1m",
    // which is what the whole-second truncation used to do before `duration` was split out.
    expect(Fmt.countdown(to: now.addingTimeInterval(0.4), from: now), "now", "under a second left")

    // `duration` is the same arithmetic without a zero case: a countdown that has run out
    // says "now", but an age that rounds down to nothing still happened.
    expect(Fmt.duration(0), "1m", "never zero")
    expect(Fmt.duration(-30), "1m", "a negative span is not a countdown, it is a bad input")
    expect(Fmt.duration(12 * 60), "12m", "minutes")
    expect(Fmt.duration(3 * 3600 + 49 * 60), "3h 49m", "hours")
    expect(Fmt.duration(2 * 86_400 + 3 * 3600), "2d 3h", "days")
    // `Int(_: Double)` traps on both of these, and both are reachable: the dates behind
    // these spans come off an endpoint that can send whatever it likes.
    expect(Fmt.duration(.nan), "0m", "NaN cannot reach Int(_:)")
    expect(Fmt.duration(1e30), "36458d 8h", "clamped rather than trapped")

    // Pinned to en_US rather than the machine's locale: the panel *should* render
    // "US$ 64,20" for a reader in Argentina, so asserting against `.current` would make
    // this pass on one Mac and fail on the next.
    let en = Locale(identifier: "en_US")

    // Memory: whole megabytes below a gigabyte, one decimal above. Binary units, which is
    // what ri_phys_footprint counts in and what footprint(1) prints.
    let mb: UInt64 = 1_048_576, gb: UInt64 = 1_073_741_824
    expect(Fmt.memory(0, locale: en), "0 MB", "nothing")
    expect(Fmt.memory(1, locale: en), "0 MB", "a single byte still reads as zero")
    expect(Fmt.memory(137 * mb, locale: en), "137 MB", "the median live session")
    // No decimals under a gigabyte: a session's footprint drifts by kilobytes constantly
    // and a tenth of a megabyte would twitch on every scan for nothing.
    expect(Fmt.memory(137 * mb + 400_000, locale: en), "137 MB", "sub-megabyte drift is invisible")
    expect(Fmt.memory(137 * mb + 600_000, locale: en), "138 MB", "and rounds rather than truncates")
    expect(Fmt.memory(999 * mb, locale: en), "999 MB", "just under the switch")
    expect(Fmt.memory(1023 * mb, locale: en), "1023 MB", "last megabyte")
    // Rounding happens before the unit is chosen, so nothing ever prints "1024 MB".
    expect(Fmt.memory(1023 * mb + 900_000, locale: en), "1.0 GB", "rounds up into gigabytes")
    expect(Fmt.memory(gb, locale: en), "1.0 GB", "exactly one gigabyte")
    expect(Fmt.memory(1_900_000_000, locale: en), "1.8 GB", "twelve sessions' worth")
    expect(Fmt.memory(12 * gb, locale: en), "12.0 GB", "double digits")
    // The decimal separator follows the reader, like `money`. Asserting this against
    // `.current` is what would make the suite machine-dependent.
    expect(Fmt.memory(gb, locale: Locale(identifier: "de_DE")), "1,0 GB", "German decimal comma")
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
    // both exist. Filtering on it would collapse this to a single bar.
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

suite("UsageResponse decoding is lenient") {
    // The endpoint is undocumented and internal, so the decoder's job is to lose exactly
    // what broke and nothing else. `Decodable`'s default is the opposite: one unreadable
    // leaf throws to the top and the whole response goes, including the parts that parsed.

    // A single bad entry costs its own bar and leaves the others standing.
    let oneBad = decode("""
    {"limits": [
      {"kind": "session", "percent": 45},
      {"kind": "weekly_all", "percent": "seventy-six"},
      {"kind": "weekly_scoped", "percent": 30, "scope": {"model": {"display_name": "Opus"}}}
    ]}
    """)
    expect(oneBad.rows.map(\.id), ["session", "weekly_scoped-Opus"], "bad entry dropped, rest kept")
    expect(oneBad.session?.percent, 45, "and the chip still has its number")

    // No percentage means nothing to draw, so that entry alone goes.
    expect(decode("{\"limits\": [{\"kind\": \"session\"}, {\"kind\": \"weekly_all\", \"percent\": 72}]}")
            .rows.map(\.id), ["weekly_all"], "an entry with no percent is dropped")

    // Everything except `percent` is tolerated, because the number is what the bar is for.
    let renamed = decode("{\"limits\": [{\"percent\": 61}]}")
    expect(renamed.rows.map(\.title), ["Limit"], "a limit with no kind still gets a bar")
    expect(renamed.rows.map(\.percent), [61], "and keeps its number")
    expect(decode("{\"limits\": [{\"kind\": 7, \"percent\": 61, \"severity\": [], \"is_active\": \"yes\"}]}")
            .rows.count, 1, "wrong types on the optional fields are ignored")

    // `limits` changing shape entirely must not cost the fallback the app keeps for
    // exactly that day.
    let reshaped = decode("""
    {"five_hour": {"utilization": 45}, "seven_day": {"utilization": 76},
     "limits": {"session": 45}}
    """)
    expect(reshaped.rows.map(\.id), ["five_hour", "seven_day"], "limits of the wrong shape falls back")
    expect(reshaped.session?.percent, 45, "fallback still feeds the chip")
    // Same when every entry is unreadable: an empty list is not a limitless account.
    expect(decode("{\"five_hour\": {\"utilization\": 45}, \"limits\": [{\"nope\": 1}]}")
            .rows.map(\.id), ["five_hour"], "all entries dropped falls back too")

    // One broken field inside `extra_usage` costs that field, not the credits row.
    let partialCredits = decode("""
    {"extra_usage": {"is_enabled": true, "used_credits": 6420, "monthly_limit": "lots",
                     "currency": "USD", "decimal_places": 2}}
    """)
    let row = partialCredits.creditsRow(locale: Locale(identifier: "en_US"))
    expect(row?.detail, "$64.20", "spend without a limit to compare it to")
    // And a broken field deeper down costs only the title's model name.
    expect(decode("{\"limits\": [{\"kind\": \"weekly_scoped\", \"percent\": 30, \"scope\": {\"model\": 5}}]}")
            .rows.map(\.title), ["Weekly (scoped)"], "unreadable scope keeps the bar")

    // A percentage is clamped where it enters, so the bar's width, the severity and the
    // chip all work from a number that can be drawn, compared and converted.
    let absurd = decode("{\"limits\": [{\"kind\": \"session\", \"percent\": 1e30}]}")
    expect(absurd.rows.first?.percent, 9999, "an absurd percent is clamped in the row")
    expect(absurd.session?.percent, 9999, "and in the gauge")
    expect(Fmt.percent(absurd.session?.percent ?? -1), "9999%", "and survives the menu bar")
    expect(decode("{\"limits\": [{\"kind\": \"session\", \"percent\": -20}]}").rows.first?.percent,
           0, "a negative percent is floored")
}

// MARK: - Menu bar chips

suite("UsageModel.agentsChipText") {
    // The fraction is the point of the feature: seven sessions open and one working is
    // exactly what the menu bar could not say before.
    expect(UsageModel.agentsChipText(total: 7, active: 1), "1/7", "some working")
    expect(UsageModel.agentsChipText(total: 7, active: 0), "0/7", "none working")
    // "7/7" and "1/1" spend width to say nothing, so they collapse to the bare count.
    expect(UsageModel.agentsChipText(total: 7, active: 7), "7", "all working")
    expect(UsageModel.agentsChipText(total: 1, active: 1), "1", "a single working session")
    expect(UsageModel.agentsChipText(total: 1, active: 0), "1", "a single idle session")
    // Defensive: the classifier cannot mark more than it was given, but the chip must not
    // invent "8/7" if it ever does.
    expect(UsageModel.agentsChipText(total: 7, active: 9), "7", "more active than total")
}

suite("UsageModel.segments") {
    func chips(_ usage: UsageResponse?,
               _ mode: UsageModel.TitleMode = .sessionAndWeek,
               error: String? = nil,
               agents: Int = 0,
               active: Int = 0,
               showAgents: Bool = true) -> [StatusIcon.Segment] {
        UsageModel.segments(usage: usage, titleMode: mode, errorText: error,
                            agentCount: agents, activeAgentCount: active,
                            showAgents: showAgents)
    }
    func seg(_ text: String, _ severity: Severity = .normal,
             _ symbol: String? = nil) -> StatusIcon.Segment {
        StatusIcon.Segment(text: text, severity: severity, symbol: symbol)
    }

    let usage = decode("""
    {"limits": [
      {"kind": "session", "percent": 45, "severity": "normal"},
      {"kind": "weekly_all", "percent": 76, "severity": "warning"}
     ],
     "extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 9500,
                     "utilization": 95, "currency": "USD", "decimal_places": 2}}
    """)

    expect(chips(usage), [seg("45%"), seg("76%", .warning)], "session + week")
    expect(chips(usage, .session), [seg("45%")], "session only")
    expect(chips(usage, .week), [seg("76%", .warning)], "week only")
    expect(chips(usage, .credits), [seg("95%", .critical)], "extra usage")
    expect(chips(usage, .iconOnly), [], "icon only")
    expect(chips(usage, .highest), [seg("76%", .warning)], "highest picks the larger")
    // The severity travels with the value rather than being re-derived from it: this
    // weekly is at 30% and already flagged, and the chip has to agree with its bar.
    let escalated = decode("""
    {"limits": [{"kind": "weekly_all", "percent": 30, "severity": "critical"}]}
    """)
    expect(chips(escalated, .week), [seg("30%", .critical)], "api severity reaches the chip")

    // Nothing fetched yet and nothing wrong: one chip carries the state.
    expect(chips(nil), [seg("…")], "loading")
    // An error replaces it rather than joining it, so the bar never shows both.
    expect(chips(nil, error: "boom"), [seg("!", .critical)], "error before any data")
    // But with cached numbers on screen the `!` is appended: without it an expired token
    // leaves yesterday's percentages up with the only warning buried in the panel.
    expect(chips(usage, error: "Session expired"),
           [seg("45%"), seg("76%", .warning), seg("!", .critical)], "error beside stale numbers")
    expect(chips(usage, .iconOnly, error: "boom"), [seg("!", .critical)], "error survives icon only")

    // The agents chip is last, carries its glyph, and is absent when there is nothing to
    // count or the user turned it off.
    expect(chips(usage, .session, agents: 3, active: 1),
           [seg("45%"), seg("1/3", .normal, "figure.run")], "agents chip")
    expect(chips(usage, .session, agents: 3, active: 3),
           [seg("45%"), seg("3", .normal, "figure.run")], "all of them working")
    expect(chips(usage, .session, agents: 0), [seg("45%")], "no agents running")
    expect(chips(usage, .session, agents: 3, showAgents: false), [seg("45%")], "agents chip off")
    // "Icon only" means no chip, including the loading one: it is not a warning, so
    // there is nothing lost by honoring the setting. The `!` is the exception, and the
    // agents chip has its own switch.
    expect(chips(nil, .iconOnly), [], "icon only stays bare while loading")
    expect(chips(nil, .iconOnly, agents: 2, active: 2), [seg("2", .normal, "figure.run")],
           "agents alone")

    // A mode whose value the account does not have shows nothing rather than a zero.
    let sessionOnly = decode("{\"limits\": [{\"kind\": \"session\", \"percent\": 45}]}")
    expect(chips(sessionOnly, .credits), [], "extra usage not enabled")
    expect(chips(sessionOnly, .week), [], "no weekly limit")
    expect(chips(sessionOnly, .highest), [seg("45%")], "highest of one")
}

suite("UsageModel.TitleMode") {
    // The raw values are a persistence format: they are what lands in UserDefaults, so
    // renaming a case silently resets everyone's menu bar to the default.
    expect(UsageModel.TitleMode.allCases.map(\.rawValue),
           ["sessionAndWeek", "session", "week", "highest", "credits", "iconOnly"], "raw values")
    expect(UsageModel.TitleMode(rawValue: "highest"), .highest, "round trip")
    expect(UsageModel.TitleMode(rawValue: "gone"), nil, "unknown value falls back")
    expect(UsageModel.TitleMode.allCases.map(\.id), UsageModel.TitleMode.allCases.map(\.rawValue),
           "id is the raw value")
    expectTrue(UsageModel.TitleMode.allCases.allSatisfy { !$0.label.isEmpty },
               "every case is labelled")
}

// MARK: - Rate limiting

suite("UsageModel.retryAfterSeconds") {
    let now = Date(timeIntervalSince1970: 1_785_412_800)   // 2026-07-30T12:00:00Z
    expect(UsageModel.retryAfterSeconds("120", now: now), 120, "seconds")
    expect(UsageModel.retryAfterSeconds(" 90 ", now: now), 90, "padded seconds")
    // What the endpoint actually sends while it is still refusing requests, which is why
    // this is only ever a lower bound (see `throttleDelay`).
    expect(UsageModel.retryAfterSeconds("0", now: now), 0, "zero")
    expect(UsageModel.retryAfterSeconds(nil, now: now), 0, "header absent")
    expect(UsageModel.retryAfterSeconds("", now: now), 0, "header empty")
    expect(UsageModel.retryAfterSeconds("banana", now: now), 0, "unparseable")
    // The other form RFC 7231 allows.
    expect(UsageModel.retryAfterSeconds("Wed, 30 Jul 2026 12:01:00 GMT", now: now), 60, "http date")
    expect(UsageModel.retryAfterSeconds("Wed, 30 Jul 2026 11:59:00 GMT", now: now), -60,
           "http date already past")
}

suite("UsageModel.throttleDelay") {
    // 60s, 2m, 4m, 8m, then the ceiling. A single blip recovers on the next tick; a
    // sustained window stops being retried into, which is what lets it close at all.
    expect(UsageModel.throttleDelay(consecutive429: 1, advertised: 0), 60, "first")
    expect(UsageModel.throttleDelay(consecutive429: 2, advertised: 0), 120, "second")
    expect(UsageModel.throttleDelay(consecutive429: 3, advertised: 0), 240, "third")
    expect(UsageModel.throttleDelay(consecutive429: 4, advertised: 0), 480, "fourth")
    expect(UsageModel.throttleDelay(consecutive429: 5, advertised: 0), 900, "clamped at maxThrottle")
    // The counter is a count, not an index: it is read before the first bump lands.
    expect(UsageModel.throttleDelay(consecutive429: 0, advertised: 0), 60, "zero counts as the first")
    // `Retry-After` can lengthen the wait, never shorten it.
    expect(UsageModel.throttleDelay(consecutive429: 1, advertised: 300), 300, "advertised above the floor")
    expect(UsageModel.throttleDelay(consecutive429: 3, advertised: 100), 240, "advertised below the floor")
    expect(UsageModel.throttleDelay(consecutive429: 1, advertised: -100), 60, "negative advertised")
    // And a bogus one cannot park the app for a day.
    expect(UsageModel.throttleDelay(consecutive429: 1, advertised: 86_400), 900, "absurd advertised")

    // A non-finite advertised value is thrown away rather than clamped, because clamping
    // does not work on one: NaN has no ordering, so `min`/`max` pass it straight through.
    // What comes out the far end is a NaN `throttledUntil`, a date every comparison in the
    // app is false against - no countdown, refresh button live, and the poll loop back to
    // its 25s floor inside the window it is meant to be waiting out.
    expect(UsageModel.throttleDelay(consecutive429: 1, advertised: .nan), 60, "NaN advertised")
    expect(UsageModel.throttleDelay(consecutive429: 3, advertised: .nan), 240,
           "NaN does not disturb the doubling")
    expect(UsageModel.throttleDelay(consecutive429: 1, advertised: .infinity), 60, "infinite")
    expect(UsageModel.throttleDelay(consecutive429: 1, advertised: -.infinity), 60, "negative infinite")

    // End to end from the header, since `Double` parses all three of these happily.
    let then = Date(timeIntervalSince1970: 1_785_412_800)
    for header in ["nan", "NaN", "inf", "-inf", "infinity"] {
        let delay = UsageModel.throttleDelay(
            consecutive429: 1, advertised: UsageModel.retryAfterSeconds(header, now: then))
        expectTrue(delay.isFinite && delay >= UsageModel.minThrottle,
                   "Retry-After: \(header) still yields a usable backoff")
    }
}

suite("UsageModel.pollDelay") {
    let now = Date(timeIntervalSince1970: 1_785_412_800)
    expect(UsageModel.pollDelay(refreshInterval: 60, throttledUntil: nil, now: now), 60, "no backoff")
    // Just past the moment it expires, so a countdown reaching zero is followed by an
    // actual attempt instead of the rest of a 15 minute sleep.
    expect(UsageModel.pollDelay(refreshInterval: 900, throttledUntil: now.addingTimeInterval(30),
                                now: now), 31, "wakes just after the backoff")
    // But never longer than the user's interval.
    expect(UsageModel.pollDelay(refreshInterval: 60, throttledUntil: now.addingTimeInterval(600),
                                now: now), 60, "capped by the interval")
    // A spent backoff falls back to the floor rather than to zero: a tight loop here is
    // exactly what holds the window open.
    expect(UsageModel.pollDelay(refreshInterval: 900, throttledUntil: now.addingTimeInterval(-5),
                                now: now), 25, "spent backoff waits the floor")
    expect(UsageModel.pollDelay(refreshInterval: 900, throttledUntil: now, now: now), 25,
           "exactly expired")
    expect(UsageModel.pollDelay(refreshInterval: 15, throttledUntil: now.addingTimeInterval(-5),
                                now: now), 15, "floor never exceeds the interval")
}

suite("UsageModel.fetchAllowedAt") {
    let now = Date(timeIntervalSince1970: 1_785_412_800)
    expect(UsageModel.fetchAllowedAt(lastAttempt: nil, throttledUntil: nil), nil, "nothing yet")
    // Measured from the attempt, not from the last success: a relaunch restores its
    // numbers from the cache on disk and must still be allowed to fetch immediately.
    expect(UsageModel.fetchAllowedAt(lastAttempt: now, throttledUntil: nil),
           now.addingTimeInterval(25), "floor after an attempt")
    expect(UsageModel.fetchAllowedAt(lastAttempt: nil, throttledUntil: now.addingTimeInterval(300)),
           now.addingTimeInterval(300), "backoff only")
    // Whichever is later wins, in both directions.
    expect(UsageModel.fetchAllowedAt(lastAttempt: now, throttledUntil: now.addingTimeInterval(300)),
           now.addingTimeInterval(300), "backoff outlasts the floor")
    expect(UsageModel.fetchAllowedAt(lastAttempt: now, throttledUntil: now.addingTimeInterval(-300)),
           now.addingTimeInterval(25), "floor outlasts a spent backoff")
}

// MARK: - Status item image

suite("StatusIcon.statusImage") {
    func image(_ segments: [StatusIcon.Segment]) -> NSImage {
        StatusIcon.statusImage(segments: segments, appearance: nil)
    }
    let normal = StatusIcon.Segment(text: "45%", severity: .normal)
    let warning = StatusIcon.Segment(text: "76%", severity: .warning)
    let critical = StatusIcon.Segment(text: "99%", severity: .critical)

    // A template image is tinted by the menu bar, which is how light and dark come for
    // free. As soon as one value needs a color of its own the whole image stops being one.
    expectTrue(image([normal]).isTemplate, "all normal draws as a template")
    expectTrue(image([]).isTemplate, "icon only is a template")
    expect(image([normal, warning]).isTemplate, false, "one warning drops the template")
    expect(image([critical]).isTemplate, false, "critical drops the template")
    expect(image([warning, critical]).isTemplate, false, "worst of several decides")

    // The menu bar height is fixed; only the width follows the contents.
    expect(image([normal]).size.height, 18, "fixed height")
    expectTrue(image([normal, warning]).size.width > image([normal]).size.width,
               "a second chip is wider")
    expectTrue(image([normal]).size.width > image([]).size.width, "the mark alone is narrowest")

    // VoiceOver reads the image, so the values have to be in its description or the status
    // item announces itself without saying anything.
    let spoken = image([normal, StatusIcon.Segment(text: "4", severity: .normal,
                                                   symbol: "figure.run")]).accessibilityDescription
    expect(spoken, "Claude Code usage, 45%, 4 agents", "spoken description")
    expect(image([]).accessibilityDescription, "Claude Code usage", "nothing to read out")
}

// MARK: - Credentials

suite("Credentials.parse") {
    func parse(_ json: String) -> String? { Credentials.parse(Data(json.utf8))?.value }

    expect(parse("{\"claudeAiOauth\": {\"accessToken\": \"sk-ant-oat01-abc\"}}"),
           "sk-ant-oat01-abc", "token")
    // Every shape that is not a usable token has to read as "no credentials". An empty
    // one would go out as a `Bearer ` header with nothing behind it and come back a 401,
    // which the panel then blames on an expired session.
    expect(parse("{\"claudeAiOauth\": {\"accessToken\": \"\"}}"), nil, "empty token")
    expect(parse("{\"claudeAiOauth\": {}}"), nil, "no token field")
    expect(parse("{\"claudeAiOauth\": {\"accessToken\": 12345}}"), nil, "token is not a string")
    expect(parse("{\"other\": {\"accessToken\": \"x\"}}"), nil, "wrong key")
    expect(parse("[]"), nil, "not an object")
    expect(parse("not json at all"), nil, "garbage")
    expect(Credentials.parse(Data())?.value, nil, "empty data")
}

suite("Credentials expiry") {
    func expiry(_ json: String) -> Date? {
        Credentials.parse(Data(json.utf8))?.expiresAt
    }
    func value(_ json: String) -> String? { Credentials.parse(Data(json.utf8))?.value }

    // Milliseconds since the epoch, which is how Claude Code writes it. A whole-second
    // value so the assertion is an exact date and not a float comparison.
    expect(expiry("{\"claudeAiOauth\": {\"accessToken\": \"t\", \"expiresAt\": 1785797331000}}"),
           Date(timeIntervalSince1970: 1_785_797_331), "milliseconds")
    // And the real thing, fractional milliseconds included, to a millisecond.
    let fractional = expiry(
        "{\"claudeAiOauth\": {\"accessToken\": \"t\", \"expiresAt\": 1785797331466}}")
    expectTrue(abs((fractional?.timeIntervalSince1970 ?? 0) - 1_785_797_331.466) < 0.001,
               "the timestamp Claude Code actually writes")
    // Losing the timestamp costs the wording of one message. It must never cost the token,
    // which is the difference between "waiting for a refresh" and "no credentials found".
    expect(expiry("{\"claudeAiOauth\": {\"accessToken\": \"t\"}}"), nil, "absent")
    expect(expiry("{\"claudeAiOauth\": {\"accessToken\": \"t\", \"expiresAt\": \"soon\"}}"),
           nil, "not a number")
    expect(value("{\"claudeAiOauth\": {\"accessToken\": \"t\", \"expiresAt\": \"soon\"}}"),
           "t", "an unreadable expiry still yields the token")

    // A *seconds* timestamp in a milliseconds field is January 1970, and the panel would
    // announce a login that expired 56 years ago. The unit is not guessed from the
    // magnitude either: guessing wrong is off by a factor of 1000 the other way.
    expect(expiry("{\"claudeAiOauth\": {\"accessToken\": \"t\", \"expiresAt\": 1785797331}}"),
           nil, "seconds, not milliseconds")
    expect(expiry("{\"claudeAiOauth\": {\"accessToken\": \"t\", \"expiresAt\": 0}}"), nil, "zero")
    expect(expiry("{\"claudeAiOauth\": {\"accessToken\": \"t\", \"expiresAt\": -1785797331466}}"),
           nil, "negative")
    expect(expiry("{\"claudeAiOauth\": {\"accessToken\": \"t\", \"expiresAt\": true}}"),
           nil, "a boolean bridges to a number and must still be refused")
    // NaN and infinity cannot be written as JSON literals, but `expiry` is the one place
    // that would turn either into a Date every comparison is false against.
    expect(Credentials.expiry(Double.nan), nil, "NaN")
    expect(Credentials.expiry(Double.infinity), nil, "infinity")
    expect(Credentials.expiry(nil), nil, "nothing at all")
}

suite("Credentials.Token.fingerprint") {
    func fp(_ token: String) -> String {
        Credentials.Token(value: token, expiresAt: nil).fingerprint
    }
    // Stable across reads, so a keychain item that has not changed is not mistaken for a
    // new login on every poll.
    expect(fp("sk-ant-oat01-abc"), fp("sk-ant-oat01-abc"), "same token, same fingerprint")
    expectTrue(fp("sk-ant-oat01-abc") != fp("sk-ant-oat01-abd"), "one character apart")
    // 16 hex digits of SHA-256, and above all not the token: this is the only form of it
    // the model keeps between requests.
    expect(fp("sk-ant-oat01-abc").count, 16, "truncated digest")
    expectTrue(fp("sk-ant-oat01-abc").allSatisfy(\.isHexDigit), "hex")
    expectTrue(!fp("sk-ant-oat01-abc").contains("sk-ant"), "carries none of the secret")
    expect(fp(""), "e3b0c44298fc1c14", "pinned against SHA-256 of the empty string")
}

// MARK: - Auth policy

suite("UsageModel.tokenAction") {
    let now = Date(timeIntervalSince1970: 1_785_800_000)
    let past = now.addingTimeInterval(-600), future = now.addingTimeInterval(600)
    let a = Credentials.Token(value: "token-a", expiresAt: nil).fingerprint
    let b = Credentials.Token(value: "token-b", expiresAt: nil).fingerprint
    func action(_ fingerprint: String, _ expiresAt: Date?,
                rejected: String?) -> UsageModel.TokenAction {
        UsageModel.tokenAction(fingerprint: fingerprint, expiresAt: expiresAt,
                               rejected: rejected, now: now)
    }
    expect(action(a, past, rejected: nil), .send, "nothing has been refused yet")
    // The clock never gets to withhold the first request: a machine whose date is wrong
    // would otherwise lock the app out of ever asking, with nothing to correct it.
    expect(action(a, Date(timeIntervalSince1970: 0), rejected: nil), .send,
           "an expiry in 1970 is still worth one request")

    // The bug in #4: the message could only be cleared by a 200, and a 429 backoff is
    // exactly the state in which no 200 can arrive. A different token in the keychain is
    // Claude Code having refreshed the login, and that is knowable without a request.
    expect(action(b, future, rejected: a), .sendAndClearAuth, "the keychain has been rewritten")
    expect(action(b, nil, rejected: a), .sendAndClearAuth, "and without an expiry to read")

    // Withholding takes both: the endpoint refused this exact token, and the token itself
    // says it has expired.
    expect(action(a, past, rejected: a), .skip, "refused, and expired")
    // A 401 alone is not conclusive. It can be transient, and retrying every poll is how
    // the app used to recover from a passing 403 on its own; parking on the first one would
    // trade #4 for a worse version of itself.
    expect(action(a, future, rejected: a), .send, "refused while it should still be valid")
    expect(action(a, nil, rejected: a), .send, "refused, with no expiry to corroborate it")
    expect(action(a, now, rejected: a), .send, "expiring exactly now has not expired yet")
}

suite("UsageModel.authMessage") {
    let now = Date(timeIntervalSince1970: 1_785_800_000)
    func message(_ expiresAt: Date?) -> String {
        UsageModel.authMessage(expiresAt: expiresAt, now: now)
    }
    // The everyday case is not an expired session at all: the access token lapsed and only
    // Claude Code rewrites it. "Session expired" sends the user looking for a login screen
    // that is not the problem.
    expect(message(now.addingTimeInterval(-12 * 60)),
           "Waiting for Claude Code to refresh the login (token expired 12m ago).",
           "lapsed token")
    expect(message(now.addingTimeInterval(-3 * 3600 - 49 * 60)),
           "Waiting for Claude Code to refresh the login (token expired 3h 49m ago).",
           "lapsed hours ago")
    // Refused while it should still have been valid is a different thing, and keeps the
    // original wording: something really is wrong with the login.
    let refusedButLive = "Session expired. Open Claude Code to refresh the login."
    expect(message(now.addingTimeInterval(600)), refusedButLive, "refused before it expired")
    expect(message(nil), refusedButLive, "no timestamp to reason from")
    expect(message(now), refusedButLive, "expiring exactly now is not yet expired")
}

// MARK: - Login item

suite("LoginItem.isInstalled") {
    func installed(_ path: String) -> Bool {
        LoginItem.isInstalled(bundlePath: path, home: "/Users/andres")
    }
    expectTrue(installed("/Applications/ClaudeUsage.app"), "system Applications")
    expectTrue(installed("/Users/andres/Applications/ClaudeUsage.app"), "home Applications")
    expectTrue(installed("/Applications/Utilities/ClaudeUsage.app"), "nested under Applications")
    // `SMAppService` remembers the path it was registered from, so offering this from a
    // build directory leaves a login item pointing at something `make clean` deletes.
    expect(installed("/Users/andres/code/claude-usage-bar/build/ClaudeUsage.app"), false,
           "running from build/")
    // A directory check, not a string prefix.
    expect(installed("/Applications Backup/ClaudeUsage.app"), false, "similarly named folder")
    expect(installed("/Applications"), false, "the folder itself")
    expect(installed("/Users/someone-else/Applications/ClaudeUsage.app"), false,
           "another user's home")
}

// MARK: - Result

print(failures == 0
      ? "\n\(checks) checks passed"
      : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
