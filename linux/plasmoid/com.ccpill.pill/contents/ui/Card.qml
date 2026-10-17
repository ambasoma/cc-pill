/*
 * The session card: full representation, shown as the Plasma popup when the
 * pill is clicked. One row per session with replay-briefing, speak-a-prompt
 * and open-terminal buttons, "+ NEW" to start a hands-free session, and the
 * voice's mute toggle in the footer.
 */
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

Item {
    id: card

    property var ctl
    // peek: shown in a no-focus window on hover; nothing that needs typing
    property bool peek: false
    readonly property var pd: ctl ? ctl.pillData : null
    readonly property QtObject theme: ctl ? ctl.theme : null
    readonly property bool online: ctl ? ctl.online : false

    property string inputFor: ""     // session id whose prompt field is open
    property bool asking: false

    Layout.preferredWidth: Kirigami.Units.gridUnit * 21
    Layout.minimumWidth: Kirigami.Units.gridUnit * 18
    Layout.maximumWidth: Kirigami.Units.gridUnit * 26
    Layout.preferredHeight: column.implicitHeight + Kirigami.Units.largeSpacing * 2
    Layout.minimumHeight: Layout.preferredHeight
    Layout.maximumHeight: Layout.preferredHeight

    readonly property var sorted: {
        if (!pd) return []
        const order = { waiting: 0, working: 1, done: 2 }
        return pd.sessions.slice().sort((a, b) => (order[a.state] - order[b.state]) || (a.since - b.since))
    }

    function detail(s) {
        if (!ctl) return ""
        const age = ctl.elapsedText(s.since)
        if (s.state === "waiting") return "needs you · " + age
        if (s.state === "working") return s.activity ? "working · " + s.activity : "working · " + age
        return "done · " + age
    }

    onVisibleChanged: if (!visible) { inputFor = ""; asking = false }

    ColumnLayout {
        id: column
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Kirigami.Units.largeSpacing }
        spacing: Kirigami.Units.smallSpacing

        // ------------------------------------------------------- header
        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents3.Label {
                text: "SESSIONS · " + (card.pd ? card.pd.sessions.length : 0)
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                font.weight: Font.DemiBold
                font.letterSpacing: 1.2
                opacity: 0.6
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents3.ToolButton {
                visible: !card.peek
                text: card.asking ? "cancel" : "+ NEW"
                flat: true
                enabled: card.online
                font: Kirigami.Theme.smallFont
                onClicked: {
                    card.asking = !card.asking
                    if (card.asking) { card.inputFor = ""; askField.forceActiveFocus() }
                }
                PlasmaComponents3.ToolTip.text: "Start a hands-free Claude session" + (card.pd && card.pd.hotkey ? " (" + card.pd.hotkey + ")" : "")
                PlasmaComponents3.ToolTip.visible: hovered
            }
        }

        // ------------------------------------------------------ ask field
        RowLayout {
            Layout.fillWidth: true
            visible: card.asking
            PlasmaComponents3.TextField {
                id: askField
                Layout.fillWidth: true
                placeholderText: "Ask " + (card.pd ? card.pd.voice.name : "Jarvis") + " for something…"
                onAccepted: card.sendAsk()
                Keys.onEscapePressed: card.asking = false
            }
            PlasmaComponents3.ToolButton {
                icon.name: "document-send"
                enabled: askField.text.trim().length > 0
                onClicked: card.sendAsk()
            }
        }

        // ------------------------------------------------------- offline
        PlasmaComponents3.Label {
            visible: !card.online
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "The cc-pill daemon isn't running.\nsystemctl --user status cc-pill"
            opacity: 0.7
        }

        PlasmaComponents3.Label {
            visible: card.online && card.sorted.length === 0
            Layout.fillWidth: true
            text: "No Claude Code sessions right now."
            opacity: 0.7
        }

        // --------------------------------------------------------- rows
        Repeater {
            model: card.sorted
            delegate: ColumnLayout {
                id: row
                required property var modelData
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        width: 8; height: 8; radius: 4
                        color: card.ctl ? card.ctl.stateColor(row.modelData.state) : "gray"
                        Layout.alignment: Qt.AlignVCenter
                        Behavior on color { ColorAnimation { duration: 300 } }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            PlasmaComponents3.Label {
                                text: row.modelData.repo
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                                Layout.maximumWidth: Kirigami.Units.gridUnit * 10
                            }
                            PlasmaComponents3.Label {
                                visible: row.modelData.remote
                                text: "ssh"
                                font: Kirigami.Theme.smallFont
                                opacity: 0.5
                            }
                        }
                        PlasmaComponents3.Label {
                            text: card.detail(row.modelData)
                            font: Kirigami.Theme.smallFont
                            opacity: 0.6
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }

                    PlasmaComponents3.ToolButton {
                        icon.name: "media-playback-start"
                        enabled: !!row.modelData.last_briefing && !!card.pd && card.pd.voice.available
                        onClicked: card.ctl.post("/recap", { sid: row.modelData.id })
                        PlasmaComponents3.ToolTip.text: row.modelData.last_briefing ? "Play recap" : "No briefing yet"
                        PlasmaComponents3.ToolTip.visible: hovered
                    }
                    PlasmaComponents3.ToolButton {
                        visible: !card.peek
                        icon.name: "mail-message-new"
                        checked: card.inputFor === row.modelData.id
                        onClicked: {
                            card.asking = false
                            card.inputFor = card.inputFor === row.modelData.id ? "" : row.modelData.id
                        }
                        PlasmaComponents3.ToolTip.text: "Send a prompt to this session"
                        PlasmaComponents3.ToolTip.visible: hovered
                    }
                    PlasmaComponents3.ToolButton {
                        icon.name: "utilities-terminal"
                        onClicked: {
                            card.ctl.post("/terminal", { sid: row.modelData.id })
                            card.ctl.expanded = false
                        }
                        PlasmaComponents3.ToolTip.text: "Open terminal"
                        PlasmaComponents3.ToolTip.visible: hovered
                    }
                }

                // the last briefing, so a summary that crawled past can be read later
                PlasmaComponents3.Label {
                    visible: !!row.modelData.last_briefing
                    text: row.modelData.last_briefing || ""
                    font: Kirigami.Theme.smallFont
                    opacity: 0.75
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    Layout.leftMargin: 8 + Kirigami.Units.smallSpacing
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8 + Kirigami.Units.smallSpacing
                    visible: card.inputFor === row.modelData.id
                    onVisibleChanged: if (visible) promptField.forceActiveFocus()
                    PlasmaComponents3.TextField {
                        id: promptField
                        Layout.fillWidth: true
                        placeholderText: "Prompt for " + row.modelData.repo + "…"
                        onAccepted: sendButton.clicked()
                        Keys.onEscapePressed: card.inputFor = ""
                    }
                    PlasmaComponents3.ToolButton {
                        id: sendButton
                        icon.name: "document-send"
                        enabled: promptField.text.trim().length > 0
                        onClicked: {
                            const t = promptField.text.trim()
                            if (!t.length) return
                            card.ctl.post("/prompt", { sid: row.modelData.id, text: t })
                            promptField.text = ""
                            card.inputFor = ""
                        }
                    }
                }
            }
        }

        // -------------------------------------------------------- footer
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            height: 1
            color: Kirigami.Theme.textColor
            opacity: 0.12
        }

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents3.Label {
                text: {
                    if (!card.pd) return ""
                    const v = card.pd.voice
                    if (!v.available) return v.name + " · voice not installed"
                    return v.name + " · " + (v.muted ? "muted" : "speaking")
                }
                font: Kirigami.Theme.smallFont
                opacity: 0.6
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents3.ToolButton {
                visible: card.pd && card.pd.voice.available
                text: card.pd && card.pd.voice.muted ? "unmute" : "mute"
                flat: true
                font: Kirigami.Theme.smallFont
                onClicked: card.ctl.post("/mute", {})
            }
        }

        PlasmaComponents3.Label {
            visible: card.peek
            text: "Click the pill to type a prompt or start a session."
            font: Kirigami.Theme.smallFont
            opacity: 0.5
            Layout.fillWidth: true
            elide: Text.ElideRight
        }

        PlasmaComponents3.Label {
            visible: card.pd && card.pd.toast
            text: card.pd && card.pd.toast ? card.pd.toast : ""
            font: Kirigami.Theme.smallFont
            color: card.theme ? card.theme.amber : Kirigami.Theme.textColor
            Layout.fillWidth: true
            elide: Text.ElideRight
        }
    }

    function sendAsk() {
        const t = askField.text.trim()
        if (!t.length) return
        card.ctl.post("/ask", { text: t })
        askField.text = ""
        card.asking = false
    }
}
