import SwiftUI
import AppKit
import Combine

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        // Menu bar only: no windows, no dock icon (LSUIElement in Info.plist).
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = UsageModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObserver: NSKeyValueObservation?
    /// Installed only while the popover is up: see `showPopover` for why dismissal is
    /// handled here instead of by `.transient`.
    private var dismissMonitors: [Any] = []
    /// Same lifetime, taken down through `NotificationCenter` rather than `NSEvent`.
    private var dismissObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    /// How many NSMenus are tracking right now; see the observers in `applicationDidFinishLaunching`.
    private var menuDepth = 0
    /// What the status item currently shows, so an unchanged update is a no-op.
    private var drawnSegments: [StatusIcon.Segment]?
    private var drawnAppearance: NSAppearance.Name?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.action = #selector(togglePopover)
            button.target = self
            // Colored chips are baked into the image, so redraw when the menu bar
            // switches between light and dark.
            appearanceObserver = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateTitle() }
            }
        }

        popover = NSPopover()
        // Not `.transient`: an NSMenu is its own window, so the moment the gear menu
        // opened the popover counted it as a click outside, closed, and took the menu
        // down with it - the settings were unreachable. With `.applicationDefined`
        // nothing dismisses the popover but us, and `showPopover` installs the monitors
        // that put the outside-click and Esc behaviour back.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        // The panel itself is built on first use and released on close: see `panelView`.

        // Redraw the status title whenever the data changes. `objectWillChange` fires
        // before the value lands, so delivery on the next run loop pass is what makes
        // `updateTitle` read the new state. `DispatchQueue.main` rather than
        // `RunLoop.main`: the latter only drains in `.default` mode, which is suspended
        // while a menu is tracking, so the status item would stall with the gear menu up.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)

        // Second line of defence for the gear menu. The clock lives on its own object, so
        // a tick cannot reach `UsageView.body` at all, but the agent scan and the poll do
        // publish through the model, and either one landing while the menu is tracking
        // rebuilds its items under the pointer. Both park while this is set.
        //
        // A depth counter rather than a flag: every NSMenu posts its own begin/end pair,
        // and a `Picker` inside a `Menu` is rendered as a submenu. Hovering out of it
        // would clear a boolean while the parent menu is still up, which is exactly the
        // moment the rebuild has to stay parked.
        for (name, delta) in [(NSMenu.didBeginTrackingNotification, 1),
                              (NSMenu.didEndTrackingNotification, -1)] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuDepth = max(0, self.menuDepth + delta)
                    self.model.menuTracking = self.menuDepth > 0
                }
            }
            menuObservers.append(token)
        }

        model.start()
        updateTitle()
    }

    deinit {
        menuObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let segments = model.statusSegments()
        let appearance = button.effectiveAppearance
        // The model publishes an agent scan every few seconds and a clock every second
        // while the panel is open; without this the whole image would be measured and
        // rendered again each time for an identical result.
        guard segments != drawnSegments || appearance.name != drawnAppearance else { return }
        drawnSegments = segments
        drawnAppearance = appearance.name
        // Everything (mark + chips) is one image, so the button carries no title.
        button.image = StatusIcon.statusImage(segments: segments, appearance: appearance)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    /// Builds the SwiftUI panel, which exists only while it is on screen.
    ///
    /// **Do not hoist this into a stored property.** A hosting controller is not an idle
    /// object: its view graph stays subscribed to the model, so every agent scan publishes
    /// into a view nobody can see and SwiftUI answers with a layout pass (visible in a
    /// `sample` of the app with the popover closed). It also holds a window's worth of
    /// backing store - IOSurface, CoreAnimation and IOAccelerator came to ~7 MB together -
    /// for a panel that is shut ~99% of the time.
    ///
    /// Rebuilding it per open is safe because the panel keeps no state of its own: every
    /// value it draws lives in `UsageModel`, which outlives it.
    private func panelView() -> NSViewController {
        NSHostingController(rootView: UsageView(model: model))
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        Task { await model.refresh() }   // no-ops if the numbers are still fresh
        model.panelVisible = true
        if popover.contentViewController == nil { popover.contentViewController = panelView() }
        // Accessory apps must activate, otherwise the popover cannot take key focus.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)

        // Dismissal, hand-rolled because the popover is `.applicationDefined`.
        //
        // A *global* mouse monitor only sees events delivered to other applications, and
        // that is exactly the distinction `.transient` gets wrong: the gear menu is our
        // own window, so clicking through it never reaches this, while a click in any
        // other app does and closes the panel. Mouse monitors need no accessibility
        // permission (keyboard ones would), so Esc is a *local* monitor instead.
        let outside = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            self?.popover.performClose(nil)
            return nil
        }
        dismissMonitors = [outside, escape].compactMap { $0 }

        // A mouse monitor cannot see Cmd+Tab, which would otherwise leave the panel
        // floating over whatever came forward. An NSMenu does not deactivate the app, so
        // the gear menu is safe from this; opening the usage page in a browser does
        // deactivate, and closing the panel then is the wanted behaviour anyway.
        dismissObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }
}

extension AppDelegate: NSPopoverDelegate {
    /// The single place the panel is known to be gone, whichever route closed it: it stops
    /// the 1 Hz clock that drives the countdowns and takes the event monitors back down.
    func popoverDidClose(_ notification: Notification) {
        model.panelVisible = false
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors = []
        if let dismissObserver {
            NotificationCenter.default.removeObserver(dismissObserver)
            self.dismissObserver = nil
        }
        // Let the popover finish tearing its window down before the content goes: this is
        // called from inside that teardown, and releasing the view controller under it is
        // asking for trouble. Next run loop pass is soon enough - `showPopover` rebuilds
        // it, so the only thing that could race is a reopen, which cannot happen before
        // this block runs.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.popover.contentViewController = nil
        }
    }
}
