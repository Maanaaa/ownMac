import AppKit
import SwiftUI

/// Ce que l'onglet Optimiser sait nettoyer. Tout reste dans le dossier de l'utilisateur, sans droits root.
enum CleanKind: String, CaseIterable, Identifiable {
    case caches, logs, derived, installers, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches: "Caches des apps"
        case .logs: "Journaux"
        case .derived: "Fichiers de build Xcode"
        case .installers: "Installeurs téléchargés"
        case .trash: "Corbeille"
        }
    }

    var detail: String {
        switch self {
        case .caches: "Recréés au besoin, les apps ouvertes sont épargnées"
        case .logs: "Rapports et journaux des apps"
        case .derived: "DerivedData, régénéré à la prochaine compilation"
        case .installers: ".dmg et .pkg des Téléchargements, mis à la corbeille"
        case .trash: "Vidée définitivement"
        }
    }

    /// Les éléments à traiter, ou nil si le dossier est inaccessible (corbeille sans accès complet au disque).
    nonisolated func items(sparing running: Set<String>) -> [URL]? {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        func children(_ path: String) -> [URL]? {
            let dir = home.appending(path: path)
            guard fm.fileExists(atPath: dir.path) else { return [] }
            return try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        }
        switch self {
        case .caches:
            return children("Library/Caches")?.filter {
                let name = $0.lastPathComponent
                return !running.contains(name) && name != "OwnMac-build"
            }
        case .logs: return children("Library/Logs")
        case .derived: return children("Library/Developer/Xcode/DerivedData")
        case .installers:
            return children("Downloads")?.filter { ["dmg", "pkg"].contains($0.pathExtension.lowercased()) }
        case .trash: return children(".Trash")
        }
    }
}

enum DiskUsage {
    nonisolated static func size(of url: URL) -> Int64 {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        guard let v = try? url.resourceValues(forKeys: [key, .isDirectoryKey]) else { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key], options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated static func size(of urls: [URL]) -> Int64 { urls.reduce(0) { $0 + size(of: $1) } }

    static func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

@MainActor
final class Optimizer: ObservableObject {
    static let shared = Optimizer()

    enum Phase: Equatable { case idle, scanning, cleaning }

    /// Taille par catégorie ; absente = inaccessible.
    @Published var sizes: [CleanKind: Int64] = [:]
    @Published var scanned = false
    @Published var selected: Set<CleanKind> = [.caches, .logs, .derived]
    @Published var phase = Phase.idle
    @Published var confirming = false
    @Published var message: String?
    @Published var hogs: [Culprit] = []
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var busyTool: String?

    private var confirmReset: Task<Void, Never>?

    var selectedTotal: Int64 { selected.reduce(0) { $0 + (sizes[$1] ?? 0) } }

    /// Une catégorie vide et sans intérêt (pas de Xcode) n'est pas affichée.
    var visibleKinds: [CleanKind] { CleanKind.allCases.filter { !(scanned && $0 == .derived && (sizes[$0] ?? 0) == 0) } }

    private var runningIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func refresh() {
        readDisk()
        refreshHogs()
    }

    private func readDisk() {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        diskFree = v?.volumeAvailableCapacityForImportantUsage ?? 0
        diskTotal = Int64(v?.volumeTotalCapacity ?? 0)
    }

    func refreshHogs() {
        Task {
            let all = await Task.detached(priority: .utility) { ProcessScan.run() }.value
            hogs = Array(all.filter(\.canQuit).sorted { $0.memoryKB > $1.memoryKB }.prefix(5))
        }
    }

    func quit(_ c: Culprit) {
        c.quit()
        hogs.removeAll { $0.name == c.name }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            refresh()
        }
    }

    func scan() async {
        guard phase == .idle else { return }
        phase = .scanning
        message = nil
        let running = runningIDs
        let result = await Task.detached(priority: .utility) {
            var out: [CleanKind: Int64] = [:]
            for k in CleanKind.allCases {
                if let items = k.items(sparing: running) { out[k] = DiskUsage.size(of: items) }
            }
            return out
        }.value
        sizes = result
        selected = selected.filter { (result[$0] ?? 0) > 0 }
        scanned = true
        phase = .idle
        readDisk()
    }

    /// Premier clic : demande confirmation. Second clic dans les 4 s : nettoie.
    func cleanTapped() {
        guard confirming else {
            confirming = true
            confirmReset?.cancel()
            confirmReset = Task {
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { confirming = false }
            }
            return
        }
        confirmReset?.cancel()
        confirming = false
        Task { await clean() }
    }

    private func clean() async {
        guard phase == .idle else { return }
        phase = .cleaning
        let kinds = selected, running = runningIDs
        let freeBefore = diskFree

        // La corbeille d'abord, pour que les installeurs qu'on y range restent récupérables
        var trashFailed = false
        if kinds.contains(.trash) {
            trashFailed = await Self.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"]) != 0
        }
        let removed = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var freed: Int64 = 0
            for k in kinds where k != .trash {
                for url in k.items(sparing: running) ?? [] {
                    let size = DiskUsage.size(of: url)
                    do {
                        if k == .installers { try fm.trashItem(at: url, resultingItemURL: nil) }
                        else { try fm.removeItem(at: url); freed += size }
                    } catch { continue }   // fichier verrouillé ou protégé : on passe
                }
            }
            return freed
        }.value

        phase = .idle
        await scan()
        let gained = max(diskFree - freeBefore, removed)
        message = gained > 0 ? "\(DiskUsage.text(gained)) libérés" : "Rien à libérer"
        if trashFailed { message! += " · corbeille non vidée (autorise OwnMac à contrôler le Finder)" }
    }

    // MARK: Outils

    func flushDNS() { admin("DNS", "dscacheutil -flushcache; killall -HUP mDNSResponder", done: "Cache DNS vidé") }
    func purgeMemory() { admin("RAM", "purge", done: "Mémoire inactive libérée") }

    func openLoginItems() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    /// macOS demande le mot de passe administrateur lui-même ; OwnMac ne le voit jamais.
    private func admin(_ id: String, _ command: String, done: String) {
        guard busyTool == nil else { return }
        busyTool = id
        Task {
            let script = "do shell script \"\(command)\" with administrator privileges"
            let status = await Self.run("/usr/bin/osascript", ["-e", script])
            busyTool = nil
            message = status == 0 ? done : "Action annulée"
            readDisk()
        }
    }

    nonisolated static func run(_ path: String, _ args: [String]) async -> Int32 {
        await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }.value
    }
}

// MARK: - Vue

struct OptimizerView: View {
    @ObservedObject private var o = Optimizer.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                disk
                Section("Nettoyage", icon: "sparkles", color: .pink) { cleaning }
                Section("Apps gourmandes", icon: "flame.fill", color: .orange) { hogs }
                Section("Outils", icon: "wrench.and.screwdriver.fill", color: .indigo) { tools }
            }
            .padding(.bottom, 4)
        }
        .onAppear { o.refresh() }
    }

    private var disk: some View {
        StatCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CaptionTitle(text: "Espace libre", icon: "internaldrive")
                    Spacer()
                    Text(DiskUsage.text(o.diskFree)).font(.system(.callout, design: .rounded, weight: .bold)).monospacedDigit()
                        .contentTransition(.numericText())
                }
                ProgressView(value: o.diskTotal > 0 ? Double(o.diskTotal - o.diskFree) / Double(o.diskTotal) : 0)
                    .tint(o.diskTotal > 0 && Double(o.diskFree) / Double(o.diskTotal) < 0.1 ? .red : .cyan)
                if let m = o.message {
                    Label(m, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
        }
        .animation(.smooth, value: o.diskFree)
        .animation(.smooth, value: o.message)
    }

    @ViewBuilder private var cleaning: some View {
        if !o.scanned {
            Text("Analyse ce qui encombre ton Mac. Rien n'est supprimé sans ta confirmation.")
                .font(.caption).foregroundStyle(.secondary)
            scanButton("Analyser")
        } else {
            ForEach(Array(o.visibleKinds.enumerated()), id: \.element) { i, k in
                if i > 0 { Divider().opacity(0.5) }
                row(k)
            }
            HStack {
                Button("Réanalyser") { Task { await o.scan() } }.buttonStyle(.plain).font(.caption)
                    .foregroundStyle(.secondary).disabled(o.phase != .idle)
                Spacer()
                if o.phase != .idle {
                    ProgressView().controlSize(.small)
                } else {
                    Button(o.confirming ? "Confirmer" : "Nettoyer \(DiskUsage.text(o.selectedTotal))") { o.cleanTapped() }
                        .buttonStyle(.glassProminent).controlSize(.small)
                        .tint(o.confirming ? .red : .accentColor)
                        .disabled(o.selected.isEmpty)
                }
            }
            .padding(.top, 2)
        }
    }

    private func row(_ k: CleanKind) -> some View {
        let size = o.sizes[k]
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { o.selected.contains(k) },
                set: { if $0 { o.selected.insert(k) } else { o.selected.remove(k) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled((size ?? 0) == 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(k.title)
                Text(size == nil ? "Accès refusé par macOS" : k.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(size.map(DiskUsage.text) ?? "—").font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func scanButton(_ title: String) -> some View {
        HStack {
            Spacer()
            if o.phase == .scanning { ProgressView().controlSize(.small) }
            else { Button(title) { Task { await o.scan() } }.buttonStyle(.glassProminent).controlSize(.small) }
        }
    }

    @ViewBuilder private var hogs: some View {
        if o.hogs.isEmpty {
            Text("Aucune app ouverte").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(Array(o.hogs.enumerated()), id: \.element.name) { i, c in
                if i > 0 { Divider().opacity(0.5) }
                HStack(spacing: 10) {
                    icon(c)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).lineLimit(1)
                        Text("\(c.memoryText) · \(Int(c.cpu.rounded())) % CPU").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Button("Quitter") { o.quit(c) }.buttonStyle(.glass).controlSize(.small)
                }
            }
        }
    }

    private func icon(_ c: Culprit) -> some View {
        Image(nsImage: c.appPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSImage())
            .resizable().frame(width: 24, height: 24)
    }

    @ViewBuilder private var tools: some View {
        toolRow("Vider le cache DNS", "Quand un site ne charge plus après un changement de réseau", id: "DNS", action: o.flushDNS)
        Divider().opacity(0.5)
        toolRow("Libérer la mémoire inactive", "Utile avant une tâche lourde", id: "RAM", action: o.purgeMemory)
        Divider().opacity(0.5)
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Apps au démarrage")
                Text("Moins d'apps au démarrage, Mac prêt plus vite").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Ouvrir") { o.openLoginItems() }.buttonStyle(.glass).controlSize(.small)
        }
    }

    private func toolRow(_ title: String, _ detail: String, id: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if o.busyTool == id { ProgressView().controlSize(.small) }
            else { Button("Lancer") { action() }.buttonStyle(.glass).controlSize(.small).disabled(o.busyTool != nil) }
        }
    }
}
