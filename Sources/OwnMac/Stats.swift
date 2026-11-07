import SwiftUI
import IOKit.ps
import Darwin

/// Charge CPU globale (0...1) entre deux appels ; nil au premier appel.
struct CPUSampler {
    private var last: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?

    mutating func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let now = (user: t.0, sys: t.1, idle: t.2, nice: t.3)
        defer { last = now }
        guard let l = last else { return nil }
        let busy = Double(now.user &- l.user) + Double(now.sys &- l.sys) + Double(now.nice &- l.nice)
        let total = busy + Double(now.idle &- l.idle)
        return total > 0 ? busy / total : nil
    }
}

/// Statistiques système en direct (CPU, mémoire, disque, batterie, réseau). Lecture seule, tout en local.
final class SystemStats: ObservableObject {
    static let historyLength = 60

    @Published var cpu = 0.0
    @Published var memUsed = 0.0
    @Published var memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var diskUsed = 0.0
    @Published var diskTotal = 0.0
    @Published var batteryLevel: Double? = nil
    @Published var charging = false
    @Published var batteryMinutes: Int? = nil
    @Published var down = 0.0   // octets / s
    @Published var up = 0.0
    @Published var cpuHistory = [Double](repeating: 0, count: historyLength)
    @Published var downHistory = [Double](repeating: 0, count: historyLength)
    @Published var upHistory = [Double](repeating: 0, count: historyLength)

    private var timer: Timer?
    private var cpuSampler = CPUSampler()
    private var lastNet: (rx: UInt32, tx: UInt32, at: Date)?

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
    }
    func stop() { timer?.invalidate(); timer = nil; cpuSampler = CPUSampler(); lastNet = nil }

    private func push(_ arr: inout [Double], _ v: Double) { arr.append(v); arr.removeFirst(arr.count - Self.historyLength) }

    private func sample() {
        sampleCPU(); sampleMemory(); sampleNetwork()
        if Int(uptime) % 10 == 0 || diskTotal == 0 { sampleDisk(); sampleBattery() }
    }

    private func sampleCPU() {
        guard let load = cpuSampler.sample() else { return }
        cpu = load
        push(&cpuHistory, load)
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        // Même définition qu'Activity Monitor : mémoire app + wired + compressée
        let pages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
                  + Double(stats.wire_count) + Double(stats.compressor_page_count)
        memUsed = max(0, pages) * page
    }

    private func sampleDisk() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage else { return }
        diskTotal = Double(total); diskUsed = Double(total) - Double(free)
    }

    private func sampleBattery() {
        let info = BatteryInfo.read()
        batteryLevel = info?.level
        charging = info?.charging ?? false
        batteryMinutes = info?.minutes
    }

    private func sampleNetwork() {
        var rx: UInt32 = 0, tx: UInt32 = 0
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            let name = String(cString: a.pointee.ifa_name)
            if a.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"),
               let data = a.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx = rx &+ data.pointee.ifi_ibytes; tx = tx &+ data.pointee.ifi_obytes
            }
            p = a.pointee.ifa_next
        }
        let now = Date()
        if let l = lastNet {
            let dt = max(now.timeIntervalSince(l.at), 0.001)
            down = Double(rx &- l.rx) / dt; up = Double(tx &- l.tx) / dt
            push(&downHistory, down); push(&upHistory, up)
        }
        lastNet = (rx, tx, now)
    }
}

// MARK: - Formatage

private func bytes(_ v: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory) }
private func rate(_ v: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) + "/s" }
private func duration(_ s: TimeInterval) -> String {
    let d = Int(s) / 86400, h = Int(s) % 86400 / 3600, m = Int(s) % 3600 / 60
    return d > 0 ? "\(d) j \(h) h" : (h > 0 ? "\(h) h \(m) min" : "\(m) min")
}

// MARK: - Composants

struct Ring: View {
    let value: Double, color: Color
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 9)
            Circle().trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.6), value: value)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit()
        }
    }
}

struct Sparkline: View {
    let values: [Double], color: Color
    var maxValue: Double? = nil
    var body: some View {
        GeometryReader { g in
            let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: g.size.height * (1 - CGFloat(min(v / top, 1))))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height)); p.addLine(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height)); p.closeSubpath()
                }.fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f); pts.dropFirst().forEach { p.addLine(to: $0) }
                }.stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct StatCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct CaptionTitle: View {
    let text: String, icon: String
    var body: some View {
        Label(text, systemImage: icon).font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(.secondary)
    }
}

struct StatsView: View {
    @EnvironmentObject var s: SystemStats

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    StatCard {
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionTitle(text: "Processeur", icon: "cpu")
                            Ring(value: s.cpu, color: .blue).frame(height: 84).frame(maxWidth: .infinity)
                            Sparkline(values: s.cpuHistory, color: .blue, maxValue: 1).frame(height: 22)
                        }
                    }
                    StatCard {
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionTitle(text: "Mémoire", icon: "memorychip")
                            Ring(value: s.memTotal > 0 ? s.memUsed / s.memTotal : 0, color: .purple).frame(height: 84).frame(maxWidth: .infinity)
                            Text("\(bytes(s.memUsed)) / \(bytes(s.memTotal))").font(.caption2).foregroundStyle(.secondary).frame(height: 22)
                        }
                    }
                }
                StatCard {
                    VStack(alignment: .leading, spacing: 10) {
                        CaptionTitle(text: "Réseau", icon: "network")
                        HStack(spacing: 14) {
                            netColumn("arrow.down", rate(s.down), s.downHistory, .green)
                            netColumn("arrow.up", rate(s.up), s.upHistory, .orange)
                        }
                    }
                }
                StatCard {
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionTitle(text: "Stockage", icon: "internaldrive")
                        ProgressView(value: s.diskTotal > 0 ? s.diskUsed / s.diskTotal : 0).tint(.cyan)
                        Text("\(bytes(s.diskUsed)) utilisés sur \(bytes(s.diskTotal))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let b = s.batteryLevel {
                    StatCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                CaptionTitle(text: "Batterie", icon: s.charging ? "battery.100.bolt" : "battery.75")
                                Spacer()
                                Text("\(Int((b * 100).rounded()))%").font(.system(.callout, design: .rounded, weight: .bold)).monospacedDigit()
                            }
                            ProgressView(value: b).tint(b < 0.2 && !s.charging ? .red : .green)
                            Text(batteryText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Label("Allumé depuis \(duration(s.uptime))", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
            }
        }
        .onAppear { s.start() }
        .onDisappear { s.stop() }
    }

    private var batteryText: String {
        let state = s.charging ? "En charge" : "Sur batterie"
        guard let m = s.batteryMinutes else { return state }
        return "\(state) · \(m / 60) h \(m % 60) min \(s.charging ? "avant pleine charge" : "restantes")"
    }

    private func netColumn(_ icon: String, _ text: String, _ hist: [Double], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: icon).font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
            Sparkline(values: hist, color: color).frame(height: 30)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
