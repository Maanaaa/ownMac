// Signature Ed25519 des versions publiées.
//   swift scripts/sign-release.swift gen  <fichier-clé>          crée la clé privée, affiche la clé publique
//   swift scripts/sign-release.swift sign <fichier-clé> <zip>    écrit <zip>.sig
// La clé privée ne doit jamais entrer dans le repo.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: gen <clé> | sign <clé> <zip>") }
let keyURL = URL(fileURLWithPath: args[2])

switch args[1] {
case "gen":
    guard !FileManager.default.fileExists(atPath: keyURL.path) else { fail("clé déjà présente, rien n'est écrasé") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: keyURL.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 4 else { fail("usage: sign <clé> <zip>") }
    let text = try String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text) else { fail("clé illisible") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    let zip = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    try key.signature(for: zip).write(to: URL(fileURLWithPath: args[3] + ".sig"))
default:
    fail("commande inconnue")
}
