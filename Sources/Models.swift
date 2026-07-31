import Foundation
import SwiftUI

// MARK: - API response (GET https://api.anthropic.com/api/oauth/usage)
//
// **Nothing here trusts the endpoint's shape.** It is undocumented and internal, so a field
// that changes type, an entry that loses its `percent`, or `limits` arriving as an object
// rather than an array all have to cost exactly what they touch and nothing more.
// `Decodable`'s default behaviour is the opposite: one unreadable leaf throws all the way
// to the top and the entire response is lost, including the half that parsed perfectly and
// including the `five_hour`/`seven_day` fallback that exists for precisely this situation.
//
// So every container is decoded field by field through `lenient`, and `limits` element by
// element through `Lenient`. A rename inside `extra_usage` costs the credits row; a broken
// limit entry costs its own bar; neither costs the panel.

/// `decodeIfPresent` that answers `nil` for a value of the wrong shape instead of throwing.
/// Absent, null and unreadable are the same thing to this app: draw what arrived, leave out
/// what did not.
private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// One element of an array, decoded on its own so a bad neighbour cannot take it down.
///
/// The unkeyed container advances past the element whether or not `T` could read it, which
/// is what makes this work where a plain `[T]` decode does not: there, the first failure
/// aborts the whole array.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct UsageResponse: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let extra_usage: ExtraUsage?
    let limits: [LimitEntry]?

    private enum CodingKeys: String, CodingKey {
        case five_hour, seven_day, extra_usage, limits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        five_hour = c.lenient(UsageWindow.self, .five_hour)
        seven_day = c.lenient(UsageWindow.self, .seven_day)
        extra_usage = c.lenient(ExtraUsage.self, .extra_usage)
        limits = c.lenient([Lenient<LimitEntry>].self, .limits)?.compactMap(\.value)
    }
}

struct UsageWindow: Decodable {
    let utilization: Double?
    let resets_at: String?

    private enum CodingKeys: String, CodingKey { case utilization, resets_at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = c.lenient(Double.self, .utilization)
        resets_at = c.lenient(String.self, .resets_at)
    }
}

struct LimitEntry: Decodable {
    /// Missing or unreadable, and there is nothing to draw: this is the one field whose
    /// absence drops the entry (through `Lenient`) rather than being tolerated.
    let percent: Double
    /// Defaulted rather than required. A renamed `kind` costs the row its title and its
    /// place in the order, but the percentage is what the bar is for, so it still shows.
    let kind: String
    let group: String?
    let severity: String?
    let resets_at: String?
    let scope: LimitScope?
    let is_active: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, resets_at, scope, is_active
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        percent = try c.decode(Double.self, forKey: .percent)
        kind = c.lenient(String.self, .kind) ?? ""
        group = c.lenient(String.self, .group)
        severity = c.lenient(String.self, .severity)
        resets_at = c.lenient(String.self, .resets_at)
        scope = c.lenient(LimitScope.self, .scope)
        is_active = c.lenient(Bool.self, .is_active)
    }
}

struct LimitScope: Decodable {
    let model: ModelRef?

    private enum CodingKeys: String, CodingKey { case model }

    init(from decoder: Decoder) throws {
        model = (try decoder.container(keyedBy: CodingKeys.self)).lenient(ModelRef.self, .model)
    }

    struct ModelRef: Decodable {
        let id: String?
        let display_name: String?

        private enum CodingKeys: String, CodingKey { case id, display_name }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lenient(String.self, .id)
            display_name = c.lenient(String.self, .display_name)
        }
    }
}

struct ExtraUsage: Decodable {
    let is_enabled: Bool?
    let monthly_limit: Double?     // in minor units (see decimal_places)
    let used_credits: Double?      // in minor units
    let utilization: Double?
    let currency: String?
    let decimal_places: Int?
    let spend_limit_reached: Bool?

    private enum CodingKeys: String, CodingKey {
        case is_enabled, monthly_limit, used_credits, utilization, currency,
             decimal_places, spend_limit_reached
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        is_enabled = c.lenient(Bool.self, .is_enabled)
        monthly_limit = c.lenient(Double.self, .monthly_limit)
        used_credits = c.lenient(Double.self, .used_credits)
        utilization = c.lenient(Double.self, .utilization)
        currency = c.lenient(String.self, .currency)
        decimal_places = c.lenient(Int.self, .decimal_places)
        spend_limit_reached = c.lenient(Bool.self, .spend_limit_reached)
    }
}

// MARK: - View model rows

/// One value for the menu bar: a percentage plus the severity that belongs to it.
///
/// The two travel together on purpose. Anything that takes a bare percentage has to
/// re-derive the severity from it, which silently drops whatever `severity` the API sent
/// and leaves a chip green while the matching bar in the panel is red.
struct Gauge {
    /// Clamped on the way in, like `UsageRow.percent` and for the same reason: see
    /// `Fmt.clampPercent`.
    let percent: Double
    let severity: Severity

    init(percent: Double, severity: Severity) {
        self.percent = Fmt.clampPercent(percent)
        self.severity = severity
    }

    init(_ limit: LimitEntry) {
        self.init(percent: limit.percent,
                  severity: .from(apiValue: limit.severity, percent: limit.percent))
    }

    /// Fallback shape (`five_hour` / `seven_day`), which carries no severity of its own.
    init(utilization: Double) {
        self.init(percent: utilization, severity: .from(apiValue: nil, percent: utilization))
    }
}

/// One usage bar shown in the popover.
struct UsageRow: Identifiable {
    let id: String
    let title: String
    /// Clamped by the initializer rather than by every reader. The bar divides by it, the
    /// chip converts it to an `Int` and the severity compares it, and a value straight off
    /// the wire can be a number none of those three survive: see `Fmt.clampPercent`.
    let percent: Double
    let resetsAt: Date?
    let severity: Severity
    /// Extra text on the right of the title (e.g. "$64.20 / $100.00").
    let detail: String?

    init(id: String, title: String, percent: Double, resetsAt: Date?,
         severity: Severity, detail: String?) {
        self.id = id
        self.title = title
        self.percent = Fmt.clampPercent(percent)
        self.resetsAt = resetsAt
        self.severity = severity
        self.detail = detail
    }
}

enum Severity: String {
    case normal, warning, critical

    /// The worst of what the API says and what the local thresholds say.
    ///
    /// Both are kept on purpose: the API can escalate a limit before it looks tight
    /// (and that escalation is never downgraded), while a response that says nothing,
    /// or says `normal` for a bar sitting at 95%, still turns orange at 75% and red at
    /// 90% instead of staying green.
    static func from(apiValue: String?, percent: Double) -> Severity {
        let threshold: Severity = percent >= 90 ? .critical : (percent >= 75 ? .warning : .normal)
        let api: Severity
        switch apiValue?.lowercased() {
        case "warning", "warn": api = .warning
        case "critical", "exceeded", "error": api = .critical
        default: api = .normal
        }
        return api.rank > threshold.rank ? api : threshold
    }

    var color: Color {
        switch self {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }

    /// Order for "which limit is worst", used to color the menu bar capsule.
    /// Also decides which of the API's severity and the local threshold wins.
    var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    var nsColor: NSColor {
        switch self {
        case .normal: return .controlTextColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

// MARK: - Formatting helpers

enum Fmt {
    /// The two ISO formatters are shared instances of a non-`Sendable` class, so they are
    /// guarded exactly like `currencyFormatter` below. They had no lock originally, on the
    /// reasoning that `Fmt.date` is only ever reached from the panel's body: that is true
    /// today and is not a property of this code, since nothing stops a `nonisolated static`
    /// (`UsageModel.segments` is one) from calling it off the main actor tomorrow.
    private static let isoLock = NSLock()

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        isoLock.lock()
        defer { isoLock.unlock() }
        return iso.date(from: s) ?? isoNoFrac.date(from: s)
    }

    /// "8h 44m", "12m", "now".
    static func countdown(to date: Date?, from now: Date) -> String {
        guard let date else { return "" }
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        let d = secs / 86_400, h = (secs % 86_400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    /// "42%", from a number that is never assumed to be sane.
    ///
    /// **`Int(_: Double)` traps** - on NaN, and on anything outside `Int`'s range - and this
    /// value arrives from an undocumented endpoint whose fields can change without notice.
    /// A `percent` of `1e30` is valid JSON, decodes into a perfectly ordinary `Double`, and
    /// then kills the app on the next menu bar redraw: the one crash a user is guaranteed
    /// to see and has no way to explain. Clamping is the whole fix.
    static func percent(_ p: Double) -> String {
        "\(Int(clampPercent(p).rounded()))%"
    }

    /// The widest percentage worth drawing. Past this it is a broken number rather than a
    /// large one, and the bar has been pinned at full width for 99 screens already.
    private static let percentCeiling: Double = 9999

    /// A percentage safe to draw, compare, convert and divide by.
    ///
    /// Applied where percentages *enter* the app (`Gauge`, `UsageRow`) rather than where
    /// they are printed, so the bar width, the severity comparison and the chip all get the
    /// same sanitized value. NaN is caught before the comparisons rather than by them: it
    /// has no ordering, so `min`/`max` would carry it straight through.
    static func clampPercent(_ p: Double) -> Double {
        guard !p.isNaN else { return 0 }
        return min(max(p, 0), percentCeiling)
    }

    /// A process's memory as "137 MB" or "1.9 GB".
    ///
    /// **Whole megabytes under a gigabyte, on purpose.** A Claude Code session moves a few
    /// hundred kilobytes constantly, so a decimal place there is a digit that twitches
    /// once a second and says nothing - the same reason `humanElapsed` refuses to print
    /// seconds. Past a gigabyte one decimal is back, because "1 GB" and "1.9 GB" are a
    /// meaningfully different amount of trouble.
    ///
    /// Binary units, which is what `ri_phys_footprint` is measured in and what the system
    /// `footprint` tool prints for the same process. The rounding happens before the unit
    /// is chosen, so 1023.7 MB reads "1.0 GB" rather than "1024 MB".
    ///
    /// `locale` for the same reason `money` takes one: the decimal separator is a comma in
    /// half the world, and a test asserting "1.9 GB" against the machine's own locale
    /// passes here and fails there.
    static func memory(_ bytes: UInt64, locale: Locale = .current) -> String {
        let mb = (bytes + 524_288) / 1_048_576          // rounded, not truncated
        if mb < 1024 { return "\(mb) MB" }
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.1f GB", locale: locale, gb)
    }

    /// Converts minor units + decimal_places into "$64.20".
    ///
    /// `locale` is a parameter rather than always `.current` so the tests can pin an
    /// expected string: the panel should absolutely render "US$ 64,20" for a reader in
    /// Argentina, but a test asserting that against the machine's own locale passes on
    /// one Mac and fails on the next.
    static func money(_ minor: Double?, decimals: Int?, currency: String?,
                      locale: Locale = .current) -> String? {
        guard let minor else { return nil }
        let places = decimals ?? 2
        let value = minor / pow(10, Double(places))
        let nf = currencyFormatter(currency: currency ?? "USD", places: places, locale: locale)
        return nf.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// `NumberFormatter` is expensive to build and this runs on every evaluation of the
    /// panel's body, twice for the credits row alone. The instances are only ever read
    /// after they are configured, which is the condition under which Foundation
    /// documents them as safe to share.
    private static let moneyLock = NSLock()
    nonisolated(unsafe) private static var moneyFormatters: [String: NumberFormatter] = [:]

    private static func currencyFormatter(currency: String, places: Int,
                                          locale: Locale) -> NumberFormatter {
        let key = "\(locale.identifier)|\(currency)|\(places)"
        moneyLock.lock()
        defer { moneyLock.unlock() }
        if let cached = moneyFormatters[key] { return cached }
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.locale = locale
        nf.currencyCode = currency
        nf.maximumFractionDigits = places
        moneyFormatters[key] = nf
        return nf
    }
}

// MARK: - Derived rows

extension LimitEntry {
    /// Display order: session first, then the all-models week, then scoped weeks.
    var rank: Int {
        switch kind {
        case "session": return 0
        case "weekly_all": return 1
        default: return 2
        }
    }

    /// Row identity that survives a reordered response. Index-based ids would make
    /// SwiftUI rebind rows onto different limits whenever the API shuffles two entries
    /// of the same rank.
    ///
    /// `group` is deliberately not part of this: every weekly entry shares `group:
    /// "weekly"`, so folding it in would lengthen the id without telling two scoped
    /// weeklies apart. What actually disambiguates them is the model, and the offset
    /// suffix in `rows` is the backstop when even that is missing.
    var rowID: String {
        let scopeKey = scope?.model?.id ?? scope?.model?.display_name ?? ""
        return scopeKey.isEmpty ? kind : "\(kind)-\(scopeKey)"
    }
}

extension UsageResponse {
    /// Limit bars in display order: session first, then weekly windows.
    var rows: [UsageRow] {
        if let limits, !limits.isEmpty {
            // Every entry is shown. `is_active` is NOT a filter: measured against a live
            // account it comes back `false` on limits that plainly exist (a session at
            // 45% with a reset time in the future, and the weekly Fable limit at 65%)
            // and `true` on exactly one entry, the highest of the three. It reads as
            // "this is the limit currently binding", not "the account has this limit", so
            // filtering on it collapses the whole panel down to a single bar. Limits the
            // account does not have are simply absent from the array.
            //
            // Sorting the offsets alongside keeps equal ranks in the order the API sent
            // them: `sorted(by:)` is not stable, so without it two scoped weeklies could
            // swap places between polls.
            let ordered = limits.enumerated().sorted {
                ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset)
            }
            var seen = Set<String>()
            return ordered.map { offset, l in
                var id = l.rowID
                if !seen.insert(id).inserted {
                    // The suffix has to be claimed too, or a third entry could collide
                    // with the id this one just invented.
                    id = "\(id)-\(offset)"
                    seen.insert(id)
                }
                return UsageRow(
                    id: id,
                    title: Self.title(for: l),
                    percent: l.percent,
                    resetsAt: Fmt.date(l.resets_at),
                    severity: .from(apiValue: l.severity, percent: l.percent),
                    detail: nil
                )
            }
        }
        // Fallback when `limits` is absent.
        var out: [UsageRow] = []
        if let f = five_hour, let u = f.utilization {
            out.append(UsageRow(id: "five_hour", title: "Current session",
                                percent: u, resetsAt: Fmt.date(f.resets_at),
                                severity: .from(apiValue: nil, percent: u), detail: nil))
        }
        if let s = seven_day, let u = s.utilization {
            out.append(UsageRow(id: "seven_day", title: "Weekly (all models)",
                                percent: u, resetsAt: Fmt.date(s.resets_at),
                                severity: .from(apiValue: nil, percent: u), detail: nil))
        }
        return out
    }

    /// Monthly extra-usage credits row, when the account has it enabled.
    ///
    /// A function rather than a property because it is the one derived row that formats
    /// money, and the locale has to be reachable so the tests can pin an expected string
    /// (see `Fmt.money`). Everything in the app calls it with the default.
    func creditsRow(locale: Locale = .current) -> UsageRow? {
        guard let e = extra_usage, e.is_enabled == true, let used = e.used_credits else { return nil }
        let pct = e.utilization ?? (e.monthly_limit.map { $0 > 0 ? used / $0 * 100 : 0 } ?? 0)
        let usedStr = Fmt.money(used, decimals: e.decimal_places, currency: e.currency,
                                locale: locale) ?? ""
        let limitStr = Fmt.money(e.monthly_limit, decimals: e.decimal_places,
                                 currency: e.currency, locale: locale)
        return UsageRow(
            id: "extra_usage",
            title: "Extra usage (monthly)",
            percent: pct,
            resetsAt: nil,
            severity: .from(apiValue: e.spend_limit_reached == true ? "critical" : nil, percent: pct),
            detail: limitStr.map { "\(usedStr) / \($0)" } ?? usedStr
        )
    }

    /// The three values the menu bar can show. Each carries its own severity so a chip
    /// colors exactly like the bar it mirrors in the panel. Same reasoning as `rows`:
    /// `is_active` is not consulted, it would hide the session chip outright.
    var session: Gauge? {
        if let limit = (limits ?? []).first(where: { $0.kind == "session" }) { return Gauge(limit) }
        if let u = five_hour?.utilization { return Gauge(utilization: u) }
        return nil
    }

    var weekly: Gauge? {
        let all = limits ?? []
        if let limit = all.first(where: { $0.kind == "weekly_all" })
            ?? all.first(where: { $0.group == "weekly" }) { return Gauge(limit) }
        if let u = seven_day?.utilization { return Gauge(utilization: u) }
        return nil
    }

    var credits: Gauge? {
        creditsRow().map { Gauge(percent: $0.percent, severity: $0.severity) }
    }

    private static func title(for l: LimitEntry) -> String {
        if let model = l.scope?.model?.display_name, !model.isEmpty {
            // Name the window, not just the model: a session-scoped entry would otherwise
            // be labelled as a weekly one.
            return l.kind == "session" ? "Session (\(model))" : "Weekly (\(model))"
        }
        switch l.kind {
        case "session": return "Current session"
        case "weekly_all": return "Weekly (all models)"
        case "weekly_scoped": return "Weekly (scoped)"
        default:
            // `kind` defaults to "" when the endpoint stops sending it, and an untitled
            // bar reads as a rendering bug rather than as a limit nobody named.
            let spelled = l.kind.replacingOccurrences(of: "_", with: " ").capitalized
            return spelled.isEmpty ? "Limit" : spelled
        }
    }
}
