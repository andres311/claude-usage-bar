import Foundation
import SwiftUI

/// The 1 Hz clock behind the reset countdowns, kept apart from `UsageModel`.
///
/// Splitting it out is what keeps a tick from re-running `UsageView.body`. Only the leaf
/// views that print elapsed time observe this, so everything else in the panel - the gear
/// menu above all - is untouched a second later.
@MainActor
final class Clock: ObservableObject {
    @Published private(set) var now = Date()
    func tick() { now = Date() }
}

/// Polls the Claude OAuth usage endpoint and publishes the result.
///
/// The access token is read from the same place Claude Code keeps it (the
/// login keychain item "Claude Code-credentials", or ~/.claude/.credentials.json
/// on setups that store it as a file). We never persist or log it.
@MainActor
final class UsageModel: ObservableObject {

    @Published private(set) var usage: UsageResponse?
    @Published private(set) var errorText: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    /// Ticks every second so the countdowns stay live.
    ///
    /// A separate object on purpose, and a `let` so this model never republishes when it
    /// ticks. Only the two leaf views that render elapsed time observe it, which means a
    /// tick cannot re-run `UsageView.body` - and that matters far beyond a wasted redraw:
    /// re-running the body rebuilds the gear menu's `NSMenu` while it is on screen, so
    /// the submenu under the pointer flickered and swallowed the click.
    let clock = Clock()
    /// Claude Code processes running on this machine.
    @Published private(set) var agents: [AgentProcess] = []
    /// Set while the API is rate limiting us (429 + Retry-After).
    @Published private(set) var throttledUntil: Date?
    /// True while the popover is on screen. `now` only drives the countdowns inside the
    /// panel, so the 1 Hz clock is parked while nothing is looking at it.
    /// True while an `NSMenu` is tracking. Deliberately **not** `@Published`: publishing
    /// it would trigger the exact rebuild it exists to prevent. Everything that would
    /// otherwise publish on a timer parks while this is set, so the menu's items stay put
    /// for as long as the pointer is in them.
    var menuTracking = false {
        didSet {
            // Catch up on the second that was skipped, now that it is safe to redraw.
            if !menuTracking, oldValue, panelVisible { clock.tick() }
        }
    }

    @Published var panelVisible = false {
        didSet {
            guard panelVisible, !oldValue else { return }
            clock.tick()
            // The scan is skipped while nothing displays it (see `start`), so the list
            // could be minutes old by the time the panel opens.
            scanAgentsNow()
        }
    }

    @Published var showAgents: Bool {
        didSet {
            UserDefaults.standard.set(showAgents, forKey: Keys.showAgents)
            if showAgents, !oldValue { scanAgentsNow() }
        }
    }

    @Published var refreshInterval: Double {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: Keys.interval)
            restartTimer()
        }
    }

    @Published var titleMode: TitleMode {
        didSet { UserDefaults.standard.set(titleMode.rawValue, forKey: Keys.titleMode) }
    }

    enum TitleMode: String, CaseIterable, Identifiable {
        case sessionAndWeek, session, week, highest, credits, iconOnly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sessionAndWeek: return "Session + week"
            case .session: return "Session only"
            case .week: return "Week only"
            case .highest: return "Highest"
            case .credits: return "Extra usage"
            case .iconOnly: return "Icon only"
            }
        }
    }

    private enum Keys {
        static let interval = "refreshInterval"
        static let titleMode = "titleMode"
        static let showAgents = "showAgents"
        static let cachedUsage = "cachedUsageJSON"
        static let cachedAt = "cachedUsageDate"
    }

    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var agentTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// When the last request was *attempted*, in memory only. The gap below must not be
    /// measured against `lastUpdated`, which is restored from the cache on disk: a
    /// relaunch would then skip its first fetch and sit on stale numbers until the next
    /// tick, which with a 15 minute interval is a long time to show yesterday's usage.
    private var lastAttempt: Date?
    /// Consecutive 429s, for the doubling backoff below. Reset by any 200.
    private var consecutive429 = 0
    /// Set by a 401/403 and cleared only by a 200. A 429 must not wipe the "session
    /// expired" message off the panel: the token is still expired, and losing the text
    /// also loses the `!` chip, which is the only thing saying the numbers are stale.
    private var authExpired = false
    /// How often the process table is scanned. This is a local `ps` (plus an `lsof` for
    /// pids never seen before, which is cached), so it is rate limited by nothing and has
    /// no business sharing a cadence with the API: it runs in its own loop precisely so a
    /// 15 minute usage interval cannot leave a session that ended on screen for 15
    /// minutes.
    ///
    /// The two cadences are far apart because only one of them is the steady state.
    /// Measured with `getrusage` over `RUSAGE_SELF` + `RUSAGE_CHILDREN` on a table of ~860
    /// processes, a warm scan costs **~33 ms of CPU** - almost all of it forking `ps` and
    /// having it format every process on the machine, so it does not get cheaper with
    /// fewer agents. That is 3.3% of a core once a second, which is fine for the seconds a
    /// popover is on screen and indefensible for an app that sits in the menu bar all day.
    /// Hence 10s whenever only the chip needs the count: ~12 s of CPU per hour.
    ///
    /// If the chip ever needs to be quicker than this, the way to buy it is a cheaper
    /// scan, not a shorter timer. `pgrep -f claude` costs ~6 ms and its pid set is a strict
    /// superset of what `isClaude` accepts (both gate on the literal "claude" appearing in
    /// the arguments), so it can decide whether the full `ps` is worth running at all.
    static let agentScanInterval: TimeInterval = 10
    static let agentScanIntervalPanelOpen: TimeInterval = 1
    /// The usage endpoint rate limits per 5-minute window, so keep a floor
    /// between requests no matter what the user picks.
    static let minFetchGap: TimeInterval = 25
    /// First step of the 429 backoff, doubled per consecutive 429. The endpoint answers
    /// `Retry-After: 0` while it is still refusing requests (measured: 429 on all 12 of
    /// 12 probes over 5.5 minutes, every response carrying that header), so honoring it
    /// literally just retries into the same window.
    static let minThrottle: TimeInterval = 60
    /// Ceiling for the 429 backoff, so neither the doubling nor a bogus `Retry-After`
    /// can park the app forever.
    static let maxThrottle: TimeInterval = 900

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let usagePageURL = URL(string: "https://claude.ai/settings/usage")!

    /// RFC 7231 date, the other form `Retry-After` is allowed to take.
    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: Keys.interval)
        refreshInterval = stored > 0 ? max(stored, Self.minFetchGap) : 60
        titleMode = TitleMode(rawValue: defaults.string(forKey: Keys.titleMode) ?? "")
            ?? .sessionAndWeek
        showAgents = defaults.object(forKey: Keys.showAgents) as? Bool ?? true

        // Show the last known numbers immediately instead of an empty panel;
        // they are labelled with their age in the footer.
        if let data = defaults.data(forKey: Keys.cachedUsage),
           let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data) {
            usage = decoded
            lastUpdated = defaults.object(forKey: Keys.cachedAt) as? Date
        }
    }

    func start() {
        restartTimer()
        // The agent list gets its own loop rather than riding on the clock or the poll.
        // Both of those are paced by something unrelated - one by what the countdowns
        // need, the other by an endpoint that rate limits - and a session that ends has
        // to leave the panel and the menu bar promptly either way.
        agentTask = Task { [weak self] in
            while !Task.isCancelled {
                // Without this the loop would keep spinning after the model is gone:
                // nothing else cancels it.
                guard let self else { return }
                // Only scan while something is actually showing the result: the panel is
                // open, or the menu bar carries the agents chip. Otherwise this is a `ps`
                // over the whole process table feeding a list nobody can see. Publishing
                // the result would also rebuild an open gear menu, hence `menuTracking`.
                if !self.menuTracking, self.panelVisible || self.showAgents {
                    self.applyScan(await AgentsMonitor.scan())
                }
                try? await Task.sleep(for: .seconds(self.panelVisible
                                                    ? Self.agentScanIntervalPanelOpen
                                                    : Self.agentScanInterval))
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.panelVisible, !self.menuTracking { self.clock.tick() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        tickTask?.cancel()
        agentTask?.cancel()
        scanTask?.cancel()
    }

    /// Off-cycle agent scan, for the moment something starts displaying the list.
    private func scanAgentsNow() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let found = await AgentsMonitor.scan()
            guard !Task.isCancelled else { return }
            self?.applyScan(found)
        }
    }

    /// Publishes a scan result, filtering the two ways a scan can be worse than no scan.
    ///
    /// `nil` means the scan itself failed (`ps` missing, or killed by its watchdog), which
    /// is not the same as "no agents are running": emptying the list on it would blink
    /// every session off the panel and out of the menu bar for a beat and then back.
    ///
    /// An unchanged list is dropped rather than assigned, because assigning publishes, and
    /// at one scan a second while the panel is open that is `UsageView.body` re-running on
    /// a timer for an identical picture - the thing the separate `Clock` exists to avoid.
    private func applyScan(_ found: [AgentProcess]?) {
        guard let found, !AgentsMonitor.sameOnScreen(found, agents) else { return }
        agents = found
    }

    private func restartTimer() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // A response landing mid-menu publishes and rebuilds it out from under
                // the pointer. Skipping one poll costs at most one interval of freshness,
                // and the menu is only ever up for a few seconds.
                if !self.menuTracking { await self.refresh() }
                try? await Task.sleep(for: .seconds(self.nextPollDelay))
            }
        }
    }

    /// Normally the user's interval, but a running 429 backoff shortens it to just past
    /// the moment it expires. Sleeping the full interval instead means the panel counts
    /// "retry in 4m" down to zero and then sits there for the rest of a 15 minute cycle,
    /// which reads as the backoff being stuck.
    private var nextPollDelay: TimeInterval {
        guard let until = throttledUntil else { return refreshInterval }
        let wait = until.timeIntervalSinceNow
        guard wait > 0 else { return min(refreshInterval, Self.minFetchGap) }
        return min(refreshInterval, wait + 1)
    }

    /// The earliest moment a request would actually go out, so the panel can disable its
    /// refresh button instead of dropping the click. Covers both the floor between
    /// requests and a running 429 backoff.
    var nextFetchAllowedAt: Date? {
        [lastAttempt?.addingTimeInterval(Self.minFetchGap), throttledUntil]
            .compactMap { $0 }.max()
    }

    /// The floor applies to a user-initiated refresh as well. It used to be bypassable
    /// from the panel's button, which made clicking it repeatedly the one supported way to
    /// walk straight into the endpoint's 5-minute 429 window - and retrying inside that
    /// window is what holds it open. The button is disabled until this allows a request.
    func refresh() async {
        guard !isLoading else { return }
        if let allowed = nextFetchAllowedAt, Date() < allowed { return }
        lastAttempt = Date()
        isLoading = true
        defer { isLoading = false }

        guard let token = await Credentials.accessToken() else {
            errorText = "No Claude Code credentials found. Run `claude` and log in."
            return
        }

        var req = URLRequest(url: Self.usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                lastUpdated = Date()
                errorText = nil
                throttledUntil = nil
                consecutive429 = 0
                authExpired = false
                UserDefaults.standard.set(data, forKey: Keys.cachedUsage)
                UserDefaults.standard.set(lastUpdated, forKey: Keys.cachedAt)
            case 401, 403:
                // Claude Code refreshes the token itself; we just wait for it.
                authExpired = true
                errorText = "Session expired. Open Claude Code to refresh the login."
            case 429:
                // Back off and keep showing the last known numbers.
                let header = ((response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After") ?? "")
                    .trimmingCharacters(in: .whitespaces)
                // Retry-After is either a number of seconds or an HTTP date.
                let advertised = Double(header)
                    ?? Self.httpDate.date(from: header)?.timeIntervalSinceNow
                    ?? 0
                // Capped at 8: `maxThrottle` already clamps the result, so anything past
                // the fourth doubling is the same wait. The cap just keeps the exponent
                // below from running away over a long outage.
                consecutive429 = min(consecutive429 + 1, 8)
                // Doubling floor: 60s, 2m, 4m, 8m, then maxThrottle. A single blip
                // recovers on the next tick, while a sustained window stops being
                // hammered - retrying inside it appears to hold it open.
                let floor = Self.minThrottle * pow(2, Double(consecutive429 - 1))
                throttledUntil = Date().addingTimeInterval(
                    min(max(advertised, floor), Self.maxThrottle))
                // Being throttled is shown by the footer's countdown, not as an error -
                // but only a 200 is evidence the login came back, so an expired session
                // keeps its message and its `!` chip through the backoff.
                if !authExpired { errorText = nil }
            default:
                errorText = "HTTP \(code)"
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Menu bar title

    /// The chips shown next to the mark, in order. `StatusIcon` turns these into the
    /// status item image.
    func statusSegments() -> [StatusIcon.Segment] {
        var out: [StatusIcon.Segment] = []

        // The gauge carries the severity the API sent, so a chip and the bar it mirrors in
        // the panel always agree. Re-deriving it from the percentage alone used to drop an
        // early escalation on the floor: a limit the API called critical stayed green.
        func chip(_ gauge: Gauge?) -> StatusIcon.Segment? {
            guard let gauge else { return nil }
            return StatusIcon.Segment(text: Fmt.percent(gauge.percent), severity: gauge.severity)
        }

        if let usage {
            switch titleMode {
            case .iconOnly:
                break
            case .session:
                if let c = chip(usage.session) { out.append(c) }
            case .week:
                if let c = chip(usage.weekly) { out.append(c) }
            case .credits:
                if let c = chip(usage.credits) { out.append(c) }
            case .highest:
                let best = [usage.session, usage.weekly].compactMap { $0 }
                    .max { $0.percent < $1.percent }
                if let c = chip(best) { out.append(c) }
            case .sessionAndWeek:
                if let c = chip(usage.session) { out.append(c) }
                if let c = chip(usage.weekly) { out.append(c) }
            }
        } else if errorText == nil {
            // Nothing fetched yet: one chip carries the state.
            out.append(StatusIcon.Segment(text: "…", severity: .normal))
        }

        // An error has to show even when cached numbers are on screen. Without this the
        // menu bar keeps displaying yesterday's percentages after the token expires and
        // the only hint that they are stale is inside the panel.
        if errorText != nil {
            out.append(StatusIcon.Segment(text: "!", severity: .critical))
        }

        if showAgents, !agents.isEmpty {
            out.append(StatusIcon.Segment(text: "\(agents.count)",
                                          severity: .normal,
                                          symbol: "figure.run"))
        }
        return out
    }
}

// MARK: - Credentials

enum Credentials {
    private static let keychainService = "Claude Code-credentials"

    /// Reads the OAuth access token off the main thread.
    static func accessToken() async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            if let json = readKeychain(), let token = parse(json) { return token }
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: file), let token = parse(data) { return token }
            return nil
        }.value
    }

    /// `security` is used instead of SecItemCopyMatching so the keychain ACL
    /// prompt is a one-time "Always Allow" for a system binary.
    private static func readKeychain() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        p.standardOutput = out
        // Not a Pipe: an undrained one deadlocks waitUntilExit() if the child ever
        // writes more to stderr than the buffer holds.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    private static func parse(_ data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { return nil }
        return token
    }
}
