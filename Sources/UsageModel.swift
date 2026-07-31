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

    /// True while the popover is on screen. The clock only drives the countdowns inside
    /// the panel, so it runs for exactly as long as this is set.
    @Published var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            guard panelVisible else {
                // Nothing is counting down: stop the loop rather than leave it waking up
                // once a second for the rest of the day (see `startClock`).
                tickTask?.cancel()
                tickTask = nil
                return
            }
            clock.tick()
            startClock()
            // The scan is skipped, and the loop behind it stopped, while nothing displays
            // the result (see `startAgentScan`), so the list could be minutes old - or
            // absent - by the time the panel opens.
            wakeAgentScan()
        }
    }

    @Published var showAgents: Bool {
        didSet {
            UserDefaults.standard.set(showAgents, forKey: Keys.showAgents)
            if showAgents, !oldValue { wakeAgentScan() }
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
    /// How often the process table is scanned. This is a local `libproc` walk, so it is
    /// rate limited by nothing and has no business sharing a cadence with the API: it runs
    /// in its own loop precisely so a 15 minute usage interval cannot leave a session that
    /// ended on screen for 15 minutes.
    ///
    /// The two cadences differ by what is watching, not by what a scan costs: at ~3 ms on
    /// a 750-process table the slow one spends about 0.4 s of CPU per hour and the fast one
    /// about a millisecond per tick. They are deliberately unhurried anyway - a count in
    /// the menu bar being half a minute stale is invisible, and the panel already scans the
    /// moment it opens (`wakeAgentScan`), so the interval below only governs how a session
    /// that ends *while you are looking* disappears.
    static let agentScanInterval: TimeInterval = 30
    static let agentScanIntervalPanelOpen: TimeInterval = 10
    /// The usage endpoint rate limits per 5-minute window, so keep a floor
    /// between requests no matter what the user picks.
    nonisolated static let minFetchGap: TimeInterval = 25
    /// First step of the 429 backoff, doubled per consecutive 429. The endpoint answers
    /// `Retry-After: 0` while it is still refusing requests (measured: 429 on all 12 of
    /// 12 probes over 5.5 minutes, every response carrying that header), so honoring it
    /// literally just retries into the same window.
    nonisolated static let minThrottle: TimeInterval = 60
    /// Ceiling for the 429 backoff, so neither the doubling nor a bogus `Retry-After`
    /// can park the app forever.
    nonisolated static let maxThrottle: TimeInterval = 900

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let usagePageURL = URL(string: "https://claude.ai/settings/usage")!

    // MARK: - Backoff arithmetic
    //
    // Static and `nonisolated` so `Tests/main.swift` can exercise the 429 policy without a
    // request, a network or the main actor. The model holds the state; these decide what
    // it means.

    /// `Retry-After` in seconds. Either a number of seconds or an RFC 7231 date, and in
    /// practice usually the literal `0` the endpoint sends while it is still refusing
    /// requests, hence a lower bound rather than the answer (see `throttleDelay`).
    ///
    /// The formatter is built per call on purpose: it is only reachable from a 429, which
    /// arrives minutes apart at most, and a cached one would either be main-actor isolated
    /// state reached from a `nonisolated` context or a mutable global shared across tasks.
    nonisolated static func retryAfterSeconds(_ header: String?, now: Date) -> TimeInterval {
        let header = (header ?? "").trimmingCharacters(in: .whitespaces)
        if let seconds = Double(header) { return seconds }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = f.date(from: header) else { return 0 }
        return date.timeIntervalSince(now)
    }

    /// How long to stop asking after a 429, given how many landed in a row.
    ///
    /// Doubles from `minThrottle`: 60s, 2m, 4m, 8m, then `maxThrottle`. A single blip
    /// recovers on the next tick, while a sustained window stops being hammered, which
    /// matters because retrying inside the window appears to hold it open. `advertised` is
    /// only ever a floor: honoring `Retry-After: 0` literally would retry straight back
    /// into the same window. The exponent is capped at 8 so a long outage cannot overflow
    /// it; `maxThrottle` has already flattened the result well before that.
    ///
    /// **A non-finite `advertised` is thrown away rather than clamped**, because clamping
    /// does not work on one: NaN has no ordering, so `min`/`max` carry it straight through
    /// - the same trap `Fmt.clampPercent` exists for, and `Double("nan")` parses. A NaN
    /// reaching here becomes a NaN `throttledUntil`, and every comparison against *that*
    /// date is false: no countdown in the footer, the refresh button live, and the poll
    /// loop back to its 25s floor inside the very window it is supposed to be backing off
    /// from. A header that is not a number is no advice, which is what `0` already means.
    nonisolated static func throttleDelay(consecutive429: Int,
                                          advertised: TimeInterval) -> TimeInterval {
        let n = min(max(consecutive429, 1), 8)
        let floor = minThrottle * pow(2, Double(n - 1))
        let advertised = advertised.isFinite ? advertised : 0
        return min(max(advertised, floor), maxThrottle)
    }

    /// How long the poll loop sleeps next.
    ///
    /// Normally the user's interval, but a running backoff shortens it to just past the
    /// moment it expires. Sleeping the full interval instead means the panel counts
    /// "retry in 4m" down to zero and then sits there for the rest of a 15 minute cycle,
    /// which reads as the backoff being stuck.
    nonisolated static func pollDelay(refreshInterval: TimeInterval,
                                      throttledUntil: Date?,
                                      now: Date) -> TimeInterval {
        guard let until = throttledUntil else { return refreshInterval }
        let wait = until.timeIntervalSince(now)
        guard wait > 0 else { return min(refreshInterval, minFetchGap) }
        return min(refreshInterval, wait + 1)
    }

    /// The earliest moment a request would actually go out: the floor between requests and
    /// a running backoff, whichever is later.
    nonisolated static func fetchAllowedAt(lastAttempt: Date?, throttledUntil: Date?) -> Date? {
        [lastAttempt?.addingTimeInterval(minFetchGap), throttledUntil].compactMap { $0 }.max()
    }

    /// What a fresh install polls at, before anyone touches the gear menu.
    ///
    /// 5 minutes rather than 1: the numbers move slowly, the endpoint rate limits per
    /// 5-minute window, and this is the one interval that runs unattended for months. The
    /// menu is where someone who wants it quicker says so.
    static let defaultRefreshInterval: TimeInterval = 300

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: Keys.interval)
        refreshInterval = stored > 0 ? max(stored, Self.minFetchGap) : Self.defaultRefreshInterval
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
        startAgentScan()
        // No clock here: it starts with the panel. See `startClock`.
    }

    /// The process-scan loop, which gets its own cadence rather than riding on the clock or
    /// the poll. Both of those are paced by something unrelated - one by what the
    /// countdowns need, the other by an endpoint that rate limits - and a session that ends
    /// has to leave the panel and the menu bar promptly either way.
    ///
    /// **It ends rather than idles when nothing is displaying a count.** Same reasoning as
    /// `startClock`: with the panel shut and "Show agent count" off, every wakeup tested
    /// two booleans and went back to sleep, which is a timer keeping a laptop out of its
    /// deep idle states in exchange for nothing. Both switches call `wakeAgentScan`, so the
    /// loop comes back the moment either one does, and `agentTask` is cleared on the way
    /// out so that call can tell a dead loop from a running one.
    private func startAgentScan() {
        guard agentTask == nil, panelVisible || showAgents else { return }
        agentTask = Task { [weak self] in
            defer { self?.agentTask = nil }
            while !Task.isCancelled {
                // Also stops the loop if the model went away underneath it, which nothing
                // else would do.
                guard let self, self.panelVisible || self.showAgents else { return }
                // Publishing a result rebuilds an open gear menu under the pointer, hence
                // `menuTracking`. Parked, not stopped: the menu closes in seconds.
                if !self.menuTracking { await self.scanAndApply() }
                try? await Task.sleep(for: .seconds(self.panelVisible
                                                    ? Self.agentScanIntervalPanelOpen
                                                    : Self.agentScanInterval))
            }
        }
    }

    /// Something that displays the count just turned on: get a fresh list on screen without
    /// waiting for the loop's next tick, and start that loop if it had shut itself down.
    ///
    /// The two branches are exclusive on purpose. `startAgentScan` scans as its first act,
    /// so calling both would walk the process table twice in the same millisecond - and two
    /// scans that close together are exactly the window `AgentsMonitor.classify` has to
    /// throw away.
    private func wakeAgentScan() {
        if agentTask == nil { startAgentScan() } else { scanAgentsNow() }
    }

    /// The 1 Hz clock, tied to `panelVisible` rather than started once and left running.
    ///
    /// The countdowns it drives exist only inside the popover, so outside it every tick is
    /// a wakeup that tests a boolean and goes back to sleep. The CPU cost of that is nil
    /// and the wakeups are not: 86 400 a day on a process with nothing to do is what keeps
    /// a laptop out of its deep idle states.
    ///
    /// Sleeps first, because opening the panel has already ticked it.
    private func startClock() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                // Also stops the loop if the model went away underneath it.
                guard let self, self.panelVisible else { return }
                if !self.menuTracking { self.clock.tick() }
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
            guard let self else { return }
            await self.scanAndApply()
        }
    }

    /// One scan, stamped with the moment its counters were read.
    ///
    /// The stamp is taken here rather than inside `applyScan` because the two are not the
    /// same instant when two scans overlap, and the CPU arithmetic downstream divides by the
    /// difference between them.
    private func scanAndApply() async {
        let found = await AgentsMonitor.scan()
        guard !Task.isCancelled else { return }
        applyScan(found, takenAt: Date())
    }

    /// The previous scan and when it was taken, which is what turns a CPU counter into a
    /// rate. Held here rather than in `AgentsMonitor` so that stays a stateless enum and
    /// the classifier stays a pure function (see `AgentsMonitor.classify`).
    ///
    /// This is the *unclassified* scan, since the raw counters are the baseline the next
    /// delta is measured from.
    private var previousScan: [AgentProcess] = []
    private var previousScanAt: Date?
    /// Per pid, the instant it was last seen above the activity threshold. The hysteresis
    /// clock; `classify` prunes it.
    private var activeSince: [Int32: Date] = [:]

    /// Publishes a scan result, filtering the two ways a scan can be worse than no scan.
    ///
    /// `nil` means the scan itself failed, which is not the same as "no agents are
    /// running": emptying the list on it would blink every session off the panel and out
    /// of the menu bar for a beat and then back.
    ///
    /// An unchanged list is dropped rather than assigned, because assigning publishes, and
    /// at one scan every ten seconds while the panel is open that is `UsageView.body`
    /// re-running on a timer for an identical picture - the thing the separate `Clock`
    /// exists to avoid.
    ///
    /// The `dt` handed to the classifier is **measured, never assumed**. The nominal
    /// cadence is 10s or 30s, but it changes when the panel opens, the loop parks entirely
    /// while a menu is tracking, and a machine that went to sleep comes back with hours on
    /// the clock. `classify` throws out a window it cannot trust.
    private func applyScan(_ found: [AgentProcess]?, takenAt: Date) {
        guard let found else { return }
        // Two scans can be in flight at once - the loop's, and the off-cycle one the panel
        // fires as it opens - and nothing says they finish in the order they started.
        // Applying the older one second would file its stale counters under a fresh
        // timestamp, and the next `dt` would then be shorter than the CPU it divides: a
        // burst of activity that never happened. The older result is simply dropped, since
        // by definition the newer one already says everything it did.
        if let previousScanAt, takenAt <= previousScanAt { return }
        let now = takenAt
        let result = AgentsMonitor.classify(
            previous: previousScan,
            current: found,
            dt: previousScanAt.map { now.timeIntervalSince($0) },
            activeSince: activeSince,
            now: now)
        previousScan = found
        previousScanAt = now
        activeSince = result.activeSince

        guard !AgentsMonitor.sameOnScreen(result.agents, agents) else { return }
        agents = result.agents
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

    private var nextPollDelay: TimeInterval {
        Self.pollDelay(refreshInterval: refreshInterval, throttledUntil: throttledUntil,
                       now: Date())
    }

    /// The earliest moment a request would actually go out, so the panel can disable its
    /// refresh button instead of dropping the click.
    var nextFetchAllowedAt: Date? {
        Self.fetchAllowedAt(lastAttempt: lastAttempt, throttledUntil: throttledUntil)
    }

    /// Fetches the usage, or returns having done nothing if it is too soon.
    ///
    /// **The floor applies to a user-initiated refresh too, and there is deliberately no
    /// way past it.** A button that could bypass it makes clicking repeatedly the fastest
    /// supported way into the endpoint's 5-minute 429 window, and retrying inside that
    /// window is what holds it open. `RefreshButton` disables itself until
    /// `nextFetchAllowedAt`, so the click is refused visibly rather than dropped here.
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
                // Before the decode, not after it: what these two react to is the status
                // line, and a 200 says the login works and the endpoint has stopped
                // refusing us whether or not the body turns out to be readable. Set
                // afterwards they were skipped by a `throw` from the decoder, which left
                // the app on an 8 minute backoff and showing "Session expired" while the
                // endpoint was answering it perfectly well.
                authExpired = false
                clearThrottle()
                usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                lastUpdated = Date()
                errorText = nil
                UserDefaults.standard.set(data, forKey: Keys.cachedUsage)
                UserDefaults.standard.set(lastUpdated, forKey: Keys.cachedAt)
            case 401, 403:
                // Claude Code refreshes the token itself; we just wait for it.
                authExpired = true
                errorText = "Session expired. Open Claude Code to refresh the login."
                clearThrottle()
            case 429:
                // Back off and keep showing the last known numbers.
                let now = Date()
                let advertised = Self.retryAfterSeconds(
                    (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"),
                    now: now)
                consecutive429 = min(consecutive429 + 1, 8)
                throttledUntil = now.addingTimeInterval(
                    Self.throttleDelay(consecutive429: consecutive429, advertised: advertised))
                // Being throttled is shown by the footer's countdown, not as an error -
                // but only a 200 is evidence the login came back, so an expired session
                // keeps its message and its `!` chip through the backoff.
                if !authExpired { errorText = nil }
            default:
                errorText = "HTTP \(code)"
                clearThrottle()
            }
        } catch {
            // Same rule as the 429 branch, for the same reason: only a 200 is evidence the
            // login came back, so a network blip must not wipe the "session expired" text
            // and with it the `!` chip - the one thing on the menu bar saying the numbers
            // have stopped being true. A failed request is also no evidence the rate limit
            // window closed, so the backoff is left exactly as it was.
            if !authExpired { errorText = error.localizedDescription }
        }
    }

    /// Ends the 429 backoff, for any answer that is not a 429.
    ///
    /// Getting an HTTP status at all - 401, 500, anything - proves the endpoint is no longer
    /// refusing us, so the doubling has to start over. Left as it was, a 401 arriving after
    /// a couple of 429s kept the app on an 8 minute cadence for as long as the counter said
    /// so, long after the window it was counting had closed. A network error is *not* such
    /// evidence and deliberately does not come through here.
    private func clearThrottle() {
        throttledUntil = nil
        consecutive429 = 0
    }

    // MARK: - Menu bar title

    /// The chips shown next to the mark, in order. `StatusIcon` turns these into the
    /// status item image.
    func statusSegments() -> [StatusIcon.Segment] {
        Self.segments(usage: usage, titleMode: titleMode, errorText: errorText,
                      agentCount: agents.count,
                      activeAgentCount: agents.count(where: \.isActive),
                      showAgents: showAgents)
    }

    /// The chip list, as a function of the six things that decide it and nothing else.
    /// `nonisolated` and taking counts rather than the agents themselves so the rules
    /// above can be tested without a model, a fetch or the main actor.
    ///
    /// `activeAgentCount` deliberately has **no default**. It used to default to `0`, which
    /// is not a neutral value here: it is the one that makes the chip read "0/7", so a
    /// caller that simply forgot the argument would report every session idle rather than
    /// fail to compile.
    nonisolated static func segments(usage: UsageResponse?,
                                     titleMode: TitleMode,
                                     errorText: String?,
                                     agentCount: Int,
                                     activeAgentCount: Int,
                                     showAgents: Bool) -> [StatusIcon.Segment] {
        var out: [StatusIcon.Segment] = []

        // Takes the whole `Gauge`, never a bare percentage: the severity has to come from
        // the same value the panel's bar reads, or an escalation the API sent at a low
        // percentage is dropped and the chip stays green next to a red bar.
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
        } else if errorText == nil, titleMode != .iconOnly {
            // Nothing fetched yet: one chip carries the state until the first response
            // lands. Not in "Icon only", where the whole point is that no chip appears -
            // and unlike the `!` below this one is not a warning, so there is nothing lost
            // by honoring the setting.
            out.append(StatusIcon.Segment(text: "…", severity: .normal))
        }

        // An error has to show even when cached numbers are on screen. Without this the
        // menu bar keeps displaying yesterday's percentages after the token expires and
        // the only hint that they are stale is inside the panel.
        if errorText != nil {
            out.append(StatusIcon.Segment(text: "!", severity: .critical))
        }

        if showAgents, agentCount > 0 {
            out.append(StatusIcon.Segment(text: agentsChipText(total: agentCount,
                                                              active: activeAgentCount),
                                          severity: .normal,
                                          symbol: "figure.run"))
        }
        return out
    }

    /// "3/7" when some sessions are working and others are only open, "7" when the
    /// distinction would say nothing.
    ///
    /// A bare number for "all of them are busy" and for a single session, because "7/7"
    /// and "1/1" spend menu bar width to tell you nothing. Everything else earns the
    /// fraction: a machine with seven sessions open and one actually running is the case
    /// this whole feature exists for.
    nonisolated static func agentsChipText(total: Int, active: Int) -> String {
        guard total > 1, active < total else { return "\(total)" }
        return "\(active)/\(total)"
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

    /// Pulls `claudeAiOauth.accessToken` out of the credentials blob. Internal rather than
    /// private so the tests can cover the shapes that must yield nothing: the token is the
    /// one secret this app touches, and an empty or malformed one has to read as "no
    /// credentials" rather than as a `Bearer ` header with nothing behind it.
    static func parse(_ data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { return nil }
        return token
    }
}
