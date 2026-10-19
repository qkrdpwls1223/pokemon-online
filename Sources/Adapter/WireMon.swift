// The battle-relevant slice of an owned Pokémon, as sent over the wire.
//
// Deliberately small and stable: only what decides a battle (species, level,
// moves, OFF toggles, gender, IVs). EXP, HP, status and faint timers stay in
// the official save — every PvP battle starts at full health.

import Foundation

struct WireMon: Codable {
    var dex: Int
    var level: Int
    var moves: [Int]
    var disabledMoves: [Int]?
    var gender: String          // upstream Gender raw value
    var ivs: Stats?

    init(dex: Int, level: Int, moves: [Int], disabledMoves: [Int]? = nil,
         gender: String, ivs: Stats? = nil) {
        self.dex = dex
        self.level = level
        self.moves = moves
        self.disabledMoves = disabledMoves
        self.gender = gender
        self.ivs = ivs
    }

    /// Demo/test mon: the last four level-up moves known at `level`,
    /// fixed mid IVs, genderless (no RNG involved).
    static func sample(dex: Int, level: Int) -> WireMon? {
        guard let s = GameData.species[dex] else { return nil }
        let mv = Array(s.levelUpMoves.filter { $0.level <= level }.map { $0.moveId }.suffix(4))
        let iv = Stats(hp: 15, atk: 15, def: 15, spAtk: 15, spDef: 15, spe: 15)
        return WireMon(dex: dex, level: level, moves: mv, gender: Gender.genderless.rawValue, ivs: iv)
    }

    init(owned m: OwnedPokemon) {
        dex = m.dex
        level = m.level
        moves = m.moves
        disabledMoves = m.disabledMoves
        gender = m.gender.rawValue
        ivs = m.ivs
    }

    /// Clamp to values the engine can run. Returns nil for an unknown species.
    /// (Both clients sanitize the same input identically, so this never
    /// causes divergence; it only keeps a hand-edited save from crashing.)
    func sanitized() -> WireMon? {
        guard GameData.species[dex] != nil else { return nil }
        var m = self
        m.level = min(max(level, 1), 100)
        m.moves = Array(moves.filter { GameData.moves[$0] != nil }.prefix(4))
        if let d = disabledMoves { m.disabledMoves = d.filter { m.moves.contains($0) } }
        if Gender(rawValue: gender) == nil { m.gender = Gender.genderless.rawValue }
        if let iv = ivs {
            func c(_ v: Int) -> Int { min(max(v, 0), 31) }
            m.ivs = Stats(hp: c(iv.hp), atk: c(iv.atk), def: c(iv.def),
                          spAtk: c(iv.spAtk), spDef: c(iv.spDef), spe: c(iv.spe))
        }
        return m
    }

    var displayName: String { Characters.displayName(dex: dex) }
    var spriteFolder: String { Characters.folder(dex: dex) }

    /// A fresh, full-HP battler built through upstream's own
    /// `Battler(mon:)` path, so stat/IV/move handling always matches the
    /// engine version we were compiled against.
    func makeBattler() -> Battler? {
        // OwnedPokemon has a property observer, so it is built by decoding
        // rather than through its memberwise init (which upstream may change).
        let seed = OwnedSeed(dex: dex, level: level, exp: 0, currentHP: 1, moves: moves,
                             disabledMoves: disabledMoves,
                             gender: Gender(rawValue: gender) ?? .genderless, ivs: ivs)
        guard let data = try? JSONEncoder().encode(seed),
              var mon = try? JSONDecoder().decode(OwnedPokemon.self, from: data) else { return nil }
        mon.heal()
        return Battler(mon: mon)
    }
}

/// Mirror of the OwnedPokemon fields needed to decode one.
private struct OwnedSeed: Codable {
    let dex: Int
    let level: Int
    let exp: Int
    let currentHP: Int
    let moves: [Int]
    let disabledMoves: [Int]?
    let gender: Gender
    let ivs: Stats?
}
