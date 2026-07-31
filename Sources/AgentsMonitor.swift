import Darwin
import Foundation

/// One running Claude Code process (a session/agent) on this machine.
///
/// Three of these fields are a raw value paired with the string that gets drawn from it,
/// and that pairing is load-bearing rather than redundant: `sameOnScreen` compares only
/// what is printed, so a value that moves on every scan (`elapsed`, `memoryBytes`,
/// `cpuNanos`) must not be what decides whether to publish. See `sameOnScreen`.
struct AgentProcess: Identifiable, Equatable {
    let id: Int32                // pid
    let folder: String           // working directory basename, "" if unknown
    let host: String             // "VS Code", "Terminal", "Cursor", …
    let elapsed: TimeInterval    // seconds since it started, what the list sorts on
    let uptime: String           // the same thing as "8m" or "3h 12m"
    /// CPU consumed since the process started, in nanoseconds. Only ever meaningful as a
    /// difference between two scans: see `AgentsMonitor.classify`.
    let cpuNanos: UInt64
    /// `ri_phys_footprint`, the number Activity Monitor prints in its "Memory" column.
    let memoryBytes: UInt64
    /// `memoryBytes` as it appears in the panel, e.g. "137 MB".
    let memoryText: String
    /// Whether this session is actually burning CPU right now. `scan()` always leaves it
    /// false; `classify` is what decides, because it needs two samples and a clock.
    var isActive: Bool

    init(id: Int32, folder: String, host: String, elapsed: TimeInterval, uptime: String,
         cpuNanos: UInt64 = 0, memoryBytes: UInt64 = 0, memoryText: String = "",
         isActive: Bool = false) {
        self.id = id
        self.folder = folder
        self.host = host
        self.elapsed = elapsed
        self.uptime = uptime
        self.cpuNanos = cpuNanos
        self.memoryBytes = memoryBytes
        self.memoryText = memoryText
        self.isActive = isActive
    }
}

/// Counts Claude Code processes by walking the process table through `libproc`.
///
/// A process counts as an agent when its executable is the `claude` binary, or when a
/// known interpreter runs it (`node /…/bin/claude`). That matches the native install,
/// the IDE extension's bundled binary and SDK/npm runs, and excludes the Claude desktop
/// app (`Claude`, capital C) and this menu bar app.
///
/// **Every question here is answered by a syscall, never by a subprocess, and it has to
/// stay that way.** A scan costs **~3 ms** on a 750-process table. Asking `ps -Ao` the
/// same thing costs **~33 ms**, because it makes the kernel format every process on the
/// machine into text so that ~99% of it can be thrown away, and one `lsof` per pid adds
/// **~13 ms** for a working directory `proc_pidinfo` returns in about a microsecond. At
/// one scan a second with the panel open, that difference is the whole CPU footprint of a
/// menu bar app. Staying in-process is also what keeps the scan a plain function call:
/// nothing here can block on an unresponsive network mount, so there is no watchdog, no
/// cache to keep coherent against pid reuse, and no undrained pipe to deadlock on.
enum AgentsMonitor {

    /// Returns `nil` when the process table could not be read at all, which callers must
    /// not confuse with an empty result: an unreadable table says nothing about how many
    /// agents are running, and blanking the list on it would flicker every live session
    /// off the screen and back.
    static func scan() async -> [AgentProcess]? {
        await Task.detached(priority: .utility) { () -> [AgentProcess]? in
            guard let pids = allPids() else { return nil }
            let own = ProcessInfo.processInfo.processIdentifier
            let now = Date().timeIntervalSince1970
            var agents: [AgentProcess] = []

            for pid in pids where pid != own {
                // The gate the whole scan is built on: one syscall, ~1.4 µs, and it
                // rejects all but a handful of the table without ever reading an argument
                // vector. It fails for processes owned by another user, who are skipped
                // rather than guessed at: macOS will not hand a non-root user another
                // user's arguments either, so there is nothing to identify them by.
                guard let exec = execPath(pid) else { continue }
                guard interpreters.contains(base(exec)) || namesClaude(exec) else { continue }

                let argv = arguments(pid)
                guard isAgent(execPath: exec, argv: argv) else { continue }

                let elapsed = max(0, now - (startTime(pid) ?? now))
                // One more syscall, and it answers both remaining questions at once.
                let usage = resourceUsage(pid)
                agents.append(AgentProcess(
                    id: pid,
                    folder: cwdName(of: pid),
                    host: hostName(execPath: exec, argv: argv),
                    elapsed: elapsed,
                    uptime: humanElapsed(elapsed),
                    cpuNanos: usage?.cpuNanos ?? 0,
                    memoryBytes: usage?.memoryBytes ?? 0,
                    memoryText: Fmt.memory(usage?.memoryBytes ?? 0)
                ))
            }
            return agents.sorted(by: precedes)
        }.value
    }

    /// Grouped by folder, then longest-running first within a folder, then by pid so the
    /// list never depends on the order the kernel happened to return.
    ///
    /// Sorting on `elapsed` and not on `uptime`: the formatted string compares wrong
    /// ("9m" would come after "12m"). Folder names use `localizedStandardCompare`, which
    /// is the Finder's rule: case-insensitive and numeric-aware, so `app2` precedes
    /// `app10`. Processes whose working directory could not be read go last, since there
    /// is no name to group them under.
    static func precedes(_ a: AgentProcess, _ b: AgentProcess) -> Bool {
        if a.folder.isEmpty != b.folder.isEmpty { return b.folder.isEmpty }
        let byFolder = a.folder.localizedStandardCompare(b.folder)
        if byFolder != .orderedSame { return byFolder == .orderedAscending }
        if a.elapsed != b.elapsed { return a.elapsed > b.elapsed }
        return a.id < b.id
    }

    /// Whether two scans would draw the same list.
    ///
    /// **Only what is printed counts.** `elapsed`, `memoryBytes` and `cpuNanos` are all
    /// excluded and all for the same reason: they change on every single scan by
    /// definition, while the strings drawn from them (`uptime`, `memoryText`) change when
    /// the picture does. Comparing the raw numbers would report a change every time and
    /// publish a redraw for an identical panel, and re-running `UsageView.body` on a timer
    /// is precisely what the separate `Clock` exists to prevent. That is why each of them
    /// is stored next to its formatted form.
    ///
    /// `isActive` *is* compared: it is drawn, and it is the whole point of the feature.
    static func sameOnScreen(_ a: [AgentProcess], _ b: [AgentProcess]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.id == $1.id && $0.folder == $1.folder
                && $0.host == $1.host && $0.uptime == $1.uptime
                && $0.isActive == $1.isActive && $0.memoryText == $1.memoryText
        }
    }

    /// How much memory every listed session is holding, for the panel's footer. It is the
    /// number that answers "why is this machine slow", which is the question behind the
    /// whole column.
    static func totalMemory(_ agents: [AgentProcess]) -> UInt64 {
        agents.reduce(0) { $0 &+ $1.memoryBytes }
    }

    // MARK: - Activity
    //
    // "Running" has to mean running. A session parked at the prompt since this morning
    // costs the machine the same RAM as one streaming tokens, and until now the chip
    // counted them the same. The discriminator is CPU, and only CPU: measured over 12 live
    // sessions the resident size of an idle one does not fall (104 MB on a 3.5 hour
    // session, 342 MB on a five minute one), so memory is a fact worth printing and a
    // useless signal. See CLAUDE.md for what else was measured and rejected.

    /// Fraction of one core, above which a session counts as working.
    ///
    /// Measured, not guessed: see the numbers in CLAUDE.md. Idle sessions sit under 1% of
    /// a core whether their TUI is visible or hidden, and a session doing work averages
    /// several percent over a scan interval. 2% sits in the gap.
    static let activeThreshold: Double = 0.02

    /// How long a session stays marked active after its last burst above the threshold.
    ///
    /// Not optional. Token streaming is bursty and a session waiting on a two minute
    /// `bash` call is working without spending a cycle, so without a grace period the chip
    /// flickers between bursts and calls a busy agent idle. It is deliberately longer than
    /// `agentScanInterval`, so a single quiet scan can never clear it on its own.
    static let activeGrace: TimeInterval = 45

    /// The window a CPU delta is trusted over.
    ///
    /// The scan cadence is 10s or 30s and it parks entirely while a menu is tracking, so
    /// the real interval has to be measured rather than assumed. Anything outside this
    /// range - a double scan firing back to back, or the hours that pass across a machine
    /// sleep - would turn a normal amount of CPU into a nonsense percentage, so the sample
    /// is dropped instead. Dropping is safe: the reading is only ever a delta, and the
    /// next scan produces a good one.
    static let minSampleWindow: TimeInterval = 0.5
    static let maxSampleWindow: TimeInterval = 120

    /// Marks which sessions are actually working, from two scans and the time between them.
    ///
    /// Deliberately outside `scan()` and `nonisolated static`: it is the decision, and the
    /// repo keeps decisions on the testable side of the main-actor line (see CLAUDE.md).
    /// It is also why `AgentsMonitor` stays a stateless enum - the previous sample and the
    /// hysteresis clock live in `UsageModel` and arrive here as parameters, so a test can
    /// drive a whole timeline without a process table or a clock.
    ///
    /// `activeSince` maps a pid to the instant it was last seen above the threshold, and
    /// comes back updated. Entries for pids that are gone are dropped, which is also what
    /// keeps pid reuse from inheriting a verdict.
    ///
    /// - Parameter dt: seconds since `previous` was taken, or `nil` on the first scan. A
    ///   window outside `minSampleWindow...maxSampleWindow` is discarded rather than
    ///   divided by, and discarded means *nothing is concluded* for the pids it covers -
    ///   see the middle case in `load`.
    static func classify(previous: [AgentProcess],
                         current: [AgentProcess],
                         dt: TimeInterval?,
                         activeSince: [Int32: Date],
                         now: Date) -> (agents: [AgentProcess], activeSince: [Int32: Date]) {
        // By pid, never by index: the two lists are independently sorted and a session
        // that started or ended between scans shifts everything after it.
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let usable = dt.map { $0 >= minSampleWindow && $0 <= maxSampleWindow } ?? false

        var since = activeSince
        var out: [AgentProcess] = []
        out.reserveCapacity(current.count)

        for var agent in current {
            if let load = load(agent: agent, previous: before[agent.id],
                               dt: dt, windowUsable: usable),
               load >= activeThreshold {
                since[agent.id] = now
            }
            // Above the threshold this instant, or recently enough to still count.
            if let last = since[agent.id], now.timeIntervalSince(last) <= activeGrace {
                agent.isActive = true
            }
            out.append(agent)
        }

        let live = Set(current.map(\.id))
        since = since.filter { live.contains($0.key) }
        return (out, since)
    }

    /// Fraction of a core this session has been using, or `nil` when it cannot be told.
    ///
    /// Three cases, and the middle one is why `windowUsable` is a parameter of its own
    /// rather than being folded into a `nil` `dt`:
    ///
    /// - **A baseline and a window worth dividing by**: the honest answer, CPU spent over
    ///   time passed.
    /// - **A baseline and a window that is not**: `nil`. Nothing is measured and nothing is
    ///   claimed; the hysteresis in `classify` goes on holding the last real verdict. This
    ///   must *not* fall through to the lifetime average below, and that is not a
    ///   hypothetical: waking a laptop puts hours on `dt`, and a session that worked hard
    ///   this morning and has been parked at the prompt since carries a lifetime average
    ///   well over the threshold. Substituting it lights up every such session for a full
    ///   grace period while they burn nothing at all. Measured on a live table, three of
    ///   fifteen sessions were above 2% on their lifetime average alone.
    /// - **No baseline at all** - the first scan after launch, a pid seen for the first
    ///   time, or a counter that went backwards because the pid was reused: the lifetime
    ///   average, which is the only thing one sample can support. It reads low for a
    ///   session idle for hours that just started working and corrects itself on the next
    ///   scan, which beats reporting nothing for the first ten seconds after launch.
    private static func load(agent: AgentProcess, previous: AgentProcess?,
                             dt: TimeInterval?, windowUsable: Bool) -> Double? {
        // A counter that went backwards means this pid is a different process now, so what
        // was sampled under it is no baseline: fall through to the lifetime average.
        if let previous, agent.cpuNanos >= previous.cpuNanos {
            guard windowUsable, let dt else { return nil }
            return Double(agent.cpuNanos - previous.cpuNanos) / 1e9 / dt
        }
        guard agent.elapsed >= 1 else { return nil }
        return Double(agent.cpuNanos) / 1e9 / agent.elapsed
    }

    // MARK: - Matching
    // Internal rather than private so Tests/main.swift can exercise the rules.

    /// Interpreters that run `claude` as a script: only for these does the first argument
    /// count, otherwise `vim claude` or `grep claude` would register as an agent.
    private static let interpreters: Set<String> = ["node", "bun", "deno", "npx", "electron"]

    /// Whether a process is a Claude Code session, from its executable and its argv.
    ///
    /// `execPath` is what the kernel actually ran, already symlink-resolved, so the native
    /// installer's `~/.local/bin/claude` arrives here as the versioned binary it points
    /// at. Both are read from the kernel as they were stored, so an install path with a
    /// space in it is just a path: there is nothing to unquote and nothing to guess.
    ///
    /// argv[0] is deliberately not consulted. It only disagrees with `execPath` when
    /// something else launched the process, and then it does not name `claude` either: a
    /// `#!/bin/sh` wrapper called `claude` arrives as `execPath: /bin/bash`,
    /// `argv: ["/bin/sh", "./claude"]`, verified against a live one.
    static func isAgent(execPath: String, argv: [String]) -> Bool {
        if namesClaude(execPath) { return true }
        guard interpreters.contains(base(execPath)) else { return false }
        // Any argument that names `claude`, not merely the first one without a dash.
        // "First non-flag argument" is only node's rule for flags that stand alone: a
        // value-taking one puts its value exactly there (`node -r ./polyfill /…/claude`,
        // `node --import ./hook.mjs /…/claude`), so the script is further along and the
        // session was missed entirely. Widening it costs nothing that was not already
        // exposed, since reaching here at all means the executable is a known interpreter.
        return argv.dropFirst().contains { !$0.hasPrefix("-") && namesClaude($0) }
    }

    private static func namesClaude(_ path: String) -> Bool {
        if base(path) == "claude" { return true }
        // The native installer symlinks `claude` to a versioned binary, so a session
        // launched through the resolved path is named after the version.
        if path.contains("/claude/versions/") { return true }
        // npm/bun installs resolve the shim to the package entry point.
        if base(path) == "cli.js", path.contains("claude-code") { return true }
        return false
    }

    private static func base(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Where the session is being driven from. The IDE cases are recognised by the
    /// extension's install path, which is the executable itself for the bundled binary and
    /// an argument for anything the extension shells out to, so both are searched.
    ///
    /// **Searched entry by entry, and only the entries that could be a path.** The markers
    /// used to be matched against the whole argument vector flattened into one line, which
    /// made `claude -p "fix the .vscode/extensions loader"` a VS Code session: a prompt is
    /// an argv entry like any other. The executable always counts (it is a path by
    /// definition, spaces and all); an argument counts when it has a slash and no
    /// whitespace, which is what a path looks like and what prose does not.
    static func hostName(execPath: String, argv: [String]) -> String {
        let paths = [execPath] + argv.filter(isPathLike)
        func names(_ markers: String...) -> Bool {
            markers.contains { marker in paths.contains { $0.contains(marker) } }
        }
        if names(".vscode/extensions", ".vscode-server") { return "VS Code" }
        if names(".cursor/extensions") { return "Cursor" }
        if names("JetBrains", ".idea") { return "JetBrains" }
        // Whole argv entries, not substrings: a directory called `my-print` is not a
        // headless run, and neither is a prompt containing " -p ", since the vector is
        // never flattened for this test. argv[0] is skipped, so an executable literally
        // named `-p` is not a flag either.
        let flags = argv.dropFirst()
        if flags.contains("-p") || flags.contains("--print") { return "Headless" }
        return "Terminal"
    }

    /// Whether an argument could be naming a location on disk rather than saying something.
    /// A path has a separator and no spaces; a prompt is prose and has both.
    private static func isPathLike(_ s: String) -> Bool {
        s.contains("/") && !s.contains(where: \.isWhitespace)
    }

    /// "3h 12m", or "8m" under the hour. Seconds are never shown: at this size they only
    /// make the column twitch.
    static func humanElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    // MARK: - libproc

    /// Every pid on the machine.
    ///
    /// Sized, then read with slack, because processes can start between the two calls. A
    /// read that exactly fills the buffer may have been truncated, and a truncated table
    /// would silently under-count agents, so it is retried rather than trusted - and if it
    /// keeps happening the answer is `nil` ("could not read"), never a short list.
    private static func allPids() -> [Int32]? {
        for attempt in 0..<3 {
            let sized = proc_listallpids(nil, 0)
            guard sized > 0 else { return nil }
            var buf = [Int32](repeating: 0, count: Int(sized) + 64 * (attempt + 1))
            let n = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<Int32>.size))
            guard n > 0 else { return nil }
            if Int(n) < buf.count { return Array(buf.prefix(Int(n))) }
        }
        return nil
    }

    /// The executable a pid is running, symlink-resolved by the kernel. `nil` when the
    /// process has exited or belongs to another user.
    private static func execPath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE spelled out: Swift does not import the macro (it is
        // marked unavailable because the struct behind it is not bridged).
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        // Cut at the terminator rather than handing the array to `String(cString:)`, which
        // is deprecated for exactly this reason: it reads until a NUL it has to trust is
        // there. `prefix(while:)` needs no such promise.
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The argument vector, as the kernel stored it at `exec`.
    ///
    /// `KERN_PROCARGS2` lays out an `Int32` argc, then the executable path, then NUL
    /// padding, then argc NUL-terminated arguments. Only ever called for the handful of
    /// pids that got past the executable gate, at ~8 µs each.
    ///
    /// Each argument is built from its own bytes with `String(decoding:as:)` rather than by
    /// pointing `String(cString:)` at the buffer. The slice deliberately stops *before* the
    /// terminator, so a C-string read would run one byte past the bounds it was handed and
    /// only find a NUL because the parent array happens to hold one - and it needs a base
    /// address that the standard library does not promise is non-nil for the empty slice an
    /// empty argument produces. Neither assumption is load-bearing any more.
    private static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return [] }

        var argc: Int32 = 0
        memcpy(&argc, buf, MemoryLayout<Int32>.size)
        var out: [String] = []
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }      // the exec path, which the caller has
        while i < size, buf[i] == 0 { i += 1 }      // alignment padding
        while i < size, out.count < Int(argc) {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    /// CPU consumed so far and memory held right now, in one syscall.
    ///
    /// `proc_pid_rusage` rather than `proc_pidinfo(PROC_PIDTASKINFO)` for one reason:
    /// `ri_phys_footprint` is the number Activity Monitor shows in its "Memory" column,
    /// while `PROC_PIDTASKINFO`'s `pti_resident_size` is plain RSS. They are far apart -
    /// measured on this app, 37 MB against 83 MB for the same pid at the same instant,
    /// with `footprint(1)` and Activity Monitor both saying 37 - and printing a number the
    /// user cannot find anywhere else is worse than printing none. Both flavours carry the
    /// same CPU counter, so choosing this one costs nothing.
    ///
    /// **The times are in mach absolute time units, not nanoseconds**, whatever
    /// `ri_user_time` sounds like. On Apple Silicon the timebase is 125/3, so reading them
    /// as nanoseconds understates CPU by 41.67x and every percentage derived from one is
    /// silently, plausibly wrong. Verified against `ps -o time` on three processes: a raw
    /// 69 923 834 reads as 0.070 s uncorrected and 2.913 s corrected, and `ps` said 2.91.
    /// The bug hides on Intel, where the timebase is 1/1.
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        // 1/1 if the call ever fails: still monotonic, just uncalibrated.
        guard info.denom != 0, info.numer != 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    private static func resourceUsage(_ pid: Int32) -> (cpuNanos: UInt64, memoryBytes: UInt64)? {
        var info = rusage_info_v4()
        // `rusage_info_t` is a bare `void *`, so the struct has to be handed over through
        // a pointer-shaped slot rather than passed directly.
        let read = withUnsafeMutablePointer(to: &info) { raw in
            raw.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard read == 0 else { return nil }
        // Divide before multiplying: the product would be the thing to overflow, and the
        // truncation is nanoseconds on a counter measured in hours.
        let ticks = info.ri_user_time &+ info.ri_system_time
        return (ticks / timebase.denom &* timebase.numer, info.ri_phys_footprint)
    }

    /// Wall-clock start time in epoch seconds.
    private static func startTime(_ pid: Int32) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard read == size else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    }

    /// Working directory basename, "" if it cannot be read.
    ///
    /// A kernel path-cache lookup of about a microsecond, so it runs fresh on every scan
    /// and needs no cache of its own. That matters beyond the cost: a process caught
    /// mid-exec reads back empty, and a cached answer would label a live session "unknown
    /// folder" for the rest of its life, where a fresh one simply resolves on the next
    /// scan. Nothing to prune, and nothing for pid reuse to poison.
    private static func cwdName(of pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard read == size else { return "" }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        guard path != "/", !path.isEmpty else { return "" }
        return (path as NSString).lastPathComponent
    }
}
