import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global hotkey via Carbon (works without any Accessibility grant).
final class HotKey {
    nonisolated(unsafe) static var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?

    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D4F4F4E), id: 1)  // 'MOON'
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | optionKey),
                            id, GetApplicationEventTarget(), 0, &ref)
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
        if let screen = NSScreen.screens.first {
            let f = screen.frame
            let rect = NSRect(x: (f.midX - Self.panelSize.width / 2).rounded(),
                              y: f.maxY - Self.panelSize.height,
                              width: Self.panelSize.width, height: Self.panelSize.height)
            panel.setFrame(rect, display: true)
        }
        panel.ignoresMouseEvents = true

        hotTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateHotRegion() }
        }

        // ⌥⌘M anywhere: open ask mode (press again to send).
        HotKey.onPress = {
            let s = Store.shared
            if s.asking { s.sendAsk() } else { s.startAsk() }
        }
        hotkey.register()

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

    /// The interactive region in screen coordinates: the pill (per current
    /// state) plus the card when it is open. Pointer inside: the window
    /// takes mouse events and the card peeks open. Pointer outside: the
    /// window is click-through and hover ends (debounced in the store).
    private func updateHotRegion() {
        guard visible, let screen = NSScreen.screens.first else { return }
        let store = Store.shared
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
        let top = f.maxY
        let cx = f.midX

        var pillW: CGFloat = 0
        var pillH: CGFloat = 0
        switch store.pillState {
        case .hidden: break
        case .idle: pillW = 70; pillH = 22
        case .working: pillW = 300; pillH = 27      // generous: label width varies
        case .waiting: pillW = 190; pillH = 70      // includes the paw underneath
        case .speaking: pillW = 460; pillH = 120
        case .moment: pillW = 220; pillH = 30
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
