import ServiceManagement

/// Lancement à la connexion via SMAppService (visible dans Réglages Système > Éléments de connexion).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("OwnMac login item: \(error)") }
    }

    /// Active une seule fois au premier lancement ; ensuite l'utilisateur garde la main.
    static func enableOnFirstRun() {
        let key = "didAutoEnableLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
