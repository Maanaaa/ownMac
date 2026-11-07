import Foundation

/// Lecture / écriture via /usr/bin/defaults (aucune dépendance, réversible).
enum Defaults {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func read(_ t: Tweak) -> String {
        let out = run("/usr/bin/defaults", ["read", t.domain, t.key])
        return out.isEmpty ? t.defaultValue : out
    }

    static func write(_ t: Tweak, _ value: String) {
        switch t.kind {
        case .bool:
            run("/usr/bin/defaults", ["write", t.domain, t.key, "-bool", value == "1" ? "true" : "false"])
        case .slider:
            run("/usr/bin/defaults", ["write", t.domain, t.key, "-int", String(Int(Double(value) ?? 0))])
        case .choice:
            run("/usr/bin/defaults", ["write", t.domain, t.key, "-string", value])
        }
    }

    static func reset(_ t: Tweak) {
        run("/usr/bin/defaults", ["delete", t.domain, t.key])
    }

    static func restart(_ process: String) {
        run("/usr/bin/killall", [process])
    }
}
