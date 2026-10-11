# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
# Build + self-check + install to ~/Applications/EyeBreak.app + register
# LaunchAgent + relaunch. This is BOTH the install and the update path.
bash build.sh

# Compile and run the self-check without touching the installed app:
swiftc -o /tmp/eyebreak main.swift && /tmp/eyebreak --selfcheck

# Trigger a break in 5 seconds instead of 20 minutes:
launchctl bootout gui/$(id -u)/com.user.eyebreak
EYEBREAK_INTERVAL=5 ~/Applications/EyeBreak.app/Contents/MacOS/EyeBreak
# (Ctrl-C, then `bash build.sh` to restore the resident agent.)

# Inspect the resident agent / its stderr:
launchctl print gui/$(id -u)/com.user.eyebreak
cat /tmp/com.user.eyebreak.err
```

Never compile with `-O`: `selfCheck()` is `assert`-based. A canary makes it
fail loudly (exit 1) when asserts are compiled out, and `build.sh`
deliberately builds unoptimized; the app uses no measurable CPU anyway.

`build.sh` builds and self-checks in a temp dir first — a failure leaves the
installed app and agent untouched and running. Only then does it boot out the
old agent, *before* moving the verified binary into place — replacing a
running executable in place gets the process SIGKILLed by code-signature
verification and launchd's KeepAlive then resurrects it in a crash loop. Keep
that ordering.

## Architecture

The entire app is `main.swift`, on purpose: no Xcode project, no SwiftPM, no
dependencies, no bundled assets. The file must keep the name
`main.swift` — swiftc only allows top-level statements there (any other name
requires `@main` + `-parse-as-library`).

`Info.plist` and the LaunchAgent plist are **generated inline by `build.sh`**,
not checked in. To change bundle metadata or launchd behavior, edit the
heredocs in `build.sh`.

Layout of `main.swift`, top to bottom:

- **Knobs** — the named constants at the top (interval, the beep/accent/cue
  volumes, accent count, snooze length, chime notes/timing). User-facing
  tuning happens here and nowhere else.
- **`Countdown`** — pure state machine ticking at 0.5 s: odd ticks beep
  (1–20), even ticks repaint the label (19→0), tick 38 pre-warms the audio
  engine, tick 40 fires the chime. Beep #20 lands 0.5 s *before* the chime as
  an upbeat. Being pure, it is what `selfCheck()` exercises headlessly.
- **`Chime`** — AVAudioEngine synth. `Chime.buffer()` is static/pure so the
  self-check can validate the rendered audio without an output device.
- **`App`** — NSApplicationDelegate: Dock icon + Dock menu, the two timers, the
  notification-style NSPanel, the Carbon hotkey.
- **`selfCheck()`** — the only test. It gates every `build.sh` install and CI
  (`.github/workflows/ci.yml`, macOS runner). When changing the timing or
  audio contract, extend it — it asserts an asserts-alive canary (catches
  `-O`), beep count/order, label sequence, beep/chime non-collision, the
  accent rule (via `beepLevel`, the same function `tick()` plays), buffer
  length, peak shape and clipping, tail decay, a zero-crossing measurement of
  the first chime note, the quiet-hours, Zoom-meeting and screen-return predicates, the single-instance lock, the
  presence of the system sounds, and the drawn Dock icon. Expected values are derived from the Knobs, so tuning them does not
  break the gate.

## Load-bearing decisions — do not regress these

- **Custom NSPanel, not `UNUserNotificationCenter`.** A real notification can't
  show a live 1 s countdown, can't receive Esc, and costs a permission prompt.
  The panel is `.nonactivatingPanel` + `orderFrontRegardless()`: it must never
  steal keyboard focus. Known trade-off (documented in README): Focus/DND does
  not silence it.
- **Esc uses Carbon `RegisterEventHotKey`**, registered only for the 20 s of a
  break, unregistered at `endBreak`. `NSEvent` global monitors and `CGEventTap`
  both trigger the Input Monitoring permission dialog — avoid them.
- **Beeps via `NSSound`** (follows the main output device and volume).
  `AudioServicesPlaySystemSound` was rejected: it obeys the separate
  alert-volume slider and can be silently disabled.
- **The chime's root note is F5 on purpose** — measured pitch of `Tink.aiff` —
  so the 20 beeps and the chime sound like one instrument in one key. The
  engine starts ~1 s before the chime (to grab the *current* output device;
  AVAudioEngine does not follow device changes while running) and stops right
  after: the app must not hold an audio device during the 20-minute wait.
- **Timers live on RunLoop `.common`** so open menus don't pause them.
- **Snooze must stay one-shot.** A repeating 3600 s timer silently turned the
  app into a permanent hourly reminder (fixed in ca9b968). `endBreak`
  restarts the 20-minute clock, so every break/skip resets the cycle phase.
  `snooze()` first ends any break in progress and only then installs its
  one-shot — in the other order, the running break's `endBreak` would
  immediately overwrite the snooze timer with the 20-minute clock.
- **Breaks are skipped when the display is asleep or the screen is locked**
  (`CGDisplayIsAsleep` / `CGSSessionScreenIsLocked`), and `tick()` re-checks,
  so a mid-break lock stops the remaining beeps. When the screen returns
  (`screensDidWake`, `didWake`, distributed `com.apple.screenIsUnlocked`),
  `screenReturned()` restarts the 20-minute clock — except mid-break or while
  `snoozed` (waking must not cut a snooze short; the rule is the pure
  `restartsClockOnScreenReturn`). This is the only idle
  handling; further idle detection is a deliberate non-feature (see README).
- **Every suppression rule lives in `breakSuppressed`** (quiet hours, sleep/lock,
  Zoom meeting), read by both `startBreak()`'s guard and every `tick()`. Add new
  rules there, not at the call sites, or "Break now" and mid-break checks drift.
- **A Zoom meeting is detected by the helper bundle ID `us.zoom.CptHost`**, which
  `zoom.us` runs only for the duration of a meeting — an idle client in the Dock
  must not silence the app all day. `NSWorkspace.runningApplications` lists
  LSUIElement helpers and costs no permission; window titles (`kCGWindowName`)
  and microphone state were rejected because both prompt. If Zoom drops the
  helper, the app keeps firing breaks rather than going silent — keep that
  direction of failure. `isZoomMeeting(running:)` is pure, for `selfCheck()`.
- **Dock tile, not a status item.** `Info.plist` carries no `LSUIElement`, so
  the app is `.regular` — no `setActivationPolicy` call needed. `buildMenu()`
  returns a fresh `NSMenu` every time (an `NSMenu` has exactly one supermenu,
  and the Dock re-asks on every right-click); it feeds both
  `applicationDockMenu` and the minimal main menu, which exists only so the
  menu bar isn't empty while the app is active. Quit deliberately has no ⌘Q.
  The icon is drawn into `NSApp.applicationIconImage` in
  `applicationWillFinishLaunching` (no bundled asset, no placeholder flash),
  and `showPanel` calls `unhideWithoutActivation` because the Dock's Hide item
  is now reachable and a hidden app never shows the panel.
- **LaunchAgent `KeepAlive = {SuccessfulExit: false}`**: crash → auto-restart,
  menu Quit → stays quit until next login. A plain `true` makes the app
  unkillable from its own menu.
- **Single instance via `flock`** on
  `~/Library/Application Support/EyeBreak/instance.lock`, taken at entry
  (after `--selfcheck`, so `build.sh` can self-check while the app runs). The
  loser must `exit(0)` — a non-zero exit under the LaunchAgent's KeepAlive
  respawns it forever. A Login Item on top of the LaunchAgent once started two
  copies at every login (removed 2026-10-06); start-at-login is the
  LaunchAgent only. Running `/tmp/eyebreak` while the agent is up now exits
  immediately — boot the agent out first, as in Commands.
- The panel's origin is recomputed on every break — display arrangements
  change between breaks; never cache an `NSScreen`.

## Releasing

```sh
git tag -a vX.Y.Z -m "Short summary" && git push origin vX.Y.Z
gh release create vX.Y.Z --title "vX.Y.Z" --notes "..."
```

The Releases page is the changelog — there is deliberately no CHANGELOG.md.
Describe user-visible behavior changes in the release notes.

## Docs

`README.md` (English) and `README.ja.md` (Japanese) must stay in sync for any
user-visible behavior change. The Design notes section of `README.md` is the
long-form rationale for the decisions above.
