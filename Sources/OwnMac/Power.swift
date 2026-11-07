import Foundation
import IOKit.ps

/// État de la batterie interne ; nil sur un Mac de bureau.
struct BatteryInfo: Equatable {
    var level: Double          // 0...1
    var onAC: Bool             // branché, même si macOS retient la charge pour préserver la batterie
    var charging: Bool
    var minutes: Int?          // temps avant pleine charge, ou restant sur batterie

    var percent: Int { Int((level * 100).rounded()) }
    var durationText: String? { minutes.map { $0 >= 60 ? "\($0 / 60) h \($0 % 60) min" : "\($0) min" } }

    static func read() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = (d[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let maximum = (d[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            let minutes = (d[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return BatteryInfo(level: maximum > 0 ? current / maximum : 0,
                               onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                               charging: charging, minutes: minutes)
        }
        return nil
    }
}

/// Réagit aux branchements et aux paliers de batterie. macOS prévient : aucun sondage.
@MainActor
final class PowerMonitor {
    private nonisolated static let lowLevels = [20, 10]

    private weak var model: IslandModel?
    private var source: CFRunLoopSource?
    private var last: BatteryInfo?

    init(model: IslandModel) { self.model = model }

    func start() {
        guard source == nil else { return }
        last = BatteryInfo.read()
        Self.current = self
        guard let s = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in PowerMonitor.current?.changed() }
        }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        source = s
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
    }

    private static var current: PowerMonitor?     // la fonction C de IOKit ne peut rien capturer

    private func changed() {
        guard let new = BatteryInfo.read() else { return }
        let old = last
        last = new
        guard let old else { return }
        guard let crossed = Self.lowCrossed(old, new) else {
            if let t = Self.toast(old, new) { model?.show(t, for: 4) }
            return
        }
        // Palier bas : on cherche l'app la plus gourmande, hors du fil principal
        Task.detached(priority: .utility) {
            let top = ProcessScan.run().max { $0.cpu < $1.cpu }
            await self.showLow(crossed, top: top)
        }
    }

    private func showLow(_ percent: Int, top: Culprit?) {
        let t = Self.lowToast(percent, top: top)
        model?.show(t, for: 6)
    }

    nonisolated static func lowCrossed(_ old: BatteryInfo, _ new: BatteryInfo) -> Int? {
        guard !new.onAC else { return nil }
        return lowLevels.first { old.percent > $0 && new.percent <= $0 }
    }

    nonisolated static func lowToast(_ percent: Int, top: Culprit?) -> IslandToast {
        let hog = top.flatMap { $0.cpu >= 20 ? "\($0.name) consomme le plus" : nil }
        return IslandToast(icon: "battery.25percent", title: "Batterie faible : \(percent) %",
                           subtitle: hog ?? "Pense à brancher ton Mac", tint: .red, progress: Double(percent) / 100)
    }

    nonisolated static func toast(_ old: BatteryInfo, _ new: BatteryInfo) -> IslandToast? {
        if !old.onAC && new.onAC {
            let eta = new.durationText.map { "Pleine charge dans \($0)" }
            return IslandToast(icon: "bolt.fill", title: "En charge : \(new.percent) %", subtitle: eta, tint: .green, progress: new.level)
        }
        if old.onAC && !new.onAC {
            let left = new.durationText.map { "\($0) restantes" }
            return IslandToast(icon: "battery.75percent", title: "Sur batterie : \(new.percent) %", subtitle: left, tint: .gray, progress: new.level)
        }
        if new.onAC && old.percent < 100 && new.percent == 100 {
            return IslandToast(icon: "battery.100percent.bolt", title: "Batterie chargée", subtitle: nil, tint: .green, progress: 1)
        }
        return nil
    }
}
