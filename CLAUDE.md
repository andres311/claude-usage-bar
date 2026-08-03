# CLAUDE.md - claude-usage-bar

macOS menu bar app (Swift + AppKit + SwiftUI, no dependencies, no Xcode project) showing
Claude Code usage and the number of Claude Code agents running locally. See README.md for
the user-facing description.

## Build

`./build.sh` compiles `Sources/*.swift` with `swiftc` once per arch (arm64 + x86_64),
`lipo`s them into `build/ClaudeUsage.app` and ad-hoc signs it. `./build.sh install`
copies it to `~/Applications` and launches it. There is no Xcode project or SPM manifest
on purpose: plain `swiftc` keeps it a two-second build.

The `Makefile` is a thin wrapper over that script and adds `test`, `run`, `stop`, `zip`
(shareable archive via `ditto`), `clean` and `uninstall`. `make help` lists them.
`build.sh` stays the source of truth; do not move compile logic into the Makefile.

The default goal is `help`, not `build`: a bare `make` prints the target list instead of
compiling. `make build` is the explicit way to compile. `help` builds that list by
`grep`ping its own `## target: description` comments, so a new target is documented by
writing one above it; the command half is printed cyan and the description plain, and the
codes are dropped entirely when stdout is not a terminal. The `[ -t 1 ]` test has to run
in the recipe's own shell: inside a `$(...)` (or a make `$(shell ...)`) it tests the
substitution's pipe, which is never a tty, so the color silently never appears.

`build` depends on `build/ClaudeUsage.app` and keeps a one-line `echo` recipe of its own:
a phony target with a prerequisite and *no* recipe makes make answer an already-built app
with "Nothing to be done for `build'", which reads like the Makefile is broken rather than
like nothing changed. The `.app` **directory** works as the timestamp only because
`build.sh` starts with `rm -rf "$APP"`; if it ever wrote in place, the directory mtime
would not move (writes land in `Contents/`) and every `make` would rebuild. `Resources/*.png`
is a prerequisite too, otherwise swapping the menu bar mark never triggers a rebuild.

`make test` is the one exception: it compiles **every source but `App.swift`** with
`Tests/main.swift` into a command line binary and runs it (307 checks, about a second).
`App.swift` is left out because its `@main` cannot coexist with top-level code, and what
it holds is `NSStatusItem`/`NSPopover` wiring that means nothing without a running app.
There is no XCTest: the harness is twenty lines at the top of `Tests/main.swift`, and because
it is top-level code the file has to be called `main.swift` and cannot be compiled with
`-parse-as-library`.

What is covered: the process-table rules (`isAgent`, `hostName`, `precedes`,
`sameOnScreen`, `humanElapsed`), the activity classifier (`classify`, including what a
window it cannot trust may and may not conclude), severity, `Fmt`, the derived rows and
gauges, **how the decoder degrades** when the response changes shape, the menu bar chips
(`UsageModel.segments`), the whole 429 policy (`retryAfterSeconds`, `throttleDelay`,
`pollDelay`, `fetchAllowedAt`), the auth policy (`tokenAction`, `authMessage`, the token
fingerprint), `StatusIcon.statusImage`'s template rule and accessibility description,
`Credentials.parse` with its expiry field and `LoginItem.isInstalled`.

**The dividing line is the main actor and the outside world.** Everything above is
reachable as a plain function taking its inputs; what is left untested needs a live
socket, the real process table or an `NSStatusItem`. That shape is deliberate: the pure
half of `UsageModel` lives in `nonisolated static` functions and the instance members
delegate to them, so a test never builds a model, touches `UserDefaults` or hops onto the
main actor. Keep new logic on that side of the line: `Credentials.parse` and
`LoginItem.isInstalled(bundlePath:home:)` are internal rather than private for exactly
that reason, and `AgentsMonitor.isAgent`/`hostName` take the executable and argv as
parameters instead of reading them from a pid. `UsageModel.tokenAction` and `authMessage`
are the newest members of that set: what to do about a refused login is decided by plain
functions over their inputs, so the whole policy runs without a keychain or a request.

Add a case whenever you touch any of it. AppKit is imported by the harness but never
started: `StatusIcon` only measures text and draws into an `NSImage`, neither of which
needs an `NSApplication`, so the run stays headless.

The app is ad-hoc signed, not notarized, so a downloaded copy needs
`xattr -dr com.apple.quarantine`. Building locally avoids it.

`@main` lives in `App.swift`, so the sources are compiled with `-parse-as-library`
(no file may be named `main.swift`).

## Screenshots

`docs/*.png` are the three images the README embeds: `menu-bar.png` (the status item on
its own), `panel.png` and `gear-menu.png`. They are 1x captures; `menu-bar.png` is
pixel-doubled with nearest-neighbor so 11pt chips stay legible and stay sharp inline.

**Anything identifying has to be painted over before a screenshot is committed**, since
the session list shows the folder every session is running in and those are real client
repos. Every row gets covered, this repo's own name included: a half-redacted column
invites the reader to work out which of the visible ones the hidden ones are near. The
names are covered with a flat rounded bar in the panel's own greys, **not blurred**: a
gaussian blur of 10px text still leaves a readable word shape at 2x and is in principle
reversible. Only the folder column is touched, so the idle dot, host, pid, uptime and
memory columns keep explaining what the list is. The README says the bars are redactions,
so nobody reads them as a state the app can be in.

## Architecture

- `App.swift` - `AppDelegate` (`@MainActor`) owns the `NSStatusItem` and an
  `NSPopover` hosting `UsageView`. AppKit is used instead of `MenuBarExtra` because the
  status title needs per-segment colors, which a SwiftUI label (rendered as a template
  image) cannot do. An accessory app must call `NSApp.activate` before showing the
  popover or it cannot take key focus.
  - The popover is **`.applicationDefined`, not `.transient`**. An `NSMenu` is its own
    window, so a transient popover treated opening the gear menu as a click outside,
    closed, and took the menu down with it: the settings were unreachable. Dismissal is
    therefore hand-rolled in `showPopover` - a **global** mouse monitor (which by
    definition only sees events delivered to *other* apps, so our own menu never trips
    it) plus a **local** keyDown monitor for Esc. Global *mouse* monitors need no
    accessibility permission; keyboard ones would, which is why Esc is local. A mouse
    monitor cannot see Cmd+Tab, though, so there is also a `didResignActiveNotification`
    observer: without it, switching apps by keyboard left the panel floating over whatever
    came forward. An `NSMenu` does **not** deactivate the app, so the gear menu is safe
    from that one. All three are torn down in `popoverDidClose`, the one place the panel is
    known to be gone (the two `NSEvent` monitors through `removeMonitor`, the observer
    through `NotificationCenter`).
  - **The panel is built on open and released on close** (`panelView()`, and the
    `contentViewController = nil` in `popoverDidClose`). A hosting controller kept around
    is not an idle object: its view graph stays subscribed to the model, so every agent
    scan published into a view nobody could see and SwiftUI answered with a layout pass,
    and it holds a window's worth of backing store (~7 MB of IOSurface + CoreAnimation)
    for something that is shut ~99% of the time. Rebuilding per open is safe because the
    panel keeps no state of its own; every value it draws lives in `UsageModel`, which
    outlives it. The release is deferred to the next run loop pass because
    `popoverDidClose` runs inside the popover's own teardown.
  - `updateTitle` compares the new `[StatusIcon.Segment]` (and the appearance name)
    against what is already on screen and returns early when they match: the model
    publishes on every agent scan and every clock tick, so without that guard the whole
    image would be measured and rendered once a second forever.
  - `objectWillChange` is delivered on `DispatchQueue.main`, not `RunLoop.main`: the
    latter only drains in `.default` mode, which is suspended while a menu is tracking,
    so the status item would stall with the gear menu open.
  - `NSMenu.didBeginTracking` / `didEndTracking` feed `model.menuTracking`, via a **depth
    counter, not a flag**: every NSMenu posts its own pair and a SwiftUI `Picker` inside a
    `Menu` renders as a submenu, so hovering out of "Refresh every" would clear a boolean
    while the parent menu is still up. See the gear menu note under `UsageModel`.
- `UsageModel.swift` - polling loop, token lookup, 429 backoff, response cache and the
  segments for the menu bar. The `minFetchGap` floor is measured against `lastAttempt`
  (in memory), never `lastUpdated`, which is restored from the on-disk cache and would
  make a relaunch skip its first fetch. `panelVisible` gates the 1 Hz clock, which only
  exists for the countdowns inside the panel, and together with `showAgents` it also
  gates the process scan: neither runs while nothing displays the result.
  - **Three loops, three unrelated cadences.** The poll (`pollTask`) is paced by an
    endpoint that rate limits; the clock (`tickTask`) by what the countdowns need; the
    agent scan (`agentTask`) by nothing at all, since it is a local `libproc` walk.
    Folding the scan into the tick loop, as it once was, is what let a 15 minute usage
    interval and a finished session end up on the same schedule in people's heads.
  - **Two of the three loops end rather than idle**, and for the same reason: a timer that
    wakes to test a boolean and go back to sleep buys nothing and keeps a laptop out of its
    deep idle states. `startClock` runs only while `panelVisible` (86 400 wakeups a day
    otherwise); `startAgentScan` only while `panelVisible || showAgents`, and it clears
    `agentTask` on the way out so `wakeAgentScan` can tell a dead loop from a running one.
    That distinction is load-bearing: `startAgentScan` scans as its first act, so a switch
    flipping on has to *either* start the loop *or* call `scanAgentsNow()`, never both -
    two scans a millisecond apart are exactly the window `classify` has to throw away.
  - **The two cadences are 10s (panel open) and 30s (chip only).** They used to be 1s and
    10s, back when the scan forked `ps` and cost ~33ms of CPU; through `libproc` the same
    work is **~3ms** on a 750-process table, so neither number is paying for anything any
    more and both were slowed down on purpose instead. A count in the menu bar being half
    a minute stale is invisible, and the panel scans the moment it opens
    (`wakeAgentScan()`), so the open cadence only governs how a session that ends *while
    you are watching* leaves the list.
  - `AgentsMonitor.scan()` returns an **optional**, and `applyScan` ignores `nil`. `nil`
    means the table could not be read, which says nothing about how many agents are
    running; treating it as an empty list blinks every live session off the panel and out
    of the menu bar and then back. `applyScan` also drops an
    unchanged result, compared with `AgentsMonitor.sameOnScreen` and **not** `==`:
    `elapsed` moves on every scan by definition, so a plain equality check would publish
    once a second while the panel is open and re-run `UsageView.body` on a timer, which is
    the one thing the separate `Clock` exists to prevent.
  - **A scan carries the instant it was taken (`applyScan(_:takenAt:)`), and an older one is
    dropped.** Two can be in flight at once - the loop's, and the off-cycle `scanAgentsNow`
    the panel fires as it opens - and nothing orders their completions. Whichever landed
    second used to become the baseline, so a stale set of CPU counters got filed under a
    fresh timestamp and the next `dt` came out shorter than the interval those counters
    actually covered: a burst of activity that never happened, and idle sessions blinking
    "working" for a grace period. Both loops now go through `scanAndApply`, which stamps the
    result where it is read, and `takenAt` is what `classify` gets as `now` as well.
  - `refresh()` takes **no `force`**. It used to, and the panel's button passed it, which
    made clicking that button repeatedly the one supported way to walk straight into the
    5-minute 429 window - and retrying inside the window is what holds it open. The floor
    now applies to everyone and `RefreshButton` disables itself until `nextFetchAllowedAt`,
    so the click is refused visibly instead of being dropped.
  - `pollDelay` shortens the poll's sleep to just past `throttledUntil`. Sleeping the
    full interval meant the panel counted "retry in 4m" down to zero and then sat there
    for the rest of a 15 minute cycle, which reads as a stuck backoff. A *spent* backoff
    falls back to `minFetchGap`, never to zero: a tight retry loop is what holds the
    window open in the first place.
  - The 429 arithmetic is four `nonisolated static` functions - `retryAfterSeconds`,
    `throttleDelay`, `pollDelay`, `fetchAllowedAt` - and the model only holds the state
    they read. That is what makes the whole policy testable without a request, and the
    `nonisolated` is load-bearing: `UsageModel` is `@MainActor`, so its static members
    would otherwise be main-actor isolated too (which is also why `minFetchGap`,
    `minThrottle` and `maxThrottle` carry the keyword). `retryAfterSeconds` builds its
    `DateFormatter` per call rather than caching one, since a cached one would be either
    isolated state reached from a non-isolated context or a mutable global; it is only
    reachable from a 429, which arrives minutes apart at most.
  - **`authRejected` holds a fingerprint of the token that got the 401, and being non-nil
    *is* the expired state** (`authExpired` is a computed read of it). The 429 branch and the
    `catch` branch both clear `errorText` only when it is nil: a rate limit or a network blip
    landing after an expired token must not wipe the "Session expired" message and with it
    the `!` chip, the only thing on the menu bar saying the numbers stopped being true.
    - It used to be a `Bool` cleared **only** by a 200, and that was issue #4. The 200 that
      would clear it *cannot arrive while a backoff is running*, so the panel kept insisting
      the session had expired for up to 8 minutes after Claude Code had already written a
      good token into the keychain. A fingerprint answers the question a boolean could not -
      "is this still the token that was refused?" - without spending a request to find out.
    - The fingerprint is 16 hex digits of SHA-256 and **never the token**: that is the one
      secret this app handles and it has no business in a property that outlives the request
      it was read for. One property rather than a flag beside it, so there are not two values
      set and cleared on the same three branches that can drift apart.
  - **`tokenAction` decides whether a token is worth a request, and withholding one takes
    two independent pieces of evidence.** `.sendAndClearAuth` when the keychain holds a
    different token (Claude Code refreshed it; the message comes down *before* the request
    rather than after a 200 that a backoff may be holding off). `.skip` only when the token
    is byte-identical to the one already refused **and** its own `expiresAt` is in the past.
    `.send` otherwise.
    - Either half alone is a way to get stuck, in opposite directions. A 401 alone can be
      transient - retrying every poll is how the app used to recover from a passing 403 by
      itself, and parking on the first one trades #4 for a worse version of itself. The
      clock alone is never consulted before the first request either: declining to ask
      because *this machine* thinks a token expired lets a skewed clock lock the app out of
      ever asking, with nothing to correct it.
    - Together they are conclusive: the server refused this exact token, it cannot start
      working on its own, and its replacement arrives through the keychain where
      `.sendAndClearAuth` sees it without a request being spent on the wait.
  - **`authMessage` distinguishes two situations wearing one status code.** The everyday one
    is not an expired session at all: the access token lasts hours, only Claude Code rewrites
    it, and a stretch of not using `claude` is enough to get a 401 on a perfectly good login.
    "Session expired" sends the user looking for a login screen that is not the problem, so
    that case reads "Waiting for Claude Code to refresh the login (token expired 12m ago)"
    and the original wording is kept for a token refused while it should still be valid. The
    `.skip` branch re-states the message every poll so the age keeps counting up instead of
    freezing at whatever it said when the 401 landed.
  - `clearThrottle()` (`throttledUntil = nil`, `consecutive429 = 0`) runs on **every branch
    that got an HTTP status other than 429** - the 200, the 401/403 and the `default` - and
    deliberately not from `catch`. Receiving any status at all is proof the endpoint has
    stopped refusing us, so the doubling has to start over; a 401 arriving after two 429s
    used to leave the counter at 2 and the next blip started at 4 minutes instead of one.
    A failed request proves nothing either way, so it leaves the backoff untouched.
    In the 200 branch it runs **before** the decode, alongside `authRejected = nil`: what
    both react to is the status line, and a `throw` from the decoder used to skip them and
    leave the app on an 8 minute backoff still showing "Session expired" while the endpoint
    was answering it perfectly well.
  - **`throttleDelay` throws away a non-finite `Retry-After` instead of clamping it**, and
    the difference matters because clamping does not work on one. `Double("nan")` parses,
    NaN has no ordering, so `min`/`max` carry it straight through - the same trap
    `Fmt.clampPercent` exists for. What came out was a NaN `throttledUntil`, a date every
    comparison in the app is false against: no countdown in the footer, the refresh button
    live, and `pollDelay` back to its 25s floor *inside* the window it was meant to be
    waiting out, which is the one behaviour known to hold that window open. A header that
    is not a number is no advice, which is what `0` already means.
  - **The gear menu is unusable if the panel redraws while it is open.** A SwiftUI `Menu`
    is an `NSMenu`; re-running `UsageView.body` rebuilds its items under the pointer, so
    the "Refresh every" submenu flickered open and shut and swallowed the click. Two
    independent guards, because one of them has to work:
    1. The clock is a separate `Clock` object held by a plain `let`, so a tick does not
       publish through `UsageModel` at all. Only `BarRow`, `UpdatedLabel` and
       `RefreshButton` observe it,
       which structurally puts `UsageView.body` out of reach of the 1 Hz tick. This is
       the deterministic one.
    2. `menuTracking` (a plain `var`, publishing it would cause the very rebuild it
       prevents) parks the agent scan and the poll while a menu is up, since those still
       publish through the model. Set from `App.swift`.
  - `statusSegments()` takes `Gauge`s, not bare `Double`s, so the API's own `severity`
    reaches the chip. It also appends a red `!` chip whenever `errorText != nil` even
    when cached numbers are on screen: otherwise an expired token leaves the menu bar
    showing yesterday's percentages with the only warning buried in the panel. The rules
    themselves are
    `static segments(usage:titleMode:errorText:agentCount:activeAgentCount:showAgents:)`
    and the instance method just feeds it the model's state, so every mode, the `!` chip
    and the agents chip are covered by tests. `activeAgentCount` has **no default value**,
    deliberately: `0` is not neutral here, it is the value that makes the chip read "0/7",
    so a caller that forgets the argument has to fail to compile rather than report every
    session idle. The agents chip reads `agentsChipText`:
    "1/7" when some sessions are working and others are only open, and a bare count when
    the fraction would say nothing ("7/7" and "1/1" spend menu bar width on a tautology). The red `!` is the one chip that ignores
    `titleMode`, "Icon only" included: a warning that the numbers stopped being true has
    to reach the menu bar whatever the display setting says. The loading `…` does not get
    that exemption, since nothing is wrong while it is up.
- `AgentsMonitor.swift` - counts processes whose executable *is* the `claude` binary, or
  whose script argument is when a known interpreter (`node`, `bun`, …) ran them, so an npm
  install (`node /…/bin/claude`) counts and `vim claude` does not. It deliberately matches
  the CLI, the IDE extension binary and SDK runs, and excludes the Claude desktop app
  (`Claude`, capital C) and this app itself.
  - **It walks the process table through `libproc`, and must not go back to a
    subprocess.** It used to shell out to `ps -Ao` and one `lsof` per pid, and that was
    the app's entire CPU cost: forking `ps` makes the kernel format every process on the
    machine into text so ~99% of it can be thrown away (~33 ms on a 750-process table),
    plus ~13 ms of `lsof` per working directory. `proc_listallpids` + `proc_pidpath` +
    `KERN_PROCARGS2` + `proc_pidinfo` answer the same questions in **~3 ms** with no fork,
    no exec and no pipes. Three pieces of machinery left with the subprocess and should
    not come back with one: the watchdog (nothing here blocks on a network mount), the cwd
    cache with its miss counter (the lookup is now cheaper than the bookkeeping was), and
    the undrained-pipe deadlock to design around.
  - `proc_pidpath` returns what the kernel actually ran, already symlink-resolved, so the
    native installer's `~/.local/bin/claude` arrives as the versioned binary it points at
    (hence the `/claude/versions/` rule). It fails for other users' processes, which is
    the same blind spot `ps` had, so nothing was lost.
  - Because argv is a real vector rather than a space-joined line, an install path with a
    space in it needs no reconstruction: that whole class of ambiguity, and the
    `exists`-probing heuristic that guessed where argv[0] ended, left with `ps`.
  - Every argument is built with `String(decoding:as:)` over its own bytes, **not** by
    pointing `String(cString:)` at the shared buffer. The slice stops before the terminator,
    so the C-string read ran one byte past the bounds it was given and only found a NUL
    because the parent array happened to hold one, and it force-unwrapped a base address the
    standard library does not promise is non-nil for the empty slice an empty argument
    (`claude ""`) produces. It worked; it worked by luck, and the compiler deprecates the
    array spelling for that exact reason. `execPath` cuts at the terminator with
    `prefix(while:)` for the same reason.
  - `isAgent` deliberately ignores argv[0]. It only disagrees with the exec path when
    something else launched the process, and then it does not name `claude` either: a
    `#!/bin/sh` wrapper called `claude` arrives as `execPath: /bin/bash`,
    `argv: ["/bin/sh", "./claude"]`, which is the same non-match as before.
  - Behind an interpreter, **any** argument that names `claude` counts, not just the first
    one without a dash. "First non-flag argument" is only node's rule for flags that stand
    alone: a value-taking one (`node -r ./polyfill /…/claude`, `node --import ./hook.mjs
    /…/claude`) puts its value exactly where the script was expected, so the session was
    missed outright. Widening it exposes nothing new, since reaching that line at all means
    the executable is already a known interpreter.
  - `hostName` matches `-p` / `--print` as whole argv entries rather than substrings, so
    neither a directory called `my-print` nor a prompt containing " -p " is a headless run.
    **The IDE markers follow the same rule, one level up.** They used to be matched against
    the executable and the whole argument vector flattened into a single line, which made
    `claude -p "fix the .vscode/extensions loader"` a VS Code session: a prompt is an argv
    entry like any other. Only the executable (a path by definition, spaces included) and
    arguments that *look* like a path - a slash and no whitespace - are searched now, which
    is what separates a location on disk from prose.
  - `allPids` retries when the read exactly fills its buffer: that may have been truncated,
    and a truncated table silently under-counts agents. After three tries it answers `nil`
    ("could not read"), never a short list.
  - Working directories come from `proc_pidinfo(PROC_PIDVNODEPATHINFO)`, a kernel
    path-cache lookup of about a microsecond, so there is no cache to poison by pid reuse
    and a directory that reads empty because the process was mid-exec simply resolves on
    the next scan.
  - `precedes` is the list order: folder (`localizedStandardCompare`, so `app2` precedes
    `app10`), then longest-running first, then pid. It sorts on `AgentProcess.elapsed`
    (seconds) and not on `uptime`, which is the same value already formatted and would
    compare wrong ("9m" after "12m"). Both are kept on the struct for that reason, and
    `memoryBytes`/`memoryText` are the same pairing for the same reason.
  - **Active vs merely open.** A session parked at the prompt since this morning costs the
    same RAM as one streaming tokens, and the chip used to count them the same. CPU is the
    discriminator, from `proc_pid_rusage(RUSAGE_INFO_V4)` - one syscall per *matched* pid
    (a dozen, not the 1300 in the table), measured at **0.9 µs**.
    - **Chosen over `proc_pidinfo(PROC_PIDTASKINFO)` for the memory, not the CPU.** Both
      carry the same CPU counter. They do not carry the same memory: `ri_phys_footprint`
      is what Activity Monitor prints in its "Memory" column, `pti_resident_size` is plain
      RSS, and on this app at one instant they read 37 MB and 83 MB. `footprint(1)` agreed
      with the 37. A number the user cannot find anywhere else is worse than no number.
    - **The times are mach absolute time units, not nanoseconds**, whatever `ri_user_time`
      is called. Apple Silicon's timebase is 125/3, so reading them raw understates CPU by
      41.67x and every percentage built on it is quietly, plausibly wrong. Verified against
      `ps -o time` on three processes: raw 69 923 834 is 0.070 s read as nanoseconds and
      2.913 s corrected, and `ps` said 2.91. It hides on Intel, where the timebase is 1/1.
    - **The threshold is 2% of a core, and it was measured.** Sampling every live session
      over a 10s window (the panel-open cadence) for four minutes: eight idle sessions ran
      at 0.44-0.55% median and 1.08% worst-case, three working ones at 2.6-4.1% median with
      every single sample above 1%. The gap between 1.1% and 2.6% is where 2% sits. Idle is
      **not** zero, so a threshold near zero would call everything active: even parked at
      the prompt these processes burn about half a percent of a core forever.
    - `classify` lives outside `scan()`, is `nonisolated static` and takes the previous
      sample, the current one, `dt` and the hysteresis map as parameters. That is the
      main-actor line again: `AgentsMonitor` stays a stateless enum, `UsageModel` holds the
      previous scan and the clock, and a test can drive a whole timeline without a process
      table. `dt` is **measured, never assumed** - the cadence changes when the panel opens,
      the loop parks while a menu tracks, and a machine that slept comes back with hours on
      it - and a window outside 0.5s..120s is discarded rather than turned into a number.
    - **Hysteresis (45s) is not optional.** Token streaming is bursty and a session waiting
      on a two minute `bash` call is working without spending a cycle. Without it the chip
      flickers between bursts and calls a busy agent idle. It is longer than
      `agentScanInterval` on purpose, so one quiet scan can never clear it alone.
    - The first scan has no delta, so it seeds from the lifetime average
      (`cpuNanos / elapsed`). That reads low for a session idle for hours that just started
      working, and it corrects itself on the next scan; the alternative is showing zero
      active sessions for the first ten seconds after launch.
    - **"No baseline" and "an untrusted window" are different cases and `load` keeps them
      apart** (hence `windowUsable` as its own parameter rather than a `nil` `dt`). Only the
      first one gets the lifetime average. Folding them together meant *discarding* a window
      silently substituted a measurement of a different span: a session that worked hard
      this morning and has been parked at the prompt since carries a lifetime average well
      over the threshold, so every wake from sleep - `dt` of hours, discarded - lit up every
      such session for a full 45s grace period while they burned nothing at all. Measured on
      a live table, 3 of 15 sessions were above 2% on lifetime average alone. An untrusted
      window now concludes nothing and lets the hysteresis hold the last real verdict.
      The test for this needs a fixture with a *busy* lifetime average: the obvious one
      (an idle seed plus an impossible spike) passes either way.
      **Waking from sleep is not the only way in, and the everyday one costs a scan.**
      `previousScanAt` is not cleared when the scan loop stops, so reopening the panel with
      the agents chip off arrives with a `dt` of minutes: untrusted, nothing concluded, and
      every session already running reads idle until the next scan 10s later. That is a
      restart being a first scan that does not get the first-scan fallback, and it is the
      trade taken on purpose - ten seconds of under-reporting beats lighting up 3 of 15
      sessions that are doing nothing. Clearing the baseline on the way out would undo it.
    - Rejected, with reasons, so they do not come back: **memory as the activity signal**
      (measured across 12 sessions, RSS does not fall when a session goes idle - 104 MB on
      a 3.5 hour session against 342 MB on a five minute one, and two freshly opened
      sessions that had done nothing at all held 920 MB and 832 MB; it is worth printing
      and useless for deciding); **`pbi_status`** from `PROC_PIDTBSDINFO` (an idle `claude`
      sits in `SSLEEP` exactly like one waiting on its first token, and zombies are already
      filtered because `KERN_PROCARGS2` fails on them); **open sockets to api.anthropic.com**
      via `PROC_PIDLISTFDS` (dozens of syscalls per agent, and keep-alive holds the
      connection open whether or not a token is being spent); **the mtime of
      `~/.claude/projects/<slug>/<session>.jsonl`** (written when a message completes, so it
      reads stale through exactly the long stream it should be reporting, and mapping pid to
      session is guesswork when a folder holds several); and **`ri_virtual_size`** (420 GB
      per process, JS heap reservations - do not display it and do not reason from it).
- `StatusIcon.swift` - draws the **entire** status item into one `NSImage`: the leading
  mark plus one rounded chip per value. The button carries no `attributedTitle`
  (`imagePosition = .imageOnly`), because attributed strings cannot draw a rounded border
  around a run of text (`.backgroundColor` is a square block) and the chips are the point.
  `UsageModel.statusSegments()` decides *what* to show, `StatusIcon` decides how.
  - The mark is `Resources/claude-mark.png`, the white Claude silhouette from lobe-icons.
    White + alpha on purpose: as a template only the alpha matters, so one asset covers
    light and dark menu bars, and `tint()` recolors it when the image cannot be a
    template. `build.sh` copies `Resources/*.png` into `Contents/Resources` **before**
    `codesign`, otherwise the seal does not cover it and macOS rejects the bundle.
    `drawFallbackMark` (12 tapered spokes, each filled separately so their winding
    directions do not cancel and punch a hole through the center) draws if the resource
    is missing. The logo is Anthropic's trademark, the README says the app is unofficial.
  - The agents chip uses `figure.run`.
  - When every value is `.normal` the image is a template, so the menu bar tints it and
    light/dark is free. If anything is warning or critical the image must carry its own
    colors, so it is drawn inside `appearance.performAsCurrentDrawingAppearance` and
    `App.swift` observes `button.effectiveAppearance` to redraw on theme changes.
  - SF Symbols ignore `foregroundColor` when drawn as images, hence the `tint` helper
    (draw, then `sourceAtop` fill).
- `Models.swift` - `Codable` API types plus the derived `UsageRow` list, the `Gauge`
  (percent + severity) the menu bar chips take, severity colors and formatting helpers.
  Row ids come from `kind` + the scope's model, never the array index: `sorted(by:)` is
  not stable, and an index-based id makes SwiftUI rebind a row onto a different limit
  when the API reorders two entries of the same rank. `group` is deliberately excluded
  from the id, every weekly entry shares `group: "weekly"`.
  - **Nothing in the decoder trusts the response's shape, and that takes real code.**
    Declaring the fields optional is not enough: `Decodable`'s default is that one leaf it
    cannot read throws all the way to the top, so a single limit entry with a renamed
    `percent` used to cost the entire response - the other three bars, the credits row, and
    the `five_hour`/`seven_day` fallback that exists for exactly that day. Every container
    therefore decodes field by field through the `lenient` helper (`decodeIfPresent` that
    answers `nil` instead of throwing), and `limits` decodes element by element through
    `Lenient<T>`, whose `init(from:)` swallows the failure while the unkeyed container still
    advances past the element. The result: a wrong type costs its field, a bad entry costs
    its own bar, `limits` arriving as an object costs nothing but falls back.
  - `percent` is the **one** field whose absence drops an entry, because a limit with no
    percentage has nothing to draw. `kind` defaults to `""` instead: it decides the title
    and the sort position, and neither is worth losing a bar over (`title(for:)` prints
    "Limit" rather than an empty label).
  - **`Fmt.percent` clamps, and that is not tidiness.** `Int(_: Double)` *traps* on NaN and
    on anything outside `Int`'s range, so a `percent` of `1e30` - valid JSON, an entirely
    ordinary `Double` once decoded - killed the app the next time the menu bar redrew.
    `Fmt.clampPercent` is applied where percentages **enter** (`Gauge.init`, `UsageRow.init`)
    rather than where they are printed, so the bar's width, the severity comparison and the
    chip all work from the same sane value.
  - The two `ISO8601DateFormatter`s are guarded by `isoLock`, exactly like
    `currencyFormatter`. They had no lock on the reasoning that `Fmt.date` is only reached
    from the panel's body: true today, and not a property of this code, since nothing stops
    a `nonisolated static` from calling it off the main actor tomorrow. `-swift-version 6`
    rejects the unguarded form, and the sources are clean under it.
  - **`is_active` is not a filter.** It used to be treated as "the account has this
    limit", which was wrong and hid real bars. Measured against a live account it comes
    back `false` on a session at 45% whose reset time is in the future *and* on the
    weekly Fable limit at 65%, and `true` on exactly one entry, the highest of the three.
    It reads as "this is the limit currently binding". Filtering on it collapsed the
    whole panel down to a single bar. Limits an account does not have are simply absent
    from the array, so every entry gets a row.
  - `Fmt.countdown` is a thin shell over `Fmt.duration`, which is the same arithmetic
    without the zero case: a countdown that has run out says "now", but an age ("token
    expired 12m ago") that rounds down to nothing still happened, so `duration` never
    prints "0m". `countdown` tests `< 1` rather than `<= 0` because the whole-second
    truncation it used to do before comparing is what makes the last fraction of a second
    read "now" and not "1m". `duration` guards `isFinite` and clamps before `Int(_:)` for
    the usual reason: these spans come off dates the API sent, and `Int(1e30)` is a crash
    rather than a large number.
  - `Fmt.money` and `creditsRow` take a `locale` (defaulting to `.current`). The app always
    passes the default and *should* render "US$ 64,20" for a reader in Argentina; the
    parameter exists so `Tests/main.swift` can pin `en_US` instead of asserting against
    whatever locale the machine happens to run in, which passed here and failed everywhere
    else. That is also why the de_DE case asserts `contains("64,20")`: the symbol is
    separated by a non-breaking space, and pinning that byte tests Foundation's CLDR data
    rather than this code. `currencyFormatter` caches the `NumberFormatter`s (they are
    expensive to build and this runs on every evaluation of the panel's body) behind a
    lock, and never mutates one after configuring it, which is the condition under which
    Foundation documents them as safe to share.
  - `Fmt.memory` prints whole megabytes under a gigabyte and one decimal above. No decimal
    in the MB range on purpose: a session's footprint drifts by kilobytes constantly, so a
    tenth of a megabyte is a digit that twitches on every scan and says nothing - the same
    reason `humanElapsed` refuses to print seconds. Binary units, which is what
    `ri_phys_footprint` counts in and what `footprint(1)` prints for the same process, and
    the rounding happens before the unit is chosen so nothing ever reads "1024 MB". It
    takes a `locale` like `money` and for the same reason: half the world writes "1,9 GB".
- `UsageView.swift` - the SwiftUI panel (bars, agents list, gear menu, login item). The
  pid is drawn with `Text(verbatim:)`: it is an identifier, and the interpolating
  initializer is free to format it as a number. `BarRow`, `UpdatedLabel` and
  `RefreshButton` are the only views that observe the `Clock`, and that is load-bearing
  rather than tidiness: see the gear menu note under `UsageModel`. `RefreshButton` needs it
  because the floor it disables itself under expires with *time* rather than with a change
  to the model. `UpdatedLabel` draws the rate-limit countdown in the
  warning orange, since in grey "Rate limited, retry in 4m" reads like an ordinary
  freshness line while the numbers above it have actually stopped updating. "Launch at login" is only offered when
  the bundle sits under `/Applications` or `~/Applications`: `SMAppService` remembers the
  path it was registered from, so enabling it while running out of `build/` leaves a
  login item pointing at a directory `make clean` deletes. The rule itself is
  `LoginItem.isInstalled(bundlePath:home:)` with both paths injected, since the property
  that reads `Bundle.main` can only ever answer for the bundle the test binary is not.
  It compares against `dir + "/"`, so `/Applications Backup/ClaudeUsage.app` is not an
  install; there is a test for that.

## API

`GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <token>`
and `anthropic-beta: oauth-2025-04-20`. Response fields used: `limits[]`
(`kind` = `session` | `weekly_all` | `weekly_scoped`, with `percent`, `severity`,
`resets_at`, `scope.model.display_name`), `extra_usage` (monthly credits, minor units +
`decimal_places`), and `five_hour` / `seven_day` as a fallback when `limits` is absent.

`resets_at` comes back as `2026-07-31T01:40:00.105304+00:00`: six fractional digits and a
numeric offset rather than `Z`. `ISO8601DateFormatter` with `.withFractionalSeconds`
handles it (there is a test pinning the exact instant), but the plain
`.withInternetDateTime` parser does not, which is why `Fmt.date` tries both.

The response also carries a `spend` object that duplicates `extra_usage` in a newer shape,
and a set of always-null codenamed fields (`tangelo`, `nimbus_quill`, …). Neither is read.

This is an undocumented internal endpoint (the one behind `/usage`); field names can
change without notice. The decoder degrades field by field and entry by entry for that
reason - see the `Models.swift` notes above, and do not "simplify" it back to a synthesized
`init(from:)`, which loses everything on the first unreadable leaf.

**Rate limiting is the main constraint.** It answers `429` with `Retry-After` (~5 minute
windows) if polled every few seconds. Keep the 25s `minFetchGap` floor, the
`throttledUntil` backoff and the 300s `defaultRefreshInterval`, which lines up with the
endpoint's own 5-minute window. Do not add a "refresh every 5s" option, and
do not add a way to bypass the floor - the panel's refresh button used to have one and it
was the only reliable way to get rate limited on purpose. **None of this applies to the
agent list**: that is a local read of the process table, nothing rate limits it, and it
has its own loop with its own interval for exactly that reason.

The 429 carries **no** `anthropic-ratelimit-*` headers (only `Retry-After`, plus
Cloudflare boilerplate), so the app cannot read the limit or the remaining budget from
the response: the client-side backoff is the whole strategy. Worse, the value it sends is
`Retry-After: 0` while it is *still* refusing requests - measured with a token from the
keychain, 12 of 12 probes 30s apart over 5.5 minutes returned `429` and every one of them
carried `Retry-After: 0`. So do **not** honor `Retry-After` literally: it is treated as a
lower bound only, and a non-finite one is thrown away outright (see `throttleDelay` above -
`Double("nan")` parses, and NaN survives every clamp it is passed through).

The real backoff is `consecutive429`, doubling from `minThrottle` (60s -> 2m -> 4m -> 8m)
and clamped by `maxThrottle` (900s), reset by any 200. A single blip therefore recovers on
the next tick, while a sustained window stops being retried into - which matters because
retrying inside the window holds it open. Confirmed both ways: polling every ~25-30s never
cleared, but a single request after 6 minutes with the app quit and no probes at all
returned `200`. A client that keeps hammering can stay rate limited indefinitely; one that
backs off gets its data back.

## Token handling

Read at request time via `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`,
falling back to `~/.claude/.credentials.json`; `claudeAiOauth.accessToken` is used and
never persisted or logged. On 401/403 the app does not attempt the OAuth refresh flow: it
tells the user to open Claude Code, which rewrites the keychain item, and the next poll
picks it up.

**The access token lapses on its own (~8h measured) and only Claude Code renews it**, when
*it* next makes a request. So a 401 on a machine that is fully logged in is the everyday
case, not the exceptional one, and the app has to treat it as a wait rather than as a
logout. `Credentials.parse` therefore reads `claudeAiOauth.expiresAt` beside the token, and
`UsageModel` keeps a fingerprint of whatever got refused. See the `authRejected`,
`tokenAction` and `authMessage` notes under `UsageModel.swift`.

`expiresAt` is milliseconds since the epoch, and `Credentials.expiry` trusts nothing about
it: non-finite is dropped (the NaN trap again), and so is anything below `1e12`, which in
practice is a *seconds* timestamp landing in a milliseconds field - 2026 read as seconds is
January 1970, and the panel would announce a login that expired 56 years ago. The unit is
deliberately not inferred from the magnitude, since guessing wrong is off by 1000 the other
way. No usable timestamp simply falls back to the shorter message.

The other keychain items matching `Claude Code-credentials-<hash>` hold MCP OAuth state,
not the login. `find-generic-password -s` is an exact match on the service, so they are
never picked up by accident.

## Gotchas

- The keychain read and the process scan must stay off the main actor (`Task.detached`),
  they block. The scan is syscalls now rather than a fork, but it still walks every pid
  on the machine.
- `Credentials.readKeychain` is the **only** subprocess left in the app, and it sets
  `standardError = FileHandle.nullDevice` rather than a `Pipe()`: an undrained pipe
  deadlocks `waitUntilExit()` as soon as the child writes more than the buffer holds. It
  deliberately has no watchdog either, because the block it can hit is the keychain ACL
  prompt, and that block is the user being asked a question. Do not add a second
  subprocess to the scan path: see `AgentsMonitor`.
- **`Int(_: Double)` traps**, on NaN and on anything outside `Int`'s range. Every number
  that reaches one comes off an endpoint that can send whatever it likes, so it goes
  through `Fmt.clampPercent` first. This is the one bug class here that is a hard crash
  rather than a wrong pixel, and it is invisible until the day the API sends something odd.
- The sources typecheck clean under `-swift-version 6`
  (`swiftc -typecheck -parse-as-library -swift-version 6 Sources/*.swift -framework AppKit
  -framework SwiftUI -framework ServiceManagement`). The build itself is Swift 5 mode, so
  that check is worth running by hand after touching anything shared across tasks: it is
  what caught the two unguarded `ISO8601DateFormatter`s.
- Menu bar text uses `NSFont.monospacedDigitSystemFont` so the width does not jitter, and
  semantic `NSColor`s so it adapts to light/dark menu bars.
- Status item colors: green/default under 75%, orange 75-90%, red above 90%. When the API
  sends a `severity` the **worse** of the two wins, so it can escalate early but cannot
  downgrade a bar sitting at 95% back to green. This has to travel with the value: the
  chips took a bare `Double` once and re-derived the severity from it, which threw the
  API's escalation away and left a chip green next to a red bar. Hence `Gauge`.
- `swiftc` rejects top-level code outside `main.swift`, so a throwaway render script for
  eyeballing the status image (render it to a PNG at 6x on light and dark strips, that is
  how the icon work was checked) has to be named `main.swift` and compiled separately,
  against `StatusIcon.swift` + `Models.swift`. Copy `claude-mark.png` next to that binary:
  for a plain CLI tool `Bundle.main` resolves resources from the executable's directory.
