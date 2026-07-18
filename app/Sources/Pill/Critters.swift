import SwiftUI

// The critters: Charlie (tuxedo cat) and Lily (white cat, brown tabby head).
// They take turns crossing the pill while Claude works, sit for a star when a
// turn lands well, and slink off with ears back when it didn't. All drawing
// happens in a 34x17 local space, scaled to lane height.

enum CritterKind {
    case charlie, lily
}

enum CritterPose {
    case run    // full gallop, bobbing
    case sad    // slow walk, ears back, tail drooping
    case sit    // seated, tail curled
}

struct CritterColors {
    let catBody: Color
    let catWhite: Color
    let outline: Color
    let gold: Color
    let tabby: Color
    let stripe: Color
    let cheek: Color

    static func of(_ theme: Theme) -> CritterColors {
        CritterColors(
            catBody: theme.night ? Color(hex: 0x232019) : Color(hex: 0x211F1C),
            catWhite: theme.night ? Color(hex: 0xF3EDD9) : Color(hex: 0xFBF7EC),
            outline: theme.night ? Color(hex: 0xF3EDD9).opacity(0.55) : Color(hex: 0x2A2620).opacity(0.25),
            gold: theme.gold,
            tabby: Color(hex: 0xA6742F),
            stripe: Color(hex: 0x43301A),
            cheek: Color(hex: 0xE89AA4))
    }
}

// MARK: - Shared drawing

func drawCritter(_ g: GraphicsContext, kind: CritterKind, pose: CritterPose,
                 at p: CGPoint, scale: CGFloat, flip: Bool, t: Double,
                 colors: CritterColors) {
    var c = g
    c.translateBy(x: p.x, y: p.y)
    if flip {
        c.translateBy(x: 34 * scale, y: 0)
        c.scaleBy(x: -1, y: 1)
    }
    c.scaleBy(x: scale, y: scale)

    if pose == .sit {
        drawSitting(c, kind: kind, t: t, colors: colors)
        return
    }

    let gaitPeriod = pose == .sad ? 0.72 : 0.26
    let bobAmp: CGFloat = pose == .sad ? 0.4 : 1.2
    let legSwing: Double = pose == .sad ? 14 : 26
    let bob = CGFloat(sin(t * 2 * .pi / gaitPeriod)) * bobAmp
    c.translateBy(x: 0, y: -abs(bob))

    let bodyColor = kind == .charlie ? colors.catBody : colors.catWhite
    let stroke = StrokeStyle(lineWidth: 0.6)

    // legs (behind the body), alternating gait
    for (i, x) in [9.0, 13.0, 18.0, 22.0].enumerated() {
        let dir = i % 2 == 0 ? 1.0 : -1.0
        let angle = Angle(degrees: legSwing * dir * sin(t * 2 * .pi / gaitPeriod))
        var leg = c
        leg.translateBy(x: x + 1.2, y: 10)
        leg.rotate(by: angle)
        let legRect = CGRect(x: -1.2, y: 0, width: 2.4, height: 6.2)
        leg.fill(Path(roundedRect: legRect, cornerRadius: 1.2), with: .color(bodyColor))
        leg.stroke(Path(roundedRect: legRect, cornerRadius: 1.2), with: .color(colors.outline), style: stroke)
        if kind == .charlie {
            leg.fill(Path(roundedRect: CGRect(x: -1.0, y: 4.4, width: 2.0, height: 1.8),
                          cornerRadius: 0.9), with: .color(colors.catWhite))
        }
    }

    // tail: up and jaunty when running, drooped when sad
    var tail = Path()
    if pose == .sad {
        tail.move(to: CGPoint(x: 6.5, y: 8.5))
        tail.addQuadCurve(to: CGPoint(x: 1.6, y: 13.5), control: CGPoint(x: 1.8, y: 9.5))
        tail.addQuadCurve(to: CGPoint(x: 6.5, y: 6.8), control: CGPoint(x: 3.4, y: 9.8))
    } else {
        tail.move(to: CGPoint(x: 5, y: 8))
        tail.addQuadCurve(to: CGPoint(x: 2.5, y: 2), control: CGPoint(x: 1.5, y: 6.5))
        tail.addQuadCurve(to: CGPoint(x: 6.5, y: 6.8), control: CGPoint(x: 3.2, y: 5.5))
    }
    tail.closeSubpath()
    c.fill(tail, with: .color(bodyColor))
    c.stroke(tail, with: .color(colors.outline), style: stroke)

    // body
    let body = Path(ellipseIn: CGRect(x: 6.5, y: 4, width: 18, height: 8.8))
    c.fill(body, with: .color(bodyColor))
    c.stroke(body, with: .color(colors.outline), style: stroke)
    if kind == .charlie {
        c.fill(Path(ellipseIn: CGRect(x: 18.3, y: 8.3, width: 6.4, height: 4.6)),
               with: .color(colors.catWhite))
    }

    // head + ears (ears sweep back when sad)
    let head = Path(ellipseIn: CGRect(x: 22.1, y: 1.6, width: 8.8, height: 8.8))
    var earL = Path()
    var earR = Path()
    if pose == .sad {
        earL.move(to: CGPoint(x: 23.2, y: 3.8))
        earL.addLine(to: CGPoint(x: 21.4, y: 1.6)); earL.addLine(to: CGPoint(x: 25.6, y: 2.7))
        earR.move(to: CGPoint(x: 27.6, y: 3.3))
        earR.addLine(to: CGPoint(x: 25.4, y: 0.7)); earR.addLine(to: CGPoint(x: 28.6, y: 2.3))
    } else {
        earL.move(to: CGPoint(x: 23.2, y: 3.6))
        earL.addLine(to: CGPoint(x: 23.9, y: 0.3)); earL.addLine(to: CGPoint(x: 26.3, y: 2.5))
        earR.move(to: CGPoint(x: 29.8, y: 3.6))
        earR.addLine(to: CGPoint(x: 29.1, y: 0.3)); earR.addLine(to: CGPoint(x: 26.7, y: 2.5))
    }
    earL.closeSubpath(); earR.closeSubpath()
    let headColor = kind == .charlie ? colors.catBody : colors.catWhite
    c.fill(earL, with: .color(kind == .charlie ? colors.catBody : colors.tabby))
    c.fill(earR, with: .color(kind == .charlie ? colors.catBody : colors.tabby))
    c.fill(head, with: .color(headColor))
    c.stroke(head, with: .color(colors.outline), style: stroke)

    if kind == .charlie {
        c.fill(Path(ellipseIn: CGRect(x: 25.6, y: 6.0, width: 4.6, height: 3.4)),
               with: .color(colors.catWhite))
        if pose == .sad {
            var eye = Path()
            eye.move(to: CGPoint(x: 27.4, y: 5.2))
            eye.addQuadCurve(to: CGPoint(x: 29.0, y: 5.2), control: CGPoint(x: 28.2, y: 4.5))
            c.stroke(eye, with: .color(colors.gold), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        } else {
            c.fill(Path(ellipseIn: CGRect(x: 27.4, y: 4.1, width: 1.6, height: 1.6)),
                   with: .color(colors.gold))
        }
    } else {
        var cap = Path()
        cap.move(to: CGPoint(x: 22.3, y: 6.2))
        cap.addQuadCurve(to: CGPoint(x: 26.5, y: 1.6), control: CGPoint(x: 22.6, y: 2.2))
        cap.addQuadCurve(to: CGPoint(x: 30.7, y: 6.2), control: CGPoint(x: 30.4, y: 2.2))
        cap.addQuadCurve(to: CGPoint(x: 22.3, y: 6.2), control: CGPoint(x: 26.5, y: 4.6))
        cap.closeSubpath()
        c.fill(cap, with: .color(colors.tabby))
        for dx in [-2.4, 0.0, 2.4] {
            var s = Path()
            s.move(to: CGPoint(x: 26.5 + dx, y: 2.2))
            s.addLine(to: CGPoint(x: 26.5 + dx * 1.15, y: 4.2))
            c.stroke(s, with: .color(colors.stripe),
                     style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        }
        var eye = Path()
        eye.move(to: CGPoint(x: 27.3, y: 6.4))
        eye.addQuadCurve(to: CGPoint(x: 29.0, y: 6.4), control: CGPoint(x: 28.15, y: 7.2))
        c.stroke(eye, with: .color(colors.stripe),
                 style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        c.fill(Path(ellipseIn: CGRect(x: 24.6, y: 7.2, width: 1.8, height: 1.8)),
               with: .color(colors.cheek))
    }
}

/// Seated pose, drawn centered-ish in the 34x17 space.
private func drawSitting(_ c: GraphicsContext, kind: CritterKind, t: Double,
                         colors: CritterColors) {
    let bodyColor = kind == .charlie ? colors.catBody : colors.catWhite
    let stroke = StrokeStyle(lineWidth: 0.6)

    // curled tail at the base
    var tail = Path()
    tail.move(to: CGPoint(x: 21.5, y: 15.2))
    tail.addQuadCurve(to: CGPoint(x: 26.5, y: 13.2), control: CGPoint(x: 26.6, y: 16.6))
    c.stroke(tail, with: .color(bodyColor), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

    // squat body
    let body = Path(ellipseIn: CGRect(x: 11, y: 6.5, width: 12, height: 10))
    c.fill(body, with: .color(bodyColor))
    c.stroke(body, with: .color(colors.outline), style: stroke)
    if kind == .charlie {
        c.fill(Path(ellipseIn: CGRect(x: 14, y: 9, width: 6, height: 6.6)),
               with: .color(colors.catWhite))
    }
    // front paws
    let pawColor = kind == .charlie ? colors.catWhite : colors.catWhite
    c.fill(Path(roundedRect: CGRect(x: 14.2, y: 14.6, width: 2.2, height: 1.9), cornerRadius: 0.9),
           with: .color(pawColor))
    c.fill(Path(roundedRect: CGRect(x: 17.4, y: 14.6, width: 2.2, height: 1.9), cornerRadius: 0.9),
           with: .color(pawColor))

    // head with a happy little tilt
    let tilt = sin(t * 2) * 2.5
    var h = c
    h.translateBy(x: 17, y: 4.6)
    h.rotate(by: Angle(degrees: tilt))
    h.translateBy(x: -17, y: -4.6)

    var earL = Path()
    earL.move(to: CGPoint(x: 13.9, y: 2.2))
    earL.addLine(to: CGPoint(x: 14.5, y: -0.6)); earL.addLine(to: CGPoint(x: 16.8, y: 1.0))
    earL.closeSubpath()
    var earR = Path()
    earR.move(to: CGPoint(x: 20.1, y: 2.2))
    earR.addLine(to: CGPoint(x: 19.5, y: -0.6)); earR.addLine(to: CGPoint(x: 17.2, y: 1.0))
    earR.closeSubpath()
    h.fill(earL, with: .color(kind == .charlie ? colors.catBody : colors.tabby))
    h.fill(earR, with: .color(kind == .charlie ? colors.catBody : colors.tabby))

    let head = Path(ellipseIn: CGRect(x: 12.8, y: 0.4, width: 8.4, height: 8.4))
    h.fill(head, with: .color(kind == .charlie ? colors.catBody : colors.catWhite))
    h.stroke(head, with: .color(colors.outline), style: stroke)

    if kind == .charlie {
        h.fill(Path(ellipseIn: CGRect(x: 15.2, y: 4.6, width: 3.8, height: 2.8)),
               with: .color(colors.catWhite))
        h.fill(Path(ellipseIn: CGRect(x: 14.9, y: 3.0, width: 1.4, height: 1.4)),
               with: .color(colors.gold))
        h.fill(Path(ellipseIn: CGRect(x: 18.4, y: 3.0, width: 1.4, height: 1.4)),
               with: .color(colors.gold))
    } else {
        var cap = Path()
        cap.move(to: CGPoint(x: 13.0, y: 4.6))
        cap.addQuadCurve(to: CGPoint(x: 17.0, y: 0.4), control: CGPoint(x: 13.2, y: 1.0))
        cap.addQuadCurve(to: CGPoint(x: 21.0, y: 4.6), control: CGPoint(x: 20.8, y: 1.0))
        cap.addQuadCurve(to: CGPoint(x: 13.0, y: 4.6), control: CGPoint(x: 17.0, y: 3.2))
        cap.closeSubpath()
        h.fill(cap, with: .color(colors.tabby))
        for dx in [-1.9, 0.0, 1.9] {
            var s = Path()
            s.move(to: CGPoint(x: 17.0 + dx, y: 1.0))
            s.addLine(to: CGPoint(x: 17.0 + dx * 1.2, y: 2.6))
            h.stroke(s, with: .color(colors.stripe),
                     style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        }
        for x in [14.9, 18.4] {
            var eye = Path()
            eye.move(to: CGPoint(x: x, y: 4.4))
            eye.addQuadCurve(to: CGPoint(x: x + 1.5, y: 4.4), control: CGPoint(x: x + 0.75, y: 5.1))
            h.stroke(eye, with: .color(colors.stripe),
                     style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        }
        h.fill(Path(ellipseIn: CGRect(x: 13.2, y: 5.4, width: 1.6, height: 1.6)),
               with: .color(colors.cheek))
    }
}

/// Four-point sparkle.
private func starPath(cx: CGFloat, cy: CGFloat, r: CGFloat) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: cx, y: cy - r))
    p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + r * 0.18, y: cy - r * 0.18))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx + r * 0.18, y: cy + r * 0.18))
    p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - r * 0.18, y: cy + r * 0.18))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx - r * 0.18, y: cy - r * 0.18))
    p.closeSubpath()
    return p
}

// MARK: - Working lane

struct CritterLane: View {
    let theme: Theme
    private let cycle = 11.0
    private let lap = 3.0

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let colors = CritterColors.of(theme)
                let phase = t.truncatingRemainder(dividingBy: cycle)
                let scale: CGFloat = 0.52
                let w: CGFloat = 34 * scale
                let y = size.height - 17 * scale - 1

                if phase < lap {
                    let f = CGFloat(phase / lap)
                    let x = -w + f * (size.width + 2 * w)
                    drawCritter(g, kind: .charlie, pose: .run, at: CGPoint(x: x, y: y),
                                scale: scale, flip: false, t: t, colors: colors)
                }
                let lilyStart = 5.5
                if phase >= lilyStart && phase < lilyStart + lap {
                    let f = CGFloat((phase - lilyStart) / lap)
                    let x = size.width + w - f * (size.width + 2 * w)
                    drawCritter(g, kind: .lily, pose: .run, at: CGPoint(x: x, y: y),
                                scale: scale, flip: true, t: t, colors: colors)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Turn-end moments

struct MomentView: View {
    let moment: Moment
    let theme: Theme

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let e = ctx.date.timeIntervalSince(moment.started)
            Canvas { g, size in
                let colors = CritterColors.of(theme)
                let scale: CGFloat = 0.82
                let y = size.height - 17 * scale - 1

                switch moment.kind {
                case .star:
                    let x = size.width / 2 - 17 * scale
                    drawCritter(g, kind: moment.critter, pose: .sit,
                                at: CGPoint(x: x, y: y), scale: scale, flip: false,
                                t: t, colors: colors)
                    // the star pops in beside the ears, twinkles, fades
                    let s = e - 0.35
                    if s > 0 {
                        let grow = min(1.0, s * 5)
                        let over = 1.0 + 0.35 * max(0, 1 - abs(s - 0.2) * 6)
                        let fade = max(0, 1 - max(0, e - 1.7) / 0.6)
                        let r = 4.6 * grow * over
                        let cx = size.width / 2 + 14
                        let cy = y + 1.5
                        var star = g
                        star.opacity = fade
                        star.fill(starPath(cx: cx, cy: cy, r: r), with: .color(colors.gold))
                        if s > 0.35 {
                            let r2 = 2.0 * min(1.0, (s - 0.35) * 5)
                            star.fill(starPath(cx: cx + 8, cy: cy - 6, r: r2), with: .color(colors.gold))
                        }
                    }
                case .sad:
                    // slow walk off toward the left, ears back
                    let f = CGFloat(min(1.0, e / moment.duration))
                    let x = size.width * 0.62 - f * (size.width * 0.62 + 34 * scale + 6)
                    drawCritter(g, kind: moment.critter, pose: .sad,
                                at: CGPoint(x: x, y: y), scale: scale, flip: true,
                                t: t, colors: colors)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The waiting paw (Charlie's: dark arm, white mitt, pink beans)

struct PawView: View {
    let theme: Theme
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let y = tapOffset(t.truncatingRemainder(dividingBy: 1.6) / 1.6)
            Canvas { g, _ in
                let colors = CritterColors.of(theme)
                let stroke = StrokeStyle(lineWidth: 0.6)
                let arm = Path(roundedRect: CGRect(x: 4.5, y: 0, width: 5, height: 9.5), cornerRadius: 2.5)
                g.fill(arm, with: .color(colors.catBody))
                g.stroke(arm, with: .color(colors.outline), style: stroke)
                let mitt = Path(ellipseIn: CGRect(x: 2.8, y: 7.8, width: 8.4, height: 8.4))
                g.fill(mitt, with: .color(colors.catWhite))
                g.stroke(mitt, with: .color(colors.outline), style: stroke)
                for (x, yy) in [(3.6, 12.9), (6.0, 13.9), (8.4, 12.9)] {
                    g.fill(Path(ellipseIn: CGRect(x: x, y: yy, width: 2, height: 2)),
                           with: .color(colors.cheek))
                }
                g.fill(Path(ellipseIn: CGRect(x: 5.5, y: 9.7, width: 3, height: 3)),
                       with: .color(colors.cheek.opacity(0.8)))
            }
            .frame(width: 14, height: 18)
            .offset(x: 34, y: y)
        }
        .allowsHitTesting(false)
    }

    /// keyframes: rest tucked up (-4), two quick taps down, back up
    private func tapOffset(_ p: Double) -> CGFloat {
        let keys: [(Double, CGFloat)] = [(0, -4), (0.5, -4), (0.6, 0), (0.7, -2.5), (0.8, 0), (1.0, -4)]
        for i in 1..<keys.count {
            let (t0, v0) = keys[i - 1]
            let (t1, v1) = keys[i]
            if p <= t1 {
                let f = (p - t0) / max(0.0001, t1 - t0)
                return v0 + (v1 - v0) * CGFloat(f)
            }
        }
        return -4
    }
}
