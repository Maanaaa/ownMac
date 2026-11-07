import AppKit
import Foundation

extension Notification.Name {
    static let ownmacUpdate = Notification.Name("ownmac.update")      // object: String (version)
}

/// Vérification optionnelle : seule connexion réseau de l'app. Ne lit que la dernière version
/// publique sur GitHub, n'envoie rien et n'installe rien : l'utilisateur télécharge lui-même.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable { let version: String; let url: URL }

    static let shared = UpdateChecker()
    private static let api = URL(string: "https://api.github.com/repos/Maanaaa/ownMac/releases/latest")!

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "updates.enabled")
            if enabled { start() } else { timer?.invalidate(); timer = nil; available = nil }
        }
    }
    @Published private(set) var available: Release?

    private var timer: Timer?

    private init() { enabled = UserDefaults.standard.bool(forKey: "updates.enabled") }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        guard enabled, timer == nil else { return }
        Task { await check() }
        let t = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await UpdateChecker.shared.check() }
        }
        t.tolerance = 3600
        timer = t
    }

    func check() async {
        var request = URLRequest(url: Self.api, timeoutInterval: 15)
        request.setValue("OwnMac", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = Self.parse(data),
              Self.isNewer(release.version, than: currentVersion) else { return }
        available = release
        let key = "updates.notified"
        guard UserDefaults.standard.string(forKey: key) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: key)
        NotificationCenter.default.post(name: .ownmacUpdate, object: release.version)
    }

    func openDownload() {
        if let available { NSWorkspace.shared.open(available.url) }
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let link = json["html_url"] as? String, let url = URL(string: link),
              url.host == "github.com" else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: url)
    }

    /// Comparaison numérique : 0.10.0 est plus récent que 0.9.0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}
