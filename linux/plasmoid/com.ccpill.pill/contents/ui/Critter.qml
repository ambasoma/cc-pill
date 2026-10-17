/*
 * The critters: Charlie (tuxedo cat) and Lily (white cat, brown tabby head).
 * Drawn on a Canvas in a 34x17 local space scaled to the item height, like
 * the Swift original. Poses: run (gallop, bobbing), sad (slow walk, ears
 * back, tail down) and sit (upright, tail curled, the occasional blink).
 */
import QtQuick

Canvas {
    id: cat

    property string kind: "charlie"   // charlie | lily
    property string pose: "run"       // run | sad | sit
    property bool flip: false         // face left instead of right
    property bool night: false
    property bool animating: true
    property real t: 0

    readonly property real s: height / 17
    width: 34 * s

    onKindChanged: requestPaint()
    onPoseChanged: requestPaint()
    onFlipChanged: requestPaint()
    onNightChanged: requestPaint()
    onHeightChanged: requestPaint()

    Timer {
        interval: 33
        running: cat.animating && cat.visible && cat.opacity > 0
        repeat: true
        onTriggered: {
            cat.t += 0.033
            cat.requestPaint()
        }
    }

    function colors() {
        const night = cat.night
        const white = night ? "#F3EDD9" : "#FBF7EC"
        const dark = night ? "#232019" : "#211F1C"
        const lily = cat.kind === "lily"
        return {
            body: lily ? white : dark,
            head: lily ? "#A6742F" : dark,
            white: white,
            outline: night ? "rgba(243,237,217,0.55)" : "rgba(42,38,32,0.25)",
            stripe: "#43301A",
            cheek: "#E89AA4",
            eye: lily ? "#1A1612" : (night ? "#F3EDD9" : "#FBF7EC"),
            lily: lily
        }
    }

    function ellipse(ctx, cx, cy, rx, ry) {
        ctx.beginPath()
        ctx.ellipse(cx - rx, cy - ry, rx * 2, ry * 2)
        ctx.closePath()
    }

    function tri(ctx, a, b, c) {
        ctx.beginPath()
        ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.lineTo(c[0], c[1])
        ctx.closePath()
    }

    // Limbs are body-coloured strokes with the thin outline around them, like
    // the Swift rounded rects: without it Lily's white legs vanish on porcelain.
    function limb(ctx, w, c) {
        ctx.strokeStyle = c.outline; ctx.lineWidth = w + 1.2; ctx.stroke()
        ctx.strokeStyle = c.body; ctx.lineWidth = w; ctx.stroke()
    }

    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)
        ctx.save()
        ctx.scale(s, s)
        if (flip) { ctx.translate(34, 0); ctx.scale(-1, 1) }
        const c = colors()
        ctx.lineCap = "round"
        ctx.lineJoin = "round"
        if (pose === "sit") drawSitting(ctx, c)
        else drawWalking(ctx, c)
        ctx.restore()
    }

    function drawWalking(ctx, c) {
        const sad = pose === "sad"
        const gait = sad ? 0.72 : 0.26
        const bobAmp = sad ? 0.4 : 1.2
        const swing = (sad ? 14 : 26) * Math.PI / 180
        const ph = t * 2 * Math.PI / gait
        const bob = Math.sin(ph) * bobAmp
        ctx.translate(0, bob + (sad ? 0.6 : 0))

        // legs: back pair and front pair swing in opposition
        const legs = [[11.5, 1], [14.5, -1], [20.5, -1], [23.5, 1]]
        for (let i = 0; i < legs.length; i++) {
            const x = legs[i][0]
            const a = Math.sin(ph + (i < 2 ? 0 : Math.PI)) * swing * legs[i][1]
            const ex = x + Math.sin(a) * 4.2, ey = 12.3 + Math.cos(a) * 4.2
            ctx.beginPath()
            ctx.moveTo(x, 12.3)
            ctx.lineTo(ex, ey)
            limb(ctx, 1.7, c)
            if (!c.lily) {   // Charlie's white mitts
                ctx.strokeStyle = c.white; ctx.lineWidth = 1.1
                ctx.beginPath()
                ctx.moveTo(x + (ex - x) * 0.7, 12.3 + (ey - 12.3) * 0.7)
                ctx.lineTo(ex, ey)
                ctx.stroke()
            }
        }

        // tail
        ctx.beginPath()
        ctx.moveTo(8.8, 10.2)
        if (sad) ctx.quadraticCurveTo(5.2, 12.8, 3.4, 15.6)
        else ctx.quadraticCurveTo(4.4, 8.2 + Math.sin(ph * 0.5) * 0.6, 3.2, 3.4)
        limb(ctx, 1.6, c)

        // body
        ellipse(ctx, 17, 10.4, 8.6, 4.3)
        ctx.fillStyle = c.body; ctx.fill()
        ctx.lineWidth = 0.6; ctx.strokeStyle = c.outline; ctx.stroke()
        if (!c.lily) {   // Charlie's white chest
            ellipse(ctx, 22.4, 12, 2.6, 1.7)
            ctx.fillStyle = c.white; ctx.fill()
        }

        // head and ears
        const hx = 26.6, hy = 7.4
        ctx.fillStyle = c.head
        if (sad) {
            tri(ctx, [hx - 2.6, hy - 2.6], [hx - 5.0, hy - 4.0], [hx - 0.8, hy - 3.4]); ctx.fill()
            tri(ctx, [hx + 0.8, hy - 3.4], [hx + 4.8, hy - 3.8], [hx + 3.2, hy - 2.0]); ctx.fill()
        } else {
            tri(ctx, [hx - 2.4, hy - 2.8], [hx - 3.0, hy - 6.6], [hx - 0.4, hy - 3.6]); ctx.fill()
            tri(ctx, [hx + 0.6, hy - 3.6], [hx + 2.8, hy - 6.6], [hx + 3.0, hy - 2.6]); ctx.fill()
        }
        ellipse(ctx, hx, hy, 4.1, 3.9)
        ctx.fillStyle = c.head; ctx.fill()
        ctx.lineWidth = 0.6; ctx.strokeStyle = c.outline; ctx.stroke()
        if (c.lily) {    // tabby stripes on Lily's head
            ctx.strokeStyle = c.stripe; ctx.lineWidth = 0.8
            for (let i = -1; i <= 1; i++) {
                ctx.beginPath()
                ctx.moveTo(hx + i * 1.4 - 0.3, hy - 3.4)
                ctx.lineTo(hx + i * 1.4 + 0.3, hy - 1.6)
                ctx.stroke()
            }
        } else {         // Charlie's white muzzle
            ellipse(ctx, hx + 2.2, hy + 1.3, 1.7, 1.3)
            ctx.fillStyle = c.white; ctx.fill()
        }
        // eye and cheek
        ellipse(ctx, hx + 1.4, hy - 0.6, 0.55, 0.6)
        ctx.fillStyle = c.eye; ctx.fill()
        ellipse(ctx, hx + 2.9, hy + 0.9, 0.6, 0.45)
        ctx.fillStyle = c.cheek; ctx.globalAlpha = 0.75; ctx.fill(); ctx.globalAlpha = 1
    }

    function drawSitting(ctx, c) {
        // tail curled around the front paws
        ctx.beginPath()
        ctx.moveTo(16.2, 15.6)
        ctx.quadraticCurveTo(9.6, 17.4, 10.2, 13.2)
        limb(ctx, 1.6, c)

        // body (upright) and chest
        ellipse(ctx, 19.2, 11.2, 5.2, 5.6)
        ctx.fillStyle = c.body; ctx.fill()
        ctx.lineWidth = 0.6; ctx.strokeStyle = c.outline; ctx.stroke()
        if (!c.lily) {
            ellipse(ctx, 19.6, 12.6, 2.4, 3.0)
            ctx.fillStyle = c.white; ctx.fill()
        }
        // front legs
        ctx.beginPath(); ctx.moveTo(17.6, 13.2); ctx.lineTo(17.6, 16.6); limb(ctx, 1.7, c)
        ctx.beginPath(); ctx.moveTo(20.8, 13.2); ctx.lineTo(20.8, 16.6); limb(ctx, 1.7, c)

        // head and ears
        const hx = 19.6, hy = 5.4
        ctx.fillStyle = c.head
        tri(ctx, [hx - 2.8, hy - 2.2], [hx - 3.0, hy - 5.0], [hx - 0.6, hy - 3.4]); ctx.fill()
        tri(ctx, [hx + 0.6, hy - 3.4], [hx + 3.0, hy - 5.0], [hx + 2.8, hy - 2.2]); ctx.fill()
        ellipse(ctx, hx, hy, 3.9, 3.7)
        ctx.fillStyle = c.head; ctx.fill()
        ctx.lineWidth = 0.6; ctx.strokeStyle = c.outline; ctx.stroke()
        if (c.lily) {
            ctx.strokeStyle = c.stripe; ctx.lineWidth = 0.8
            for (let i = -1; i <= 1; i++) {
                ctx.beginPath()
                ctx.moveTo(hx + i * 1.4 - 0.3, hy - 3.2)
                ctx.lineTo(hx + i * 1.4 + 0.3, hy - 1.6)
                ctx.stroke()
            }
        } else {
            ellipse(ctx, hx, hy + 1.6, 1.9, 1.3)
            ctx.fillStyle = c.white; ctx.fill()
        }
        // eyes, with a blink every few seconds
        const blink = (t % 3.4) > 3.25
        ctx.fillStyle = c.eye; ctx.strokeStyle = c.eye; ctx.lineWidth = 0.6
        for (const ex of [hx - 1.3, hx + 1.3]) {
            if (blink) {
                ctx.beginPath(); ctx.moveTo(ex - 0.6, hy - 0.2); ctx.lineTo(ex + 0.6, hy - 0.2); ctx.stroke()
            } else {
                ellipse(ctx, ex, hy - 0.3, 0.55, 0.65); ctx.fill()
            }
        }
        ellipse(ctx, hx + 2.6, hy + 1.0, 0.6, 0.45)
        ctx.fillStyle = c.cheek; ctx.globalAlpha = 0.75; ctx.fill(); ctx.globalAlpha = 1
    }
}
