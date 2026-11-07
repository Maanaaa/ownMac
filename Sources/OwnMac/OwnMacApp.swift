import SwiftUI

@main
struct OwnMacApp: App {
    @StateObject private var store = Store()
    @StateObject private var clip = ClipboardStore()

    var body: some Scene {
        MenuBarExtra("OwnMac", systemImage: "slider.horizontal.3") {
            ContentView().environmentObject(store).environmentObject(clip)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Racine (Liquid Glass)

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            TabPicker()
            Group {
                if store.tab == 1 { ClipboardView() } else { SettingsList() }
            }
            footer
        }
        .padding(16)
        .frame(width: 372, height: 540)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .glassEffect(.regular.tint(.accentColor.opacity(0.5)), in: .circle)
            VStack(alignment: .leading, spacing: 0) {
                Text("OwnMac").font(.system(.title3, design: .rounded, weight: .bold))
                Text("Personnalise ton Mac").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var footer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack {
                if store.tab == 0 {
                    Button("Réinitialiser") { store.resetAll() }.buttonStyle(.glass)
                }
                Spacer()
                Button("Quitter") { NSApplication.shared.terminate(nil) }.buttonStyle(.glass)
            }
        }
        .controlSize(.regular)
    }
}

struct TabPicker: View {
    @EnvironmentObject var store: Store
    private let tabs = [("Réglages", "switch.2"), ("Presse-papier", "doc.on.clipboard")]

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(0..<tabs.count, id: \.self) { i in
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { store.tab = i }
                    } label: {
                        Label(tabs[i].0, systemImage: tabs[i].1)
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(store.tab == i ? .regular.tint(.accentColor.opacity(0.55)).interactive()
                                                : .regular.interactive(), in: .capsule)
                }
            }
        }
    }
}

// MARK: - Réglages

struct SettingsList: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Section("Général", icon: "gearshape.fill", color: .gray) {
                    Toggle("Lancer au démarrage", isOn: Binding(
                        get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                }
                ForEach(Catalog.groups) { g in
                    Section(g.title, icon: g.icon, color: color(for: g.id)) {
                        ForEach(Array(g.tweaks.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { Divider().opacity(0.5) }
                            TweakRow(tweak: t)
                        }
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func color(for id: String) -> Color {
        switch id { case "dock": .blue; case "finder": .cyan; default: .orange }
    }
}

/// Section = pastille d'icône + carte en verre aux coins continus.
struct Section<Content: View>: View {
    let title: String, icon: String, color: Color
    @ViewBuilder var content: Content

    init(_ title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.color = color; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title).font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

struct TweakRow: View {
    @EnvironmentObject var store: Store
    let tweak: Tweak

    private var value: String { store.values[tweak.id] ?? tweak.defaultValue }

    var body: some View {
        switch tweak.kind {
        case .bool:
            Toggle(tweak.title, isOn: Binding(
                get: { value == "1" || value.lowercased() == "true" },
                set: { store.set(tweak, $0 ? "1" : "0") }))
        case .slider(let range):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tweak.title)
                    Spacer()
                    Text("\(Int(Double(value) ?? 0))").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(value) ?? range.lowerBound },
                    set: { store.set(tweak, String(Int($0))) }), in: range)
            }
        case .choice(let options):
            HStack {
                Text(tweak.title)
                Spacer()
                Picker("", selection: Binding(get: { value }, set: { store.set(tweak, $0) })) {
                    ForEach(options, id: \.self) { Text($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }
}
