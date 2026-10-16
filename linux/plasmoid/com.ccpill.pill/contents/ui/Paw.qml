/*
 * The needs-you paw: a small amber paw print that taps while a session
 * waits on a permission prompt.
 */
import QtQuick

Canvas {
    id: paw
    property color color: "#B26E1C"
    property bool tapping: true

    readonly property real s: height / 13
    width: 14 * s

    onColorChanged: requestPaint()
    onHeightChanged: requestPaint()

    transform: Translate { id: tap }

    SequentialAnimation {
        running: paw.tapping && paw.visible
        loops: Animation.Infinite
        NumberAnimation { target: tap; property: "y"; from: 0; to: -2.2; duration: 220; easing.type: Easing.OutQuad }
        NumberAnimation { target: tap; property: "y"; to: 0; duration: 200; easing.type: Easing.InQuad }
        PauseAnimation { duration: 180 }
        NumberAnimation { target: tap; property: "y"; to: -2.2; duration: 220; easing.type: Easing.OutQuad }
        NumberAnimation { target: tap; property: "y"; to: 0; duration: 200; easing.type: Easing.InQuad }
        PauseAnimation { duration: 1100 }
    }

    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)
        ctx.scale(s, s)
        ctx.fillStyle = paw.color
        const dots = [[3.0, 5.6, 1.35], [5.6, 3.3, 1.45], [8.4, 3.3, 1.45], [11.0, 5.6, 1.35]]
        for (const d of dots) {
            ctx.beginPath()
            ctx.ellipse(d[0] - d[2], d[1] - d[2], d[2] * 2, d[2] * 2)
            ctx.fill()
        }
        ctx.beginPath()
        ctx.ellipse(7 - 3.3, 9.6 - 2.7, 6.6, 5.4)
        ctx.fill()
    }
}
