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
    // The words live in a slot of fixed width (ctl.slotChars average characters)
    // so the panel never shuffles while traces stream; see SlideText.qml.
    readonly property bool customFont: ctl ? ctl.customFont : false
    readonly property font labelFont: customFont ? ctl.customFontValue : nativeLook ? Kirigami.Theme.defaultFont : porcelainFont
    readonly property font porcelainFont: Qt.font({ pixelSize: Math.round(pillH * 0.42), weight: Font.Medium })
    readonly property font speakFont: customFont ? ctl.customFontValue : nativeLook ? Kirigami.Theme.defaultFont
                                                 : Qt.font({ pixelSize: Math.round(pillH * 0.46), weight: Font.Medium })
    // extra clickable (and hoverable) room on each side of the pill
    readonly property int hit: ctl ? Math.max(0, ctl.hitPadding) : 0
    TextMetrics { id: slotMetrics; font: pillRoot.labelFont; text: "n".repeat(pillRoot.ctl ? pillRoot.ctl.slotChars : 22) }
    readonly property real slotW: Math.ceil(slotMetrics.width)
    readonly property real padH: nativeLook ? Kirigami.Units.smallSpacing * 1.5 : Math.round(pillH * 0.4)
    readonly property real maxW: 430

    // No sessions: either gone entirely (the Mac way) or parked as a faint
    // dot, so the widget can still be found, hovered and clicked, and so an
    // offline daemon is discoverable through the tooltip.
    readonly property bool parked: st === "hidden" && ctl && ctl.idleDot

    readonly property real targetW: {
        if (st === "hidden") return parked ? Math.round(pillH * 0.24) + padH * 2 : 0
        if (compact) return pillH * 2.6
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

    readonly property real outerW: animW > 0 ? animW + hit * 2 : 0
    Layout.minimumWidth: vertical ? -1 : outerW
    Layout.preferredWidth: vertical ? -1 : outerW
    Layout.maximumWidth: vertical ? -1 : outerW
    Layout.fillHeight: !vertical
    Layout.fillWidth: vertical
    Layout.preferredHeight: vertical ? pillH + 4 + hit * 2 : -1
    Layout.minimumHeight: vertical ? pillH + 4 + hit * 2 : -1

    // ----------------------------------------------------------- helpers

    function blend(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
    }

    // Words fill in as they are spoken: the first N bright, the rest faint
    // (the bloom itself lives in main.qml; this picks the faint colour).
    function bloomText() {
        if (!theme) return ""
        const dim = theme.nativeLook ? Qt.rgba(theme.ink.r, theme.ink.g, theme.ink.b, 0.35).toString()
                                 : blend(theme.bg, theme.ink, 0.2).toString()
        return ctl.bloomHtml(dim)
    }

    readonly property bool audioPlaying: briefing !== null && !briefing.silent
                                         && ctl.elapsed(briefing.started) < briefing.duration
    readonly property real bloomProgress: ctl ? ctl.bloomProgress : 0
    readonly property string briefingMode: ctl ? ctl.briefingMode : "popup"

    readonly property string labelText: {
        if (!pd) return ""
        if (st === "working") return pd.pill.narration || pd.pill.label
        if (st === "waiting") return "needs you"
        if (st === "speaking") return briefingMode === "popup" ? ((briefing && briefing.repo) || "briefing") : bloomText()
        if (st === "idle") return sessions.length === 1 ? "done" : sessions.length + " done"
        if (st === "moment") return pd.moment && pd.moment.kind === "sad" ? "ran into trouble" : "done"
        return ""
    }

    // -------------------------------------------------------------- pill

    Rectangle {
        id: pill
        anchors.centerIn: parent
        width: Math.max(0, Math.min(pillRoot.animW, pillRoot.width))
        height: pillRoot.pillH
        radius: pillRoot.theme ? Math.max(0, Math.min(height / 2, pillRoot.theme.cornerRadius)) : height / 2
        visible: width > 1 && pillRoot.theme !== null
        color: pillRoot.theme ? pillRoot.theme.bg : "transparent"
        border.width: pillRoot.theme ? pillRoot.theme.borderWidth : 0
        border.color: pillRoot.theme && border.width > 0 ? pillRoot.theme.line : "transparent"
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

            // the parked dot: no sessions (or no daemon)
            Rectangle {
                id: idleDot
                visible: pillRoot.parked
                width: Math.round(pillRoot.pillH * 0.24)
                height: width
                radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: pillRoot.theme ? pillRoot.theme.ink : "gray"
                opacity: hitArea.containsMouse ? 0.7 : 0.3
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }

            // one dot per session
            Row {
                id: dots
                spacing: Math.round(pillRoot.pillH * 0.16)
                anchors.verticalCenter: parent.verticalCenter
                // stays through briefings so the widget's width never moves;
                // the moment icon takes its place for a turn-end moment
                visible: pillRoot.st !== "moment" && pillRoot.sessions.length > 0
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

            // turn-end moment without the cats: a plain Breeze check or warning
            // where the dots were
            Kirigami.Icon {
                id: momentIcon
                visible: pillRoot.moment !== null && !pillRoot.compact && !(pillRoot.ctl && pillRoot.ctl.showCats)
                source: pillRoot.moment && pillRoot.moment.kind === "sad" ? "dialog-warning" : "checkmark"
                color: pillRoot.theme ? (pillRoot.moment && pillRoot.moment.kind === "sad" ? pillRoot.theme.amber : pillRoot.theme.sage) : "gray"
                isMask: true
                width: Math.round(pillRoot.pillH * 0.6)
                height: momentIcon.width
                anchors.verticalCenter: content.verticalCenter
            }

            // the words: narration, "needs you", "done", or the briefing filling
            // in. A fixed-width slot while sessions live; the briefing widens it.
            Item {
                id: slot
                anchors.verticalCenter: parent.verticalCenter
                visible: !pillRoot.compact && pillRoot.st !== "hidden"
                // the bloom text is only in the slot for the "widen" and "slot"
                // modes; "popup" shows the repo name here and blooms outward
                readonly property bool speaking: pillRoot.st === "speaking" && pillRoot.briefingMode !== "popup"
                // "widen": the Mac way, the pill grows to fit the briefing
                TextMetrics { id: briefMetrics; font: pillRoot.speakFont; text: pillRoot.briefing ? pillRoot.briefing.text : "" }
                width: slot.speaking && pillRoot.briefingMode === "widen"
                       ? Math.max(pillRoot.slotW, Math.min(Math.ceil(briefMetrics.width) + 6, pillRoot.maxW - pillRoot.pillH * 3))
                       : pillRoot.slotW
                height: pillRoot.pillH
                clip: true

                readonly property color ink: !pillRoot.theme ? "black"
                    : (pillRoot.nativeLook && pillRoot.st === "waiting") ? pillRoot.theme.amber : pillRoot.theme.ink

                SlideText { id: textA; slotWidth: slot.width; height: slot.height; verticalAlignment: Text.AlignVCenter
                            crawl: slot.speaking ? pillRoot.bloomProgress : -1
                            font: slot.speaking ? pillRoot.speakFont : pillRoot.labelFont; color: slot.ink
                            textFormat: slot.speaking ? Text.StyledText : Text.PlainText
                            Behavior on color { ColorAnimation { duration: 600 } } }
                SlideText { id: textB; slotWidth: slot.width; height: slot.height; verticalAlignment: Text.AlignVCenter
                            crawl: slot.speaking ? pillRoot.bloomProgress : -1
                            font: slot.speaking ? pillRoot.speakFont : pillRoot.labelFont; color: slot.ink; opacity: 0
                            textFormat: slot.speaking ? Text.StyledText : Text.PlainText
                            Behavior on color { ColorAnimation { duration: 600 } } }

                property Item front: textA
                property Item back: textB

                // Swap choreography, as on the Mac: the outgoing text slides down
                // out of the slot while the incoming one fades in. Bloom updates
                // while speaking just replace the text.
                function swap(t) {
                    if (slot.speaking || slot.front.text === "" || t === "") {
                        leaveY.stop(); leaveO.stop(); arriveO.stop()
                        slot.front.text = t; slot.front.y = 0; slot.front.opacity = 1
                        slot.back.text = ""; slot.back.opacity = 0
                        return
                    }
                    if (slot.front.text === t) return
                    leaveY.stop(); leaveO.stop(); arriveO.stop()
                    const f = slot.front, b = slot.back
                    b.text = t; b.y = 0; b.opacity = 0
                    slot.front = b; slot.back = f
                    leaveY.target = f; leaveO.target = f; arriveO.target = b
                    leaveY.start(); leaveO.start(); arriveO.start()
                }
                NumberAnimation { id: leaveY; property: "y"; to: slot.height; duration: 380; easing.type: Easing.OutCubic
                                  onFinished: { if (leaveY.target) { leaveY.target.text = ""; leaveY.target.y = 0 } } }
                NumberAnimation { id: leaveO; property: "opacity"; to: 0; duration: 220 }
                NumberAnimation { id: arriveO; property: "opacity"; to: 1; duration: 240 }

                Connections { target: pillRoot; function onLabelTextChanged() { slot.swap(pillRoot.labelText) } }
                Component.onCompleted: swap(pillRoot.labelText)
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
                visible: pillRoot.st === "speaking" && pillRoot.audioPlaying && !pillRoot.nativeLook
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter
                Repeater {
                    model: 4
                    delegate: Rectangle {
                        id: bar
                        required property int index
                        width: 2.5
                        radius: 1.25
                        anchors.verticalCenter: parent.verticalCenter
                        color: pillRoot.theme ? pillRoot.theme.gold : "#A88117"
                        height: 4
                        SequentialAnimation on height {
                            running: waves.visible
                            loops: Animation.Infinite
                            NumberAnimation { to: pillRoot.pillH * (0.38 + 0.12 * ((bar.index * 7) % 3)); duration: 160 + bar.index * 45; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 4; duration: 190 + bar.index * 35; easing.type: Easing.InOutSine }
                        }
                    }
                }
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

    }

    // The activation area: the pill plus the configured padding around it.
    // Click toggles the card; with "open on hover" the card opens once the
    // pointer has rested here for the configured delay.
    MouseArea {
        id: hitArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: pillRoot.toggle()
        onContainsMouseChanged: if (pillRoot.ctl) pillRoot.ctl.pillHovered = containsMouse
        onEntered: if (pillRoot.ctl && pillRoot.ctl.openOnHover && !pillRoot.ctl.expanded) hoverTimer.restart()
        onExited: hoverTimer.stop()
        Timer {
            id: hoverTimer
            interval: pillRoot.ctl ? Math.max(0, pillRoot.ctl.hoverDelay) : 400
            onTriggered: if (pillRoot.ctl && hitArea.containsMouse && !pillRoot.ctl.expanded) pillRoot.ctl.peekOpen = true
        }
    }

    function toggle() {
        if (!ctl) return
        ctl.peekOpen = false
        ctl.expanded = !ctl.expanded
    }

    // keyboard: the panel can focus widgets; Enter or Space opens the card
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: ctl ? ctl.toolTipMainText || "cc-pill" : "cc-pill"
    Accessible.description: ctl ? ctl.toolTipSubText : ""
    Keys.onReturnPressed: toggle()
    Keys.onEnterPressed: toggle()
    Keys.onSpacePressed: toggle()
}
