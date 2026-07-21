import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global hotkey via Carbon (works without any Accessibility grant).
final class HotKey {
    nonisolated(unsafe) static var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?

    private static let keycodes: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46, "space": 49, "`": 50,
    ]

    /// "cmd+alt+m" style spec -> (keycode, modifiers). Nil if unparseable.
    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for raw in spec.lowercased().split(separator: "+") {
            let tok = raw.trimmingCharacters(in: .whitespaces)
            switch tok {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "alt", "opt", "option": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "shift": mods |= UInt32(shiftKey)
            default:
                guard let k = keycodes[tok] else { return nil }
                key = UInt32(k)
            }
        }
        guard let k = key, mods != 0 else { return nil }
        return (k, mods)
    }

    func register(_ spec: String) {
        guard let (key, mods) = Self.parse(spec) ?? Self.parse("cmd+alt+m") else { return }
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.onPress?() }
            return noErr
        }, 1, &eventSpec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D4F4F4E), id: 1)  // 'MOON'
        RegisterEventHotKey(key, mods, id, GetApplicationEventTarget(), 0, &ref)
        MBLog.log("hotkey registered: \(spec)")
    }
}

/// The camera notch on built-in MacBook displays, in points. The top-center
/// of a notched screen is dead pixels: a pill pinned there vanishes behind
/// the hardware. When a notch is present the pill instead docks to its
/// bottom edge and matches its width, so the notch itself becomes the
/// resting island and the pill reads as the hardware swelling downward.
struct NotchInfo: Equatable {
    let width: CGFloat
    let height: CGFloat

    static func of(_ screen: NSScreen) -> NotchInfo? {
        // Rehearsal knob for machines without a notch: CC_PILL_FAKE_NOTCH
        // ("200x37", or any value for the 14" MacBook Pro shape).
        if let fake = ProcessInfo.processInfo.environment["CC_PILL_FAKE_NOTCH"] {
            let parts = fake.split(separator: "x").compactMap { Double($0) }
            return parts.count == 2
                ? NotchInfo(width: parts[0], height: parts[1])
                : NotchInfo(width: 200, height: 37)
        }
        let inset = screen.safeAreaInsets.top
        guard inset > 0 else { return nil }
        let aux = (screen.auxiliaryTopLeftArea?.width ?? 0)
                + (screen.auxiliaryTopRightArea?.width ?? 0)
        let width = screen.frame.width - aux
        // No auxiliary areas would make "the notch" the whole screen; that
        // combination is not a notch, whatever safeAreaInsets claims.
        guard width > 0, width < screen.frame.width / 2 else { return nil }
        return NotchInfo(width: width, height: inset)
    }
}

/// Borderless, non-activating panel that floats over the menu bar.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: IslandPanel!
    private var hosting: NSHostingView<AnyView>?
    private var hotTimer: Timer?
    private let hotkey = HotKey()
    private var visible = false
    private var wasAsking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MBLog.log("---- cc-pill starting ----")
        // Any uncaught ObjC exception should at least leave a trace.
        NSSetUncaughtExceptionHandler { ex in
            MBLog.log("FATAL uncaught exception: \(ex.name.rawValue): \(ex.reason ?? "?")")
        }

        let panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // AFTER isFloatingPanel (which silently resets level to .floating,
        // BELOW the menu bar): pin above the menu bar so the pill draws over it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.panel = panel

        let root = ContentView().environmentObject(Store.shared)
        let hosting = NSHostingView(rootView: AnyView(root))
        panel.contentView = hosting
        self.hosting = hosting

        // Fixed window, never resized: transitions are pure SwiftUI springs
        // with zero frame churn. The window ignores the mouse except when
        // the pointer is actually over the pill or the card (checked below),
        // so the big transparent area never blocks clicks underneath.
        repositionPanel()
        // Lid opened or closed, display plugged or unplugged, resolution
        // changed: recompute the frame and the notch instead of needing a
        // restart. Docking a notched MacBook flips modes on the fly.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.repositionPanel() }
        }
        panel.ignoresMouseEvents = true

        hotTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateHotRegion() }
        }

        // Ask-mode hotkey (configurable): open ask mode, press again to send.
        HotKey.onPress = {
            let s = Store.shared
            if s.asking { s.sendAsk() } else { s.startAsk() }
        }
        hotkey.register(Store.shared.config.hotkey)

        EventWatcher.shared.start()
        Store.shared.adoptExisting()

        // Show/hide with session presence; re-evaluated on every store change.
        let update = { [weak self] in self?.updateVisibility() }
        Store.shared.objectWillChange.sink {
            DispatchQueue.main.async { update() }
        }.store(in: &bag)

        updateVisibility()
        MBLog.log("pill ready")
    }

    private var bag = Set<AnyCancellable>()

    private func updateVisibility() {
        let shouldShow = Store.shared.pillState != .hidden
        if shouldShow && !visible {
            panel.orderFrontRegardless()
            visible = true
            MBLog.log("panel shown")
        } else if !shouldShow && visible {
            panel.orderOut(nil)
            visible = false
            Store.shared.pinned = false
            MBLog.log("panel hidden")
        }
    }

    static let panelSize = CGSize(width: 560, height: 480)

    /// Pin the window to the top-center of the primary screen; on notched
    /// MacBooks, to the notch's bottom edge so the pill hangs from the
    /// hardware instead of vanishing behind it.
    private func repositionPanel() {
        guard let screen = NSScreen.screens.first else { return }
        let notch = NotchInfo.of(screen)
        if Store.shared.notch != notch {
            Store.shared.notch = notch
            MBLog.log(notch.map { "notch mode: \(Int($0.width))x\(Int($0.height))" }
                      ?? "no notch: pill over the menu bar")
        }
        let f = screen.frame
        let rect = NSRect(x: (f.midX - Self.panelSize.width / 2).rounded(),
                          y: f.maxY - (notch?.height ?? 0) - Self.panelSize.height,
                          width: Self.panelSize.width, height: Self.panelSize.height)
        if panel.frame != rect { panel.setFrame(rect, display: true) }
    }

    /// The interactive region in screen coordinates: the pill (per current
    /// state) plus the card when it is open. Pointer inside: the window
    /// takes mouse events and the card peeks open. Pointer outside: the
    /// window is click-through and hover ends (debounced in the store).
    private var menuTick = 0
    private var menuOpen = false

    /// True while any menu (menu bar dropdown, status item, context menu)
    /// is on screen. The pill is a dark slab over the menu bar; when a menu
    /// opens, the bar lightens behind it and the silhouette shows, so the
    /// pill steps aside instead.
    private func menuIsOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let me = ProcessInfo.processInfo.processIdentifier
        return list.contains { w in
            (w[kCGWindowLayer as String] as? Int) == menuLevel &&
            (w[kCGWindowOwnerPID as String] as? Int32) != me
        }
    }

    private func updateHotRegion() {
        guard visible, let screen = NSScreen.screens.first else { return }
        let store = Store.shared
        // Courtesy fade while the user is in a menu (checked every ~0.25s).
        menuTick += 1
        if menuTick % 3 == 0 {
            let open = menuIsOpen() && !store.asking
            if open != menuOpen {
                menuOpen = open
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    panel.animator().alphaValue = open ? 0 : 1
                }
                MBLog.log(open ? "menu open: pill stepping aside" : "menu closed: pill back")
            }
        }
        if menuOpen {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            store.setHover(false)
            return
        }
        // Ask mode owns the mouse and keyboard while it is open.
        if store.asking {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            if !wasAsking { panel.makeKeyAndOrderFront(nil) }
            wasAsking = true
            return
        }
        if wasAsking {
            wasAsking = false
            panel.resignKey()
        }
        let f = screen.frame
        let notchW = store.notch?.width ?? 0
        let top = f.maxY - (store.notch?.height ?? 0)
        let cx = f.midX

        var pillW: CGFloat = 0
        var pillH: CGFloat = 0
        switch store.pillState {
        case .hidden: break
        case .idle: pillW = max(70, notchW); pillH = 22
        case .working: pillW = max(300, notchW); pillH = 27  // generous: label width varies
        case .waiting: pillW = max(190, notchW); pillH = 70  // includes the paw underneath
        case .speaking: pillW = 460; pillH = 120
        case .moment: pillW = max(220, notchW); pillH = 30
        case .listening: pillW = 460; pillH = 120   // unreachable: asking returns above
        }
        var hot = false
        let p = NSEvent.mouseLocation
        if pillW > 0 {
            let m: CGFloat = 8
            let pillRect = NSRect(x: cx - pillW / 2 - m, y: top - pillH - m,
                                  width: pillW + 2 * m, height: pillH + 2 * m)
            hot = pillRect.contains(p)
        }
        if !hot, store.showCard, store.pillState != .hidden {
            let rows = CGFloat(store.sessions.count)
            let inputExtra: CGFloat = store.inputFor != nil ? 90 : 0
            let cardH = 46 + rows * 54 + 40 + inputExtra + 24
            let cardTop = top - pillH - 10
            let cardRect = NSRect(x: cx - 190, y: cardTop - cardH,
                                  width: 380, height: cardH + 14)
            hot = cardRect.contains(p)
        }
        if panel.ignoresMouseEvents == hot {
            panel.ignoresMouseEvents = !hot
        }
        store.setHover(hot)
    }
}

import Combine

nonisolated(unsafe) var appDelegate: AppDelegate?
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    appDelegate = delegate
    app.delegate = delegate
    app.run()
}
