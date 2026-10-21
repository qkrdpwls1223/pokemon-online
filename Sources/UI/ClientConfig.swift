// pmf-battle's own settings (server address, nickname, lobby password),
// stored apart from the official app: %LOCALAPPDATA%\pmf-battle\config.json.
// The password is encrypted with DPAPI (readable only by this Windows user).

import WinSDK
import Foundation

enum ClientInfo {
    static let version = "0.3.0"

    /// Clients are only paired when this matches exactly: same upstream
    /// commit (same engine + game data), same PvP rules, same protocol.
    static var engineKey: String {
        let commit = EngineInfo.upstreamCommit + (EngineInfo.upstreamDirty ? "+dirty" : "")
        return "\(commit)/pvp\(PvPRules.version)/proto\(WireProtocol.version)"
    }
}

struct ClientConfig {
    static let defaultURL = "https://10.10.33.36:7777"

    var url: String = ClientConfig.defaultURL
    var name: String = ""
    var password: String = ""

    /// On-disk shape; every field optional so older or partial files load.
    private struct Stored: Codable {
        var url: String?
        var name: String?
        var passwordDPAPI: String?
    }

    private static var fileURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("pmf-battle", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    static func load() -> ClientConfig {
        var c = ClientConfig()
        c.name = ProcessInfo.processInfo.environment["USERNAME"] ?? "트레이너"
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return c }
        if let u = s.url, !u.isEmpty { c.url = u }
        if let n = s.name, !n.isEmpty { c.name = n }
        if let p = s.passwordDPAPI { c.password = DPAPI.unprotect(p) ?? "" }
        return c
    }

    func save() {
        let u = ClientConfig.fileURL
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let stored = Stored(url: url, name: name,
                            passwordDPAPI: password.isEmpty ? nil : DPAPI.protect(password))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(stored) { try? data.write(to: u, options: .atomic) }
    }
}

/// Windows DPAPI (CryptProtectData), base64 on disk.
enum DPAPI {
    static func protect(_ text: String) -> String? {
        var input = Array(text.utf8)
        guard !input.isEmpty else { return nil }
        return input.withUnsafeMutableBufferPointer { buf -> String? in
            var inBlob = DATA_BLOB(cbData: DWORD(buf.count), pbData: buf.baseAddress)
            var outBlob = DATA_BLOB()
            guard CryptProtectData(&inBlob, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &outBlob),
                  let out = outBlob.pbData else { return nil }
            defer { LocalFree(out) }
            return Data(bytes: out, count: Int(outBlob.cbData)).base64EncodedString()
        }
    }

    static func unprotect(_ base64: String) -> String? {
        guard var input = Data(base64Encoded: base64).map({ [UInt8]($0) }), !input.isEmpty else { return nil }
        return input.withUnsafeMutableBufferPointer { buf -> String? in
            var inBlob = DATA_BLOB(cbData: DWORD(buf.count), pbData: buf.baseAddress)
            var outBlob = DATA_BLOB()
            guard CryptUnprotectData(&inBlob, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &outBlob),
                  let out = outBlob.pbData else { return nil }
            defer { LocalFree(out) }
            return String(decoding: UnsafeBufferPointer(start: out, count: Int(outBlob.cbData)), as: UTF8.self)
        }
    }
}
