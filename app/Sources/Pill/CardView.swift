import SwiftUI

struct CardView: View {
    @EnvironmentObject var store: Store
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SESSIONS · \(store.sessions.count)")
                Spacer()
                Button(action: { store.startAsk() }) {
                    Text("+ NEW").foregroundColor(theme.olive)
                }
                .buttonStyle(.plain)
                .help("Start a new session by voice (⌥⌘M)")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .kerning(1.2)
            .foregroundColor(theme.pillInk.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ForEach(store.sessions.sorted(by: { $0.since > $1.since })) { s in
                Divider().overlay(theme.pillInk.opacity(0.12)).padding(.horizontal, 8)
                SessionRow(session: s, theme: theme)
            }

            Divider().overlay(theme.pillInk.opacity(0.12)).padding(.horizontal, 8)
            HStack {
                Text("\(store.config.name) · \(Actions.jarvisMuted() ? "muted" : "speaking")")
                Spacer()
                Button(action: { Actions.toggleMute(); store.objectWillChange.send() }) {
                    Text(Actions.jarvisMuted() ? "unmute" : "mute")
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11))
            .foregroundColor(theme.pillInk.opacity(0.6))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.pillBG)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.pillLine, lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: .black.opacity(theme.night ? 0.5 : 0.25), radius: 20, y: 10)
        .onHover { h in store.setHover(h) }
    }
}

struct SessionRow: View {
    @EnvironmentObject var store: Store
    let session: ClaudeSession
    let theme: Theme
    @State private var draft = ""

    var inInput: Bool { store.inputFor == session.id }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                StateDot(state: session.state, theme: theme)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(session.repo)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.pillInk)
                        if session.remote {
                            Text("ssh")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.pillInk.opacity(0.5))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .overlay(Capsule().stroke(theme.pillInk.opacity(0.3), lineWidth: 0.5))
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 20)) { ctx in
                        Text(detail(at: ctx.date))
                            .font(.system(size: 11))
                            .foregroundColor(theme.pillInk.opacity(0.55))
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    ActionButton(symbol: "play.fill", help: "Play recap", theme: theme,
                                 disabled: session.lastBriefing == nil) {
                        Actions.recap(session)
                    }
                    ActionButton(symbol: "mic.fill", help: "Speak a prompt", theme: theme) {
                        if inInput {
                            store.speech.stop()
                            store.inputFor = nil
                        } else {
                            store.inputFor = session.id
                            draft = ""
                            store.speech.start()
                        }
                    }
                    ActionButton(symbol: "terminal.fill", help: "Open terminal", theme: theme) {
                        Actions.openTerminal(session)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if inInput {
                PromptInput(session: session, theme: theme, draft: $draft)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }

    private func detail(at now: Date) -> String {
        let mins = max(0, Int(now.timeIntervalSince(session.since) / 60))
        let ago = mins == 0 ? "now" : "\(mins)m"
        switch session.state {
        case .working:
            if let a = session.activity, let at = session.activityAt,
               now.timeIntervalSince(at) < 90 {
                return "\(a) · \(ago)"
            }
            return "working · \(ago)"
        case .waiting: return "waiting on you · \(ago)"
        case .done: return "done · \(ago)"
        }
    }
}

struct PromptInput: View {
    @EnvironmentObject var store: Store
    let session: ClaudeSession
    let theme: Theme
    @Binding var draft: String

    var body: some View {
        let speech = store.speech
        VStack(alignment: .leading, spacing: 6) {
            switch speech.phase {
            case .recording:
                HStack(spacing: 6) {
                    WaveBars(color: theme.amber)
                    Text(speech.transcript.isEmpty ? "listening…" : speech.transcript)
                        .font(.system(size: 12))
                        .foregroundColor(theme.pillInk.opacity(speech.transcript.isEmpty ? 0.5 : 0.95))
                        .lineLimit(3)
                    Spacer()
                }
            case .denied, .unavailable:
                Text(speech.phase == .denied ? "mic permission denied · type instead" : "no mic detected · type instead")
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.amber)
            default:
                EmptyView()
            }

            HStack(spacing: 8) {
                TextField("prompt for \(session.repo)…", text: bindingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(theme.pillInk)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(theme.pillInk.opacity(0.07)))
                    .onSubmit { send() }
                Button(action: send) {
                    Text("send")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.pillBG)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(theme.olive))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var bindingText: Binding<String> {
        Binding(
            get: {
                let s = store.speech
                return s.phase == .recording ? s.transcript : draft
            },
            set: { v in
                if store.speech.phase == .recording { store.speech.transcript = v }
                draft = v
            })
    }

    private func send() {
        let text = store.speech.phase == .recording || !store.speech.transcript.isEmpty
            ? store.speech.transcript : draft
        store.speech.stop()
        if Actions.sendPrompt(session, text: text.isEmpty ? draft : text) {
            store.inputFor = nil
            draft = ""
            store.speech.transcript = ""
        }
    }
}

struct StateDot: View {
    let state: SessionState
    let theme: Theme
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let period = state == .waiting ? 1.1 : 1.8
            let breathe = 0.45 + 0.55 * abs(sin(t * .pi / period))
            Circle()
                .fill(color.opacity(state == .done ? 1 : breathe))
                .frame(width: 8, height: 8)
        }
        .frame(width: 8, height: 8)
    }
    private var color: Color {
        switch state {
        case .working: return theme.olive
        case .waiting: return theme.amber
        case .done: return Color(hex: 0x7FB39D)
        }
    }
}

struct ActionButton: View {
    let symbol: String
    let help: String
    let theme: Theme
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.pillInk.opacity(disabled ? 0.25 : 0.8))
                .frame(width: 26, height: 26)
                .background(Circle().fill(theme.pillInk.opacity(hover && !disabled ? 0.12 : 0)))
                .overlay(Circle().stroke(theme.pillInk.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
        .help(help)
    }
}
