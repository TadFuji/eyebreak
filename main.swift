// EyeBreak — 20-20-20 rule reminder. Dock agent, no dependencies.
import AppKit
import AVFoundation
import Carbon.HIToolbox

// ===== Knobs =====
// Clamped: a mistyped EYEBREAK_INTERVAL=0 would spin the run loop, inf/nan would never fire.
let rawInterval = ProcessInfo.processInfo.environment["EYEBREAK_INTERVAL"].flatMap(Double.init) ?? 20 * 60
let interval = rawInterval.isFinite ? min(max(rawInterval, 1), 86400) : 20 * 60
let beepVolume: Float = 0.45
let accentVolume: Float = 0.75          // the last accentLast beeps: "3 seconds left" without looking
let accentLast = 3
let cueVolume: Float = 0.65             // Submarine, the "look away now" opening cue
let snoozeSeconds: TimeInterval = 3600
let chimeNotes: [Double] = [698.46, 880.00, 1046.50, 1396.91]   // F5 A5 C6 F6 — F5 matches Tink's pitch
let chimeIOI = 0.09, chimeTau = 0.09, chimeTailTau = 0.35
let chimeGain: Float = 0.34
let chimeDuration = chimeIOI * Double(chimeNotes.count - 1) + chimeTailTau * 4.5   // 1.845s with the defaults
let chimeFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

// Quiet hours follow the Mac's current local time, including time-zone changes.
func isQuietHours(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
    let hour = calendar.component(.hour, from: date)
    return hour >= 23 || hour < 6
}

// A Zoom meeting must never be interrupted. zoom.us launches us.zoom.CptHost for the
// duration of a meeting and quits it when the meeting ends, so this suppresses breaks
// only during calls — the client sitting idle in the Dock all day must not silence the
// app. Pure, so selfCheck exercises it without Zoom installed.
let zoomMeetingBundleIDs: Set<String> = ["us.zoom.CptHost"]

func isZoomMeeting(running bundleIDs: [String]) -> Bool {
    bundleIDs.contains { zoomMeetingBundleIDs.contains($0) }
}

// The screen coming back (display wake, system wake, unlock) means the eyes were off it,
// so the 20-minute clock starts over from that moment instead of firing minutes later.
// Not mid-break (that break already ends itself) and not while snoozed — waking the
// screen must not cut an hour's snooze short. Pure, for selfCheck.
func restartsClockOnScreenReturn(breakRunning: Bool, snoozed: Bool) -> Bool {
    !breakRunning && !snoozed
}

// ===== Single instance =====
// One copy only, however it was started (the LaunchAgent, a stray Login Item, a Finder
// double-click). flock is atomic, so two copies starting at the same instant can't both
// win, and the kernel drops the lock when the process dies, so a crash never leaves it stale.
let instanceLockPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/EyeBreak/instance.lock").path

// true = this process is the one copy. The fd is deliberately never closed: the lock
// lives exactly as long as the process. If the lock file can't be opened, run anyway —
// a duplicate is better than a silent app.
func acquireInstanceLock(at path: String) -> Bool {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return true }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
    close(fd)
    return false
}

// ===== Countdown state machine — ticks every 0.5s, 40 ticks = 20s =====
// odd tick  -> beep (t = 0.5, 1.5, ... 19.5), 20 beeps
// even tick -> label update (t = 1.0, 2.0, ... 20.0), 19 down to 0
struct Countdown {
    static let ticks = 40
    private(set) var n = 0

    struct Step { let beep: Int?; let label: Int?; let warmUp: Bool; let chime: Bool }

    mutating func next() -> Step {
        n += 1
        return Step(beep: n % 2 == 1 ? (n + 1) / 2 : nil,
                    label: n % 2 == 0 ? 20 - n / 2 : nil,
                    warmUp: n == Countdown.ticks - 2,    // t = 19.0 — grab the current output device
                    chime: n == Countdown.ticks)         // t = 20.0
    }
    var done: Bool { n >= Countdown.ticks }
}

// One source for the accent rule: tick() plays it, selfCheck() asserts on it.
func beepLevel(_ b: Int) -> Float { b > Countdown.ticks / 2 - accentLast ? accentVolume : beepVolume }

// ===== Chime: synthesized ascending arpeggio (no system sound is an ascending run) =====
final class Chime {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: chimeFormat)
    }

    func warmUp() {
        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("EyeBreak: audio engine start failed: \(error)") }
        }
    }
    func shutDown() { node.stop(); engine.stop() }

    static func buffer() -> AVAudioPCMBuffer {
        let sr = chimeFormat.sampleRate
        let total = chimeDuration
        let buf = AVAudioPCMBuffer(pcmFormat: chimeFormat, frameCapacity: AVAudioFrameCount(total * sr))!
        buf.frameLength = buf.frameCapacity
        let ch = buf.floatChannelData![0]
        let n = Int(buf.frameLength)
        ch.update(repeating: 0, count: n)
        for (k, f) in chimeNotes.enumerated() {
            let start = Int(Double(k) * chimeIOI * sr)
            let decay = (k == chimeNotes.count - 1) ? chimeTailTau : chimeTau
            for i in start..<n {
                let x = Double(i - start) / sr
                let env = exp(-x / decay) * (1 - exp(-x / 0.002))          // 3ms soft attack = no click
                let s = sin(2 * .pi * f * x) + 0.3 * exp(-x / 0.05) * sin(4 * .pi * f * x)
                ch[i] += Float(env * s) * chimeGain                        // fast-decaying 2nd harmonic = bell
            }
        }
        return buf
    }

    // False = the engine would not start; the caller falls back to an audible signal.
    func play() -> Bool {
        warmUp()
        guard engine.isRunning else { return false }
        node.scheduleBuffer(Chime.buffer(), completionHandler: nil)
        node.play()
        return true
    }
}

// ===== App =====
final class App: NSObject, NSApplicationDelegate {
    let chime = Chime()
    let tink = NSSound(named: NSSound.Name("Tink"))
    let cue = NSSound(named: NSSound.Name("Submarine"))
    let label = NSTextField(labelWithString: "")
    var mainTimer: Timer?, tickTimer: Timer?, quietTimer: Timer?
    var panel: NSPanel?
    var hotKey: EventHotKeyRef?
    var snoozed = false   // true only while snooze()'s one-shot is pending
    var countdown = Countdown()

    // Drawn, not bundled — the app ships no assets. Static/pure like Chime.buffer(),
    // so selfCheck can render and inspect it headlessly.
    static func icon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { r in
            NSColor(red: 0.16, green: 0.21, blue: 0.29, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 115, yRadius: 115).fill()
            let cfg = NSImage.SymbolConfiguration(pointSize: 300, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            guard let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: "EyeBreak")?
                .withSymbolConfiguration(cfg) else { return true }
            eye.draw(in: NSRect(x: (r.width - eye.size.width) / 2,
                                y: (r.height - eye.size.height) / 2,
                                width: eye.size.width, height: eye.size.height))
            return true
        }
    }

    // Before didFinishLaunching: the generic placeholder tile never flashes.
    func applicationWillFinishLaunching(_ n: Notification) { NSApp.applicationIconImage = App.icon() }

    func applicationDidFinishLaunching(_ n: Notification) {
        let appItem = NSMenuItem()
        appItem.submenu = buildMenu()   // a Dock app owns the menu bar while active: don't leave it empty
        let bar = NSMenu()
        bar.addItem(appItem)
        NSApp.mainMenu = bar

        installHotKeyHandler()
        scheduleQuietBoundary()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshQuietHours),
                                               name: .NSSystemTimeZoneDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshQuietHours),
                                               name: .NSSystemClockDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshQuietHours),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenReturned),
                                                              name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenReturned),
                                                            name: .init("com.apple.screenIsUnlocked"), object: nil)
        schedule(interval)
    }

    // A fresh instance per call: an NSMenu can have only one supermenu, and the
    // Dock asks for its menu again on every right-click.
    // No ⌘Q on Quit — it means "silent until next login", too costly to mistype.
    func buildMenu() -> NSMenu {
        let m = NSMenu(title: "EyeBreak")
        m.addItem(withTitle: "今すぐ休憩", action: #selector(startBreak), keyEquivalent: "")
        m.addItem(withTitle: "1時間停止", action: #selector(snooze), keyEquivalent: "")
        m.addItem(NSMenuItem.separator())
        m.addItem(withTitle: "終了（今日はもう鳴らさない）", action: #selector(quit), keyEquivalent: "")
        m.items.forEach { $0.target = self }
        return m
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { buildMenu() }

    func schedule(_ seconds: TimeInterval) {
        mainTimer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in self?.fire() }
        t.tolerance = min(seconds / 20, 60)   // proportional: EYEBREAK_INTERVAL=5 must not slip by a minute
        RunLoop.main.add(t, forMode: .common)   // .common: keeps ticking while a menu is open
        mainTimer = t
        snoozed = false
    }

    @objc func screenReturned() {
        guard restartsClockOnScreenReturn(breakRunning: tickTimer != nil, snoozed: snoozed) else { return }
        schedule(interval)
        NSLog("EyeBreak: screen back — 20-minute clock restarted")
    }

    // Nobody is looking at a dark or locked screen — skip rather than beep 20 times at it.
    var screenUnavailable: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // NSWorkspace lists LSUIElement helpers like CptHost and needs no permission —
    // reading window titles (Screen Recording) or the mic state would.
    var zoomMeetingActive: Bool {
        isZoomMeeting(running: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    // Every reason to hold a break back, checked before one starts and on every tick.
    var breakSuppressed: Bool { isQuietHours() || screenUnavailable || zoomMeetingActive }

    func fire() { startBreak() }   // startBreak() honours breakSuppressed itself

    // Also stop a chime whose tail crosses 23:00, after the countdown timer has ended.
    @objc func refreshQuietHours() {
        if isQuietHours() {
            endBreak(playedChime: false)
            tink?.stop()
            cue?.stop()
            chime.shutDown()
            panel?.orderOut(nil)
        }
        scheduleQuietBoundary()
    }

    func scheduleQuietBoundary() {
        quietTimer?.invalidate()
        guard let next = Calendar.current.nextDate(after: Date(),
                                                   matching: DateComponents(hour: 23),
                                                   matchingPolicy: .nextTime) else { return }
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.refreshQuietHours()
        }
        RunLoop.main.add(t, forMode: .common)
        quietTimer = t
    }

    // One-shot: resume the normal cadence an hour later. (A repeating 3600s
    // timer would silently turn the app into an hourly reminder forever.)
    @objc func snooze() {
        if tickTimer != nil { endBreak(playedChime: false) }   // silence the break being snoozed away…
        mainTimer?.invalidate()                                // …then drop the 20-min timer endBreak just set
        let t = Timer(timeInterval: snoozeSeconds, repeats: false) { [weak self] _ in self?.schedule(interval) }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        mainTimer = t
        snoozed = true   // after endBreak's schedule() above cleared it
    }
    @objc func quit() { NSApp.terminate(nil) }

    // ===== Break =====
    @objc func startBreak() {
        guard tickTimer == nil, !breakSuppressed else { return }
        chime.shutDown()   // a break begun inside the previous hold window would inherit a stale output device
        countdown = Countdown()
        label.stringValue = "遠くを見て  20"
        showPanel()
        cue?.volume = cueVolume
        cue?.play()
        let err = RegisterEventHotKey(UInt32(kVK_Escape), 0,
                                      EventHotKeyID(signature: OSType(0x4559_4542), id: 1),
                                      GetApplicationEventTarget(), 0, &hotKey)   // Esc is ours for these 20s only
        if err != noErr { NSLog("EyeBreak: Esc hotkey registration failed (\(err)) — click the panel to dismiss") }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    func tick() {
        if breakSuppressed { endBreak(playedChime: false); return }   // locked/slept/quiet/meeting mid-break: stop beeping at it
        let s = countdown.next()
        if let b = s.beep {
            tink?.stop()
            tink?.volume = beepLevel(b)
            tink?.play()
        }
        if let l = s.label { label.stringValue = l > 0 ? "遠くを見て  \(l)" : "おつかれさま" }
        if s.warmUp { chime.warmUp() }
        if s.chime, !chime.play() {   // engine dead (device mid-switch etc.): end on a beep, not on silence
            tink?.stop()
            tink?.volume = accentVolume
            tink?.play()
        }
        if countdown.done {
            endBreak(playedChime: true)
        }
    }

    @objc func dismiss() { endBreak(playedChime: false) }

    func endBreak(playedChime: Bool) {
        guard tickTimer != nil else { return }
        tickTimer?.invalidate(); tickTimer = nil
        tink?.stop()
        cue?.stop()   // the ~1.5s opening cue may still be sounding on an early dismiss/snooze
        if let h = hotKey { UnregisterEventHotKey(h); hotKey = nil }
        schedule(interval)   // the 20-minute clock counts from the end of the last break
        let hold = playedChime ? chimeDuration + 0.5 : 0.0   // tail + margin for output-device latency
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self, self.tickTimer == nil else { return }
            self.panel?.orderOut(nil)
            self.chime.shutDown()          // don't hold the audio device for the next 20 minutes
        }
    }

    // ===== Notification-style panel =====
    func showPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 72),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let fx = NSVisualEffectView(frame: p.contentView!.bounds)
            fx.material = .hudWindow
            fx.state = .active
            fx.blendingMode = .behindWindow
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 16
            fx.layer?.masksToBounds = true
            fx.autoresizingMask = [.width, .height]
            label.font = .systemFont(ofSize: 20, weight: .medium)
            label.alignment = .center
            label.frame = NSRect(x: 12, y: 24, width: 256, height: 26)
            label.autoresizingMask = [.width]
            fx.addSubview(label)
            fx.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(dismiss)))
            p.contentView = fx
            panel = p
        }
        // Re-read the screen every time: external monitors come and go.
        if let vf = NSScreen.main?.visibleFrame {
            panel!.setFrameOrigin(NSPoint(x: vf.maxX - 296, y: vf.maxY - 88))
        }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }   // Dock menu > Hide would swallow the panel
        panel!.orderFrontRegardless()    // show without stealing focus from what the user is typing in
    }

    func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let app = Unmanaged<App>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { app.dismiss() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}

// ===== Self-check =====
func selfCheck() {
    // Canary: with -O, swiftc strips assert()s and every check below would silently pass.
    var assertsAlive = false
    assert({ assertsAlive = true; return true }(), "")
    if !assertsAlive { print("selfcheck FAILED: asserts compiled out — build without -O"); exit(1) }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    for (hour, minute, second, quiet) in [(22, 59, 59, false), (23, 0, 0, true),
                                        (0, 0, 0, true), (5, 59, 59, true), (6, 0, 0, false)] {
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8,
                                                      hour: hour, minute: minute, second: second))!
        assert(isQuietHours(at: date, calendar: calendar) == quiet, "quiet-hours boundary failed: \(hour):\(minute):\(second)")
    }

    assert(isZoomMeeting(running: []) == false, "no apps must not read as a meeting")
    assert(isZoomMeeting(running: ["us.zoom.xos", "com.apple.Safari"]) == false,
           "the idle Zoom client must not read as a meeting")
    assert(isZoomMeeting(running: ["us.zoom.xos", "us.zoom.CptHost"]), "CptHost means a meeting is running")

    assert(restartsClockOnScreenReturn(breakRunning: false, snoozed: false), "screen return must restart the clock")
    assert(!restartsClockOnScreenReturn(breakRunning: false, snoozed: true), "screen return must not cut a snooze short")
    assert(!restartsClockOnScreenReturn(breakRunning: true, snoozed: false), "screen return must not restart mid-break")

    // flock locks belong to the open file, so a second open() in this same process
    // conflicts exactly like a second app instance would.
    let lockDir = FileManager.default.temporaryDirectory.appendingPathComponent("eyebreak-selfcheck-\(getpid())")
    let lockPath = lockDir.appendingPathComponent("sub/instance.lock").path
    assert(acquireInstanceLock(at: lockPath), "first instance must get the lock (and create its directory)")
    assert(!acquireInstanceLock(at: lockPath), "second instance must be refused")
    try? FileManager.default.removeItem(at: lockDir)

    var c = Countdown()
    var beeps: [Int] = [], labels: [Int] = [], chimes = 0, warmUps = 0
    while !c.done {
        let s = c.next()
        if let b = s.beep { beeps.append(b) }
        if let l = s.label { labels.append(l) }
        if s.chime { chimes += 1 }
        if s.warmUp { warmUps += 1 }
        assert(!(s.beep != nil && s.chime), "beep and chime must never land on the same tick")
    }
    let nBeeps = Countdown.ticks / 2
    assert(beeps == Array(1...nBeeps), "expected \(nBeeps) beeps numbered 1...\(nBeeps), got \(beeps)")
    assert(labels == Array((0...nBeeps - 1).reversed()), "expected labels \(nBeeps - 1)...0, got \(labels)")
    assert(chimes == 1 && warmUps == 1, "chime/warmUp must fire exactly once")
    let accented = (1...nBeeps).filter { beepLevel($0) == accentVolume }
    assert(accented == Array(nBeeps - accentLast + 1...nBeeps),
           "accent is not on precisely the last \(accentLast) beeps: \(accented)")

    let b = Chime.buffer()
    let sr = chimeFormat.sampleRate, n = Int(b.frameLength)
    let s = UnsafeBufferPointer(start: b.floatChannelData![0], count: n)
    assert(abs(Double(n) / sr - chimeDuration) < 0.02, "chime length drifted: \(Double(n) / sr)s")
    let peak = s.reduce(Float(0)) { max($0, abs($1)) }
    assert(peak / chimeGain > 0.9 && peak / chimeGain < 1.6, "chime peak \(peak) out of shape for gain \(chimeGain)")
    assert(peak < 1.0, "chime clips: peak \(peak)")
    assert(abs(s[n - 1]) < 0.01, "chime is cut off before it decays (click)")
    // Zero crossings over the first note only (the 2nd enters at chimeIOI) => fundamental must be chimeNotes[0].
    var zc = 0
    let win = 0.9 * chimeIOI
    let w = Int(win * sr)
    for i in 1..<w where (s[i] < 0) != (s[i - 1] < 0) { zc += 1 }
    let f0 = Double(zc) / (2 * win)
    assert(abs(f0 - chimeNotes[0]) < 25, "first chime note drifted from \(chimeNotes[0]) Hz: \(f0) Hz")
    assert(chimeNotes == chimeNotes.sorted(), "arpeggio must ascend")

    assert(NSSound(named: NSSound.Name("Tink")) != nil, "/System/Library/Sounds/Tink.aiff is missing")
    assert(NSSound(named: NSSound.Name("Submarine")) != nil, "/System/Library/Sounds/Submarine.aiff is missing")
    // The Dock icon is drawn, not bundled: a blank or all-dark tile would ship unnoticed.
    let tile = NSBitmapImageRep(data: App.icon().tiffRepresentation!)!
    var lit = 0
    for y in stride(from: 0, to: tile.pixelsHigh, by: 8) {
        for x in stride(from: 0, to: tile.pixelsWide, by: 8)
        where (tile.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0) > 0.9 {
            lit += 1
        }
    }
    assert(lit > 200, "Dock icon: the white eye glyph did not render (\(lit) light samples of 4096)")
    assert(tile.colorAt(x: 4, y: 4)?.alphaComponent ?? 1 < 0.5, "Dock icon lost its rounded corners")
    print("selfcheck ok — beeps:\(beeps.count) chime:\(String(format: "%.3f", Double(n) / sr))s f0:\(Int(f0))Hz peak:\(peak)")
}

// ===== Entry =====
if CommandLine.arguments.contains("--selfcheck") {
    selfCheck()
    exit(0)
}
// Exit 0, not 1: the LaunchAgent's KeepAlive {SuccessfulExit: false} would respawn a
// failing duplicate in a loop.
guard acquireInstanceLock(at: instanceLockPath) else {
    FileHandle.standardError.write("EyeBreak is already running — exiting\n".data(using: .utf8)!)
    exit(0)
}
let delegate = App()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
