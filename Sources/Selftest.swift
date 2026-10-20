// Headless checks (dev build, console): `pmf-battle.exe --selftest`.
// build.ps1 selftest also runs `--simulate <seed>` in two separate processes
// and compares the digests, which catches per-process nondeterminism (e.g.
// Swift's randomly seeded hashing leaking into battle order).

import Foundation

enum Selftest {
    static func sampleTeams() -> (a: [WireMon], b: [WireMon]) {
        let a = [(25, 40), (6, 40), (9, 40)].compactMap { WireMon.sample(dex: $0.0, level: $0.1) }
        let b = [(3, 40), (65, 40), (143, 40)].compactMap { WireMon.sample(dex: $0.0, level: $0.1) }
        return (a, b)
    }

    static func simulateDigest(seed: UInt64) -> String {
        let t = sampleTeams()
        guard let battle = PvPBattle(seed: seed, partyA: t.a, partyB: t.b) else { return "invalid" }
        _ = battle.runToEnd()
        return "\(battle.digest) winner=\(battle.winner?.rawValue ?? "draw") rounds=\(battle.rounds)"
    }

    /// `--probe URL`: open the WebSocket, send a ping, print the first reply.
    /// Exercises TLS/proxy/upgrade without the GUI (dev build: console).
    static func probe(_ urlText: String) -> Int32 {
        guard let addr = ServerAddress(urlText) else { print("invalid url: \(urlText)"); return 2 }
        print("probe \(addr.display)\(addr.path)")
        let ws = WebSocketConnection()
        do { try ws.connect(to: addr) } catch { print("CONNECT FAILED: \(error)"); return 1 }
        print("connected (HTTP 101 upgrade OK)")
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var first: String?
        ws.onMessage = { text in
            lock.lock(); let isFirst = first == nil; if isFirst { first = text }; lock.unlock()
            if isFirst { done.signal() }
        }
        ws.onClose = { reason in print("closed: \(reason ?? "by us")"); done.signal() }
        Thread.detachNewThread { ws.runReceiveLoop() }
        ws.send(text: #"{"t":"ping"}"#)
        _ = done.wait(timeout: .now() + 5)
        lock.lock(); let reply = first; lock.unlock()
        print("first message: \(reply ?? "(none)")")
        ws.close()
        Thread.sleep(forTimeInterval: 0.3)
        return reply != nil ? 0 : 1
    }

    static func run() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            print((cond ? "  PASS  " : "  FAIL  ") + what)
            if !cond { ok = false }
        }
        print("pmf-battle selftest — engine \(ClientInfo.engineKey)")

        // 1. game data + sample teams
        let t = sampleTeams()
        check(GameData.species.count >= 251, "gamedata/species.json 로드 (\(GameData.species.count)종)")
        check(t.a.count == 3 && t.b.count == 3, "샘플 팀 구성")

        // 2. same seed -> same battle (in-process)
        let d1 = simulateDigest(seed: 20261019)
        let d2 = simulateDigest(seed: 20261019)
        check(d1 == d2, "같은 시드 재현성 (\(d1))")
        check(simulateDigest(seed: 1) != simulateDigest(seed: 2), "다른 시드는 다른 전투")

        // 3. many seeds: always terminates, sane outcomes
        var wins = [PvPSide.a: 0, .b: 0]
        var draws = 0, maxRounds = 0, failures = 0
        for seed in UInt64(1)...300 {
            guard let b = PvPBattle(seed: seed &* 0x9E37_79B9, partyA: t.a, partyB: t.b) else { failures += 1; continue }
            _ = b.runToEnd()
            if !b.finished { failures += 1 }
            if let w = b.winner { wins[w, default: 0] += 1 } else { draws += 1 }
            maxRounds = max(maxRounds, b.rounds)
        }
        check(failures == 0, "300판 모두 정상 종료 (A승 \(wins[.a]!), B승 \(wins[.b]!), 무 \(draws), 최대 \(maxRounds)라운드)")
        check(maxRounds <= PvPRules.maxRounds, "라운드 상한 준수")

        // 4. mirror match + side swap sanity
        if let m = PvPBattle(seed: 7, partyA: t.a, partyB: t.a) {
            _ = m.runToEnd()
            check(m.finished, "미러 매치 종료")
        }

        // 5. official save (informational: absent on a fresh machine)
        do {
            let party = try OfficialSave.loadParty()
            print("  INFO  공식 세이브 파티: " + party.map { "\($0.displayName) Lv.\($0.level)" }.joined(separator: ", "))
            if let b = PvPBattle(seed: 99, partyA: party, partyB: t.b) {
                _ = b.runToEnd()
                check(b.finished, "내 파티 vs 샘플 팀 대전 종료")
            } else {
                check(false, "내 파티로 대전 생성")
            }
        } catch {
            print("  INFO  공식 세이브 없음 — \(error)")
        }

        // 6. eyeball a log
        print("\n--- 샘플 전투 로그 (seed 20261019) ---")
        if let b = PvPBattle(seed: 20261019, partyA: t.a, partyB: t.b) {
            var active: [PvPSide: Int] = [.a: 0, .b: 0]
            var printed = 0
            for step in b.runToEnd() where printed < 40 {
                switch step {
                case .sendOut(let side, let i, let reason):
                    active[side] = i
                    print("[\(side.rawValue)] \(b.wire(side, i).displayName) 등장 (\(reason))")
                case .event(let e):
                    let na = b.wire(.a, active[.a]!).displayName
                    let nb = "상대 " + b.wire(.b, active[.b]!).displayName
                    for l in BattleLog.lines(for: e, playerName: na, wildName: nb) { print("    \(l.text)") }
                case .end(let w, let d):
                    print("== 종료: \(w?.rawValue ?? "무승부") \(d ? "(판정)" : "")")
                }
                printed += 1
            }
        }
        print(ok ? "\nALL PASS" : "\nSOME CHECKS FAILED")
        return ok
    }
}
