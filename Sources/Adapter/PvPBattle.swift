// Party-vs-party battle runner on top of upstream's 1-vs-1 BattleSession.
//
// Determinism contract (docs/design.md §3): both clients build this from the
// same (seed, partyA, partyB) and the same upstream commit, so every roll
// drawn from BattleRNG matches and both screens show the identical battle.
// Rules that need randomness (who gets dragged in by Roar) draw from
// BattleRNG too — never from the system RNG.
//
// Engine mapping: side A is upstream's "player", side B its "wild". The
// server picks A at random, so the engine's small player-side tie-breaks
// (equal Speed goes to the player) don't always favor the challenger.
// Balls are never stocked, so no capture can happen.
//
// Turn input: every round currently goes through upstream's own move choice
// (random among usable moves — "spectator mode"). Manual move selection plugs
// in at `nextRound()`; see docs/design.md §5.

import Foundation

enum PvPRules {
    /// Bump whenever this file changes battle outcomes. Part of the engine
    /// compatibility key, so mismatched clients are never paired.
    static let version = 1
    static let maxPartySize = 6
    /// Hard stop for stalling teams; the side with more HP left wins.
    static let maxRounds = 600
}

enum PvPSide: String, Codable {
    case a = "A", b = "B"
    var other: PvPSide { self == .a ? .b : .a }
}

enum PvPStep {
    enum SendOutReason { case lead, replaceFainted, forced }
    case sendOut(side: PvPSide, index: Int, reason: SendOutReason)
    case event(BattleEvent)
    /// winner nil = draw. `byDecision`: ended by the round cap (HP compared).
    case end(winner: PvPSide?, byDecision: Bool)
}

final class PvPBattle {
    let seed: UInt64
    let parties: [PvPSide: [WireMon]]
    private(set) var teams: [PvPSide: [Battler]] = [:]
    private(set) var active: [PvPSide: Int] = [.a: 0, .b: 0]
    private(set) var finished = false
    private(set) var winner: PvPSide?
    private(set) var rounds = 0
    private(set) var log: [PvPStep] = []
    private var session: BattleSession?
    private var hasher = FNV1a64()

    /// nil when either party yields no battler.
    init?(seed: UInt64, partyA: [WireMon], partyB: [WireMon]) {
        self.seed = seed
        let a = partyA.compactMap { $0.sanitized() }.prefix(PvPRules.maxPartySize)
        let b = partyB.compactMap { $0.sanitized() }.prefix(PvPRules.maxPartySize)
        parties = [.a: Array(a), .b: Array(b)]
        // Seed BEFORE building battlers: construction is RNG-free today, but
        // if upstream ever rolls something there it must be reproducible.
        BattleRNG.reseed(seed)
        let ta = a.compactMap { $0.makeBattler() }
        let tb = b.compactMap { $0.makeBattler() }
        guard !ta.isEmpty, !tb.isEmpty, ta.count == a.count, tb.count == b.count else { return nil }
        teams = [.a: ta, .b: tb]
    }

    func battler(_ side: PvPSide, _ index: Int) -> Battler { teams[side]![index] }
    func activeBattler(_ side: PvPSide) -> Battler { battler(side, active[side]!) }
    func wire(_ side: PvPSide, _ index: Int) -> WireMon { parties[side]![index] }

    /// Lead-off: both first members come out.
    func start() -> [PvPStep] {
        guard session == nil, !finished else { return [] }
        var out: [PvPStep] = [.sendOut(side: .a, index: 0, reason: .lead),
                              .sendOut(side: .b, index: 0, reason: .lead)]
        session = BattleSession(player: activeBattler(.a), wild: activeBattler(.b), balls: [])
        record(&out)
        return out
    }

    /// One engine round plus whatever party bookkeeping it triggers.
    func nextRound() -> [PvPStep] {
        guard let s = session, !finished else { return [] }
        var out: [PvPStep] = s.nextRound().map { .event($0) }
        rounds += 1

        // Roar/Whirlwind hit side A: trainer rules — a random benched member
        // is dragged in and the battle goes on.
        if s.playerDraggedOut {
            if let idx = randomBench(.a) {
                let incoming = refreshed(.a, idx)
                active[.a] = idx
                s.dragOutPlayer(replacement: incoming)
                out.append(.sendOut(side: .a, index: idx, reason: .forced))
            } else {
                s.markPlayerFled()   // nobody to drag in: resolved below
            }
        }
        if s.isOver || rounds >= PvPRules.maxRounds {
            out += resolveSessionEnd(s)
        }
        record(&out)
        return out
    }

    /// Spectator mode: simulate everything at once (playback is separate).
    func runToEnd() -> [PvPStep] {
        var all = start()
        while !finished { all += nextRound() }
        return all
    }

    /// Hex digest of everything that happened — both clients report it so a
    /// desync (different upstream builds, a nondeterminism bug) is caught.
    var digest: String {
        let hex = String(hasher.value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    // MARK: - session boundaries

    private func resolveSessionEnd(_ s: BattleSession) -> [PvPStep] {
        let aMon = activeBattler(.a), bMon = activeBattler(.b)
        let stalled = rounds >= PvPRules.maxRounds
            || (s.turn >= 200 && !aMon.isFainted && !bMon.isFainted && !s.playerFled && !s.wildFled)
        if stalled { return finish(winner: hpLeader(), byDecision: true) }

        var out: [PvPStep] = []
        var aOut = false, bOut = false
        var changedA: PvPStep.SendOutReason?
        var changedB: PvPStep.SendOutReason?

        if aMon.isFainted {
            if let n = firstConscious(.a) { active[.a] = n; changedA = .replaceFainted } else { aOut = true }
        } else if s.playerFled, let n = randomBench(.a) {
            // Teleport (or a Roar with nobody to drag in): mainline trainer
            // battles never let a mon leave, so a benched one takes over when
            // there is one; otherwise the same mon simply stays in.
            active[.a] = n; changedA = .forced
        }
        if bMon.isFainted {
            if let n = firstConscious(.b) { active[.b] = n; changedB = .replaceFainted } else { bOut = true }
        } else if s.wildFled, let n = randomBench(.b) {
            active[.b] = n; changedB = .forced
        }

        if aOut || bOut {
            return finish(winner: aOut && bOut ? nil : (aOut ? .b : .a), byDecision: false)
        }
        if let r = changedA {
            _ = refreshed(.a, active[.a]!)
            out.append(.sendOut(side: .a, index: active[.a]!, reason: r))
        }
        if let r = changedB {
            _ = refreshed(.b, active[.b]!)
            out.append(.sendOut(side: .b, index: active[.b]!, reason: r))
        }
        // A new 1-vs-1 session; the mon that stayed in keeps its Battler
        // (stages, volatiles) — only the newcomer is fresh.
        session = BattleSession(player: activeBattler(.a), wild: activeBattler(.b), balls: [])
        return out
    }

    private func finish(winner w: PvPSide?, byDecision: Bool) -> [PvPStep] {
        finished = true
        winner = w
        return [.end(winner: w, byDecision: byDecision)]
    }

    // MARK: - party helpers

    private func firstConscious(_ side: PvPSide) -> Int? {
        teams[side]!.firstIndex { !$0.isFainted }
    }

    private func randomBench(_ side: PvPSide) -> Int? {
        let current = active[side]!
        let bench = teams[side]!.indices.filter { $0 != current && !teams[side]![$0].isFainted }
        guard !bench.isEmpty else { return nil }
        return bench[Int.random(in: 0..<bench.count, using: &BattleRNG.g)]
    }

    /// The member as it re-enters: rebuilt from its wire data (switching out
    /// clears stages and volatiles, mainline-style) but keeping HP and its
    /// major status. Toxic's counter restarts, as in Gen 4.
    private func refreshed(_ side: PvPSide, _ index: Int) -> Battler {
        let old = teams[side]![index]
        guard let fresh = wire(side, index).makeBattler() else { return old }
        fresh.currentHP = old.currentHP
        fresh.status = old.status
        fresh.sleepTurns = old.sleepTurns
        teams[side]![index] = fresh
        return fresh
    }

    /// Remaining HP share of each team; nil on an exact tie.
    private func hpLeader() -> PvPSide? {
        func share(_ side: PvPSide) -> Double {
            let t = teams[side]!
            let cur = t.reduce(0) { $0 + Swift.max(0, $1.currentHP) }
            let total = t.reduce(0) { $0 + $1.maxHP }
            return total > 0 ? Double(cur) / Double(total) : 0
        }
        let a = share(.a), b = share(.b)
        if abs(a - b) < 1e-9 { return nil }
        return a > b ? .a : .b
    }

    // MARK: - digest

    private func record(_ steps: inout [PvPStep]) {
        for st in steps {
            log.append(st)
            switch st {
            case .sendOut(let side, let index, let reason):
                hasher.add("S|\(side.rawValue)|\(index)|\(reason)")
            case .event(let e):
                hasher.add("E|\(e.kind)|\(e.actorIsPlayer)|\(e.moveId)|\(e.damage)|\(e.targetIsPlayer)|"
                           + "\(e.targetHP)|\(e.fainted)|\(e.statusApplied ?? "-")|\(e.turn)|\(e.crit)")
            case .end(let w, let d):
                hasher.add("X|\(w?.rawValue ?? "draw")|\(d)")
            }
        }
    }
}

/// 64-bit FNV-1a over UTF-8 — identical on every platform (unlike Hasher,
/// which is randomly seeded per process).
struct FNV1a64 {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func add(_ s: String) {
        for b in s.utf8 {
            value ^= UInt64(b)
            value = value &* 0x0000_0100_0000_01B3
        }
        value ^= 0x0A   // record separator
        value = value &* 0x0000_0100_0000_01B3
    }
}
