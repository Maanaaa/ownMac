import AppKit
import SwiftUI

extension Notification.Name {
    static let ownmacCopied = Notification.Name("ownmac.copied")                  // object: String
    static let ownmacPresenceCheck = Notification.Name("ownmac.presenceCheck")    // object: Bool
}

// MARK: - État partagé entre les écrans

struct IslandToast: Equatable {
    let id = UUID()
    let icon: String, title: String, subtitle: String?, tint: Color
}

struct Track: Equatable {
    var title: String, artist: String, app: String, playing: Bool
}

enum IslandMode: Hashable { case idle, compact, toast, expanded }

@MainActor
final class IslandModel: ObservableObject {
    @Published var toast: IslandToast?
    @Published var track: Track?
    @Published var timerEnd: Date?
    @Published var now = Date()
    @Published var alert: HealthAlert?
    var onDismissAlert: ((HealthAlert.Kind) -> Void)?

    private var toastTask: Task<Void, Never>?
    private var ticker: Timer?
    private var presenceToastID: UUID?
    private let scriptQueue = DispatchQueue(label: "ownmac.island.script")

    var remaining: Int { max(0, Int((timerEnd?.timeIntervalSince(now) ?? 0).rounded(.up))) }
    var remainingText: String { String(format: "%d:%02d", remaining / 60, remaining % 60) }

    init() {
        let dc = DistributedNotificationCenter.default()
        for (name, app) in [("com.apple.Music.playerInfo", "Music"), ("com.spotify.client.PlaybackStateChanged", "Spotify")] {
            dc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] n in
                let title = n.userInfo?["Name"] as? String ?? ""
                let artist = n.userInfo?["Artist"] as? String ?? ""
                let state = n.userInfo?["Player State"] as? String ?? ""
                Task { @MainActor in self?.updateTrack(title, artist, state, app) }
            }
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: .ownmacCopied, object: nil, queue: .main) { [weak self] n in
            let text = n.object as? String ?? ""
            Task { @MainActor in self?.showCopied(text) }
        }
        nc.addObserver(forName: .ownmacPresenceCheck, object: nil, queue: .main) { [weak self] n in
            let active = n.object as? Bool ?? false
            Task { @MainActor in self?.showPresence(active) }
        }
    }

    // MARK: Toasts

    func show(_ t: IslandToast, for seconds: Double?) {
        toastTask?.cancel()
        toast = t
        guard let seconds else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    private func showCopied(_ text: String) {
        // Si le presse-papier est protégé, on n'affiche pas son contenu à l'écran
        let hide = UserDefaults.standard.bool(forKey: "clip.protect")
        let preview = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        show(IslandToast(icon: "doc.on.doc.fill", title: "Copié", subtitle: hide ? nil : preview, tint: .blue), for: 2)
    }

    private func showPresence(_ active: Bool) {
        if active {
            let t = IslandToast(icon: "eye.fill", title: "Vérification de présence", subtitle: "Caméra allumée quelques secondes", tint: .green)
            presenceToastID = t.id
            show(t, for: nil)
        } else if toast?.id == presenceToastID {
            toast = nil
        }
    }

    // MARK: Musique (notifications publiques de Musique et Spotify)

    private func updateTrack(_ title: String, _ artist: String, _ state: String, _ app: String) {
        guard state != "Stopped", !title.isEmpty else { if track?.app == app { track = nil }; return }
        let changed = track?.title != title
        track = Track(title: title, artist: artist, app: app, playing: state == "Playing")
        if changed && state == "Playing" {
            show(IslandToast(icon: "music.note", title: title, subtitle: artist, tint: .pink), for: 3)
        }
    }

    func control(_ action: String) {
        guard let app = track?.app else { return }
        let verb = (action == "previous") ? (app == "Spotify" ? "previous track" : "back track")
                                          : (action == "next" ? "next track" : "playpause")
        scriptQueue.async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(app)\" to \(verb)")?.executeAndReturnError(&error)
            guard error != nil else { return }
            Task { @MainActor in
                self?.show(IslandToast(icon: "exclamationmark.triangle.fill", title: "Contrôle impossible",
                                       subtitle: "Autorise OwnMac à piloter \(app) (Confidentialité > Automatisation)", tint: .orange), for: 4)
            }
        }
    }

    // MARK: Minuteur

    func startTimer(minutes: Int) {
        now = Date()
        timerEnd = now.addingTimeInterval(Double(minutes) * 60)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stopTimer() { ticker?.invalidate(); ticker = nil; timerEnd = nil }

    private func tick() {
        now = Date()
        guard remaining == 0 else { return }
        stopTimer()
        NSSound(named: "Glass")?.play()
        show(IslandToast(icon: "timer", title: "Minuteur terminé", subtitle: nil, tint: .orange), for: 5)
    }
}

/// Ce qui dépend de l'écran : encoche réelle ou pastille virtuelle.
@MainActor
final class IslandScreen: ObservableObject {
    let notch: CGSize, hasNotch: Bool
    @Published var expanded = false

    init(notch: CGSize, hasNotch: Bool) { self.notch = notch; self.hasNotch = hasNotch }

    func mode(_ m: IslandModel) -> IslandMode {
        if expanded { return .expanded }
        if m.toast != nil { return .toast }
        if m.alert != nil || m.timerEnd != nil || m.track?.playing == true { return .compact }
        return .idle
    }

    func size(_ m: IslandModel) -> CGSize {
        switch mode(m) {
        case .expanded: CGSize(width: 400, height: notch.height + 118 + (m.alert == nil ? 0 : 72))
        case .toast:    CGSize(width: 340, height: notch.height + 50)
        case .compact:  CGSize(width: notch.width + (m.alert == nil ? 150 : 230), height: notch.height)
        case .idle:     notch
        }
    }
}

// MARK: - Contrôleur (un panneau par écran)

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Le premier clic doit agir même si le panneau n'est jamais la fenêtre active.
private final class FirstMouseHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandController {
    static let shared = IslandController()
    private static let windowSize = CGSize(width: 480, height: 240)

    private struct Entry { let panel: NSPanel; let state: IslandScreen; let top: CGFloat; let centerX: CGFloat }

    private let model = IslandModel()
    private lazy var health = HealthMonitor(model: model)
    private var entries: [Entry] = []
    private var monitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var poll: Timer?

    func setEnabled(_ on: Bool) {
        teardown()
        guard on else { return }
        rebuild()
        health.start()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            Task { @MainActor in IslandController.shared.mouseMoved() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in IslandController.shared.rebuild() }
        }
    }

    private func teardown() {
        health.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        monitor = nil; screenObserver = nil
        poll?.invalidate(); poll = nil
        entries.forEach { $0.panel.close() }
        entries = []
    }

    private func rebuild() {
        entries.forEach { $0.panel.close() }
        entries = NSScreen.screens.map(makeEntry)
    }

    private func makeEntry(_ screen: NSScreen) -> Entry {
        let hasNotch = screen.safeAreaInsets.top > 0
        let left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea
        let notch = hasNotch
            ? CGSize(width: screen.frame.width - (left?.width ?? 0) - (right?.width ?? 0), height: screen.safeAreaInsets.top)
            : CGSize(width: 180, height: max(screen.frame.maxY - screen.visibleFrame.maxY, 28))
        let centerX = screen.frame.minX + (left?.width ?? (screen.frame.width - notch.width) / 2) + notch.width / 2
        let state = IslandScreen(notch: notch, hasNotch: hasNotch)

        let s = Self.windowSize
        let panel = IslandPanel(contentRect: NSRect(x: centerX - s.width / 2, y: screen.frame.maxY - s.height, width: s.width, height: s.height),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)   // au-dessus de la barre de menus
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let host = FirstMouseHost(rootView: IslandView(model: model, screen: state))
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()
        return Entry(panel: panel, state: state, top: screen.frame.maxY, centerX: centerX)
    }

    private func rect(_ e: Entry, margin: CGFloat = 0) -> NSRect {
        let size = e.state.size(model)
        return NSRect(x: e.centerX - size.width / 2, y: e.top - size.height, width: size.width, height: size.height)
            .insetBy(dx: -margin, dy: -margin)
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        for e in entries where !e.state.expanded {
            // Sans encoche et au repos, seul le bord tout en haut déclenche : on ne gêne pas la barre de menus
            let idlePill = !e.state.hasNotch && e.state.mode(model) == .idle
            let inside = rect(e).contains(p) && (!idlePill || p.y >= e.top - 2)
            if inside { setExpanded(e, true) }
        }
    }

    private func setExpanded(_ e: Entry, _ on: Bool) {
        e.state.expanded = on
        e.panel.ignoresMouseEvents = !on
        guard on, poll == nil else { return }
        // Une fois le curseur sur le panneau, le moniteur global ne reçoit plus rien : on suit la sortie ici.
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in IslandController.shared.checkLeave() }
        }
    }

    private func checkLeave() {
        let p = NSEvent.mouseLocation
        for e in entries where e.state.expanded && !rect(e, margin: 14).contains(p) { setExpanded(e, false) }
        if !entries.contains(where: { $0.state.expanded }) { poll?.invalidate(); poll = nil }
    }
}

// MARK: - Vues

/// Bas arrondi, haut évasé pour se fondre dans le bord de l'écran, comme l'encoche.
struct NotchShape: Shape {
    var flare: CGFloat = 10
    var bottom: CGFloat

    var animatableData: CGFloat {
        get { bottom }
        set { bottom = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: flare, y: flare), control: CGPoint(x: flare, y: 0))
        p.addLine(to: CGPoint(x: flare, y: h - bottom))
        p.addQuadCurve(to: CGPoint(x: flare + bottom, y: h), control: CGPoint(x: flare, y: h))
        p.addLine(to: CGPoint(x: w - flare - bottom, y: h))
        p.addQuadCurve(to: CGPoint(x: w - flare, y: h - bottom), control: CGPoint(x: w - flare, y: h))
        p.addLine(to: CGPoint(x: w - flare, y: flare))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - flare, y: 0))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var screen: IslandScreen

    private var mode: IslandMode { screen.mode(model) }

    var body: some View {
        let size = screen.size(model)
        ZStack(alignment: .top) {
            NotchShape(bottom: mode == .compact ? 12 : 24)
                .fill(.black)
                .frame(width: size.width + 20, height: size.height)
            Group {
                switch mode {
                case .compact: compact
                case .toast: if let t = model.toast { toastView(t) }
                case .expanded: expanded
                case .idle: EmptyView()
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
            .transition(.opacity)
        }
        .opacity(mode == .idle ? 0 : 1)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: mode)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: model.alert?.kind)
    }

    // Icône à gauche de l'encoche, info à droite
    private var compact: some View {
        HStack {
            if let a = model.alert {
                Image(systemName: a.icon).foregroundStyle(alertColor(a))
                Spacer()
                Text(a.shortLabel).font(.system(.caption, design: .rounded, weight: .semibold))
                    .lineLimit(1).frame(maxWidth: 92, alignment: .trailing).foregroundStyle(alertColor(a))
            } else if model.timerEnd != nil {
                Image(systemName: "timer").foregroundStyle(.orange)
                Spacer()
                Text(model.remainingText).font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit().foregroundStyle(.orange)
            } else {
                Image(systemName: "music.note").foregroundStyle(.pink)
                Spacer()
                MusicBars()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: screen.notch.height)
    }

    private func toastView(_ t: IslandToast) -> some View {
        HStack(spacing: 12) {
            Image(systemName: t.icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(t.tint.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.system(.callout, design: .rounded, weight: .semibold)).lineLimit(1)
                if let s = t.subtitle, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, screen.notch.height + 4)
    }

    private var expanded: some View {
        VStack(spacing: 10) {
            if let a = model.alert {
                alertRow(a)
                Divider().overlay(.white.opacity(0.15))
            }
            musicRow
            Divider().overlay(.white.opacity(0.15))
            timerRow
        }
        .padding(.horizontal, 20)
        .padding(.top, screen.notch.height + 10)
    }

    private func alertColor(_ a: HealthAlert) -> Color { a.critical ? .red : .orange }

    private func alertRow(_ a: HealthAlert) -> some View {
        HStack(spacing: 12) {
            Image(systemName: a.icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(alertColor(a).gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.system(.callout, design: .rounded, weight: .semibold)).lineLimit(1)
                Text(a.detail).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if let c = a.culprit, c.canQuit {
                    Button("Quitter") { c.quit() }.buttonStyle(.plain).foregroundStyle(.orange)
                        .font(.caption.weight(.semibold))
                }
                Button("Ignorer") { model.onDismissAlert?(a.kind) }.buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6)).font(.caption)
            }
        }
    }

    private var musicRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background((model.track == nil ? Color.gray : .pink).gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.track?.title ?? "Aucune lecture").font(.system(.callout, design: .rounded, weight: .semibold)).lineLimit(1)
                Text(model.track?.artist ?? "Musique ou Spotify").font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let t = model.track {
                iconButton("backward.fill") { model.control("previous") }
                iconButton(t.playing ? "pause.fill" : "play.fill") { model.control("playpause") }
                iconButton("forward.fill") { model.control("next") }
            }
        }
    }

    private var timerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer").foregroundStyle(.orange)
            if model.timerEnd != nil {
                Text(model.remainingText).font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit()
                Spacer()
                Button("Arrêter") { model.stopTimer() }.buttonStyle(.plain).foregroundStyle(.orange)
            } else {
                Text("Minuteur").font(.system(.callout, design: .rounded, weight: .semibold))
                Spacer()
                ForEach([5, 15, 25], id: \.self) { m in
                    Button("\(m) min") { model.startTimer(minutes: m) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.14), in: .capsule)
                }
            }
        }
    }

    private func iconButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13)).frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// Barres d'égaliseur décoratives : 4 images/s suffisent, pour rester léger.
struct MusicBars: View {
    private let heights: [ClosedRange<CGFloat>] = [4...14, 7...16, 3...12, 6...15]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<heights.count, id: \.self) { i in
                    let phase = (sin(t * (3 + Double(i) * 1.3) + Double(i)) + 1) / 2
                    let r = heights[i]
                    Capsule().fill(.pink)
                        .frame(width: 3, height: r.lowerBound + (r.upperBound - r.lowerBound) * phase)
                }
            }
            .frame(height: 16)
            .animation(.easeInOut(duration: 0.25), value: t)
        }
    }
}
