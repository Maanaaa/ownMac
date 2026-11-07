import AppKit
import Foundation

/// Le processus (ou l'app, helpers regroupés) responsable d'une surcharge.
struct Culprit: Equatable {
    var name: String
    var cpu: Double            // en % d'un cœur, comme le Moniteur d'activité (240 = 2,4 cœurs)
    var memoryKB: Double
    var appPath: String?       // renseigné seulement pour les apps .app

    var memoryText: String { ByteCountFormatter.string(fromByteCount: Int64(memoryKB * 1024), countStyle: .memory) }

    /// Traduit les processus système obscurs en langage courant.
    var explanation: String? {
        switch name {
        case "kernel_task": "macOS freine le processeur pour le refroidir"
        case "WindowServer": "affichage, souvent lié aux écrans externes ou aux animations"
        case "mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync": "Spotlight indexe tes fichiers"
        case "backupd", "backupd-helper": "sauvegarde Time Machine en cours"
        case "photoanalysisd", "photolibraryd", "mediaanalysisd": "Photos analyse ta bibliothèque"
        case "softwareupdated", "softwareupdate": "mise à jour macOS en cours"
        case "bird", "cloudd", "fileproviderd": "synchronisation iCloud en cours"
        case "Pages web (WebKit)": "un onglet Safari ou une page web intégrée"
        default: nil
        }
    }

    /// On ne propose de quitter que de vraies apps, jamais un composant système.
    var canQuit: Bool {
        guard let appPath, !appPath.hasPrefix("/System/") else { return false }
        return Self.runningApp(appPath) != nil
    }

    func quit() {
        guard let appPath else { return }
        Self.runningApp(appPath)?.terminate()   // fermeture normale : l'app peut proposer d'enregistrer
    }

    private static func runningApp(_ path: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.path == path && $0.activationPolicy == .regular
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }
}

enum ProcessScan {
    /// Lit `ps` et regroupe les helpers sous leur app (Chrome Helper -> Google Chrome).
    static func run() -> [Culprit] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pcpu=,rss=,comm="]
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> [Culprit] {
        var byKey: [String: Culprit] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3,
                  let cpu = Double(f[0].replacingOccurrences(of: ",", with: ".")),
                  let rss = Double(f[1]) else { continue }
            let (name, appPath) = identify(String(f[2]))
            var c = byKey[name] ?? Culprit(name: name, cpu: 0, memoryKB: 0, appPath: appPath)
            c.cpu += cpu
            c.memoryKB += rss
            byKey[name] = c
        }
        return Array(byKey.values)
    }

    private static func identify(_ command: String) -> (String, String?) {
        if let r = command.range(of: ".app/") {
            let path = String(command[..<r.lowerBound]) + ".app"
            return ((path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""), path)
        }
        let base = (command as NSString).lastPathComponent
        return (base.hasPrefix("com.apple.WebKit") ? "Pages web (WebKit)" : base, nil)
    }
}

struct HealthAlert: Equatable {
    enum Kind: Int { case cpu, memory, thermal }     // ordre = priorité croissante

    let kind: Kind
    let critical: Bool
    let title: String
    let detail: String
    let culprit: Culprit?

    var icon: String {
        switch kind {
        case .cpu: "gauge.with.dots.needle.100percent"
        case .memory: "memorychip"
        case .thermal: "flame.fill"
        }
    }
    var shortLabel: String { culprit?.name ?? title }
}

/// Surveillance discrète : une lecture CPU toutes les 5 s, `ps` seulement quand il y a un problème.
@MainActor
final class HealthMonitor {
    private static let highCPU = 0.85, clearCPU = 0.70, sustainedTicks = 3      // 3 x 5 s = 15 s
    private static let toastCooldown: TimeInterval = 300, muteDuration: TimeInterval = 1800

    private weak var model: IslandModel?
    private var timer: Timer?
    private var memorySource: DispatchSourceMemoryPressure?
    private var thermalObserver: NSObjectProtocol?
    private var sampler = CPUSampler()
    private var highTicks = 0
    private var memoryState: DispatchSource.MemoryPressureEvent = .normal
    private var lastToast: [HealthAlert.Kind: Date] = [:]
    private var mutedUntil: [HealthAlert.Kind: Date] = [:]

    init(model: IslandModel) {
        self.model = model
        model.onDismissAlert = { [weak self] kind in self?.mute(kind) }
    }

    func start() {
        guard timer == nil else { return }
        _ = sampler.sample()
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        t.tolerance = 2
        timer = t
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            Task { @MainActor in self?.memoryState = event; self?.evaluate() }
        }
        source.resume()
        memorySource = source
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        memorySource?.cancel(); memorySource = nil
        highTicks = 0
        model?.alert = nil
    }

    private func mute(_ kind: HealthAlert.Kind) {
        mutedUntil[kind] = Date().addingTimeInterval(Self.muteDuration)
        model?.alert = nil
    }

    private func isMuted(_ k: HealthAlert.Kind) -> Bool { (mutedUntil[k] ?? .distantPast) > Date() }

    private func activeKind() -> HealthAlert.Kind? {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical, !isMuted(.thermal) { return .thermal }
        if memoryState != .normal, !isMuted(.memory) { return .memory }
        // Hystérésis : une alerte CPU déclenchée à 85 % ne retombe que sous 70 %
        let wasActive = model?.alert?.kind == .cpu
        if (highTicks >= Self.sustainedTicks || wasActive && highTicks > 0), !isMuted(.cpu) { return .cpu }
        return nil
    }

    private func evaluate() {
        if let load = sampler.sample() {
            let threshold = model?.alert?.kind == .cpu ? Self.clearCPU : Self.highCPU
            highTicks = load >= threshold ? highTicks + 1 : 0
        }
        guard let kind = activeKind() else { model?.alert = nil; return }
        let thermal = ProcessInfo.processInfo.thermalState
        let memory = memoryState
        Task.detached(priority: .utility) {
            let processes = ProcessScan.run()
            let alert = Self.makeAlert(kind, thermal: thermal, memory: memory, processes: processes)
            await self.publish(alert)
        }
    }

    private func publish(_ alert: HealthAlert) {
        guard activeKind() == alert.kind, let model else { return }
        let isNew = model.alert?.kind != alert.kind
        model.alert = alert
        guard isNew, Date().timeIntervalSince(lastToast[alert.kind] ?? .distantPast) >= Self.toastCooldown else { return }
        lastToast[alert.kind] = Date()
        model.show(IslandToast(icon: alert.icon, title: alert.title, subtitle: alert.detail,
                               tint: alert.critical ? .red : .orange), for: 6)
    }

    nonisolated static func makeAlert(_ kind: HealthAlert.Kind, thermal: ProcessInfo.ThermalState,
                                      memory: DispatchSource.MemoryPressureEvent, processes: [Culprit]) -> HealthAlert {
        let topCPU = processes.max { $0.cpu < $1.cpu }
        // kernel_task : sa mémoire n'est ni anormale ni actionnable
        let topMemory = processes.filter { $0.name != "kernel_task" }.max { $0.memoryKB < $1.memoryKB }
        func cpuDetail(_ c: Culprit?) -> String? {
            guard let c, c.cpu >= 30 else { return nil }
            return "\(c.name) : \(Int(c.cpu)) % du CPU" + (c.explanation.map { " (\($0))" } ?? "")
        }
        switch kind {
        case .thermal:
            let culprit = (topCPU?.cpu ?? 0) >= 30 ? topCPU : nil
            return HealthAlert(kind: .thermal, critical: thermal == .critical,
                               title: thermal == .critical ? "Surchauffe" : "Mac très chaud, il ralentit",
                               detail: cpuDetail(culprit) ?? "Aucune app ne domine : chaleur ambiante ou recharge ?",
                               culprit: culprit)
        case .memory:
            let detail = topMemory.map { "\($0.name) : \($0.memoryText) de mémoire" + ($0.explanation.map { " (\($0))" } ?? "") }
            return HealthAlert(kind: .memory, critical: memory == .critical, title: "Mémoire saturée",
                               detail: detail ?? "Ferme quelques apps", culprit: topMemory)
        case .cpu:
            return HealthAlert(kind: .cpu, critical: false, title: "Processeur au maximum",
                               detail: cpuDetail(topCPU) ?? "Plusieurs processus se partagent la charge",
                               culprit: (topCPU?.cpu ?? 0) >= 30 ? topCPU : nil)
        }
    }
}
