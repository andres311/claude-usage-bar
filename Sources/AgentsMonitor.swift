import Foundation

/// One running Claude Code process (a session/agent) on this machine.
struct AgentProcess: Identifiable, Equatable {
    let id: Int32                // pid
    let folder: String           // working directory basename, "" if unknown
    let host: String             // "VS Code", "Terminal", "Cursor", …
    let elapsed: TimeInterval    // seconds since it started, what the list sorts on
    let uptime: String           // the same thing as "8m" or "3h 12m"
}

/// Counts Claude Code processes by scanning the process table.
///
/// A process counts as an agent when argv[0] names the `claude` executable, or when a
/// known interpreter runs it (`node /…/bin/claude`). That matches the native install,
/// the IDE extension's bundled binary and SDK/npm runs, and excludes the Claude desktop
/// app and this menu bar app.
///
/// `ps` `comm` is deliberately not asked for: macOS truncates it to 16 characters, so for
/// any real install path it is a useless prefix (`/Users/andres/.l`) that can also contain
/// a space and throw the column split off by one. `pid` and `etime` never contain spaces
/// and `args` is taken as the whole remainder of the line, so the parse cannot misalign.
enum AgentsMonitor {

    /// Returns `nil` when the process table could not be read at all (no `ps`, or the
    /// watchdog killed it), which callers must not confuse with an empty result: an
    /// unreadable table says nothing about how many agents are running, and blanking the
    /// list on it would flicker every live session off the screen and back.
    static func scan() async -> [AgentProcess]? {
        await Task.detached(priority: .utility) { () -> [AgentProcess]? in
            guard let raw = run("/bin/ps", ["-Ao", "pid=,etime=,args="]) else { return nil }
            var agents: [AgentProcess] = []
            var live = Set<Int32>()

            for line in raw.split(separator: "\n") {
                let fields = line.split(separator: " ", maxSplits: 2,
                                        omittingEmptySubsequences: true)
                guard fields.count == 3, let pid = Int32(fields[0]) else { continue }
                let args = String(fields[2]).trimmingCharacters(in: .whitespaces)

                guard isClaude(args: args) else { continue }
                // Never count ourselves, even if renamed.
                if pid == ProcessInfo.processInfo.processIdentifier { continue }

                live.insert(pid)
                let elapsed = elapsedSeconds(String(fields[1]))
                agents.append(AgentProcess(
                    id: pid,
                    folder: cwdName(of: pid),
                    host: hostName(args: args),
                    elapsed: elapsed,
                    uptime: humanElapsed(elapsed)
                ))
            }
            pruneCwdCache(keeping: live)
            return agents.sorted(by: precedes)
        }.value
    }

    /// Grouped by folder, then longest-running first within a folder, then by pid so the
    /// list never depends on the order `ps` happened to print.
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
    /// `elapsed` is deliberately excluded. It changes on every scan by definition, while
    /// `uptime` - the same value rounded to a minute - is what actually gets printed. A
    /// plain `==` would therefore report a change every second and publish a redraw for an
    /// identical picture, and re-running `UsageView.body` on a timer is precisely what the
    /// `Clock` being a separate object exists to prevent.
    static func sameOnScreen(_ a: [AgentProcess], _ b: [AgentProcess]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.id == $1.id && $0.folder == $1.folder
                && $0.host == $1.host && $0.uptime == $1.uptime
        }
    }

    // MARK: - Matching
    // Internal rather than private so Tests/main.swift can exercise the parsing.

    /// Interpreters that run `claude` as a script: only for these does argv[1] count,
    /// otherwise `vim claude` or `grep claude` would register as an agent.
    private static let interpreters: Set<String> = ["node", "bun", "deno", "npx", "electron"]

    /// Whether a path exists on disk, injected so the tests stay hermetic.
    static let fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    static func isClaude(args: String, exists: (String) -> Bool = fileExists) -> Bool {
        // Cheap gate before any path work: every rule below needs the literal lowercase
        // "claude" somewhere in the line, and this runs once per process on the machine.
        guard args.contains("claude") else { return false }

        let candidates = argv0Candidates(args, exists: exists)
        guard let argv0 = candidates.first else { return false }
        if candidates.contains(where: namesClaude) { return true }
        // An interpreter running the CLI: only then does argv[1] count.
        guard interpreters.contains(base(argv0)) else { return false }
        let rest = args.dropFirst(argv0.count).trimmingCharacters(in: .whitespaces)
        return argv0Candidates(rest, exists: exists).contains(where: namesClaude)
    }

    /// The possible argv[0] values for a `ps args` line, longest last.
    ///
    /// `ps` prints the argument vector space-joined and unquoted, so an executable path
    /// that contains a space is indistinguishable from two separate arguments. When the
    /// first token is an absolute path that does not exist, the next token is folded in
    /// and the result tried again, which recovers
    /// `/Users/x/My Code/.local/bin/claude` without turning `vim claude` into a match:
    /// `vim` is not an absolute path, and `/usr/bin/vim` exists so it is never extended.
    /// Folding stops at the first token that starts with `-`, since that is a flag.
    static func argv0Candidates(_ args: String, exists: (String) -> Bool) -> [String] {
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = tokens.first else { return [] }
        var out = [first]
        guard first.hasPrefix("/") else { return out }

        var candidate = first
        for token in tokens.dropFirst() {
            // Bounded: no real install path has this many spaces, and this runs per line.
            if out.count >= 8 || token.hasPrefix("-") || exists(candidate) { break }
            candidate += " " + token
            out.append(candidate)
        }
        return out
    }

    private static func namesClaude(_ token: String) -> Bool {
        if base(token) == "claude" { return true }
        // The native installer symlinks `claude` to a versioned binary, so a session
        // launched through the resolved path is named after the version.
        if token.contains("/claude/versions/") { return true }
        // npm/bun installs resolve the shim to the package entry point.
        if base(token) == "cli.js", token.contains("claude-code") { return true }
        return false
    }

    private static func base(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func hostName(args: String) -> String {
        if args.contains(".vscode/extensions") || args.contains(".vscode-server") { return "VS Code" }
        if args.contains(".cursor/extensions") { return "Cursor" }
        if args.contains("JetBrains") || args.contains(".idea") { return "JetBrains" }
        // Whole tokens, not substrings: a directory called `my-print` or a prompt that
        // mentions `-p` is not a headless run. `ps` drops the shell's quoting, so a
        // prompt containing a bare ` -p ` can still fool this; nothing in the output can
        // tell the two apart, and the label is cosmetic.
        let flags = args.split(separator: " ").dropFirst().map(String.init)
        if flags.contains("-p") || flags.contains("--print") { return "Headless" }
        return "Terminal"
    }

    // MARK: - Details

    /// `lsof` costs ~20 ms per pid and the scan runs every few seconds, so each working
    /// directory is looked up once and kept. A process keeps its cwd for its whole life in
    /// practice; entries for pids that are gone are dropped, which also covers pid reuse.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cwdCache: [Int32: String] = [:]
    /// Consecutive failed lookups per pid. A failure is not cached as the answer right
    /// away: `lsof` also comes back empty when the process was mid-exec or the watchdog
    /// fired, and writing that in would leave a live session labelled "unknown folder"
    /// for as long as it runs. After a few tries it is accepted, so a process whose cwd
    /// genuinely cannot be read does not cost an `lsof` on every scan forever.
    nonisolated(unsafe) private static var cwdMisses: [Int32: Int] = [:]
    private static let cwdRetries = 3

    private static func cwdName(of pid: Int32) -> String {
        cacheLock.lock()
        let cached = cwdCache[pid]
        let misses = cwdMisses[pid] ?? 0
        cacheLock.unlock()
        if let cached { return cached }
        if misses >= cwdRetries { return "" }

        let name = lookUpCwdName(of: pid)
        cacheLock.lock()
        if name.isEmpty {
            cwdMisses[pid] = misses + 1
        } else {
            cwdCache[pid] = name
            cwdMisses[pid] = nil
        }
        cacheLock.unlock()
        return name
    }

    private static func pruneCwdCache(keeping live: Set<Int32>) {
        cacheLock.lock()
        cwdCache = cwdCache.filter { live.contains($0.key) }
        cwdMisses = cwdMisses.filter { live.contains($0.key) }
        cacheLock.unlock()
    }

    /// Working directory via lsof (a single fd lookup per pid).
    ///
    /// `-w` silences the warnings `-b` would otherwise print; both keep lsof away from
    /// the kernel calls that block on an unresponsive network mount. The watchdog in
    /// `run` is the backstop for the cases they do not cover.
    private static func lookUpCwdName(of pid: Int32) -> String {
        guard let out = run("/usr/sbin/lsof",
                            ["-b", "-w", "-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { return "" }
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            if path == "/" || path.isEmpty { continue }
            return (path as NSString).lastPathComponent
        }
        return ""
    }

    /// ps etime is `[[dd-]hh:]mm:ss`.
    static func elapsedSeconds(_ etime: String) -> TimeInterval {
        var days = 0, rest = etime
        if let dash = etime.firstIndex(of: "-") {
            days = Int(etime[etime.startIndex..<dash]) ?? 0
            rest = String(etime[etime.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Int($0) ?? 0 }
        var h = 0, m = 0, s = 0
        switch parts.count {
        case 3: h = parts[0]; m = parts[1]; s = parts[2]
        case 2: m = parts[0]; s = parts[1]
        default: break
        }
        return TimeInterval((days * 24 + h) * 3600 + m * 60 + s)
    }

    /// "3h 12m", or "8m" under the hour. Seconds are never shown: at this size they only
    /// make the column twitch.
    static func humanElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// Runs `path` and returns its stdout, or nil if it could not start or had to be
    /// killed for taking too long.
    ///
    /// The watchdog is not optional. `lsof` can sit in the kernel for a long time when a
    /// process's working directory lives on an unresponsive network mount, and this whole
    /// scan runs on the task the 1 Hz tick loop awaits: one stuck pid would freeze the
    /// agent list, the reset countdowns and the menu bar with it. `terminate()` is used
    /// rather than `kill(pid)` because Foundation guards it against a child that has
    /// already exited, so it cannot land on a reused pid.
    private static func run(_ path: String, _ args: [String],
                            timeout: TimeInterval = 5) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        // Not a Pipe: an undrained one deadlocks waitUntilExit() once the child writes
        // more than the buffer holds, and that would freeze the scan for good.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                       execute: watchdog)
        // This read is what blocks; killing the child closes the pipe and releases it.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()

        // Killed by the watchdog: whatever arrived is a truncated prefix, so drop it
        // rather than report half a process table as the whole truth.
        if p.terminationReason == .uncaughtSignal { return nil }
        return String(data: data, encoding: .utf8)
    }
}
