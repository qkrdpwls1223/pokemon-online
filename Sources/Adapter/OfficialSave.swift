// Read-only access to the official app's raising save.
//
// The file is decoded with upstream's own `RaisingSave` type, so a format
// change upstream is picked up by `git pull` + rebuild. Nothing here writes:
// RaisingState (which persists on almost every call) is never touched.

import Foundation

enum OfficialSave {
    enum LoadError: Error, CustomStringConvertible {
        case notFound(String)
        case unreadable(String)
        case emptyParty

        var description: String {
            switch self {
            case .notFound(let p): return "세이브 파일이 없습니다: \(p)\n공식 프로그램에서 키우기 모드를 먼저 시작해 주세요."
            case .unreadable(let why): return "세이브 파일을 읽을 수 없습니다: \(why)"
            case .emptyParty: return "파티에 포켓몬이 없습니다."
            }
        }
    }

    /// Same location upstream's RaisingState.saveURL(dev: false) resolves:
    /// <applicationSupport>\PokemonMouseFollower\raising.json
    /// (= %LOCALAPPDATA%\PokemonMouseFollower on Windows).
    /// PMF_BATTLE_SAVE overrides it (handy for testing with a copied save).
    static var url: URL {
        if let p = ProcessInfo.processInfo.environment["PMF_BATTLE_SAVE"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("PokemonMouseFollower", isDirectory: true)
            .appendingPathComponent("raising.json")
    }

    /// The party in battle order: the follower (activeIndex) leads, the rest
    /// keep their save order.
    static func loadParty() throws -> [WireMon] {
        let u = url
        guard FileManager.default.fileExists(atPath: u.path) else { throw LoadError.notFound(u.path) }
        // The official app saves atomically (temp + rename); a read racing the
        // rename can fail once, so retry briefly.
        var data: Data?
        var lastError: Error?
        for attempt in 0..<3 {
            do { data = try Data(contentsOf: u); break }
            catch { lastError = error; if attempt < 2 { Thread.sleep(forTimeInterval: 0.15) } }
        }
        guard let data else { throw LoadError.unreadable("\(lastError.map { "\($0)" } ?? "unknown")") }
        let save: RaisingSave
        do { save = try JSONDecoder().decode(RaisingSave.self, from: data) }
        catch { throw LoadError.unreadable("\(error)") }

        var party = save.party
        if party.indices.contains(save.activeIndex), save.activeIndex != 0 {
            let lead = party.remove(at: save.activeIndex)
            party.insert(lead, at: 0)
        }
        let wire = party.compactMap { WireMon(owned: $0).sanitized() }
        guard !wire.isEmpty else { throw LoadError.emptyParty }
        return Array(wire.prefix(PvPRules.maxPartySize))
    }
}
