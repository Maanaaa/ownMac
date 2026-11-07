import LocalAuthentication
import SwiftUI

/// Protège l'onglet presse-papier par Touch ID (repli : mot de passe / Apple Watch).
final class BiometricGate: ObservableObject {
    @Published var protectClipboard: Bool { didSet { UserDefaults.standard.set(protectClipboard, forKey: "clip.protect") } }
    @Published private(set) var unlockedUntil = Date.distantPast
    @Published var checking = false

    init() { protectClipboard = UserDefaults.standard.bool(forKey: "clip.protect") }

    var isUnlocked: Bool { !protectClipboard || Date() < unlockedUntil }

    func authenticate() {
        guard !checking else { return }
        checking = true
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Accéder à l'historique du presse-papier") { ok, _ in
            DispatchQueue.main.async {
                self.checking = false
                if ok { self.unlockedUntil = Date().addingTimeInterval(60) }
            }
        }
    }

    func lockNow() { unlockedUntil = .distantPast; objectWillChange.send() }
}

struct LockedView: View {
    @EnvironmentObject var gate: BiometricGate
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "touchid").font(.system(size: 44, weight: .light))
            Text("Presse-papier verrouillé").font(.system(.headline, design: .rounded))
            Button("Déverrouiller") { gate.authenticate() }.buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { gate.authenticate() }
    }
}
