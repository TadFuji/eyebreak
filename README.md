# EyeBreak

[![CI](https://github.com/TadFuji/eyebreak/actions/workflows/ci.yml/badge.svg)](https://github.com/TadFuji/eyebreak/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)

A tiny macOS menu bar app that enforces the **20-20-20 rule**: every 20 minutes,
look at something 20 feet (6 m) away for 20 seconds.

**One Swift file. Zero dependencies. No Xcode project. No notification permission.**

[日本語版 README はこちら](README.ja.md)

## What a break looks like

Every 20 minutes, a small notification-style panel slides into the top-right
corner — *"遠くを見て 20 → 19 → …"* — and the audio takes over from there:

```
t = 0.0   Submarine (E4)     — low opening cue: look away now
t = 0.5   Tink #1  (F5)      — one beep per second, 20 total
   ⋮
t = 17.5  Tink #18           — the last 3 beeps are louder:
t = 18.5  Tink #19             "3 seconds left" — audible with
t = 19.5  Tink #20             your eyes out the window
t = 20.0  chime F5→A5→C6→F6  — synthesized ascending arpeggio: done
```

Press <kbd>Esc</kbd> (or click the panel) to skip a break. The menu bar icon
offers **Break now**, **Pause for 1 hour**, and **Quit** (quit lasts until your
next login, then it comes back on its own).

## Install

Requires macOS with the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/TadFuji/eyebreak.git
cd eyebreak
bash build.sh
```

`build.sh` does everything: compiles `main.swift` into a proper `.app` bundle,
runs the built-in self-check (the install aborts if it fails), installs to
`~/Applications/EyeBreak.app`, registers a LaunchAgent for start-at-login, and
launches it. Safe to re-run any time — it is also the update path.

No Gatekeeper dialog appears: locally built binaries never receive the
`com.apple.quarantine` attribute, and the linker ad-hoc-signs the executable
automatically on Apple Silicon.

## Design notes

Decisions an engineer might wonder about:

- **A custom `NSPanel`, not `UNUserNotificationCenter`.** A real notification
  banner can't render a live 1-second countdown and can't receive an Esc
  keypress — and it costs a permission prompt. A borderless, non-activating
  panel (`.hudWindow` material, `orderFrontRegardless()`) looks like a
  notification, updates every second, and never steals keyboard focus from
  what you're typing. Trade-off, stated honestly: Focus/Do Not Disturb will
  *not* silence it — that's what "Pause for 1 hour" is for.

- **The beep is the system's own `Tink.aiff` — chosen by measurement, not
  vibes.** FFT analysis of every sound in `/System/Library/Sounds` showed Tink
  is a 34 ms, overtone-free pure tone at exactly **F5 (698 Hz)** — the platonic
  "beep" ships with the OS. Playback via `NSSound` follows the main output
  device and volume (unlike `AudioServicesPlaySystemSound`, which is at the
  mercy of the separate *alert volume* slider).

- **The finishing chime is synthesized** (`AVAudioPCMBuffer`, ~30 lines):
  an ascending **F5 → A5 → C6 → F6** arpeggio, 90 ms note spacing, a
  fast-decaying 2nd harmonic for a bell-like timbre, and a long tail on the
  final note. No bundled asset needed — and no built-in macOS sound is an
  ascending run. Its root note is deliberately the same F5 as Tink, so the 20
  beeps and the chime sound like one instrument in one key. The engine starts
  1 s before the chime and stops right after, so the app holds no audio device
  during the 20-minute wait and always picks up the *current* output device.

- **Esc via Carbon `RegisterEventHotKey`** — registered only for the
  20 seconds of the break, then released. It's the one API that takes the
  actual Esc key globally with **no Input Monitoring permission** and no focus
  theft (`NSEvent` global monitors and `CGEventTap` both trigger the
  permission dialog).

- **Breaks are skipped when the display is asleep or the screen is locked**
  (`CGDisplayIsAsleep`, `CGSessionCopyCurrentDictionary`) — nobody needs
  20 beeps aimed at a dark screen at 2 a.m. That's the *only* idle handling;
  deliberate non-features are listed below.

- **LaunchAgent with `KeepAlive = {SuccessfulExit: false}`.** Crashes
  auto-restart; a clean Quit from the menu stays quit until next login. With a
  plain `KeepAlive = true`, launchd resurrects the app the instant you quit
  it — the classic "unkillable app" bug.

- **The countdown is a pure state machine** (`Countdown`) ticking at 0.5 s:
  odd ticks beep, even ticks repaint the label, so beep #20 lands half a
  second *before* the chime as an upbeat. Being pure, it's exactly what the
  self-check exercises.

## Testing

```sh
swiftc -o eyebreak main.swift && ./eyebreak --selfcheck
```

The self-check asserts the whole contract: exactly 20 beeps numbered 1–20,
labels 19→0 with no gaps, exactly one chime that never collides with a beep,
the accent on precisely the last 3 beeps — and, on the synthesized buffer:
correct length, no clipping (peak ≈ 0.40), fully decayed tail (no click), and
a zero-crossing measurement proving the first note really is F5 (±25 Hz).
CI runs this on every push. `build.sh` runs it before every install.

To try a break without waiting 20 minutes:

```sh
launchctl bootout gui/$(id -u)/com.user.eyebreak
EYEBREAK_INTERVAL=5 ~/Applications/EyeBreak.app/Contents/MacOS/EyeBreak
```

(<kbd>Ctrl</kbd>+<kbd>C</kbd>, then `bash build.sh` to restore the resident copy.)

## Deliberate non-features

- No Focus-mode integration (no public API; every workaround breaks across
  macOS updates)
- No idle detection beyond display-sleep/lock (which absorbs the real cases)
- No preferences window, statistics, or history — the knobs are five named
  constants at the top of `main.swift`

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.user.eyebreak
launchctl disable gui/$(id -u)/com.user.eyebreak
osascript -e 'tell application "Finder" to delete POSIX file "'"$HOME"'/Library/LaunchAgents/com.user.eyebreak.plist"'
osascript -e 'tell application "Finder" to delete POSIX file "'"$HOME"'/Applications/EyeBreak.app"'
```

Everything goes to the Trash — recoverable until you empty it.

## License

[MIT](LICENSE)
