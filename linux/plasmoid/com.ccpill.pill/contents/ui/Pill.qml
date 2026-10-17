/*
 * The pill: compact representation living in the Plasma panel.
 *
 * Hidden when nothing is running. Resting: sun or moon and one dot per
 * session. Working: live narration of what Claude is doing, cats taking
 * laps. Needs you: amber ping and a tapping paw. Briefing: the pill widens
 * and the words fill in, paced to the audio. Turn-end moments: a cat sits
 * for a gold star, or slinks off with ears back.
 */
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

Item {
    id: pillRoot

    property var ctl   // the PlasmoidItem in main.qml

    readonly property var pd: ctl ? ctl.pillData : null
    readonly property QtObject theme: ctl ? ctl.theme : null
    readonly property string st: ctl ? ctl.pillState : "hidden"
    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property bool compact: vertical || height < 20

    readonly property var briefing: pd && st === "speaking" ? pd.briefing : null
    readonly property var moment: pd && st === "moment" ? pd.moment : null
    readonly property var sessions: pd ? pd.sessions : []

    // ------------------------------------------------------------ sizing

    readonly property bool nativeLook: theme ? theme.nativeLook : true
    readonly property real pillH: Math.max(16, Math.min(height - 2, 27))
    readonly property real padH: nativeLook ? Kirigami.Units.smallSpacing * 1.5 : Math.round(pillH * 0.4)
    readonly property real maxW: 430

    readonly property real targetW: {
        if (st === "hidden") return 0
        if (compact) return pillH * 2.6
        if (st === "idle" && !nativeLook) return 70
        return Math.min(maxW, content.implicitWidth + padH * 2)
    }

    property real animW: targetW
    Behavior on animW {
        NumberAnimation {
            duration: pillRoot.nativeLook ? 250 : 420
            easing.type: pillRoot.nativeLook ? Easing.OutCubic : Easing.OutBack
            easing.overshoot: 0.45
        }
    }

    Layout.minimumWidth: vertical ? -1 : animW
    Layout.preferredWidth: vertical ? -1 : animW
    Layout.maximumWidth: vertical ? -1 : animW
    Layout.fillHeight: !vertical
    Layout.fillWidth: vertical
    Layout.preferredHeight: vertical ? pillH + 4 : -1
    Layout.minimumHeight: vertical ? pillH + 4 : -1

    // ----------------------------------------------------------- helpers

    function blend(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
    }

    function esc(w) {
        return w.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // Words fill in as they are spoken: the first N bright, the rest faint.
    function bloomText() {
        const b = briefing
        if (!b || !theme) return ""
        const words = b.text.split(/\s+/).filter(w => w.length > 0)
        let shown = words.length
        if (!b.silent && b.duration > 0) {
            shown = Math.min(words.length, Math.ceil(Math.min(1, ctl.elapsed(b.started) / b.duration) * words.length))
        }
        const dim = theme.nativeLook ? Qt.rgba(theme.ink.r, theme.ink.g, theme.ink.b, 0.35).toString()
                                 : blend(theme.bg, theme.ink, 0.2).toString()
        return words.map((w, i) => i < shown ? esc(w) : '<font color="' + dim + '">' + esc(w) + '</font>').join(" ")
    }

    readonly property bool audioPlaying: briefing !== null && !briefing.silent
                                         && ctl.elapsed(briefing.started) < briefing.duration

    readonly property string labelText: {
        if (!pd) return ""
        if (st === "working") return pd.pill.narration || pd.pill.label
        if (st === "waiting") return "needs you"
        if (st === "speaking") return bloomText()
        return ""
    }

    // -------------------------------------------------------------- pill

    Rectangle {
        id: pill
        anchors.centerIn: parent
        width: Math.max(0, Math.min(pillRoot.animW, pillRoot.width))
        height: pillRoot.pillH
        radius: height / 2
        visible: width > 1 && pillRoot.theme !== null
        color: pillRoot.theme ? pillRoot.theme.bg : "transparent"
        border.width: 1
        border.color: pillRoot.theme ? pillRoot.theme.line : "transparent"
        clip: true

        Behavior on color { ColorAnimation { duration: 600 } }
        Behavior on border.color { ColorAnimation { duration: 600 } }

        // gloss: a soft highlight across the top half (porcelain), barely there at night
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 1 }
            height: parent.height * 0.5
            radius: parent.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, pillRoot.theme ? pillRoot.theme.gloss * 0.9 : 0) }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }

        // ember breathing behind the cats at night (porcelain only)
        Rectangle {
            visible: pillRoot.theme && !pillRoot.nativeLook && pillRoot.theme.night && pillRoot.st === "working"
            anchors.centerIn: parent
            width: parent.width * 0.7
            height: parent.height * 1.4
            radius: height / 2
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.5; color: Qt.rgba(0.85, 0.57, 0.23, 0.22) }
                GradientStop { position: 1.0; color: "transparent" }
            }
            SequentialAnimation on opacity {
                running: visible
                loops: Animation.Infinite
                NumberAnimation { to: 1.0; duration: 1600; easing.type: Easing.InOutSine }
                NumberAnimation { to: 0.35; duration: 1600; easing.type: Easing.InOutSine }
            }
        }

        Row {
            id: content
            anchors.centerIn: parent
            spacing: Math.round(pillRoot.pillH * 0.22)

            // sun by day, crescent moon at night (porcelain only)
            Canvas {
                id: glyph
                width: Math.round(pillRoot.pillH * 0.52)
                height: width
                anchors.verticalCenter: parent.verticalCenter
                visible: pillRoot.st !== "speaking" && !pillRoot.nativeLook
                readonly property bool night: pillRoot.theme ? pillRoot.theme.night : false
                readonly property color gold: pillRoot.theme ? pillRoot.theme.gold : "#A88117"
                onNightChanged: requestPaint()
                onGoldChanged: requestPaint()
                onWidthChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    ctx.clearRect(0, 0, width, height)
                    const c = width / 2, r = width * 0.26
                    ctx.fillStyle = gold
                    ctx.strokeStyle = gold
                    if (night) {
                        ctx.beginPath(); ctx.arc(c, c, r * 1.45, 0, Math.PI * 2); ctx.fill()
                        ctx.globalCompositeOperation = "destination-out"
                        ctx.beginPath(); ctx.arc(c + r * 0.95, c - r * 0.4, r * 1.45, 0, Math.PI * 2); ctx.fill()
                        ctx.globalCompositeOperation = "source-over"
                    } else {
                        ctx.beginPath(); ctx.arc(c, c, r, 0, Math.PI * 2); ctx.fill()
                        ctx.lineWidth = Math.max(1, width * 0.08)
                        for (let i = 0; i < 8; i++) {
                            const a = i * Math.PI / 4
                            ctx.beginPath()
                            ctx.moveTo(c + Math.cos(a) * r * 1.5, c + Math.sin(a) * r * 1.5)
                            ctx.lineTo(c + Math.cos(a) * r * 1.95, c + Math.sin(a) * r * 1.95)
                            ctx.stroke()
                        }
                    }
                }
            }

            // one dot per session
            Row {
                id: dots
                spacing: Math.round(pillRoot.pillH * 0.16)
                anchors.verticalCenter: parent.verticalCenter
                visible: pillRoot.st !== "speaking" && pillRoot.st !== "moment" && pillRoot.sessions.length > 0
                Repeater {
                    model: pillRoot.sessions
                    delegate: Rectangle {
                        id: dot
                        required property var modelData
                        width: Math.round(pillRoot.pillH * (pillRoot.nativeLook ? 0.24 : 0.18))
                        height: width
                        radius: width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: pillRoot.ctl ? pillRoot.ctl.stateColor(modelData.state) : "gray"
                        Behavior on color { ColorAnimation { duration: 300 } }
                        // the amber ping
                        SequentialAnimation on scale {
                            running: dot.modelData.state === "waiting" && dot.visible
                            loops: Animation.Infinite
                            NumberAnimation { to: 1.55; duration: 500; easing.type: Easing.OutQuad }
                            NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InQuad }
                            PauseAnimation { duration: 400 }
                            onRunningChanged: if (!running) dot.scale = 1
                        }
                    }
                }
            }

            // the words: narration, "needs you", or the briefing filling in
            Text {
                id: label
                anchors.verticalCenter: parent.verticalCenter
                visible: !pillRoot.compact && text.length > 0
                text: pillRoot.labelText
                textFormat: pillRoot.st === "speaking" ? Text.StyledText : Text.PlainText
                // native look: the panel's text colour, attention colour while a session waits
                color: !pillRoot.theme ? "black"
                       : (pillRoot.nativeLook && pillRoot.st === "waiting") ? pillRoot.theme.amber : pillRoot.theme.ink
                // native look: the panel font as-is; porcelain: sized to the pill
                readonly property font porcelainFont: Qt.font({
                    pixelSize: Math.round(pillRoot.pillH * (pillRoot.st === "speaking" ? 0.46 : 0.42)),
                    weight: Font.Medium
                })
                font: pillRoot.nativeLook ? Kirigami.Theme.defaultFont : porcelainFont
                elide: Text.ElideRight
                maximumLineCount: 1
                width: Math.min(metrics.width + 2, pillRoot.maxW - pillRoot.padH * 2 - (waves.visible ? waves.width + content.spacing : 0))
                TextMetrics { id: metrics; font: label.font; text: label.text.replace(/<[^>]+>/g, "") }
                Behavior on color { ColorAnimation { duration: 600 } }
            }

            // the paw, tapping from the right while a session needs you (porcelain)
            Paw {
                visible: pillRoot.st === "waiting" && !pillRoot.compact && !pillRoot.nativeLook
                height: Math.round(pillRoot.pillH * 0.5)
                anchors.verticalCenter: parent.verticalCenter
                color: pillRoot.theme ? pillRoot.theme.amber : "#B26E1C"
            }

            // wave bars while the voice is speaking
            Row {
                id: waves
                visible: pillRoot.st === "speaking" && pillRoot.audioPlaying
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter
                Repeater {
                    model: 4
                    delegate: Rectangle {
                        required property int index
                        width: 2.5
                        radius: 1.25
                        anchors.verticalCenter: parent.verticalCenter
                        color: pillRoot.theme ? pillRoot.theme.gold : "#A88117"
                        height: 4
                        SequentialAnimation on height {
                            running: waves.visible
                            loops: Animation.Infinite
                            NumberAnimation { to: pillRoot.pillH * (0.38 + 0.12 * ((index * 7) % 3)); duration: 160 + index * 45; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 4; duration: 190 + index * 35; easing.type: Easing.InOutSine }
                        }
                    }
                }
            }

            // turn-end moment without the cats: a plain Breeze check or warning
            Kirigami.Icon {
                visible: pillRoot.moment !== null && !pillRoot.compact && !(pillRoot.ctl && pillRoot.ctl.showCats)
                source: pillRoot.moment && pillRoot.moment.kind === "sad" ? "dialog-warning" : "checkmark"
                color: pillRoot.theme ? (pillRoot.moment && pillRoot.moment.kind === "sad" ? pillRoot.theme.amber : pillRoot.theme.sage) : "gray"
                isMask: true
                width: Math.round(pillRoot.pillH * 0.6)
                height: width
                anchors.verticalCenter: parent.verticalCenter
            }

            // turn-end moment with the cats: one sits for a star, or walks off sad
            Item {
                id: momentBox
                visible: pillRoot.moment !== null && !pillRoot.compact && pillRoot.ctl && pillRoot.ctl.showCats
                width: pillRoot.moment && pillRoot.moment.kind === "sad" ? 110 : 64
                height: pillRoot.pillH
                anchors.verticalCenter: parent.verticalCenter
                clip: true

                Critter {
                    id: momentCat
                    height: Math.round(pillRoot.pillH * 0.66)
                    y: parent.height - height - 1
                    night: pillRoot.theme ? pillRoot.theme.night : false
                    kind: pillRoot.moment ? pillRoot.moment.critter : "charlie"
                    pose: pillRoot.moment && pillRoot.moment.kind === "sad" ? "sad" : "sit"
                    x: pose === "sit" ? 4 : 0
                    NumberAnimation on x {
                        running: momentBox.visible && momentCat.pose === "sad"
                        from: -momentCat.width * 0.3
                        to: momentBox.width
                        duration: 3000
                    }
                }

                Text {
                    id: star
                    visible: pillRoot.moment && pillRoot.moment.kind === "star"
                    text: "★"
                    color: pillRoot.theme ? pillRoot.theme.gold : "#A88117"
                    font.pixelSize: Math.round(pillRoot.pillH * 0.5)
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: -1
                    x: momentCat.x + momentCat.width + 6
                    transformOrigin: Item.Center
                    SequentialAnimation on scale {
                        running: star.visible
                        NumberAnimation { from: 0; to: 1.3; duration: 260; easing.type: Easing.OutBack }
                        NumberAnimation { to: 1.0; duration: 180 }
                    }
                }
            }
        }

        // the cats, taking laps while Claude works
        Item {
            id: lane
            anchors.fill: parent
            visible: pillRoot.st === "working" && pillRoot.ctl && pillRoot.ctl.showCats && !pillRoot.compact

            Critter {
                id: runner
                height: Math.round(pillRoot.pillH * 0.62)
                y: lane.height - height - 1
                night: pillRoot.theme ? pillRoot.theme.night : false
                visible: laps.running
                opacity: 0.92
                animating: laps.running
            }

            readonly property int lapMs: Math.max(1400, Math.round((pill.width + runner.width) / 58 * 1000))

            SequentialAnimation {
                id: laps
                running: lane.visible
                loops: Animation.Infinite
                ScriptAction { script: { runner.kind = "charlie"; runner.flip = false } }
                NumberAnimation { target: runner; property: "x"; from: -runner.width; to: pill.width; duration: lane.lapMs }
                PauseAnimation { duration: 1100 }
                ScriptAction { script: { runner.kind = "lily"; runner.flip = true } }
                NumberAnimation { target: runner; property: "x"; from: pill.width; to: -runner.width; duration: lane.lapMs }
                PauseAnimation { duration: 1100 }
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (pillRoot.ctl) pillRoot.ctl.expanded = !pillRoot.ctl.expanded
        }
    }
}
