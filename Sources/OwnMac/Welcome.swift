import AppKit
import SwiftUI

final class WelcomeModel: ObservableObject {
    @Published var page = 0
    @Published var launchAtLogin = LoginItem.isEnabled
    static let pageCount = 4
}

/// Fenêtre d'introduction, affichée une fois. Reste accessible depuis Réglages.
@MainActor
final class WelcomeController {
    static let shared = WelcomeController()
    private static let doneKey = "welcome.done"

    private var window: NSWindow?
    private var observer: NSObjectProtocol?

    func showIfNeeded() {
        if !UserDefaults.standard.bool(forKey: Self.doneKey) { show() }
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: WelcomeView(model: WelcomeModel(), hasNotch: hasNotch) { [weak w] in w?.close() })
        w.center()
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in WelcomeController.shared.closed() }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closed() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        window = nil
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    let hasNotch: Bool
    let finish: () -> Void
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case 0: page(icon: "slider.horizontal.3", tint: .accentColor, title: "Bienvenue sur OwnMac",
                             text: "Ton Mac te parle dans l'encoche, et tes réglages tiennent dans la barre de menus.")
                case 1: page(icon: "capsule.fill", tint: .black, title: "Découvre l'île",
                             text: hasNotch
                                ? "Passe le curseur sur l'encoche pour l'ouvrir. Sur un écran externe, colle-le tout en haut, au centre."
                                : "Colle le curseur tout en haut de l'écran, au centre, pour l'ouvrir.")
                case 2: page(icon: "tray.and.arrow.down.fill", tint: .blue, title: "Garde tes fichiers à portée",
                             text: "Glisse un fichier vers le haut de l'écran : l'étagère de l'île le garde pour toi. Reprends-le quand tu veux, depuis n'importe quelle app.")
                default: choices
                }
            }
            .id(model.page)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if model.page > 0 {
                    Button("Retour") { go(-1) }.buttonStyle(.glass)
                }
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<WelcomeModel.pageCount, id: \.self) { i in
                        Circle().fill(i == model.page ? Color.primary : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if model.page < WelcomeModel.pageCount - 1 {
                    Button("Continuer") { go(1) }.buttonStyle(.glassProminent)
                } else {
                    Button("Commencer", action: finish).buttonStyle(.glassProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 520, height: 440)
    }

    private func go(_ step: Int) {
        withAnimation(.smooth(duration: 0.25)) { model.page += step }
    }

    private func page(icon: String, tint: Color, title: String, text: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold)).multilineTextAlignment(.center)
            Text(text).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 400).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tes choix").font(.system(.largeTitle, design: .rounded, weight: .bold))
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { on in
                    LoginItem.set(on)
                    model.launchAtLogin = LoginItem.isEnabled
                })) { choice("Lancer au démarrage", "OwnMac reste disponible dans la barre de menus.") }
                Divider()
                Toggle(isOn: $updates.enabled) {
                    choice("Vérifier les mises à jour", "Interroge GitHub de temps en temps. Rien n'est envoyé, et l'app ne fait aucune autre connexion.")
                }
            }
            .padding(16)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("Pour afficher la barre de menus, clique sur l'icône de curseurs en haut à droite. Ces choix s'y retrouvent, dans Réglages.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func choice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
