// Wire protocol v2 — one JSON object per WebSocket text message, every
// object tagged by "t". The server half lives in server/server.js;
// docs/design.md §4 is the reference table.

import Foundation

enum WireProtocol {
    static let version = 2
}

// MARK: - client -> server

struct HelloMsg: Encodable {
    let t = "hello"
    let proto = WireProtocol.version
    let password: String       // lobby password ("" when the server has none)
    let name: String
    let engine: String
    let client: String
    let party: [WireMon]
}

struct PartyMsg: Encodable {
    let t = "party"
    let party: [WireMon]
}

struct ChallengeMsg: Encodable {
    let t = "challenge"
    let to: String
}

struct CancelChallengeMsg: Encodable {
    let t = "cancelChallenge"
}

struct RespondMsg: Encodable {
    let t = "respond"
    let from: String
    let accept: Bool
}

struct BattleDoneMsg: Encodable {
    let t = "battleDone"
    let battleId: String
    let winner: String      // "A" | "B" | "draw"
    let digest: String
}

struct PingMsg: Encodable {
    let t = "ping"
}

// MARK: - server -> client

struct Envelope: Decodable {
    let t: String
}

struct WelcomeMsg: Decodable {
    let id: String
    let name: String           // may differ from the requested one (dedup)
    let serverVersion: String?
}

struct ServerErrorMsg: Decodable {
    let code: String
    let message: String
}

struct LobbyLead: Decodable {
    let dex: Int
    let level: Int
}

/// One party member as the lobby shows it (no IVs or gender).
struct LobbyMon: Decodable {
    let dex: Int
    let level: Int
    let moves: [Int]
}

struct LobbyUser: Decodable {
    let id: String
    let name: String
    let status: String         // "idle" | "challenging" | "battling"
    let lead: LobbyLead?
    let partySize: Int
    let party: [LobbyMon]?     // server 0.3+; older servers send only `lead`
    let compatible: Bool       // same engine key as the receiving client
    let bot: Bool?             // practice bot (server/tools/bot.js)
}

struct LobbyMsg: Decodable {
    let users: [LobbyUser]
}

struct ChallengedMsg: Decodable {
    let from: String
    let fromName: String
    let expiresIn: Int
}

struct ChallengeSentMsg: Decodable {
    let to: String
    let toName: String
    let expiresIn: Int
}

struct ChallengeEndedMsg: Decodable {
    let peer: String
    let peerName: String?
    let reason: String         // declined | expired | cancelled | busy | incompatible | offline
}

struct BattlePlayer: Decodable {
    let id: String
    let name: String
    let party: [WireMon]
}

struct BattleStartMsg: Decodable {
    let battleId: String
    let seed: String           // UInt64 in decimal (JSON numbers can't hold 64 bits)
    let mode: String           // "auto" (spectator); "manual" reserved
    let you: String            // "A" | "B"
    let a: BattlePlayer
    let b: BattlePlayer
}

struct BattleCheckMsg: Decodable {
    let battleId: String
    let consistent: Bool
}

struct PeerLeftMsg: Decodable {
    let battleId: String
    let name: String?
}

/// Every server message the client understands, decoded off a raw line.
enum ServerMessage {
    case welcome(WelcomeMsg)
    case error(ServerErrorMsg)
    case lobby(LobbyMsg)
    case challenged(ChallengedMsg)
    case challengeSent(ChallengeSentMsg)
    case challengeEnded(ChallengeEndedMsg)
    case battleStart(BattleStartMsg)
    case battleCheck(BattleCheckMsg)
    case peerLeft(PeerLeftMsg)
    case pong
    case unknown(String)

    static func decode(_ line: String) -> ServerMessage? {
        let data = Data(line.utf8)
        let dec = JSONDecoder()
        guard let env = try? dec.decode(Envelope.self, from: data) else { return nil }
        func d<T: Decodable>(_ type: T.Type) -> T? { try? dec.decode(T.self, from: data) }
        switch env.t {
        case "welcome": return d(WelcomeMsg.self).map(ServerMessage.welcome)
        case "error": return d(ServerErrorMsg.self).map(ServerMessage.error)
        case "lobby": return d(LobbyMsg.self).map(ServerMessage.lobby)
        case "challenged": return d(ChallengedMsg.self).map(ServerMessage.challenged)
        case "challengeSent": return d(ChallengeSentMsg.self).map(ServerMessage.challengeSent)
        case "challengeEnded": return d(ChallengeEndedMsg.self).map(ServerMessage.challengeEnded)
        case "battleStart": return d(BattleStartMsg.self).map(ServerMessage.battleStart)
        case "battleCheck": return d(BattleCheckMsg.self).map(ServerMessage.battleCheck)
        case "peerLeft": return d(PeerLeftMsg.self).map(ServerMessage.peerLeft)
        case "pong": return .pong
        default: return .unknown(env.t)
        }
    }
}

func encodeJSON<T: Encodable>(_ msg: T) -> String? {
    guard let data = try? JSONEncoder().encode(msg) else { return nil }
    return String(decoding: data, as: UTF8.self)
}
