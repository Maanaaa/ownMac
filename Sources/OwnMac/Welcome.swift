import AppKit
import CoreText
import SwiftUI

extension Notification.Name {
    static let ownmacReady = Notification.Name("ownmac.ready")      // fin de la bienvenue
}

// MARK: - Lettrage : le contour du mot, tracé comme à la plume

enum Lettering {
    /// Contour vectoriel d'un mot, lettre par lettre, de gauche à droite.
    static func path(_ text: String, font: String, size: CGFloat) -> CGPath {
        let ctFont = CTFontCreateWithName(font as CFString, size, nil)
        let attributed = CFAttributedStringCreate(nil, text as CFString,
                                                  [kCTFontAttributeName: ctFont] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let result = CGMutablePath()
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for i in 0..<CTRunGetGlyphCount(run) {
                let range = CFRange(location: i, length: 1)
                var glyph = CGGlyph(), position = CGPoint.zero
                CTRunGetGlyphs(run, range, &glyph)
                CTRunGetPositions(run, range, &position)
                guard let outline = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                result.addPath(outline, transform: CGAffineTransform(translationX: position.x, y: position.y))
            }
        }
        return result
    }
}

/// Recadre le mot dans l'espace disponible, et remet l'axe vertical dans le sens de SwiftUI.
struct LetteringShape: Shape, @unchecked Sendable {     // CGPath est immuable
    let glyphs: CGPath

    func path(in rect: CGRect) -> Path {
        let box = glyphs.boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return Path() }
        let scale = min(rect.width / box.width, rect.height / box.height)
        let t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        return Path(glyphs).applying(t)
    }
}

// MARK: - Déroulé

@MainActor
final class WelcomeModel: ObservableObject {
    enum Stage { case hello, tour }
    static let pageCount = 3

    @Published var stage = Stage.hello
    @Published var stroke: CGFloat = 0      // avancement du tracé
    @Published var fill = 0.0               // remplissage des lettres
    @Published var helloGone = false
    @Published var page = 0
    @Published var beat = 0                 // tempo des petites démos
    @Published var launchAtLogin = LoginItem.isEnabled

    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var ticker: Timer?

    /// Hors du dossier Applications, macOS peut exécuter l'app depuis un emplacement temporaire.
    var isOutsideApplications: Bool {
        let path = Bundle.main.bundleURL.path
        return !(path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"))
    }

    func play() async {
        if reduceMotion {
            stroke = 1
            fill = 1
            await pause(1.4)
        } else {
            await pause(0.5)
            withAnimation(.easeInOut(duration: 3)) { stroke = 1 }
            await pause(2.7)
            withAnimation(.easeIn(duration: 0.8)) { fill = 1 }
            await pause(1.3)
            withAnimation(.easeIn(duration: 0.6)) { helloGone = true }
            await pause(0.5)
        }
        showTour()
    }

    func showTour() {
        withAnimation(.smooth(duration: 0.7)) { stage = .tour }
        guard ticker == nil, !reduceMotion else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 2.3, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { self.beat += 1 }
            }
        }
    }

    func go(_ step: Int) {
        withAnimation(.smooth(duration: 0.45)) {
            page = min(max(page + step, 0), Self.pageCount - 1)
            beat = 0
        }
    }

    func stop() { ticker?.invalidate(); ticker = nil }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Fenêtre plein écran

private final class WelcomeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Plein écran au premier lancement, puis accessible depuis Réglages.
@MainActor
final class WelcomeController {
    static let shared = WelcomeController()
    /// Clé propre à cette version : les personnes déjà installées découvrent aussi la nouvelle bienvenue.
    private static let doneKey = "welcome.v2.done"

    private var window: NSWindow?
    private var model: WelcomeModel?
    private var escape: Any?

    func showIfNeeded() {
        if !UserDefaults.standard.bool(forKey: Self.doneKey) { show() }
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }

        let model = WelcomeModel()
        let w = WelcomeWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)     // couvre la barre de menus et le Dock
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WelcomeView(model: model) { WelcomeController.shared.finish() })
        host.sizingOptions = []        // la fenêtre garde la taille de l'écran, quel que soit le contenu
        w.contentView = host
        w.setFrame(screen.frame, display: true)
        window = w
        self.model = model

        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }        // Échap
            Task { @MainActor in WelcomeController.shared.finish() }
            return nil
        }
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.6; w.animator().alphaValue = 1 }
        Task { await model.play() }
    }

    private func finish() {
        guard let w = window else { return }
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        model?.stop()
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
        window = nil
        model = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.7; w.animator().alphaValue = 0 }, completionHandler: {
            w.orderOut(nil)
            NotificationCenter.default.post(name: .ownmacReady, object: nil)
        })
    }
}

// MARK: - Vues

struct Aurora: View {
    let moving: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + 0.18 * sin(t * 0.31), 0], [1, 0],
                [0, 0.5 + 0.2 * sin(t * 0.27)],
                [0.5 + 0.2 * sin(t * 0.37), 0.5 + 0.2 * cos(t * 0.29)],
                [1, 0.5 + 0.2 * cos(t * 0.33)],
                [0, 1], [0.5 + 0.18 * cos(t * 0.23), 1], [1, 1],
            ], colors: [
                .black, Color(red: 0.11, green: 0.08, blue: 0.32), .black,
                Color(red: 0.05, green: 0.16, blue: 0.42), Color(red: 0.42, green: 0.12, blue: 0.5), Color(red: 0.62, green: 0.13, blue: 0.3),
                .black, Color(red: 0.12, green: 0.08, blue: 0.3), .black,
            ])
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    let finish: () -> Void

    var body: some View {
        ZStack {
            Aurora(moving: !model.reduceMotion).ignoresSafeArea()
            if model.stage == .hello { hello } else { tour.transition(.opacity.combined(with: .scale(scale: 0.97))) }
            VStack {
                HStack {
                    Spacer()
                    Button("Passer", action: finish).buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            .padding(30)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var hello: some View {
        let shape = LetteringShape(glyphs: Lettering.path("Bonjour", font: "SnellRoundhand-Bold", size: 300))
        return ZStack {
            shape.trim(from: 0, to: model.stroke)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            shape.fill(.white).opacity(model.fill)
        }
        .frame(maxWidth: 760, maxHeight: 340)
        .padding(40)
        .scaleEffect(model.helloGone ? 1.12 : 1)
        .blur(radius: model.helloGone ? 18 : 0)
        .opacity(model.helloGone ? 0 : 1)
        .accessibilityLabel("Bonjour")
    }

    private var tour: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Group {
                switch model.page {
                case 0: scene(title: "Ton Mac te parle.", text: "Copies, charge, surchauffe : tout passe par l'encoche, puis disparaît.") {
                    IslandDemo(beat: model.beat)
                }
                case 1: scene(title: "Une étagère au-dessus de tout.", text: "Glisse un fichier vers le haut de l'écran et reprends-le depuis n'importe quelle app.") {
                    ShelfDemo(beat: model.beat)
                }
                default: choices
                }
            }
            .id(model.page)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 26)), removal: .opacity))
            Spacer(minLength: 20)
            HStack {
                Button("Retour") { model.go(-1) }.buttonStyle(.glass).opacity(model.page > 0 ? 1 : 0).disabled(model.page == 0)
                Spacer()
                HStack(spacing: 8) {
                    ForEach(0..<WelcomeModel.pageCount, id: \.self) { i in
                        Capsule().fill(.white.opacity(i == model.page ? 0.95 : 0.3))
                            .frame(width: i == model.page ? 22 : 7, height: 7)
                    }
                }
                Spacer()
                if model.page < WelcomeModel.pageCount - 1 {
                    Button("Continuer") { model.go(1) }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Commencer", action: finish).buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.extraLarge)
            .frame(maxWidth: 640)
            .padding(.bottom, 56)
        }
        .padding(.horizontal, 32)
    }

    private func scene<Demo: View>(title: String, text: String, @ViewBuilder demo: () -> Demo) -> some View {
        VStack(spacing: 30) {
            demo()
            VStack(spacing: 12) {
                Text(title).font(.system(size: 54, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6).lineLimit(2)
                Text(text).font(.title2).foregroundStyle(.white.opacity(0.72)).multilineTextAlignment(.center)
                    .frame(maxWidth: 580).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var choices: some View {
        VStack(spacing: 26) {
            Text("Dernière chose.").font(.system(size: 54, weight: .bold, design: .rounded))
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { on in
                    LoginItem.set(on)
                    model.launchAtLogin = LoginItem.isEnabled
                })) { choice("Lancer au démarrage", "OwnMac reste disponible dans la barre de menus.") }
                Divider()
                UpdateChoice(render: choice)
            }
            .padding(22)
            .frame(maxWidth: 580)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            if model.isOutsideApplications {
                Label("Range OwnMac dans le dossier Applications pour que le lancement au démarrage reste fiable.", systemImage: "folder.fill")
                    .font(.callout).foregroundStyle(.orange).frame(maxWidth: 580)
            }
            Text("Clique sur l'icône de curseurs en haut à droite pour retrouver tes réglages.")
                .font(.callout).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
        }
    }

    private func choice(_ title: String, _ detail: String) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
        })
    }
}

private struct UpdateChoice: View {
    @ObservedObject private var updates = UpdateChecker.shared
    let render: (String, String) -> AnyView

    var body: some View {
        Toggle(isOn: $updates.enabled) {
            render("Vérifier les mises à jour", "Interroge GitHub de temps en temps, et installe une nouvelle version quand tu le demandes. Rien n'est envoyé.")
        }
    }
}

/// Une île miniature, dans un coin d'écran en verre.
private struct DemoScreen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) { content }
            .frame(width: 560, height: 230, alignment: .top)
            .background(.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

private struct DemoIsland<Content: View>: View {
    let width: CGFloat, height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: width, height: height)
            .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26, style: .continuous))
            .clipped()
    }
}

private struct IslandDemo: View {
    let beat: Int
    private let toasts: [(String, String, String, Color)] = [
        ("doc.on.doc.fill", "Copié", "Compte rendu de la réunion", .blue),
        ("bolt.fill", "En charge : 42 %", "Pleine charge dans 1 h 15 min", .green),
        ("flame.fill", "Mac très chaud, il ralentit", "Une app : 240 % du CPU", .orange),
    ]

    var body: some View {
        let t = toasts[beat % toasts.count]
        DemoScreen {
            DemoIsland(width: 420, height: 92) {
                HStack(spacing: 14) {
                    Image(systemName: t.0).font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44).background(t.3.gradient, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.1).font(.system(.title3, design: .rounded, weight: .semibold))
                        Text(t.2).font(.callout).foregroundStyle(.white.opacity(0.62))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .id(beat)
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
    }
}

private struct ShelfDemo: View {
    let beat: Int

    var body: some View {
        let step = beat % 3
        DemoScreen {
            DemoIsland(width: step == 2 ? 240 : 420, height: step == 0 ? 34 : (step == 1 ? 118 : 34)) {
                ZStack {
                    if step == 1 {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                            .background(Color.blue.opacity(0.3), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(14)
                    }
                    if step == 2 {
                        HStack {
                            Image(systemName: "tray.full.fill")
                            Spacer()
                            Text("1").fontWeight(.semibold)
                        }
                        .foregroundStyle(.blue).padding(.horizontal, 18)
                    }
                }
            }
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 42))
                .foregroundStyle(.blue, .white)
                .frame(width: 76, height: 92)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(radius: 12, y: 6)
                .scaleEffect(step == 1 ? 0.62 : 1)
                .rotationEffect(.degrees(step == 0 ? -6 : 0))
                .offset(y: step == 0 ? 124 : 18)
                .opacity(step == 2 ? 0 : 1)
        }
    }
}
