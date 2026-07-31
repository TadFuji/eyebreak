// EyeBreak — 20-20-20 rule reminder. Menu bar agent, no dependencies.
import AppKit
import AVFoundation
import Carbon.HIToolbox

// ===== Knobs =====
let interval = ProcessInfo.processInfo.environment["EYEBREAK_INTERVAL"].flatMap(Double.init) ?? 20 * 60
let beepVolume: Float = 0.35
let accentVolume: Float = 0.60          // last 3 beeps: "3 seconds left" without looking at the screen
let chimeNotes: [Double] = [698.46, 880.00, 1046.50, 1396.91]   // F5 A5 C6 F6 — F5 matches Tink's pitch
let chimeIOI = 0.09, chimeTau = 0.09, chimeTailTau = 0.35
let chimeGain: Float = 0.28
let chimeFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

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

// ===== Chime: synthesized ascending arpeggio (no system sound is an ascending run) =====
final class Chime {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: chimeFormat)
    }

    func warmUp() { if !engine.isRunning { try? engine.start() } }
    func shutDown() { node.stop(); engine.stop() }

    static func buffer() -> AVAudioPCMBuffer {
        let sr = chimeFormat.sampleRate
        let total = chimeIOI * Double(chimeNotes.count - 1) + chimeTailTau * 4.5
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

    func play() {
        warmUp()
        node.scheduleBuffer(Chime.buffer(), completionHandler: nil)
        node.play()
    }
}

// ===== App =====
final class App: NSObject, NSApplicationDelegate {
    let chime = Chime()
    let tink = NSSound(named: NSSound.Name("Tink"))
    let cue = NSSound(named: NSSound.Name("Submarine"))
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let label = NSTextField(labelWithString: "")
    var mainTimer: Timer?, tickTimer: Timer?
    var panel: NSPanel?
    var hotKey: EventHotKeyRef?
    var countdown = Countdown()

    func applicationDidFinishLaunching(_ n: Notification) {
        status.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "EyeBreak")
        let m = NSMenu()
        m.addItem(withTitle: "今すぐ休憩", action: #selector(startBreak), keyEquivalent: "")
        m.addItem(withTitle: "1時間停止", action: #selector(snooze), keyEquivalent: "")
        m.addItem(NSMenuItem.separator())
        m.addItem(withTitle: "終了（今日はもう鳴らさない）", action: #selector(quit), keyEquivalent: "q")
        m.items.forEach { $0.target = self }
        status.menu = m

        installHotKeyHandler()
        schedule(interval)
    }

    func schedule(_ seconds: TimeInterval) {
        mainTimer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in self?.fire() }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)   // .common: keeps ticking while a menu is open
        mainTimer = t
    }

    // Nobody is looking at a dark or locked screen — skip rather than beep 20 times at it.
    var screenUnavailable: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func fire() { if !screenUnavailable { startBreak() } }

    // One-shot: resume the normal cadence an hour later. (A repeating 3600s
    // timer would silently turn the app into an hourly reminder forever.)
    @objc func snooze() {
        mainTimer?.invalidate()
        let t = Timer(timeInterval: 3600, repeats: false) { [weak self] _ in self?.schedule(interval) }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        mainTimer = t
    }
    @objc func quit() { NSApp.terminate(nil) }

    // ===== Break =====
    @objc func startBreak() {
        guard tickTimer == nil else { return }
        countdown = Countdown()
        label.stringValue = "遠くを見て  20"
        showPanel()
        cue?.volume = 0.5
        cue?.play()
        RegisterEventHotKey(UInt32(kVK_Escape), 0,
                            EventHotKeyID(signature: OSType(0x4559_4542), id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)   // Esc is ours for these 20s only
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    func tick() {
        let s = countdown.next()
        if let b = s.beep {
            tink?.stop()
            tink?.volume = b >= 18 ? accentVolume : beepVolume
            tink?.play()
        }
        if let l = s.label { label.stringValue = l > 0 ? "遠くを見て  \(l)" : "おつかれさま" }
        if s.warmUp { chime.warmUp() }
        if s.chime { chime.play() }
        if countdown.done {
            endBreak(playedChime: true)
        }
    }

    @objc func dismiss() { endBreak(playedChime: false) }

    func endBreak(playedChime: Bool) {
        guard tickTimer != nil else { return }
        tickTimer?.invalidate(); tickTimer = nil
        if let h = hotKey { UnregisterEventHotKey(h); hotKey = nil }
        schedule(interval)   // the 20-minute clock counts from the end of the last break
        let hold = playedChime ? 2.0 : 0.0   // > 1.845s: let the chime tail ring out
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
    assert(beeps == Array(1...20), "expected 20 beeps numbered 1...20, got \(beeps)")
    assert(labels == Array((0...19).reversed()), "expected labels 19...0, got \(labels)")
    assert(chimes == 1 && warmUps == 1, "chime/warmUp must fire exactly once")
    assert(beeps.filter { $0 >= 18 }.count == 3, "exactly the last 3 beeps are accented")

    let b = Chime.buffer()
    let sr = chimeFormat.sampleRate, n = Int(b.frameLength)
    let s = UnsafeBufferPointer(start: b.floatChannelData![0], count: n)
    assert(abs(Double(n) / sr - 1.845) < 0.02, "chime length drifted: \(Double(n) / sr)s")
    let peak = s.reduce(Float(0)) { max($0, abs($1)) }
    assert(peak > 0.30 && peak < 0.55, "chime peak \(peak) — silent, clipping, or gain changed")
    assert(abs(s[n - 1]) < 0.01, "chime is cut off before it decays (click)")
    // Zero crossings over the first note only (2nd note starts at 90ms) => fundamental must be F5.
    var zc = 0
    let w = Int(0.08 * sr)
    for i in 1..<w where (s[i] < 0) != (s[i - 1] < 0) { zc += 1 }
    let f0 = Double(zc) / (2 * 0.08)
    assert(abs(f0 - 698.46) < 25, "first chime note is not F5: \(f0) Hz")
    assert(chimeNotes == chimeNotes.sorted(), "arpeggio must ascend")

    assert(NSSound(named: NSSound.Name("Tink")) != nil, "/System/Library/Sounds/Tink.aiff is missing")
    assert(NSSound(named: NSSound.Name("Submarine")) != nil, "/System/Library/Sounds/Submarine.aiff is missing")
    print("selfcheck ok — beeps:\(beeps.count) chime:\(String(format: "%.3f", Double(n) / sr))s f0:\(Int(f0))Hz peak:\(peak)")
}

// ===== Entry =====
if CommandLine.arguments.contains("--selfcheck") {
    selfCheck()
    exit(0)
}
let delegate = App()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
