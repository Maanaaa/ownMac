import Foundation

enum TweakKind {
    case bool
    case slider(ClosedRange<Double>)          // valeur numérique
    case choice([String])                     // valeur texte parmi une liste
}

struct Tweak: Identifiable {
    let id: String
    let title: String
    let domain: String
    let key: String
    let kind: TweakKind
    let restart: String          // process à relancer après modification
    let defaultValue: String
}

struct TweakGroup: Identifiable {
    let id: String
    let title: String
    let icon: String
    let tweaks: [Tweak]
}

enum Catalog {
    static let groups: [TweakGroup] = [
        TweakGroup(id: "dock", title: "Dock", icon: "dock.rectangle", tweaks: [
            Tweak(id: "dock.autohide", title: "Masquer automatiquement", domain: "com.apple.dock",
                  key: "autohide", kind: .bool, restart: "Dock", defaultValue: "0"),
            Tweak(id: "dock.size", title: "Taille des icônes", domain: "com.apple.dock",
                  key: "tilesize", kind: .slider(16...128), restart: "Dock", defaultValue: "48"),
            Tweak(id: "dock.recents", title: "Apps récentes", domain: "com.apple.dock",
                  key: "show-recents", kind: .bool, restart: "Dock", defaultValue: "1"),
            Tweak(id: "dock.mineffect", title: "Effet de réduction", domain: "com.apple.dock",
                  key: "mineffect", kind: .choice(["genie", "scale", "suck"]), restart: "Dock", defaultValue: "genie"),
        ]),
        TweakGroup(id: "finder", title: "Finder", icon: "folder", tweaks: [
            Tweak(id: "finder.desktop", title: "Afficher les icônes du bureau", domain: "com.apple.finder",
                  key: "CreateDesktop", kind: .bool, restart: "Finder", defaultValue: "1"),
            Tweak(id: "finder.hidden", title: "Afficher les fichiers cachés", domain: "com.apple.finder",
                  key: "AppleShowAllFiles", kind: .bool, restart: "Finder", defaultValue: "0"),
            Tweak(id: "finder.path", title: "Barre de chemin", domain: "com.apple.finder",
                  key: "ShowPathbar", kind: .bool, restart: "Finder", defaultValue: "0"),
            Tweak(id: "finder.status", title: "Barre d'état", domain: "com.apple.finder",
                  key: "ShowStatusBar", kind: .bool, restart: "Finder", defaultValue: "0"),
            Tweak(id: "finder.ext", title: "Toujours afficher les extensions", domain: "NSGlobalDomain",
                  key: "AppleShowAllExtensions", kind: .bool, restart: "Finder", defaultValue: "0"),
        ]),
        TweakGroup(id: "shots", title: "Captures d'écran", icon: "camera.viewfinder", tweaks: [
            Tweak(id: "shots.shadow", title: "Désactiver l'ombre des fenêtres", domain: "com.apple.screencapture",
                  key: "disable-shadow", kind: .bool, restart: "SystemUIServer", defaultValue: "0"),
            Tweak(id: "shots.type", title: "Format", domain: "com.apple.screencapture",
                  key: "type", kind: .choice(["png", "jpg", "heic", "pdf"]), restart: "SystemUIServer", defaultValue: "png"),
        ]),
    ]
}
