import AppKit

/// Keeps the Dock on one "anchor" display.
///
/// Two mechanisms (the same ones DockAnchor uses):
///  1. Guard: an event tap swallows mouse-move events in a thin strip along the bottom edge of every
///     *other* display, so the Dock never sees the "cursor pushed against the bottom edge" gesture
///     there and never jumps away.
///  2. Relocate: to put the Dock onto the anchor display, the cursor is warped to a free stretch of the
///     anchor's bottom edge and synthetic mouse moves "push" against it, then the cursor is put back.
///     A watchdog does this automatically whenever the Dock ends up on the wrong display
///     (display plugged in, wake from sleep, Dock restart, ...).
final class DockController {
    static let shared = DockController()

    /// Marks events we synthesize so our own tap lets them through.
    private static let syntheticMarker: Int64 = 0x444F_434B_4841_434B // "DOCKHACK"
    private static let guardStripHeight: CGFloat = 6

    // MARK: Settings

    private let defaults = UserDefaults.standard

    /// nil = automatic (topmost display).
    var anchorPreferenceUUID: String? {
        get { defaults.string(forKey: "anchorUUID") }
        set { defaults.set(newValue, forKey: "anchorUUID"); refreshDisplays(reason: "anchor changed"); scheduleCheck(after: 0.2, force: true) }
    }

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled"); refreshDisplays(reason: newValue ? "enabled" : "disabled"); if newValue { scheduleCheck(after: 0.2, force: true) } }
    }

    // MARK: State

    private(set) var displays: [Display] = []
    private(set) var anchor: Display?
    private(set) var lastDockDisplay: Display?
    private(set) var tapActive = false
    private(set) var statusNote = ""

    private var tap: CFMachPort?
    private var guardZones: [CGRect] = []          // read from the tap callback (main thread)
    private let relocatingLock = NSLock()
    private var _relocating = false
    private var relocating: Bool {
        get { relocatingLock.lock(); defer { relocatingLock.unlock() }; return _relocating }
        set { relocatingLock.lock(); _relocating = newValue; relocatingLock.unlock() }
    }

    private var wrongStreak = 0
    private var failedAttempts = 0
    private var lastAttempt = Date.distantPast
    private var watchdog: Timer?
    private var tapRetryTimer: Timer?

    var onStateChange: (() -> Void)?

    // MARK: Lifecycle

    func start() {
        refreshDisplays(reason: "launch")
        installTap()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplays(reason: "screen parameters changed")
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Log.write("system event: \(name.rawValue)")
                self?.failedAttempts = 0
                self?.refreshDisplays(reason: "wake")
            }
        }

        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.check() }
    }

    // MARK: Displays

    func refreshDisplays(reason: String) {
        let newDisplays = Displays.all()
        let changed = newDisplays != displays
        displays = newDisplays

        if let uuid = anchorPreferenceUUID, let d = displays.first(where: { $0.uuid == uuid }) {
            anchor = d
        } else {
            anchor = Displays.topmost(displays)
        }

        guardZones = []
        if enabled, let anchor, displays.count > 1, Displays.dockOrientation() == "bottom" {
            for d in displays where d.id != anchor.id {
                // Only real edges matter: skip stretches that continue into a display below.
                for seg in Displays.freeBottomSegments(of: d, among: displays) {
                    guardZones.append(CGRect(x: seg.lowerBound, y: d.bounds.maxY - Self.guardStripHeight,
                                             width: seg.upperBound - seg.lowerBound, height: Self.guardStripHeight + 1))
                }
            }
        }

        if changed {
            failedAttempts = 0
            Log.write("displays (\(reason)): " + displays.map { "\($0.name) \($0.bounds)" }.joined(separator: " | ")
                      + " → anchor: \(anchor?.name ?? "none"), guard zones: \(guardZones)")
        }
        onStateChange?()
    }

    // MARK: Watchdog

    private func scheduleCheck(after delay: TimeInterval, force: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if force { self?.failedAttempts = 0; self?.wrongStreak = 1 }
            self?.check()
        }
    }

    private func check() {
        let current = Displays.dockDisplay(among: displays)
        if current?.id != lastDockDisplay?.id {
            Log.write("Dock is now on: \(current?.name ?? "unknown")")
            lastDockDisplay = current
            onStateChange?()
        }

        guard enabled, tapActive, let anchor, displays.count > 1, !relocating else { wrongStreak = 0; return }
        guard Displays.dockOrientation() == "bottom" else { statusNote = "Dock must be at the bottom"; wrongStreak = 0; return }
        guard let current, current.id != anchor.id else {
            wrongStreak = 0
            if failedAttempts > 0 { failedAttempts = 0; statusNote = ""; onStateChange?() }
            return
        }

        wrongStreak += 1
        // Wait until the Dock has been on the wrong display for ~2 checks, the user isn't dragging,
        // and we're not hammering (back off after repeated failures so we don't keep stealing the cursor).
        guard wrongStreak >= 2,
              NSEvent.pressedMouseButtons == 0,
              failedAttempts < 3,
              Date().timeIntervalSince(lastAttempt) > 4 else { return }

        relocate(reason: "Dock found on \(current.name)")
    }

    // MARK: Relocation

    /// Where to "push" the cursor to summon the Dock onto the anchor display.
    private func triggerPoint(for anchor: Display) -> CGPoint {
        let free = Displays.freeBottomSegments(of: anchor, among: displays)
        if let widest = free.max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }) {
            return CGPoint(x: (widest.lowerBound + widest.upperBound) / 2, y: anchor.bounds.maxY - 1)
        }
        // No free stretch: the whole bottom edge is shared. Try the middle anyway.
        return CGPoint(x: anchor.bounds.midX, y: anchor.bounds.maxY - 1)
    }

    func relocate(reason: String) {
        guard tapActive, let anchor, !relocating else {
            Log.write("relocate skipped (tapActive=\(tapActive), relocating=\(relocating))")
            return
        }
        relocating = true
        lastAttempt = Date()
        let target = triggerPoint(for: anchor)
        let hasFreeEdge = !Displays.freeBottomSegments(of: anchor, among: displays).isEmpty
        Log.write("relocating → \(anchor.name) at \(target) (\(reason)), free edge: \(hasFreeEdge)")

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let original = CGEvent(source: nil)?.location ?? .zero
            let source = CGEventSource(stateID: .hidSystemState)
            let approach = CGPoint(x: target.x, y: target.y - 60)

            CGWarpMouseCursorPosition(approach)
            usleep(30_000)
            for i in 0...10 {
                let t = CGFloat(i) / 10
                self.postMove(CGPoint(x: target.x, y: approach.y + (target.y - approach.y) * t), dy: 6, source: source)
                usleep(12_000)
            }
            for _ in 0..<16 {          // keep pushing against the edge
                self.postMove(target, dy: 6, source: source)
                usleep(25_000)
            }
            CGWarpMouseCursorPosition(original)
            self.postMove(original, dy: 0, source: source)

            DispatchQueue.main.async {
                self.relocating = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.verifyRelocation(to: anchor) }
            }
        }
    }

    private func verifyRelocation(to anchor: Display) {
        let now = Displays.dockDisplay(among: displays)
        if now?.id == anchor.id {
            failedAttempts = 0
            statusNote = ""
            Log.write("relocation OK")
        } else {
            failedAttempts += 1
            statusNote = failedAttempts >= 3 ? "Couldn't move the Dock automatically" : ""
            Log.write("relocation FAILED (\(failedAttempts)); Dock on \(now?.name ?? "unknown")")
        }
        wrongStreak = 0
        onStateChange?()
    }

    private func postMove(_ point: CGPoint, dy: Int64, source: CGEventSource?) {
        CGWarpMouseCursorPosition(point)
        guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaY, value: dy)
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        e.post(tap: .cghidEventTap)
    }

    // MARK: Event tap

    var hasAccessibility: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<DockController>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            tapActive = false
            Log.write("event tap unavailable – waiting for Accessibility permission")
            requestAccessibility()
            tapRetryTimer?.invalidate()
            tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self, self.hasAccessibility else { return }
                t.invalidate()
                self.installTap()
            }
            onStateChange?()
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapActive = true
        Log.write("event tap installed")
        onStateChange?()
        scheduleCheck(after: 0.5, force: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .mouseMoved else { return Unmanaged.passUnretained(event) }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        if relocating { return nil }                    // don't let the real mouse fight the relocation

        let p = event.location
        for zone in guardZones where zone.contains(p) {
            return nil                                  // swallow: the Dock never sees the edge push
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: Self-test (debug)

    /// Pushes *unmarked* synthetic moves against the bottom edge of a non-anchor display, i.e. simulates a
    /// user bumping into the MacBook's bottom edge. With the guard on, the Dock must not move.
    func selfTestBump() {
        guard tapActive, let anchor, let victim = displays.first(where: { $0.id != anchor.id }) else { return }
        let p = CGPoint(x: victim.bounds.midX, y: victim.bounds.maxY - 1)
        Log.write("self-test: bumping bottom edge of \(victim.name) at \(p), guard \(enabled ? "ON" : "OFF")")
        DispatchQueue.global().async {
            let original = CGEvent(source: nil)?.location ?? .zero
            let source = CGEventSource(stateID: .hidSystemState)
            for i in 0..<30 {
                let pt = CGPoint(x: p.x, y: i < 10 ? p.y - CGFloat(10 - i) * 5 : p.y)
                CGWarpMouseCursorPosition(pt)
                if let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
                    e.setIntegerValueField(.mouseEventDeltaY, value: 6)
                    e.post(tap: .cghidEventTap)
                }
                usleep(25_000)
            }
            CGWarpMouseCursorPosition(original)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                Log.write("self-test done: Dock on \(Displays.dockDisplay(among: self.displays)?.name ?? "unknown")")
            }
        }
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DockHack.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}
