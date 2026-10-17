/*
 * cc-pill for KDE Plasma 6.
 *
 * The widget is a renderer: all session logic lives in the ccpilld daemon
 * (linux/daemon/ccpilld.py), which this file polls over localhost. The
 * compact representation is the pill in the panel (Pill.qml), the full
 * representation is the session card popup (Card.qml).
 */
import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ------------------------------------------------------------ daemon

    readonly property int port: Plasmoid.configuration.port
    readonly property bool showCats: Plasmoid.configuration.showCats
    // "plasma": follow the Plasma colour scheme, font and icons like any other
    // panel widget (default). "porcelain": the macOS cc-pill look.
    readonly property bool nativeLook: Plasmoid.configuration.style !== "porcelain"
    readonly property int slotChars: Plasmoid.configuration.slotChars
    readonly property bool openOnHover: Plasmoid.configuration.openOnHover
    readonly property int hoverDelay: Plasmoid.configuration.hoverDelay
    readonly property int hitPadding: Plasmoid.configuration.hitPadding
    readonly property string base: "http://127.0.0.1:" + port

    property bool online: false
    property int failures: 0
    property var pillData: emptyState()
    // local wall clock minus the daemon's, so "since" stamps can be aged here
    property real clockOffset: 0
    property real nowSec: Date.now() / 1000

    function emptyState() {
        return {
            pill: { state: "hidden", label: "", narration: "" },
            sessions: [],
            briefing: null,
            moment: null,
            voice: { name: "Jarvis", muted: false, available: false },
            toast: null,
            hotkey: ""
        }
    }

    readonly property string pillState: online ? pillData.pill.state : "hidden"
    readonly property bool hidden: pillState === "hidden"
    readonly property int sessionCount: pillData.sessions.length
    readonly property int waitingCount: pillData.sessions.filter(s => s.state === "waiting").length
    readonly property int workingCount: pillData.sessions.filter(s => s.state === "working").length

    // ------------------------------------------------------------- theme
    // Native: the panel's own colours (text, highlight, neutral, positive).
    // Porcelain: cc-pill's porcelain by day and kiln at night, picked from
    // the colour scheme's luminance.

    readonly property color schemeBg: Kirigami.Theme.backgroundColor
    readonly property bool night: (0.2126 * schemeBg.r + 0.7152 * schemeBg.g + 0.0722 * schemeBg.b) < 0.5

    // Custom colours and font, when the user picked them in the settings,
    // override either look.
    readonly property var cfg: Plasmoid.configuration
    readonly property bool customColors: cfg.colors === "custom"
    readonly property bool customFont: cfg.customFont
    readonly property font customFontValue: Qt.font({
        family: cfg.fontFamily || Kirigami.Theme.defaultFont.family,
        pointSize: cfg.fontSize > 0 ? cfg.fontSize : Kirigami.Theme.defaultFont.pointSize,
        weight: Math.max(100, Math.min(900, cfg.fontWeight || 400)),
        italic: cfg.fontItalic
    })
    readonly property color schemeInk: Kirigami.Theme.textColor

    readonly property QtObject theme: QtObject {
        readonly property bool nativeLook: root.nativeLook
        readonly property bool night: root.night
        readonly property color bg: root.customColors ? root.cfg.backgroundColor
            : root.nativeLook ? (root.cfg.capsule ? Qt.rgba(root.schemeInk.r, root.schemeInk.g, root.schemeInk.b, 0.09) : "transparent")
            : (root.night ? "#181D0E" : "#F8F3E8")
        readonly property color ink: root.customColors ? root.cfg.textColor
            : root.nativeLook ? root.schemeInk : (root.night ? "#EFE8D3" : "#2A2620")
        readonly property color line: root.customColors ? root.cfg.borderColor
            : root.nativeLook ? Qt.rgba(root.schemeInk.r, root.schemeInk.g, root.schemeInk.b, 0.28)
            : (root.night ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(0.165, 0.149, 0.125, 0.16))
        readonly property color gold: root.customColors ? root.cfg.accentColor
            : root.nativeLook ? Kirigami.Theme.highlightColor : (root.night ? "#D9B44A" : "#A88117")
        readonly property color amber: root.customColors ? root.cfg.attentionColor
            : root.nativeLook ? Kirigami.Theme.neutralTextColor : (root.night ? "#D9913A" : "#B26E1C")
        readonly property color olive: root.customColors ? root.cfg.accentColor
            : root.nativeLook ? Kirigami.Theme.highlightColor : (root.night ? "#A9BD66" : "#5F7036")
        readonly property color sage: root.customColors ? root.cfg.doneColor
            : root.nativeLook ? Kirigami.Theme.positiveTextColor : "#7FB39D"
        readonly property real gloss: (root.nativeLook || root.customColors) ? 0 : (root.night ? 0.07 : 0.38)
        // porcelain always has its hairline; the native look has none unless asked
        readonly property int borderWidth: root.nativeLook ? root.cfg.borderWidth : Math.max(1, root.cfg.borderWidth)
        readonly property int cornerRadius: root.cfg.cornerRadius
    }

    // --------------------------------------------------------- plasmoid

    Plasmoid.status: hidden ? PlasmaCore.Types.PassiveStatus
                            : (pillState === "waiting" ? PlasmaCore.Types.NeedsAttentionStatus
                                                       : PlasmaCore.Types.ActiveStatus)
    preferredRepresentation: compactRepresentation
    hideOnWindowDeactivate: true

    toolTipMainText: online ? (sessionCount === 0 ? "cc-pill" : sessionCount + (sessionCount === 1 ? " Claude session" : " Claude sessions"))
                            : "cc-pill daemon not running"
    toolTipSubText: {
        if (!online) return "systemctl --user status cc-pill"
        if (sessionCount === 0) return "Waiting for a Claude Code session"
        const parts = []
        if (waitingCount) parts.push(waitingCount + " need" + (waitingCount === 1 ? "s" : "") + " you")
        if (workingCount) parts.push(workingCount + " working")
        const done = sessionCount - waitingCount - workingCount
        if (done) parts.push(done + " done")
        return parts.join(" · ")
    }

    compactRepresentation: Pill { ctl: root }
    fullRepresentation: Card { ctl: root }

    // ------------------------------------------------------------ polling

    Timer {
        interval: root.online ? 500 : 3000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.poll()
    }

    Timer {
        interval: 100
        running: !root.hidden || root.expanded
        repeat: true
        onTriggered: root.nowSec = Date.now() / 1000
    }

    function poll() {
        const xhr = new XMLHttpRequest()
        xhr.open("GET", root.base + "/state")
        xhr.setRequestHeader("X-CC-Pill", "1")
        xhr.timeout = 1500
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    const d = JSON.parse(xhr.responseText)
                    if (!d || !d.pill || !Array.isArray(d.sessions)) throw new Error("shape")
                    root.clockOffset = Date.now() / 1000 - d.t
                    root.pillData = d
                    root.online = true
                    root.failures = 0
                } catch (e) {
                    root.markOffline()
                }
            } else {
                root.markOffline()
            }
        }
        xhr.send()
    }

    function markOffline() {
        root.failures += 1
        if (root.failures >= 2 && root.online) {
            root.online = false
            root.pillData = emptyState()
        }
    }

    function post(path, body, cb) {
        const xhr = new XMLHttpRequest()
        xhr.open("POST", root.base + path)
        xhr.setRequestHeader("X-CC-Pill", "1")
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.timeout = 10000
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            let obj = null
            try { obj = JSON.parse(xhr.responseText) } catch (e) { obj = null }
            if (cb) cb(xhr.status === 200, obj)
            // Refresh promptly so a toast or mute change shows up at once.
            root.poll()
        }
        xhr.send(JSON.stringify(body || {}))
    }

    // ------------------------------------------------------------ helpers

    function elapsed(since) {
        return Math.max(0, root.nowSec - root.clockOffset - since)
    }

    function elapsedText(since) {
        const s = elapsed(since)
        if (s < 60) return "just now"
        const m = Math.floor(s / 60)
        if (m < 60) return m + "m"
        const h = Math.floor(m / 60)
        return h + "h " + (m % 60) + "m"
    }

    function stateColor(state) {
        if (state === "waiting") return theme.amber
        if (state === "working") return theme.olive
        return theme.sage
    }
}
