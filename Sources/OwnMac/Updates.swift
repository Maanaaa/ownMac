import AppKit
import Foundation

extension Notification.Name {
    static let ownmacUpdate = Notification.Name("ownmac.update")      // object: String (version)
}

/// Vérification optionnelle : seule connexion réseau de l'app. Lit la dernière version publique
/// sur GitHub, n'envoie rien, et n'installe qu'à la demande (voir UpdateInstaller).
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let url: URL
        var zip: URL? = nil
        var signature: URL? = nil
        var canInstall: Bool { zip != nil && signature != nil }
    }
    enum Phase: Equatable { case idle, working(String), failed(String) }

    static let shared = UpdateChecker()
    private static let api = URL(string: "https://api.github.com/repos/Maanaaa/ownMac/releases/latest")!
    private nonisolated static let assetPrefix = "https://github.com/Maanaaa/ownMac/releases/download/"
    private static let minimumCheckGap: TimeInterval = 60

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "updates.enabled")
            if enabled { start() } else { stop() }
        }
    }
    @Published private(set) var available: Release?
    @Published private(set) var status: String?
    @Published private(set) var phase = Phase.idle

    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastCheck = Date.distantPast

    private init() { enabled = UserDefaults.standard.bool(forKey: "updates.enabled") }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        guard enabled, timer == nil else { return }
        Task { await check() }
        let t = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await UpdateChecker.shared.check() }
        }
        t.tolerance = 600
        timer = t
        // Ouverture du panneau de la barre de menus et sortie de veille : l'état affiché doit être à jour
        let recheck: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfStale() }
        }
        let nc = NotificationCenter.default, wc = NSWorkspace.shared.notificationCenter
        observers = [
            (nc, nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: recheck)),
            (wc, wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: recheck)),
        ]
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        available = nil
        status = nil
    }

    private func checkIfStale() {
        if Date().timeIntervalSince(lastCheck) >= Self.minimumCheckGap { Task { await check() } }
    }

    func check() async {
        lastCheck = Date()
        var request = URLRequest(url: Self.api, timeoutInterval: 15)
        request.setValue("OwnMac", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = Self.parse(data) else {
            status = "Vérification impossible pour l'instant"
            return
        }
        guard Self.isNewer(release.version, than: currentVersion) else {
            available = nil
            status = "OwnMac est à jour"
            return
        }
        status = nil
        available = release
        let key = "updates.notified"
        guard UserDefaults.standard.string(forKey: key) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: key)
        NotificationCenter.default.post(name: .ownmacUpdate, object: release.version)
    }

    func openDownload() {
        if let available { NSWorkspace.shared.open(available.url) }
    }

    /// Télécharge, vérifie, puis laisse le script remplacer l'app une fois celle-ci fermée.
    func install() async {
        guard let release = available, let zip = release.zip, let signature = release.signature else {
            openDownload()
            return
        }
        guard phase != .working("Téléchargement…"), phase != .working("Installation…") else { return }
        phase = .working("Téléchargement…")
        do {
            let app = try await UpdateInstaller.prepare(zipURL: zip, signatureURL: signature, currentVersion: currentVersion)
            phase = .working("Installation…")
            // La nouvelle copie peut changer d'emplacement : son lancement au démarrage est à réenregistrer
            UserDefaults.standard.set(LoginItem.isEnabled, forKey: "update.restoreLoginItem")
            try UpdateInstaller.launchSwap(new: app, destination: UpdateInstaller.destination())
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let link = json["html_url"] as? String, let url = URL(string: link),
              url.host == "github.com" else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) -> URL? {
            assets.first { $0["name"] as? String == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap { $0.hasPrefix(assetPrefix) ? URL(string: $0) : nil }
        }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: url,
                       zip: asset("OwnMac.zip"), signature: asset("OwnMac.zip.sig"))
    }

    /// Comparaison numérique : 0.10.0 est plus récent que 0.9.0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}
