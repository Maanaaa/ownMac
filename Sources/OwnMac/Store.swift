import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var tab = 0
    @Published var values: [String: String] = [:]
    private var pending: [String: Task<Void, Never>] = [:]

    @Published var launchAtLogin = false
    @Published var islandEnabled = UserDefaults.standard.object(forKey: "island.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(islandEnabled, forKey: "island.enabled")
            IslandController.shared.setEnabled(islandEnabled)
        }
    }

    init() {
        LoginItem.enableOnFirstRun()
        launchAtLogin = LoginItem.isEnabled
        reload()
    }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
    }

    func reload() {
        for g in Catalog.groups { for t in g.tweaks { values[t.id] = Defaults.read(t) } }
    }

    func set(_ t: Tweak, _ v: String) {
        values[t.id] = v
        // debounce : évite de relancer le Dock à chaque cran du slider
        pending[t.id]?.cancel()
        pending[t.id] = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            Defaults.write(t, v)
            Defaults.restart(t.restart)
        }
    }

    func resetAll() {
        var procs = Set<String>()
        for g in Catalog.groups { for t in g.tweaks { Defaults.reset(t); procs.insert(t.restart) } }
        procs.forEach(Defaults.restart)
        reload()
    }
}
