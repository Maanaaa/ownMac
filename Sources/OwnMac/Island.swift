import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let ownmacCopied = Notification.Name("ownmac.copied")                  // object: String
    static let ownmacPresenceCheck = Notification.Name("ownmac.presenceCheck")    // object: Bool
}

// MARK: - État partagé entre les écrans

struct IslandToast: Equatable {
    let id = UUID()
    let icon: String, title: String, subtitle: String?, tint: Color
    var progress: Double? = nil       // affiche une jauge (batterie)
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
    @Published var shelf: [URL] = []
    @Published var dropActive = false     // un fichier est glissé vers l'île
    @Published var dropHover = false      // il survole la zone de dépôt
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
        nc.addObserver(forName: .ownmacUpdate, object: nil, queue: .main) { [weak self] n in
            let version = n.object as? String ?? ""
            Task { @MainActor in
                self?.show(IslandToast(icon: "arrow.down.circle.fill", title: "OwnMac \(version) disponible",
                                       subtitle: "À télécharger depuis Réglages", tint: .blue), for: 6)
            }
        }
        nc.addObserver(forName: .ownmacReady, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.show(IslandToast(icon: "sparkles", title: "OwnMac est prêt", subtitle: "Survole l'encoche pour commencer", tint: .blue), for: 5)
            }
        }
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

    // MARK: Étagère (références aux fichiers : rien n'est copié ni déplacé)

    func addToShelf(_ urls: [URL]) {
        for url in urls where url.isFileURL && FileManager.default.fileExists(atPath: url.path) && !shelf.contains(url) {
            shelf.append(url)
        }
    }

    func removeFromShelf(_ url: URL) { shelf.removeAll { $0 == url } }
    func clearShelf() { shelf.removeAll() }
    func pruneShelf() { shelf.removeAll { !FileManager.default.fileExists(atPath: $0.path) } }

    func receive(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for p in matching {
            p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in self?.addToShelf([url]) }
            }
        }
        return !matching.isEmpty
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
        if m.alert != nil || m.timerEnd != nil || m.track?.playing == true || !m.shelf.isEmpty { return .compact }
        return .idle
    }

    func size(_ m: IslandModel) -> CGSize {
        switch mode(m) {
        case .expanded:
            if m.dropActive { return CGSize(width: 400, height: notch.height + 104) }
            return CGSize(width: 400, height: notch.height + 118 + (m.alert == nil ? 0 : 72) + (m.shelf.isEmpty ? 0 : 92))
        case .toast:   return CGSize(width: 340, height: notch.height + 50)
        case .compact: return CGSize(width: notch.width + (m.alert == nil ? 150 : 230), height: notch.height)
        case .idle:    return notch
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
    private static let windowSize = CGSize(width: 480, height: 340)

    private struct Entry { let panel: NSPanel; let state: IslandScreen; let top: CGFloat; let centerX: CGFloat }

    private let model = IslandModel()
    private lazy var health = HealthMonitor(model: model)
    private lazy var power = PowerMonitor(model: model)
    private var dragMonitors: [Any] = []
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var entries: [Entry] = []
    private var monitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var poll: Timer?

    func setEnabled(_ on: Bool) {
        teardown()
        guard on else { return }
        rebuild()
        health.start()
        power.start()
        dragMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
                Task { @MainActor in IslandController.shared.mouseDown() }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { _ in
                Task { @MainActor in IslandController.shared.mouseDragged() }
            },
        ].compactMap { $0 }
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
        power.stop()
        dragMonitors.forEach(NSEvent.removeMonitor)
        dragMonitors = []
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

    private func mouseDown() { dragChangeCount = NSPasteboard(name: .drag).changeCount }

    /// macOS remplit le presse-papier de glisser au début d'un glisser de fichier : c'est le signal.
    private func mouseDragged() {
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != dragChangeCount, board.types?.contains(.fileURL) == true else { return }
        let p = NSEvent.mouseLocation
        for e in entries where !e.state.expanded {
            let zone = NSRect(x: e.centerX - 170, y: e.top - 70, width: 340, height: 70)
            if zone.contains(p) {
                model.dropActive = true
                setExpanded(e, true)
            }
        }
    }

    private func setExpanded(_ e: Entry, _ on: Bool) {
        if on { model.pruneShelf() }
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
        let pressed = NSEvent.pressedMouseButtons != 0
        // Pendant qu'on sort un fichier de l'étagère, l'île doit rester ouverte jusqu'au lâcher
        for e in entries where e.state.expanded && !rect(e, margin: 14).contains(p) && (!pressed || model.dropActive) {
            setExpanded(e, false)
        }
        if !pressed { model.dropActive = false }
        if !entries.contains(where: { $0.state.expanded }) {
            model.dropActive = false
            poll?.invalidate(); poll = nil
        }
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
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(get: { model.dropHover }, set: { model.dropHover = $0 })) {
            model.receive($0)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: mode)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: model.dropActive)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: model.shelf)
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
            } else if model.track?.playing == true {
                Image(systemName: "music.note").foregroundStyle(.pink)
                Spacer()
                MusicBars()
            } else {
                Image(systemName: "tray.full.fill").foregroundStyle(.blue)
                Spacer()
                Text("\(model.shelf.count)").font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit().foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: screen.notch.height)
    }

    private func toastView(_ t: IslandToast) -> some View {
        HStack(spacing: 12) {
            Image(systemName: t.icon)
                .font(.system(size: 14, weight: .semibold))
                .symbolEffect(.pulse, isActive: t.progress != nil)
                .frame(width: 32, height: 32)
                .background(t.tint.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.system(.callout, design: .rounded, weight: .semibold)).lineLimit(1)
                if let s = t.subtitle, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let p = t.progress { batteryGauge(p, t.tint) }
        }
        .padding(.horizontal, 20)
        .padding(.top, screen.notch.height + 4)
    }

    private func batteryGauge(_ level: Double, _ tint: Color) -> some View {
        Capsule().fill(.white.opacity(0.18)).frame(width: 52, height: 18)
            .overlay(alignment: .leading) {
                Capsule().fill(tint.gradient).frame(width: max(14, 52 * min(1, level)))
            }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 22))
                .symbolEffect(.bounce, value: model.dropHover)
            Text("Dépose ici").font(.system(.callout, design: .rounded, weight: .semibold))
        }
        .foregroundStyle(model.dropHover ? .white : .white.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.dropHover ? Color.blue.opacity(0.35) : .clear,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
    }

    private var shelfRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Étagère").font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button("Vider") { model.clearShelf() }.buttonStyle(.plain).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.shelf, id: \.self) { ShelfItem(url: $0, model: model) }
                }
            }
        }
    }

    private var expanded: some View {
        VStack(spacing: 10) {
            if model.dropActive {
                dropZone
            } else {
            if let a = model.alert {
                alertRow(a)
                Divider().overlay(.white.opacity(0.15))
            }
            if !model.shelf.isEmpty {
                shelfRow
                Divider().overlay(.white.opacity(0.15))
            }
            musicRow
            Divider().overlay(.white.opacity(0.15))
            timerRow
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, screen.notch.height + 10)
        .padding(.bottom, model.dropActive ? 14 : 0)
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

/// Un fichier de l'étagère : à glisser vers n'importe quelle app.
struct ShelfItem: View {
    let url: URL
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 34, height: 34)
            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                .frame(width: 58)
        }
        .overlay(alignment: .topTrailing) {
            Button { model.removeFromShelf(url) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
        }
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help(url.path)
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
