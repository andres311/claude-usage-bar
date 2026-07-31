import Foundation
import SwiftUI

// MARK: - API response (GET https://api.anthropic.com/api/oauth/usage)

struct UsageResponse: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let extra_usage: ExtraUsage?
    let limits: [LimitEntry]?
}

struct UsageWindow: Decodable {
    let utilization: Double?
    let resets_at: String?
}

struct LimitEntry: Decodable {
    let kind: String
    let group: String?
    let percent: Double
    let severity: String?
    let resets_at: String?
    let scope: LimitScope?
    let is_active: Bool?
}

struct LimitScope: Decodable {
    let model: ModelRef?
    struct ModelRef: Decodable {
        let id: String?
        let display_name: String?
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
}

// MARK: - View model rows

/// One value for the menu bar: a percentage plus the severity that belongs to it.
///
/// The severity travels with the number on purpose. The chips used to re-derive it from
/// the percentage alone, which silently dropped whatever `severity` the API had sent and
/// left a chip green while the matching bar in the panel was already red.
struct Gauge {
    let percent: Double
    let severity: Severity

    init(percent: Double, severity: Severity) {
        self.percent = percent
        self.severity = severity
    }

    init(_ limit: LimitEntry) {
        percent = limit.percent
        severity = .from(apiValue: limit.severity, percent: limit.percent)
    }

    /// Fallback shape (`five_hour` / `seven_day`), which carries no severity of its own.
    init(utilization: Double) {
        percent = utilization
        severity = .from(apiValue: nil, percent: utilization)
    }
}

/// One usage bar shown in the popover.
struct UsageRow: Identifiable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: Date?
    let severity: Severity
    /// Extra text on the right of the title (e.g. "$64.20 / $100.00").
    let detail: String?
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
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
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

    static func percent(_ p: Double) -> String {
        "\(Int(p.rounded()))%"
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
            // "this is the limit currently binding", not "the account has this limit" -
            // filtering on it collapsed the whole panel down to a single bar.
            // Limits the account does not have are simply absent from the array.
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
            return l.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
