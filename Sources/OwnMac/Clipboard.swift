import SwiftUI
import AppKit

/// Historique du presse-papier (texte uniquement, en mémoire : rien n'est écrit sur disque).
@MainActor
final class ClipboardStore: ObservableObject {
    @Published var items: [String] = []
    private let limit = 20
    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        // Ignore les contenus marqués confidentiels/temporaires (gestionnaires de mots de passe)
        let types = pb.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }
        guard let s = pb.string(forType: .string),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items.removeAll { $0 == s }
        items.insert(s, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        lastCount = pb.changeCount
        items.removeAll { $0 == s }
        items.insert(s, at: 0)
    }

    func remove(_ s: String) { items.removeAll { $0 == s } }
    func clear() { items.removeAll() }
}

struct ClipboardView: View {
    @EnvironmentObject var clip: ClipboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if clip.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 34, weight: .light))
                    Text("Rien copié pour l'instant").font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(clip.items, id: \.self) { s in
                            HStack(alignment: .top, spacing: 8) {
                                Button { clip.copy(s) } label: {
                                    Text(s).lineLimit(3).font(.callout)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { clip.remove(s) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
            }
            HStack {
                Text("\(clip.items.count)/20 · clic pour recopier").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Vider") { clip.clear() }.buttonStyle(.glass).controlSize(.small).disabled(clip.items.isEmpty)
            }
        }
    }
}
