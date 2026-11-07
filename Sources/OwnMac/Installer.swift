import AppKit
import CryptoKit
import Foundation

enum UpdateError: LocalizedError {
    case badSignature, badBundle, notNewer, unsigned, tooLarge, noFile

    var errorDescription: String? {
        switch self {
        case .badSignature: "Signature invalide : mise à jour refusée"
        case .badBundle: "Le fichier reçu n'est pas OwnMac"
        case .notNewer: "Cette version n'est pas plus récente"
        case .unsigned: "L'app reçue est endommagée"
        case .tooLarge: "Fichier anormalement gros"
        case .noFile: "Téléchargement incomplet"
        }
    }
}

/// Télécharge, vérifie et remplace l'app. Rien ne s'exécute avant que la signature soit validée.
enum UpdateInstaller {
    /// Clé publique des versions officielles. La clé privée reste sur la machine de publication.
    static let publicKey = "aaVLKk2e9dFo3dpUI7kXJPTdYnTxfLIC5bgj6Ff0A1Y="
    private static let bundleID = "local.ownmac"
    private static let maxSize = 50 * 1024 * 1024

    static func isValid(signature: Data, for zip: Data, publicKey: String = publicKey) -> Bool {
        guard let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: zip)
    }

    /// Télécharge et vérifie. Renvoie l'app prête à installer.
    static func prepare(zipURL: URL, signatureURL: URL, currentVersion: String) async throws -> URL {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("OwnMac-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let (zipFile, _) = try await URLSession.shared.download(from: zipURL)
        let (signature, _) = try await URLSession.shared.data(from: signatureURL)
        let zip = try Data(contentsOf: zipFile)
        guard zip.count <= maxSize else { throw UpdateError.tooLarge }
        guard isValid(signature: signature, for: zip) else { throw UpdateError.badSignature }
        let archive = stage.appendingPathComponent("OwnMac.zip")
        try zip.write(to: archive)
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, stage.path]) else { throw UpdateError.noFile }
        let app = stage.appendingPathComponent("OwnMac.app")
        try validate(app: app, currentVersion: currentVersion)
        return app
    }

    static func validate(app: URL, currentVersion: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              let version = info["CFBundleShortVersionString"] as? String else { throw UpdateError.badBundle }
        // Compare à la version contenue dans le zip signé : un ancien zip ne peut pas être rejoué
        guard UpdateChecker.isNewer(version, than: currentVersion) else { throw UpdateError.notNewer }
        guard run("/usr/bin/codesign", ["--verify", "--strict", app.path]) else { throw UpdateError.unsigned }
    }

    /// Où installer : sur place si possible, sinon Applications (cas de la translocation de macOS).
    static func destination(current: URL = Bundle.main.bundleURL, fileManager: FileManager = .default) -> URL {
        let parent = current.deletingLastPathComponent().path
        if !current.path.contains("/AppTranslocation/"), fileManager.isWritableFile(atPath: parent) { return current }
        let system = URL(fileURLWithPath: "/Applications/OwnMac.app")
        if fileManager.isWritableFile(atPath: "/Applications") { return system }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/OwnMac.app")
    }

    /// Attend la fin de l'app, échange les deux versions, restaure l'ancienne en cas d'échec, relance.
    static let swapScript = #"""
    pid="$1"; new="$2"; dest="$3"; backup="$dest.previous"
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    mkdir -p "$(dirname "$dest")"
    rm -rf "$backup"
    if [ -e "$dest" ] && ! mv "$dest" "$backup"; then open "$dest"; exit 1; fi
    if mv "$new" "$dest"; then
      rm -rf "$backup" "$(dirname "$new")"
    else
      [ -e "$backup" ] && mv "$backup" "$dest"
    fi
    open "$dest"
    """#

    static func launchSwap(new: URL, destination: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", swapScript, "ownmac-update", String(pid), new.path, destination.path]
        try p.run()
    }

    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
