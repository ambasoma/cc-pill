/*
 * The session card: full representation, shown as the Plasma popup when the
 * pill is clicked. One row per session: its state, what it is doing, its
 * last briefing, and replay and send-a-prompt buttons. A pin
 * keeps the card open. Under the sessions: Alfred, the assistant (type, or
 * hold Space to talk). The footer holds the voice and its mute toggle.
 */
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

Item {
    id: card

    property var ctl
    // peek: shown in a no-focus window on hover; nothing that needs typing
    property bool peek: false
    readonly property var pd: ctl ? ctl.pillData : null
    readonly property bool online: ctl ? ctl.online : false

    property string inputFor: ""     // session id whose prompt field is open

    readonly property color ink: Kirigami.Theme.textColor
    readonly property int pad: Kirigami.Units.largeSpacing
    readonly property int gap: Kirigami.Units.smallSpacing
    readonly property int dotSize: 8

    Layout.preferredWidth: Kirigami.Units.gridUnit * 22
    Layout.minimumWidth: Kirigami.Units.gridUnit * 18
    Layout.maximumWidth: Kirigami.Units.gridUnit * 26
    Layout.preferredHeight: column.implicitHeight + pad * 2
    Layout.minimumHeight: Layout.preferredHeight
    Layout.maximumHeight: Layout.preferredHeight

    readonly property var sorted: {
        if (!pd) return []
        const order = { waiting: 0, working: 1, done: 2 }
        return pd.sessions.slice().sort((a, b) => (order[a.state] - order[b.state]) || (a.since - b.since))
    }

    readonly property var counts: {
        const c = { waiting: 0, working: 0, done: 0 }
        for (const s of sorted) c[s.state] += 1
        return c
    }

    function stateWord(state) {
        return state === "waiting" ? "needs you" : state
    }

    function detail(s) {
        if (!ctl) return ""
        return s.state === "working" && s.activity ? s.activity : ctl.elapsedText(s.since)
    }

    function tint(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a)
    }

    onVisibleChanged: if (!visible) inputFor = ""

    // Dictation: the daemon writes down what you said for one session, and
    // its row puts the words into the prompt field for you to check and send.
    signal dictated(string sid, string text)
    property int dictationSeen: -1
    onPdChanged: {
        if (!pd || !pd.alfred) return
        const d = pd.alfred.dictation
        const n = d ? d.n : 0
        if (d && dictationSeen >= 0 && n !== dictationSeen && !peek) dictated(d.sid, d.text)
        dictationSeen = n
    }

    ColumnLayout {
        id: column
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: card.pad }
        spacing: card.gap

        // ------------------------------------------------------- header
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: card.gap
            spacing: card.gap

            PlasmaComponents3.Label {
                text: "SESSIONS"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                font.weight: Font.DemiBold
                font.letterSpacing: 1.2
                opacity: 0.6
            }
            // "1 needs you · 1 working · 2 done", each count in its state's colour
            Repeater {
                model: card.online ? ["waiting", "working", "done"].filter(k => card.counts[k] > 0) : []
                delegate: RowLayout {
                    id: countItem
                    required property string modelData
                    required property int index
                    spacing: card.gap
                    PlasmaComponents3.Label {
                        visible: countItem.index > 0
                        text: "·"
                        font: Kirigami.Theme.smallFont
                        opacity: 0.4
                    }
                    PlasmaComponents3.Label {
                        text: card.counts[countItem.modelData] + " " + card.stateWord(countItem.modelData)
                        font: Kirigami.Theme.smallFont
                        color: card.ctl ? card.ctl.stateColor(countItem.modelData) : card.ink
                    }
                }
            }
            Item { Layout.fillWidth: true }
            // Keep Open, like the pin on the clock's and the network's popups
            PlasmaComponents3.ToolButton {
                visible: !card.peek && card.ctl !== null
                checkable: true
                checked: card.ctl ? card.ctl.cfg.pin : false
                display: PlasmaComponents3.AbstractButton.IconOnly
                icon.name: "window-pin-symbolic"
                text: "Keep Open"
                onToggled: card.ctl.cfg.pin = checked
                Accessible.name: text
                PlasmaComponents3.ToolTip.text: text
                PlasmaComponents3.ToolTip.visible: hovered
            }
        }

        // ------------------------------------------- offline / no sessions
        PlasmaExtras.PlaceholderMessage {
            visible: !card.online || card.sorted.length === 0
            Layout.fillWidth: true
            Layout.topMargin: card.pad
            Layout.bottomMargin: card.pad
            iconName: card.online ? "dialog-messages-symbolic" : "network-disconnect-symbolic"
            text: card.online ? "No Claude Code sessions" : "The cc-pill daemon isn't running"
            explanation: card.online ? "Sessions show here when they start." : "systemctl --user status cc-pill"
        }

        // --------------------------------------------------------- rows
        Repeater {
            model: card.online ? card.sorted : []
            delegate: Item {
                id: row
                required property var modelData
                readonly property color stateColor: card.ctl ? card.ctl.stateColor(modelData.state) : card.ink
                readonly property bool waiting: modelData.state === "waiting"
                readonly property bool speaking: !!card.pd && card.pd.pill.state === "speaking"
                                                 && !!card.pd.briefing && !card.pd.briefing.silent
                                                 && card.pd.briefing.sid === modelData.id
                readonly property bool typing: card.inputFor === modelData.id
                // the buttons show on hover or keyboard focus, so the card stays calm
                readonly property bool active: hover.hovered || typing || speaking

                Layout.fillWidth: true
                implicitHeight: body.implicitHeight + card.gap * 2

                HoverHandler { id: hover }

                Rectangle {
                    anchors.fill: parent
                    radius: Kirigami.Units.cornerRadius
                    color: row.waiting ? card.tint(row.stateColor, hover.hovered ? 0.16 : 0.10)
                                       : card.tint(card.ink, hover.hovered ? 0.06 : 0)
                    Behavior on color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
                }

                ColumnLayout {
                    id: body
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: card.gap }
                    spacing: 2

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: card.gap

                        // the dot sits on the name's line, not in the middle of the block
                        Rectangle {
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: Math.round((name.implicitHeight - card.dotSize) / 2)
                            Layout.preferredWidth: card.dotSize
                            Layout.preferredHeight: card.dotSize
                            radius: card.dotSize / 2
                            color: row.stateColor
                            Behavior on color { ColorAnimation { duration: 300 } }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            RowLayout {
                                spacing: card.gap
                                PlasmaComponents3.Label {
                                    id: name
                                    text: row.modelData.repo
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                    Layout.maximumWidth: Kirigami.Units.gridUnit * 10
                                }
                                // where it runs: its LXD container, and ssh from elsewhere
                                Repeater {
                                    model: [row.modelData.container || "", row.modelData.remote ? "ssh" : ""]
                                           .filter(t => t !== "")
                                    delegate: Rectangle {
                                        id: chip
                                        required property string modelData
                                        Layout.alignment: Qt.AlignVCenter
                                        implicitWidth: chipText.implicitWidth + card.gap * 2
                                        implicitHeight: chipText.implicitHeight + 2
                                        radius: height / 2
                                        color: card.tint(card.ink, 0.08)
                                        PlasmaComponents3.Label {
                                            id: chipText
                                            anchors.centerIn: parent
                                            text: chip.modelData
                                            font: Kirigami.Theme.smallFont
                                            opacity: 0.75
                                        }
                                    }
                                }
                            }

                            RowLayout {
                                spacing: card.gap
                                Layout.fillWidth: true
                                PlasmaComponents3.Label {
                                    text: card.stateWord(row.modelData.state)
                                    font: Kirigami.Theme.smallFont
                                    color: row.stateColor
                                }
                                PlasmaComponents3.Label {
                                    text: "·"
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.4
                                }
                                PlasmaComponents3.Label {
                                    text: card.detail(row.modelData)
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.6
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }
                        }

                        // ------------------------------------------ actions
                        RowLayout {
                            Layout.alignment: Qt.AlignTop
                            spacing: 0

                            PlasmaComponents3.ToolButton {
                                visible: !card.peek
                                display: PlasmaComponents3.AbstractButton.IconOnly
                                icon.name: "dialog-messages-symbolic"
                                text: "Send a prompt to this session"
                                checkable: true
                                checked: row.typing
                                opacity: row.active || activeFocus ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
                                onClicked: card.inputFor = row.typing ? "" : row.modelData.id
                                Accessible.name: text
                                PlasmaComponents3.ToolTip.text: text
                                PlasmaComponents3.ToolTip.visible: hovered
                            }
                            PlasmaComponents3.ToolButton {
                                // shows at rest while muted, so the state is visible
                                display: PlasmaComponents3.AbstractButton.IconOnly
                                icon.name: row.modelData.muted ? "audio-volume-muted-symbolic" : "audio-volume-high-symbolic"
                                text: row.modelData.muted ? "Unmute this session" : "Mute this session"
                                checkable: true
                                checked: !!row.modelData.muted
                                opacity: row.active || activeFocus || row.modelData.muted ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
                                onClicked: card.ctl.post("/session/mute", { sid: row.modelData.id, on: !row.modelData.muted })
                                Accessible.name: text
                                PlasmaComponents3.ToolTip.text: text
                                PlasmaComponents3.ToolTip.visible: hovered
                            }
                            PlasmaComponents3.ToolButton {
                                // last, at the edge: the one button that shows at rest
                                display: PlasmaComponents3.AbstractButton.IconOnly
                                icon.name: row.speaking ? "media-playback-stop-symbolic" : "media-playback-start-symbolic"
                                text: row.speaking ? "Stop" : (row.modelData.last_briefing ? "Play the last briefing" : "No briefing yet")
                                enabled: row.speaking || (!!row.modelData.last_briefing && !!card.pd && card.pd.voice.available)
                                opacity: row.active || activeFocus ? 1 : (enabled ? 0.55 : 0)
                                Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
                                onClicked: row.speaking ? card.ctl.post("/stop", {}) : card.ctl.post("/recap", { sid: row.modelData.id })
                                Accessible.name: text
                                PlasmaComponents3.ToolTip.text: text
                                PlasmaComponents3.ToolTip.visible: hovered
                            }
                        }
                    }

                    // the last briefing, as a quote in the state's colour
                    RowLayout {
                        visible: !!row.modelData.last_briefing
                        Layout.fillWidth: true
                        Layout.leftMargin: card.dotSize + card.gap
                        Layout.topMargin: 2
                        spacing: card.gap
                        Rectangle {
                            Layout.fillHeight: true
                            Layout.preferredWidth: 2
                            radius: 1
                            color: card.tint(row.stateColor, row.speaking ? 0.9 : 0.45)
                        }
                        PlasmaComponents3.Label {
                            text: row.modelData.last_briefing || ""
                            font: Kirigami.Theme.smallFont
                            opacity: row.speaking ? 1 : 0.8
                            wrapMode: Text.WordWrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: card.dotSize + card.gap
                        Layout.topMargin: card.gap
                        visible: row.typing
                        onVisibleChanged: if (visible) promptField.forceActiveFocus()
                        readonly property var al: card.pd ? card.pd.alfred : null
                        readonly property bool canDictate: !!al && al.can_listen
                        readonly property var dictating: al && al.dictating && al.dictating.sid === row.modelData.id
                                                         ? al.dictating : null
                        Connections {
                            target: card
                            function onDictated(sid, text) {
                                if (sid !== row.modelData.id || !text) return
                                const had = promptField.text.replace(/\s+$/, "")
                                promptField.text = had.length ? had + " " + text : text
                                card.inputFor = row.modelData.id
                                promptField.cursorPosition = promptField.text.length
                                promptField.forceActiveFocus()
                            }
                        }
                        PlasmaComponents3.TextField {
                            id: promptField
                            Layout.fillWidth: true
                            readonly property string target: row.modelData.repo + (row.modelData.container ? " in " + row.modelData.container : "")
                            placeholderText: parent.dictating ? (parent.dictating.listening ? "Listening\u2026" : "Writing it down\u2026")
                                             : parent.canDictate ? "Message " + target + ", or hold Space to talk"
                                             : "Message " + target + "\u2026"
                            onAccepted: sendButton.clicked()
                            Keys.onEscapePressed: card.inputFor = ""
                            // Hold Space in the empty field to dictate: a tap does
                            // nothing, a hold records until you let go.
                            Keys.onPressed: event => {
                                if (event.key !== Qt.Key_Space || text.length > 0 || !parent.canDictate) return
                                event.accepted = true
                                if (!event.isAutoRepeat && !holdToDictate.running && !holdToDictate.held && !parent.dictating)
                                    holdToDictate.start()
                            }
                            Keys.onReleased: event => {
                                if (event.key !== Qt.Key_Space || event.isAutoRepeat || text.length > 0) return
                                event.accepted = true
                                if (holdToDictate.running) {
                                    holdToDictate.stop()
                                } else if (holdToDictate.held) {
                                    holdToDictate.held = false
                                    card.ctl.post("/alfred/dictate", { sid: row.modelData.id, on: false })
                                }
                            }
                            Timer {
                                id: holdToDictate
                                property bool held: false
                                interval: 250
                                onTriggered: {
                                    held = true
                                    card.ctl.post("/alfred/dictate", { sid: row.modelData.id, on: true })
                                }
                            }
                        }
                        PlasmaComponents3.ToolButton {
                            visible: parent.canDictate
                            focusPolicy: Qt.NoFocus      // the field keeps the keyboard
                            display: PlasmaComponents3.AbstractButton.IconOnly
                            icon.name: "audio-input-microphone-symbolic"
                            text: "Hold to dictate"
                            checked: !!parent.dictating && parent.dictating.listening
                            onPressed: card.ctl.post("/alfred/dictate", { sid: row.modelData.id, on: true })
                            onReleased: card.ctl.post("/alfred/dictate", { sid: row.modelData.id, on: false })
                            Accessible.name: text
                            PlasmaComponents3.ToolTip.text: text
                            PlasmaComponents3.ToolTip.visible: hovered
                        }
                        PlasmaComponents3.ToolButton {
                            id: sendButton
                            display: PlasmaComponents3.AbstractButton.IconOnly
                            icon.name: "document-send-symbolic"
                            text: "Send"
                            enabled: promptField.text.trim().length > 0
                            onClicked: {
                                const t = promptField.text.trim()
                                if (!t.length) return
                                card.ctl.post("/prompt", { sid: row.modelData.id, text: t })
                                promptField.text = ""
                                card.inputFor = ""
                            }
                            Accessible.name: text
                            PlasmaComponents3.ToolTip.text: text
                            PlasmaComponents3.ToolTip.visible: hovered
                        }
                    }
                }
            }
        }

        // --------------------------------------------------------- Alfred
        ColumnLayout {
            id: alfredBox
            readonly property var a: card.pd ? card.pd.alfred : null
            visible: card.online && !card.peek && a !== null
            Layout.fillWidth: true
            Layout.topMargin: card.gap
            spacing: card.gap

            // the last exchange: what you asked, what he said
            ColumnLayout {
                visible: !!alfredBox.a && (alfredBox.a.you !== "" || alfredBox.a.reply !== ""
                                           || alfredBox.a.busy || alfredBox.a.listening)
                Layout.fillWidth: true
                Layout.leftMargin: card.gap
                spacing: 2
                PlasmaComponents3.Label {
                    visible: !!alfredBox.a && alfredBox.a.you !== "" && !alfredBox.a.listening
                    text: alfredBox.a ? "\u201c" + alfredBox.a.you + "\u201d" : ""
                    font: Kirigami.Theme.smallFont
                    opacity: 0.55
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: card.gap
                    PlasmaComponents3.BusyIndicator {
                        visible: !!alfredBox.a && (alfredBox.a.busy || alfredBox.a.listening)
                        running: visible
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    }
                    PlasmaComponents3.Label {
                        text: !alfredBox.a ? "" : alfredBox.a.listening ? "Listening\u2026"
                              : alfredBox.a.busy ? "Thinking\u2026" : alfredBox.a.reply
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                }
                // a send waits for your yes
                RowLayout {
                    visible: !!alfredBox.a && !!alfredBox.a.pending && !alfredBox.a.busy
                    spacing: card.gap
                    PlasmaComponents3.Button {
                        icon.name: "document-send-symbolic"
                        text: "Send"
                        onClicked: card.ctl.post("/alfred/confirm", { id: alfredBox.a.pending.id })
                    }
                    PlasmaComponents3.Button {
                        text: "Cancel"
                        onClicked: card.ctl.post("/alfred/cancel", { id: alfredBox.a.pending.id })
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                PlasmaComponents3.TextField {
                    id: askField
                    Layout.fillWidth: true
                    readonly property bool canListen: !!alfredBox.a && alfredBox.a.can_listen
                    placeholderText: alfredBox.a && alfredBox.a.listening ? "Listening\u2026 let go of Space to send"
                                     : canListen ? "Ask " + (card.pd ? card.pd.voice.name : "Alfred") + ", or hold Space to talk"
                                     : "Ask " + (card.pd ? card.pd.voice.name : "Alfred") + "\u2026"
                    onAccepted: {
                        const t = text.trim()
                        if (!t.length) return
                        card.ctl.post("/alfred/ask", { text: t })
                        text = ""
                    }
                    Keys.onEscapePressed: text = ""
                    // Hold Space in the empty box to talk: a tap does nothing,
                    // a hold records until you let go.
                    Keys.onPressed: event => {
                        if (event.key !== Qt.Key_Space || text.length > 0 || !canListen) return
                        event.accepted = true
                        if (!event.isAutoRepeat && !holdToTalk.running && !(alfredBox.a && alfredBox.a.listening))
                            holdToTalk.start()
                    }
                    Keys.onReleased: event => {
                        if (event.key !== Qt.Key_Space || event.isAutoRepeat || text.length > 0) return
                        event.accepted = true
                        if (holdToTalk.running) holdToTalk.stop()
                        else if (alfredBox.a && alfredBox.a.listening) card.ctl.post("/alfred/listen", { on: false })
                    }
                    Timer {
                        id: holdToTalk
                        interval: 250
                        onTriggered: card.ctl.post("/alfred/listen", { on: true })
                    }
                }
                PlasmaComponents3.ToolButton {
                    visible: askField.canListen
                    display: PlasmaComponents3.AbstractButton.IconOnly
                    icon.name: "audio-input-microphone-symbolic"
                    text: "Hold to talk"
                    checked: !!alfredBox.a && alfredBox.a.listening
                    onPressed: card.ctl.post("/alfred/listen", { on: true })
                    onReleased: card.ctl.post("/alfred/listen", { on: false })
                    Accessible.name: text
                    PlasmaComponents3.ToolTip.text: text
                    PlasmaComponents3.ToolTip.visible: hovered
                }
            }

            Connections {
                target: card.ctl
                function onSummoned() { focusLater.restart() }
            }
            Timer {
                // the popup has to be open before the box can take the keyboard
                id: focusLater
                interval: 150
                onTriggered: askField.forceActiveFocus()
            }
        }

        // ---------------------------------------------------------- toast
        PlasmaComponents3.Label {
            visible: !!(card.pd && card.pd.toast)
            text: card.pd && card.pd.toast ? card.pd.toast : ""
            font: Kirigami.Theme.smallFont
            opacity: 0.85
            Layout.fillWidth: true
            Layout.leftMargin: card.gap
            elide: Text.ElideRight
        }

        // -------------------------------------------------------- footer
        Kirigami.Separator {
            Layout.fillWidth: true
            Layout.topMargin: card.gap
            opacity: 0.6
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: card.gap
            spacing: card.gap
            readonly property var voice: card.pd ? card.pd.voice : null

            PlasmaComponents3.Label {
                text: parent.voice ? parent.voice.name : ""
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                font.weight: Font.DemiBold
                opacity: 0.75
            }
            PlasmaComponents3.Label {
                text: !parent.voice ? "" : !parent.voice.available ? "voice not installed"
                      : parent.voice.muted ? "muted" : "voice on"
                font: Kirigami.Theme.smallFont
                opacity: 0.55
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents3.ToolButton {
                visible: !!parent.voice && parent.voice.available
                display: PlasmaComponents3.AbstractButton.IconOnly
                checkable: true
                checked: !!parent.voice && parent.voice.muted
                icon.name: checked ? "audio-volume-muted-symbolic" : "audio-volume-high-symbolic"
                text: checked ? "Unmute " + parent.voice.name : "Mute " + (parent.voice ? parent.voice.name : "")
                onClicked: card.ctl.post("/mute", {})
                Accessible.name: text
                PlasmaComponents3.ToolTip.text: text
                PlasmaComponents3.ToolTip.visible: hovered
            }
        }

        PlasmaComponents3.Label {
            visible: card.peek
            text: "Click the pill to send a prompt."
            font: Kirigami.Theme.smallFont
            opacity: 0.5
            Layout.fillWidth: true
            Layout.leftMargin: card.gap
            elide: Text.ElideRight
        }
    }
}
