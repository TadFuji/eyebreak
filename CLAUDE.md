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

Never compile with `-O`: `selfCheck()` is `assert`-based and dies silently under
optimization. `build.sh` deliberately builds unoptimized; the app uses no
measurable CPU anyway.

`build.sh` boots out the old agent *before* overwriting the binary — replacing a
running executable in place gets the process SIGKILLed by code-signature
verification and launchd's KeepAlive then resurrects it in a crash loop. Keep
that ordering.

## Architecture

The entire app is `main.swift` (~210 lines), on purpose: no Xcode project, no
SwiftPM, no dependencies, no bundled assets. The file must keep the name
`main.swift` — swiftc only allows top-level statements there (any other name
requires `@main` + `-parse-as-library`).

`Info.plist` and the LaunchAgent plist are **generated inline by `build.sh`**,
not checked in. To change bundle metadata or launchd behavior, edit the
heredocs in `build.sh`.

Layout of `main.swift`, top to bottom:

- **Knobs** — five named constants (interval, volumes, chime notes/timing).
  User-facing tuning happens here and nowhere else.
- **`Countdown`** — pure state machine ticking at 0.5 s: odd ticks beep
  (1–20), even ticks repaint the label (19→0), tick 38 pre-warms the audio
  engine, tick 40 fires the chime. Beep #20 lands 0.5 s *before* the chime as
  an upbeat. Being pure, it is what `selfCheck()` exercises headlessly.
- **`Chime`** — AVAudioEngine synth. `Chime.buffer()` is static/pure so the
  self-check can validate the rendered audio without an output device.
- **`App`** — NSApplicationDelegate: status item + menu, the two timers, the
  notification-style NSPanel, the Carbon hotkey.
- **`selfCheck()`** — the only test. It gates every `build.sh` install and CI
  (`.github/workflows/ci.yml`, macOS runner). When changing the timing or
  audio contract, extend it — it asserts beep count/order, label sequence,
  beep/chime non-collision, accent placement, buffer length, peak (clipping),
  tail decay, and a zero-crossing measurement of the first chime note (F5).

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
- **Breaks are skipped when the display is asleep or the screen is locked**
  (`CGDisplayIsAsleep` / `CGSSessionScreenIsLocked`). This is the only idle
  handling; further idle detection is a deliberate non-feature (see README).
- **LaunchAgent `KeepAlive = {SuccessfulExit: false}`**: crash → auto-restart,
  menu Quit → stays quit until next login. A plain `true` makes the app
  unkillable from its own menu.
- The panel's origin is recomputed on every break — display arrangements
  change between breaks; never cache an `NSScreen`.

## Docs

`README.md` (English) and `README.ja.md` (Japanese) must stay in sync for any
user-visible behavior change. The Design notes section of `README.md` is the
long-form rationale for the decisions above.
