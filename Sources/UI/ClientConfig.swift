// pmf-battle's own settings (server address, nickname), stored apart from
// the official app: %LOCALAPPDATA%\pmf-battle\config.json.

import Foundation

enum ClientInfo {
    static let version = "0.1.0"

    /// Clients are only paired when this matches exactly: same upstream
    /// commit (same engine + game data), same PvP rules, same protocol.
    static var engineKey: String {
        let commit = EngineInfo.upstreamCommit + (EngineInfo.upstreamDirty ? "+dirty" : "")
        return "\(commit)/pvp\(PvPRules.version)/proto\(WireProtocol.version)"
    }
}

struct ClientConfig: Codable {
    var host: String = "127.0.0.1"
    var port: Int = 7777
    var name: String = ""

    private static var url: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("pmf-battle", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    static func load() -> ClientConfig {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(ClientConfig.self, from: data) else {
            var c = ClientConfig()
            c.name = ProcessInfo.processInfo.environment["USERNAME"] ?? "트레이너"
            return c
        }
        return c
    }

    func save() {
        let u = ClientConfig.url
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: u, options: .atomic) }
    }
}
