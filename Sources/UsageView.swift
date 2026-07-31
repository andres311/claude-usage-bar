import SwiftUI
import ServiceManagement

struct UsageView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let usage = model.usage {
                VStack(spacing: 10) {
                    ForEach(usage.rows) { row in
                        BarRow(row: row, clock: model.clock)
                    }
                }
                if let credits = usage.creditsRow() {
                    Divider()
                    BarRow(row: credits, clock: model.clock)
                }
            } else if model.errorText == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading usage…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }

            Divider()
            agentsSection

            if let error = model.errorText {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Claude Code usage").font(.headline)
            Spacer()
            RefreshButton(clock: model.clock,
                          isLoading: model.isLoading,
                          readyAt: model.nextFetchAllowedAt) {
                Task { await model.refresh() }
            }
        }
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Active agents", systemImage: "figure.run")
                    .font(.subheadline)
                    .labelStyle(.titleAndIcon)
                Spacer()
                Text("\(model.agents.count)")
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(model.agents.isEmpty ? .secondary : .primary)
            }
            if model.agents.isEmpty {
                Text("No Claude Code sessions running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Sorted by folder, then longest-running first: see AgentsMonitor.precedes.
                ForEach(model.agents) { agent in
                    HStack(spacing: 6) {
                        Text(agent.folder.isEmpty ? "unknown folder" : agent.folder)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(agent.host)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        // verbatim: a pid is an identifier, never a formatted number.
                        Text(verbatim: "#\(agent.id)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(agent.uptime)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            UpdatedLabel(clock: model.clock,
                         lastUpdated: model.lastUpdated,
                         throttledUntil: model.throttledUntil)
            Spacer()
            Button("Usage page") {
                NSWorkspace.shared.open(UsageModel.usagePageURL)
            }
            .buttonStyle(.link)
            .font(.caption)

            Menu {
                Picker("Refresh every", selection: $model.refreshInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                }
                Picker("Menu bar shows", selection: $model.titleMode) {
                    ForEach(UsageModel.TitleMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("Show agent count", isOn: $model.showAgents)
                if LoginItem.isInstalled {
                    Toggle("Launch at login", isOn: Binding(
                        get: { LoginItem.isEnabled },
                        set: { LoginItem.set($0) }
                    ))
                } else {
                    // Spelled out rather than a bare disabled toggle: a menu item cannot
                    // show a tooltip, so the reason has to be in the label.
                    Text("Launch at login (install to ~/Applications first)")
                }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
    }

}

/// The panel's refresh button.
///
/// It observes the clock, like `BarRow` and `UpdatedLabel` and for the same structural
/// reason: the floor it is disabled under expires with time rather than with a change to
/// the model, and a tick must not reach `UsageView.body` (see the gear menu note in
/// `UsageModel`). Disabling it is the point. `refresh()` enforces the same 25s floor the
/// poll loop does, so without this the click would simply be dropped with no explanation.
private struct RefreshButton: View {
    @ObservedObject var clock: Clock
    let isLoading: Bool
    let readyAt: Date?
    let action: () -> Void

    private var waiting: Bool { (readyAt?.timeIntervalSince(clock.now) ?? 0) > 0 }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isLoading || waiting)
        .help(helpText)
    }

    private var helpText: String {
        guard waiting, let readyAt else { return "Refresh now" }
        let secs = Int(readyAt.timeIntervalSince(clock.now).rounded(.up))
        // Under a minute this is the ordinary floor between requests; anything longer is
        // the 429 backoff, which `Fmt.countdown` already words the way the footer does.
        return secs < 60
            ? "Just refreshed, wait \(secs)s"
            : "Rate limited, retry in \(Fmt.countdown(to: readyAt, from: clock.now))"
    }
}

/// The footer's freshness line, and the one place the backoff is visible.
///
/// It observes the clock rather than the model so a tick redraws this label alone. Being
/// rate limited is shown in the same orange as a warning bar: the numbers above it are
/// still the last good ones, but they have stopped updating, and in plain grey that reads
/// as a normal "updated a while ago".
private struct UpdatedLabel: View {
    @ObservedObject var clock: Clock
    let lastUpdated: Date?
    let throttledUntil: Date?

    var body: some View {
        if let until = throttledUntil, until > clock.now {
            Text("Rate limited, retry in \(Fmt.countdown(to: until, from: clock.now))")
                .font(.caption)
                .foregroundStyle(Severity.warning.color)
        } else {
            Text(updatedText)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var updatedText: String {
        guard let last = lastUpdated else { return "Never updated" }
        let secs = Int(clock.now.timeIntervalSince(last))
        if secs < 5 { return "Updated just now" }
        if secs < 60 { return "Updated \(secs)s ago" }
        return "Updated \(secs / 60)m ago"
    }
}

/// A labelled progress bar with percentage and reset countdown.
private struct BarRow: View {
    let row: UsageRow
    @ObservedObject var clock: Clock

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).font(.subheadline)
                Spacer()
                Text(Fmt.percent(row.percent))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(row.severity.color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(row.severity.color)
                        .frame(width: max(2, geo.size.width * min(row.percent, 100) / 100))
                }
            }
            .frame(height: 6)

            if let detail = row.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            } else if let reset = row.resetsAt {
                Text("Resets in \(Fmt.countdown(to: reset, from: clock.now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Login item

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `SMAppService` remembers the bundle path it was registered from, so enabling this
    /// while the app is running out of `build/` leaves a login item pointing at a
    /// directory `make clean` deletes. Only offer it from a real install location.
    static var isInstalled: Bool {
        let path = Bundle.main.bundlePath
        let applications = (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        return ["/Applications", applications].contains { path.hasPrefix($0 + "/") }
    }

    static func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Login item toggle failed: \(error.localizedDescription)")
        }
    }
}
