import AppKit
import Combine
import Darwin
import Foundation

// MARK: - Logging (the E2E-verifiable trace of everything the app does)

enum MBLog {
    static let path = NSString(string: "~/.cc-pill/pill.log").expandingTildeInPath
    static func log(_ msg: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }
}

// MARK: - Config

struct MBConfig {
    /// The assistant's name (used in the card footer and docs).
    var name = "Jarvis"
    /// Folder containing the voice system (say.py, .venv, pillctl, .off).
    /// Defaults to <install>/voice, derived from the app bundle location.
    var speaker: String = {
        let bundle = Bundle.main.bundlePath as NSString
        let appDir = bundle.deletingLastPathComponent as NSString   // <install>/app
        return (appDir.deletingLastPathComponent as NSString).appendingPathComponent("voice")
    }()
    /// Where pill-launched sessions run.
    var homeRepo: String = NSHomeDirectory()
    /// Extra system instructions for pill-launched sessions (optional).
    var pillSystemPrompt = ""
    /// Permission mode for pill-launched sessions:
    /// "acceptEdits" (auto-accept file edits, other tools still prompt),
    /// "bypass" (skip all permission prompts), or "default".
    var permissionMode = "acceptEdits"
    /// Terminal app used by "open terminal" (bundle id).
    var terminalBundle = "com.apple.Terminal"
    /// Ask-mode global hotkey, e.g. "cmd+alt+m".
    var hotkey = "cmd+alt+m"
    /// Idle pill sessions are garbage collected after this many minutes
    /// (done, detached, untouched). 0 disables GC.
    var pillGCMinutes = 30.0
    /// Brand fonts (config keys "font" and "font_body"): display for short
    /// labels, body for reading text. A family's -Regular/-Medium/-SemiBold/
    /// -Bold faces must be installed. Nil = system font; body falls back to
    /// display when only "font" is set.
    var fontFamily: String? = nil
    var bodyFontFamily: String? = nil
    var claudeBin: String = {
        for p in ["/opt/homebrew/bin/claude",
                  NSString(string: "~/.local/bin/claude").expandingTildeInPath,
                  "/usr/local/bin/claude"] where FileManager.default.fileExists(atPath: p) {
            return p
        }
        return "claude"
    }()

    static func load() -> MBConfig {
        var cfg = MBConfig()
        let p = NSString(string: "~/.cc-pill/config.json").expandingTildeInPath
        if let data = FileManager.default.contents(atPath: p),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = obj["name"] as? String, !s.isEmpty { cfg.name = s }
            if let s = obj["speaker"] as? String {
                cfg.speaker = NSString(string: s).expandingTildeInPath
            }
            if let s = obj["pill_system_prompt"] as? String { cfg.pillSystemPrompt = s }
            if let s = obj["home_repo"] as? String {
                cfg.homeRepo = NSString(string: s).expandingTildeInPath
            }
            if let p = obj["permission_mode"] as? String, !p.isEmpty { cfg.permissionMode = p }
            if let f = obj["font"] as? String, !f.isEmpty { cfg.fontFamily = f }
            if let f = obj["font_body"] as? String, !f.isEmpty { cfg.bodyFontFamily = f }
            if let t = obj["terminal"] as? String, !t.isEmpty { cfg.terminalBundle = t }
            if let h = obj["hotkey"] as? String, !h.isEmpty { cfg.hotkey = h }
            if let s = obj["claude_bin"] as? String { cfg.claudeBin = s }
            if let m = obj["pill_gc_minutes"] as? Double { cfg.pillGCMinutes = m }
        }
        return cfg
    }
}

// MARK: - Model types

enum SessionState: String {
    case working, waiting, done
}

struct ClaudeSession: Identifiable, Equatable {
    let id: String          // Claude Code session_id
    var repo: String
    var cwd: String
    var pid: Int32
    var state: SessionState
    var since: Date         // when the CURRENT state was entered
    var activity: String?   // "editing worker.py", from PreToolUse events
    var activityAt: Date?
    var lastBriefing: String?
    var remote: Bool
}

struct Briefing: Equatable {
    var text: String
    var duration: Double    // seconds the reveal is paced over
    var silent: Bool
    var started: Date
    var repo: String
    var sad: Bool           // the news sounds like a failure
}

enum MomentKind: Equatable {
    case star   // turn finished well: critter sits, a star pops
    case sad    // turn ended badly: ears back, slow walk off
}

struct Moment: Equatable {
    var kind: MomentKind
    var critter: CritterKind
    var started: Date
    var repo: String
    var duration: Double { kind == .sad ? 3.0 : 2.4 }
}

enum PillState: Equatable {
    case hidden
    case idle
    case working(String)
    case waiting
    case speaking
    case moment(Moment)
    case listening   // ask mode: mic open, transcript filling in
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    let config = MBConfig.load()

    @Published var sessions: [ClaudeSession] = []
    @Published var briefing: Briefing?
    @Published var moment: Moment?
    @Published var narration = ""   // the working pill's alternating label
    @Published var asking = false   // ask mode: pill becomes a voice prompt
    @Published var askDraft = ""
    @Published var pinned = false
    @Published var hovering = false

    // MARK: ask mode (start a new session from the pill)

    func startAsk() {
        guard !asking else { return }
        asking = true
        pinned = false
        askDraft = ""
        speech.transcript = ""
        speech.start()
        MBLog.log("ask: listening")
    }

    func cancelAsk() {
        speech.stop()
        asking = false
        MBLog.log("ask: cancelled")
    }

    func sendAsk() {
        let spoken = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = spoken.isEmpty ? typed : spoken
        speech.stop()
        asking = false
        guard !text.isEmpty else {
            MBLog.log("ask: empty, dropped")
            return
        }
        Actions.launchSession(prompt: text)
    }

    private var narrTimer: Timer?

    init() {
        narrTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in Store.shared.updateNarration() }
        }
    }

    /// Alternates the working label between repo name (with elapsed minutes
    /// on long turns) and the current tool activity. Published as state so
    /// the pill's width change animates with a spring instead of snapping.
    func updateNarration() {
        if case .working = rawPillState {
            heldWorking = rawPillState
            holdUntil = Date().addingTimeInterval(1.1)
        }
        guard case .working = pillState, let s = narratedSession else {
            setNarration("")
            return
        }
        let working = sessions.filter { $0.state == .working }
        let base = working.count > 1 ? "\(working.count) sessions" : s.repo
        let mins = Int(Date().timeIntervalSince(s.since) / 60)
        var text = mins >= 3 ? "\(base) · \(mins)m" : base
        let phase = Int(Date().timeIntervalSinceReferenceDate / 3.5) % 2
        if phase == 1, let a = s.activity, let at = s.activityAt,
           Date().timeIntervalSince(at) < 90 {
            text = a
        }
        setNarration(text)
    }

    private var narrClear: DispatchWorkItem?

    /// Swaps are immediate; clearing is delayed so the outgoing text can
    /// finish sliding out before the pill contracts, and so an incoming
    /// text moments later cancels the collapse entirely.
    private func setNarration(_ text: String) {
        if text.isEmpty {
            guard !narration.isEmpty, narrClear == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                self?.narration = ""
                self?.narrClear = nil
            }
            narrClear = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
        } else {
            narrClear?.cancel()
            narrClear = nil
            if narration != text { narration = text }
        }
    }
    /// Session id whose row is currently in prompt-input mode.
    @Published var inputFor: String?
    @Published var toast: String?

    let speech = SpeechInput()
    private var briefingTimer: Timer?
    private var hoverOff: DispatchWorkItem?

    var showCard: Bool { pinned || hovering }

    /// Debounced and idempotent (called on a fast poll): hover-off only
    /// lands after a grace period, so the pointer can cross the gap between
    /// pill and card without the card flickering.
    func setHover(_ h: Bool) {
        if h {
            hoverOff?.cancel()
            hoverOff = nil
            if !hovering { hovering = true }
        } else {
            guard hovering, hoverOff == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                self?.hovering = false
                self?.hoverOff = nil
            }
            hoverOff = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        }
    }

    private var rawPillState: PillState {
        if asking { return .listening }
        if briefing != nil { return .speaking }
        if let m = moment { return .moment(m) }
        if sessions.isEmpty { return .hidden }
        if sessions.contains(where: { $0.state == .waiting }) { return .waiting }
        let working = sessions.filter { $0.state == .working }
        if let w = working.max(by: { $0.since < $1.since }) {
            return .working(working.count > 1 ? "\(working.count) sessions" : w.repo)
        }
        return .idle
    }

    // Contraction hysteresis: when working ends, hold the expanded pill for
    // a beat. If something new arrives within the window (next tool, the
    // briefing) the pill never collapsed at all; otherwise it settles once.
    private var heldWorking: PillState?
    private var holdUntil = Date.distantPast

    var pillState: PillState {
        let raw = rawPillState
        if case .idle = raw, let held = heldWorking, Date() < holdUntil {
            return held
        }
        return raw
    }

    /// The working session whose activity the pill narrates.
    var narratedSession: ClaudeSession? {
        sessions.filter { $0.state == .working }.max(by: { $0.since < $1.since })
    }

    // MARK: event application

    func apply(_ evt: [String: Any]) {
        let type = evt["type"] as? String ?? ""
        let sid = evt["sid"] as? String ?? ""
        let repo = evt["repo"] as? String ?? "?"
        let cwd = evt["cwd"] as? String ?? ""
        let pid = Int32(evt["pid"] as? Int ?? 0)
        let remote = evt["remote"] as? Bool ?? false

        switch type {
        case "start":
            upsert(sid: sid, repo: repo, cwd: cwd, pid: pid, remote: remote, state: .done)
            MBLog.log("session start: \(repo) [\(short(sid))]")
        case "prompt":
            upsert(sid: sid, repo: repo, cwd: cwd, pid: pid, remote: remote, state: .working)
            MBLog.log("working: \(repo) [\(short(sid))]")
        case "stop":
            let wasWorking = sessions.first(where: { $0.id == sid })?.state == .working
            upsert(sid: sid, repo: repo, cwd: cwd, pid: pid, remote: remote, state: .done)
            if let i = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[i].activity = nil
                sessions[i].activityAt = nil
            }
            MBLog.log("done: \(repo) [\(short(sid))]")
            if wasWorking {
                // A finished turn earns a critter moment. Usually the Jarvis
                // briefing arrives within seconds and the moment plays after
                // the bloom; if no briefing shows up, play it anyway.
                pendingMoment = true
                pendingMomentRepo = repo
                momentFallback?.invalidate()
                momentFallback = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
                    Task { @MainActor in
                        let s = Store.shared
                        if s.pendingMoment, s.briefing == nil { s.startMoment(.star) }
                    }
                }
            }
        case "tool":
            let label = evt["label"] as? String ?? ""
            guard !label.isEmpty, !sid.isEmpty else { return }
            if let i = sessions.firstIndex(where: { $0.id == sid }) {
                if sessions[i].state != .working {
                    sessions[i].state = .working
                    sessions[i].since = Date()
                }
                if sessions[i].activity != label {
                    sessions[i].activity = label
                    sessions[i].activityAt = Date()
                    MBLog.log("activity: \(repo): \(label)")
                }
            } else {
                upsert(sid: sid, repo: repo, cwd: cwd, pid: pid, remote: remote, state: .working)
                if let i = sessions.firstIndex(where: { $0.id == sid }) {
                    sessions[i].activity = label
                    sessions[i].activityAt = Date()
                }
            }
        case "notify":
            let idle = evt["idle"] as? Bool ?? false
            if idle {
                MBLog.log("idle nag ignored: \(repo)")
            } else {
                upsert(sid: sid, repo: repo, cwd: cwd, pid: pid, remote: remote, state: .waiting)
                MBLog.log("waiting: \(repo) [\(short(sid))]")
            }
        case "end":
            sessions.removeAll { $0.id == sid }
            MBLog.log("session end: \(repo) [\(short(sid))]")
        case "briefing":
            let text = evt["text"] as? String ?? ""
            guard !text.isEmpty else { return }
            let silent = evt["silent"] as? Bool ?? false
            var duration = evt["duration"] as? Double ?? 0
            if duration <= 0 {
                duration = min(6.0, Double(text.split(separator: " ").count) * 0.3)
            }
            let sad = text.range(
                of: #"fail(ed|ing)?|error|broke|broken|couldn.t|didn.t work|crash"#,
                options: [.regularExpression, .caseInsensitive]) != nil
            momentFallback?.invalidate()  // moment now plays after the bloom
            briefing = Briefing(text: text, duration: duration, silent: silent,
                                started: Date(), repo: repo, sad: sad)
            if !sid.isEmpty, let i = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[i].lastBriefing = text
            }
            MBLog.log("briefing (\(silent ? "silent" : String(format: "%.1fs", duration))): \(text.prefix(60))")
            briefingTimer?.invalidate()
            briefingTimer = Timer.scheduledTimer(withTimeInterval: duration + 3.0, repeats: false) { _ in
                Task { @MainActor in
                    let s = Store.shared
                    let wasSad = s.briefing?.sad ?? false
                    s.briefing = nil
                    MBLog.log("briefing cleared")
                    if s.pendingMoment { s.startMoment(wasSad ? .sad : .star) }
                }
            }
        default:
            break
        }
    }

    private func upsert(sid: String, repo: String, cwd: String, pid: Int32,
                        remote: Bool, state: SessionState) {
        guard !sid.isEmpty else { return }
        // A real hook event supersedes an adopted placeholder for the same claude.
        if pid > 0, !sid.hasPrefix("tmux-") {
            sessions.removeAll { $0.pid == pid && $0.id.hasPrefix("tmux-") }
        }
        if let i = sessions.firstIndex(where: { $0.id == sid }) {
            if sessions[i].state != state {
                sessions[i].state = state
                sessions[i].since = Date()   // elapsed measures time IN a state
            }
            if pid > 0 { sessions[i].pid = pid }
            if !cwd.isEmpty { sessions[i].cwd = cwd; sessions[i].repo = repo }
        } else {
            sessions.append(ClaudeSession(id: sid, repo: repo, cwd: cwd, pid: pid,
                                          state: state, since: Date(),
                                          activity: nil, activityAt: nil,
                                          lastBriefing: nil, remote: remote))
        }
    }

    // MARK: critter moments

    private var pendingMoment = false
    private var pendingMomentRepo = ""
    private var momentFallback: Timer?
    private var momentTimer: Timer?

    func startMoment(_ kind: MomentKind) {
        pendingMoment = false
        let critter: CritterKind = Bool.random() ? .charlie : .lily
        let m = Moment(kind: kind, critter: critter, started: Date(), repo: pendingMomentRepo)
        moment = m
        MBLog.log("moment: \(kind == .sad ? "sad" : "star") (\(critter == .charlie ? "charlie" : "lily")) for \(m.repo)")
        momentTimer?.invalidate()
        momentTimer = Timer.scheduledTimer(withTimeInterval: m.duration, repeats: false) { _ in
            Task { @MainActor in Store.shared.moment = nil }
        }
    }

    /// Drop sessions whose claude process is gone (crash, killed terminal).
    func reap() {
        sessions.removeAll { s in
            guard s.pid > 0 else { return false }
            if kill(s.pid, 0) == 0 { return false }
            if errno == ESRCH {
                MBLog.log("reaped dead session: \(s.repo) [\(short(s.id))]")
                return true
            }
            return false
        }
        // Backstop in case the briefing timer got lost.
        if let b = briefing, Date().timeIntervalSince(b.started) > b.duration + 10 {
            briefing = nil
        }
        gcPillSessions()
    }

    /// App restarts lose in-memory session state, which would orphan any
    /// running claude sessions (invisible to the island, immune to GC).
    /// On startup, adopt every cc-* tmux pane running claude; a real hook
    /// event for the same pid later replaces the placeholder.
    func adoptExisting() {
        let r = Actions.run(["tmux", "list-panes", "-a", "-F",
                             "#{session_name}\u{1}#{pane_pid}\u{1}#{pane_current_path}\u{1}#{pane_current_command}"])
        let out = r.out
        MBLog.log("adopt scan: code=\(r.code) lines=\(out.split(separator: "\n").count)")
        for line in out.split(separator: "\n") {
            let p = line.split(separator: "\u{1}", omittingEmptySubsequences: false)
            guard p.count == 4, p[0].hasPrefix("cc-"),
                  ["claude", "node"].contains(String(p[3])),
                  let pid = Int32(p[1]) else {
                MBLog.log("adopt skip: count=\(p.count) line=\(String(line.prefix(90)))")
                continue
            }
            guard !sessions.contains(where: { $0.pid == pid }) else { continue }
            let cwd = String(p[2])
            sessions.append(ClaudeSession(
                id: "tmux-\(pid)", repo: (cwd as NSString).lastPathComponent,
                cwd: cwd, pid: pid, state: .done, since: Date(),
                activity: nil, activityAt: nil, lastBriefing: nil, remote: false))
            MBLog.log("adopted existing session \(p[0]) (pid \(pid))")
        }
    }

    /// Pill-launched tmux sessions that finished their work and sat idle get
    /// cleaned up: done, detached, and untouched past the configured window.
    /// Working, waiting, and attached sessions are never touched, nor are
    /// the user's own wrapper sessions (only names containing "-pill").
    private func gcPillSessions() {
        let window = config.pillGCMinutes * 60
        guard window > 0 else { return }
        let stale = sessions.filter {
            $0.state == .done && Date().timeIntervalSince($0.since) > window
        }
        guard !stale.isEmpty else { return }
        let out = Actions.run(["tmux", "list-panes", "-a", "-F",
                               "#{session_name}\u{1}#{session_attached}\u{1}#{pane_pid}"]).out
        for line in out.split(separator: "\n") {
            let p = line.split(separator: "\u{1}", omittingEmptySubsequences: false)
            guard p.count == 3, p[0].contains("-pill"), p[1] == "0",
                  let panePid = Int32(p[2]) else { continue }
            if stale.contains(where: { $0.pid == panePid }) {
                Actions.run(["tmux", "kill-session", "-t", String(p[0])])
                MBLog.log("gc: killed idle pill session \(p[0])")
            }
        }
    }

    func flash(_ msg: String) {
        toast = msg
        MBLog.log("toast: \(msg)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.toast == msg { self?.toast = nil }
        }
    }

    private func short(_ sid: String) -> String { String(sid.prefix(8)) }
}

// MARK: - Event watcher

final class EventWatcher {
    static let shared = EventWatcher()
    let dir = NSString(string: "~/.cc-pill/events").expandingTildeInPath
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var reapTimer: Timer?

    func start() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            MBLog.log("ERROR: cannot watch \(dir)")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in self?.drain() }
        s.setCancelHandler { [fd = self.fd] in close(fd) }
        s.resume()
        source = s
        drain()
        reapTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in Store.shared.reap() }
        }
        MBLog.log("watching \(dir)")
    }

    private func drain() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let p = (dir as NSString).appendingPathComponent(name)
            if let data = fm.contents(atPath: p),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                Task { @MainActor in Store.shared.apply(obj) }
            }
            try? fm.removeItem(atPath: p)
        }
    }
}

// MARK: - Actions (recap, open terminal, send prompt)

enum Actions {
    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 8) -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        // Under launchd the PATH is bare (no Homebrew): tmux, jq etc live
        // in /opt/homebrew/bin. Augment instead of trusting the inherited env.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        // Without a UTF-8 locale (launchd default), tmux sanitizes the
        // control-char field separators in format output to "_", which
        // silently breaks every parse of list-panes.
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("", -1) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }

    /// tmux pane for a session's cwd: (paneId, tmuxSessionName), searched on the default server.
    static func tmuxPane(forCwd cwd: String) -> (pane: String, session: String)? {
        let r = run(["tmux", "list-panes", "-a", "-F",
                     "#{pane_id}\u{1}#{session_name}\u{1}#{pane_current_path}"])
        guard r.code == 0 else { return nil }
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: "\u{1}", omittingEmptySubsequences: false)
            if parts.count == 3, String(parts[2]) == cwd {
                return (String(parts[0]), String(parts[1]))
            }
        }
        return nil
    }

    @MainActor
    static func recap(_ s: ClaudeSession) {
        let speaker = Store.shared.config.speaker
        let py = speaker + "/.venv/bin/python"
        let say = speaker + "/say.py"
        guard FileManager.default.fileExists(atPath: py) else {
            Store.shared.flash("Voice system not found")
            return
        }
        let text: String
        if let b = s.lastBriefing {
            text = b
        } else {
            // Fall back to the global last briefing from the jarvis log.
            let r = run(["bash", speaker + "/pillctl", "last"])
            if r.code == 0 { MBLog.log("recap fallback via jarvisctl") }
            return
        }
        MBLog.log("recap: \(s.repo): \(text.prefix(50))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [say, text]
        try? p.run()
    }

    @MainActor
    static func openTerminal(_ s: ClaudeSession) {
        if let (_, sess) = tmuxPane(forCwd: s.cwd) {
            let clients = run(["tmux", "list-clients", "-F", "#{client_name}"])
            let names = clients.out.split(separator: "\n").map(String.init)
            if let c = names.first {
                run(["tmux", "switch-client", "-c", c, "-t", sess])
                MBLog.log("switched client \(c) to \(sess)")
            } else if Store.shared.config.terminalBundle == "com.mitchellh.ghostty" {
                // No attached client: open a fresh Ghostty window attached to it.
                run(["open", "-na", "Ghostty", "--args", "-e", "tmux", "attach", "-t", sess])
                MBLog.log("opened new Ghostty attached to \(sess)")
            } else {
                MBLog.log("no attached tmux client; attach manually: tmux attach -t \(sess)")
            }
        } else {
            MBLog.log("no tmux pane for \(s.cwd); focusing the terminal")
        }
        if let app = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Store.shared.config.terminalBundle) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    @MainActor
    static func sendPrompt(_ s: ClaudeSession, text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        guard let (pane, _) = tmuxPane(forCwd: s.cwd) else {
            Store.shared.flash("No tmux session for \(s.repo)")
            MBLog.log("sendPrompt FAILED, no pane for \(s.cwd)")
            return false
        }
        let a = run(["tmux", "send-keys", "-t", pane, "-l", t])
        let b = run(["tmux", "send-keys", "-t", pane, "Enter"])
        let ok = a.code == 0 && b.code == 0
        MBLog.log("sendPrompt to \(pane) (\(s.repo)) ok=\(ok): \(t.prefix(60))")
        if ok { Store.shared.flash("Sent to \(s.repo)") }
        return ok
    }

    /// Start a fresh Claude session in the home repo, detached in tmux, and
    /// deliver the prompt once the TUI is ready. The session then flows
    /// through the normal machinery: hooks track it, the ticker narrates,
    /// Jarvis briefs at the end.
    @MainActor
    static func launchSession(prompt: String) {
        let cfg = Store.shared.config
        Store.shared.flash("Starting: \(prompt.prefix(34))…")
        Task.detached {
            let repoName = (cfg.homeRepo as NSString).lastPathComponent
            var name = "cc-\(repoName)-pill"
            var n = 2
            while run(["tmux", "has-session", "-t", "=\(name)"]).code == 0 {
                name = "cc-\(repoName)-pill-\(n)"; n += 1
            }
            var cmd = [cfg.claudeBin]
            switch cfg.permissionMode {
            case "bypass": cmd.append("--dangerously-skip-permissions")
            case "default": break
            default: cmd += ["--permission-mode", "acceptEdits"]
            }
            if !cfg.pillSystemPrompt.isEmpty {
                cmd += ["--append-system-prompt", cfg.pillSystemPrompt]
            }
            let create = run(["tmux", "new-session", "-d", "-s", name,
                              "-c", cfg.homeRepo] + cmd)
            guard create.code == 0 else {
                await MainActor.run {
                    Store.shared.flash("Couldn't start the session")
                    MBLog.log("launch FAILED: \(create.out.prefix(120))")
                }
                return
            }
            // Wait for the input box before typing into it. Auto-mode shows
            // a Bypass Permissions acceptance dialog first: answer it (its
            // selector uses the same ❯ glyph as the input prompt, so match
            // on the ready screen's own marker text instead).
            var ready = false
            var accepted = false
            for _ in 0..<40 {   // up to 20s
                usleep(500_000)
                if run(["tmux", "has-session", "-t", "=\(name)"]).code != 0 { break }
                let pane = run(["tmux", "capture-pane", "-t", name, "-p"]).out
                if !accepted, pane.contains("Yes, I accept") {
                    run(["tmux", "send-keys", "-t", name, "2"])
                    usleep(300_000)
                    run(["tmux", "send-keys", "-t", name, "Enter"])
                    accepted = true
                    continue
                }
                if pane.contains("shift+tab to cycle") || pane.contains("? for shortcuts") {
                    ready = true
                    break
                }
            }
            usleep(600_000)
            let a = run(["tmux", "send-keys", "-t", name, "-l", prompt])
            let b = run(["tmux", "send-keys", "-t", name, "Enter"])
            let line = "launched \(name) ready=\(ready) sent=\(a.code == 0 && b.code == 0): \(prompt.prefix(60))"
            await MainActor.run { MBLog.log(line) }
        }
    }

    @MainActor
    static func jarvisMuted() -> Bool {
        FileManager.default.fileExists(atPath: Store.shared.config.speaker + "/.off")
    }

    @MainActor
    static func toggleMute() {
        let off = Store.shared.config.speaker + "/.off"
        let fm = FileManager.default
        if fm.fileExists(atPath: off) {
            try? fm.removeItem(atPath: off)
            MBLog.log("voice unmuted")
        } else {
            fm.createFile(atPath: off, contents: nil)
            run(["killall", "afplay"])
            MBLog.log("voice muted")
        }
    }
}
