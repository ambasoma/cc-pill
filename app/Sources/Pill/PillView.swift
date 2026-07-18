import SwiftUI

// MARK: - Theme (porcelain by day, kiln by night)

struct Theme {
    let pillBG: Color
    let pillInk: Color
    let pillLine: Color
    let gold: Color
    let amber: Color
    let olive: Color
    let gloss: Double
    let emberMax: Double
    let night: Bool

    static func of(_ scheme: ColorScheme) -> Theme {
        if scheme == .dark {
            return Theme(pillBG: Color(hex: 0x181D0E), pillInk: Color(hex: 0xEFE8D3),
                         pillLine: Color.white.opacity(0.06),
                         gold: Color(hex: 0xD9B44A), amber: Color(hex: 0xD9913A),
                         olive: Color(hex: 0xA9BD66),
                         gloss: 0.07, emberMax: 0.95, night: true)
        }
        return Theme(pillBG: Color(hex: 0xF8F3E8), pillInk: Color(hex: 0x2A2620),
                     pillLine: Color(hex: 0x2A2620).opacity(0.16),
                     gold: Color(hex: 0xA88117), amber: Color(hex: 0xB26E1C),
                     olive: Color(hex: 0x5F7036),
                     gloss: 0.38, emberMax: 0, night: false)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Root content

struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) var scheme
    var onResize: (CGSize) -> Void = { _ in }

    var body: some View {
        let theme = Theme.of(scheme)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                PillView(theme: theme)
                if case .waiting = store.pillState {
                    PawView(theme: theme)
                        .offset(y: 23)
                }
            }
            .zIndex(2)
            if store.showCard, store.pillState != .hidden {
                CardView(theme: theme)
                    .padding(.top, 10)
                    .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
                    .zIndex(1)
            }
            if let toast = store.toast {
                ToastView(text: toast, theme: theme)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 30)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: store.pillState)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: store.showCard)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: store.narration)
        .animation(.easeInOut(duration: 0.25), value: store.toast)
        .fixedSize()
        .background(GeometryReader { g in
            Color.clear.preference(key: SizeKey.self, value: g.size)
        })
        .onPreferenceChange(SizeKey.self) { onResize($0) }
        // Pin the content to top-center of the window, whatever slack the
        // window envelope has; otherwise it sits top-leading and the pill
        // drifts left of the screen center.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - The pill

struct PillView: View {
    @EnvironmentObject var store: Store
    let theme: Theme
    @FocusState private var askFocus: Bool

    var body: some View {
        let state = store.pillState
        HStack(spacing: 6) {
            switch state {
            case .hidden:
                EmptyView()
            case .idle:
                SunMoon(theme: theme)
                HStack(spacing: 5) {
                    ForEach(Array(store.sessions.prefix(3).enumerated()), id: \.offset) { _, s in
                        Circle()
                            .fill(s.state == .waiting ? theme.amber :
                                  (s.state == .working ? theme.olive : theme.olive.opacity(0.45)))
                            .frame(width: 4.5, height: 4.5)
                    }
                }
            case .working(let label):
                SunMoon(theme: theme)
                NarrationText(text: store.narration.isEmpty ? label : store.narration,
                              ink: theme.pillInk.opacity(0.85))
            case .waiting:
                PingDot(color: theme.amber)
                WaitingLabel(ink: theme.pillInk.opacity(0.9))
            case .moment(let m):
                MomentView(moment: m, theme: theme)
                    .frame(width: m.kind == .sad ? 110 : 64, height: 21)
                Text(m.repo)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.pillInk.opacity(0.7))
            case .speaking:
                if let b = store.briefing {
                    RevealText(text: b.text, start: b.started, duration: b.duration, ink: theme.pillInk)
                    if !b.silent {
                        WaveBars(color: theme.gold)
                    }
                }
            case .listening:
                if store.speech.phase == .recording {
                    WaveBars(color: theme.amber)
                }
                TextField(listenPlaceholder, text: askBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(theme.pillInk)
                    .lineLimit(1...3)
                    .focused($askFocus)
                    .onSubmit { store.sendAsk() }
                    .onExitCommand { store.cancelAsk() }
                    .onAppear { askFocus = true }
                Button(action: { store.sendAsk() }) {
                    Text("go")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.pillBG)
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background(Capsule().fill(theme.olive))
                }
                .buttonStyle(.plain)
                Button(action: { store.cancelAsk() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.pillInk.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(theme.pillInk.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
            }
        }
        .padding(.horizontal, pillPadding(state))
        .padding(.vertical, isSpeaking(state) ? 10 : 0)
        .padding(.top, {
            if case .working = state { return 3.0 }   // breathe below the screen edge
            return 0
        }())
        .frame(width: pillWidth(state), height: pillHeight(state), alignment: alignmentFor(state))
        .frame(minHeight: isSpeaking(state) ? 44 : nil)
        .background(
            ZStack(alignment: .top) {
                PillShape(radius: cornerFor(state))
                    .fill(theme.pillBG)
                // porcelain glaze highlight
                PillShape(radius: cornerFor(state))
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(theme.gloss), .clear],
                        startPoint: .top, endPoint: .center))
                // kiln ember, breathing while working at night
                if case .working = state, theme.emberMax > 0 {
                    EmberGlow(maxOpacity: theme.emberMax)
                        .clipShape(PillShape(radius: cornerFor(state)))
                }
                // critters take their laps while working
                if case .working = state {
                    CritterLane(theme: theme)
                        .clipShape(PillShape(radius: cornerFor(state)))
                }
                PillShape(radius: cornerFor(state))
                    .strokeBorder(theme.pillLine, lineWidth: 1)
            }
        )
        // Nothing may paint outside the pill, ever: outgoing text slides
        // down and vanishes at the pill's own edge instead of ghosting
        // over the menu bar while the pill contracts.
        .clipShape(PillShape(radius: cornerFor(state)))
        .compositingGroup()
        .shadow(color: .black.opacity(theme.night ? 0.45 : 0.20),
                radius: theme.night ? 11 : 7, y: 4)
        .contentShape(Rectangle())
        .onHover { h in store.setHover(h) }
        .onTapGesture { store.pinned.toggle() }
    }

    private func isSpeaking(_ s: PillState) -> Bool {
        if case .speaking = s { return true }
        if case .listening = s { return true }
        return false
    }

    private var listenPlaceholder: String {
        switch store.speech.phase {
        case .recording: return "listening…"
        case .requesting: return "one sec…"
        case .denied: return "mic denied · type instead"
        case .unavailable: return "no mic · type instead"
        case .idle: return "ask for anything…"
        }
    }

    private var askBinding: Binding<String> {
        Binding(
            get: {
                let s = store.speech
                return s.phase == .recording || !s.transcript.isEmpty
                    ? s.transcript : store.askDraft
            },
            set: { v in
                if store.speech.phase == .recording || !store.speech.transcript.isEmpty {
                    store.speech.transcript = v
                }
                store.askDraft = v
            })
    }
    private func pillWidth(_ s: PillState) -> CGFloat? {
        switch s {
        case .hidden: return 0
        case .idle: return 70
        case .working: return nil    // sized by the narrated label
        case .waiting: return nil
        case .speaking: return 430
        case .moment: return nil
        case .listening: return 430
        }
    }
    private func pillHeight(_ s: PillState) -> CGFloat? {
        switch s {
        case .hidden: return 0
        case .idle: return 22
        case .working: return 27
        case .waiting: return 26
        case .speaking: return nil   // grows with the text
        case .moment: return 27
        case .listening: return nil
        }
    }
    private func pillPadding(_ s: PillState) -> CGFloat {
        isSpeaking(s) ? 18 : 12
    }
    private func cornerFor(_ s: PillState) -> CGFloat {
        switch s {
        case .idle: return 11
        case .speaking, .listening: return 22
        default: return 13
        }
    }
    private func alignmentFor(_ s: PillState) -> Alignment {
        if case .working = s { return .top }
        return .center
    }
}

/// Rounded only at the bottom, like a tab hanging from the top of the screen.
struct PillShape: InsettableShape {
    var radius: CGFloat
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> PillShape {
        var s = self; s.inset += amount; return s
    }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        // Top corners get a small radius too: a square top reads as a sharp
        // rectangle whenever an open menu lightens the bar behind the pill.
        let top = min(9, radius * 0.6)
        return Path(roundedRect: r,
                    cornerRadii: RectangleCornerRadii(topLeading: top, bottomLeading: radius,
                                                      bottomTrailing: radius, topTrailing: top))
    }
}

// MARK: - Small pieces

struct SunMoon: View {
    let theme: Theme
    var body: some View {
        Canvas { g, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            if theme.night {
                // crescent: gold disc minus an offset bite
                var moon = Path(ellipseIn: CGRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11))
                let bite = Path(ellipseIn: CGRect(x: c.x - 5.5 + 3.6, y: c.y - 5.5 - 1.4, width: 11, height: 11))
                moon = moon.subtracting(bite)
                g.fill(moon, with: .color(theme.gold))
            } else {
                g.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)),
                       with: .color(theme.gold))
                for i in 0..<8 {
                    let a = CGFloat(i) * .pi / 4
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + cos(a) * 4.4, y: c.y + sin(a) * 4.4))
                    p.addLine(to: CGPoint(x: c.x + cos(a) * 6.3, y: c.y + sin(a) * 6.3))
                    g.stroke(p, with: .color(theme.gold), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                }
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// The working label with its swap choreography: the outgoing text slides
/// down out of the pill while the incoming one fades in, revealing its words
/// left to right like the spoken briefings do.
struct NarrationText: View {
    let text: String
    let ink: Color

    var body: some View {
        ZStack {
            LabelReveal(text: text, ink: ink)
                .id(text)
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .move(edge: .bottom).combined(with: .opacity)))
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: text)
    }
}

/// Words appear left to right with a quick per-word fade.
struct LabelReveal: View {
    let text: String
    let ink: Color
    @State private var born = Date()

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
            let e = ctx.date.timeIntervalSince(born)
            let per = 0.45 / Double(max(1, words.count))
            words.enumerated().reduce(Text("")) { acc, item in
                let start = Double(item.offset) * per
                let f = min(1.0, max(0.0, (e - start) / 0.18))
                return acc + Text(item.element + (item.offset < words.count - 1 ? " " : ""))
                    .foregroundColor(ink.opacity(0.1 + 0.9 * f))
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
        }
        .onAppear { born = Date() }
    }
}

/// Waiting label: shows how long Claude has been blocked on you.
struct WaitingLabel: View {
    @EnvironmentObject var store: Store
    let ink: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let w = store.sessions.filter { $0.state == .waiting }
                .max(by: { $0.since < $1.since })
            let mins = w.map { Int(ctx.date.timeIntervalSince($0.since) / 60) } ?? 0
            Text(mins >= 2 ? "needs you · \(mins)m" : "needs you")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ink)
                .lineLimit(1)
        }
    }
}

struct PingDot: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            ZStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Circle().stroke(color, lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                    .scaleEffect(0.6 + 1.0 * t)
                    .opacity(max(0, 0.9 - t))
            }
            .frame(width: 16, height: 16)
        }
    }
}

struct WaveBars: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * 6 + Double(i) * 0.9
                    let h = 6 + 6 * abs(sin(phase))
                    Capsule().fill(color)
                        .frame(width: 2.5, height: h)
                }
            }
            .frame(height: 14)
        }
    }
}

struct RevealText: View {
    let text: String
    let start: Date
    let duration: Double
    let ink: Color

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        TimelineView(.periodic(from: start, by: 0.08)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(start)
            let shown = duration > 0
                ? Int((elapsed / duration) * Double(words.count) + 0.5)
                : words.count
            words.enumerated().reduce(Text("")) { acc, item in
                acc + Text(item.element + " ")
                    .foregroundColor(ink.opacity(item.offset < shown ? 1 : 0.15))
            }
            .font(.system(size: 12.5, weight: .medium))
            .lineSpacing(2)
            .frame(maxWidth: 340, alignment: .leading)
        }
    }
}

struct EmberGlow: View {
    let maxOpacity: Double
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = 0.35 + 0.65 * abs(sin(t * .pi / 2.4))
            GeometryReader { g in
                RadialGradient(
                    colors: [Color(hex: 0xD9913A).opacity(0.55), .clear],
                    center: UnitPoint(x: 0.5, y: 1.15),
                    startRadius: 0,
                    endRadius: g.size.width * 0.55)
            }
            .opacity(maxOpacity * pulse)
            .allowsHitTesting(false)
        }
    }
}

struct ToastView: View {
    let text: String
    let theme: Theme
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.pillInk)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(theme.pillBG))
            .overlay(Capsule().stroke(theme.pillLine, lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }
}
