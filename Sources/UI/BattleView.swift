// Battle playback view: replays a precomputed PvP timeline with idle
// sprites, HP bars, upstream's own battle-log wording and upstream's
// move-effect clips (EffectPlayer).
//
// The view never simulates — it only plays PvPStep values. Spectator mode
// hands it the whole timeline at once; manual mode (later) will append steps
// round by round through `append(_:)`.
//
// Effect choreography follows upstream's BattleController beat by beat
// (projectile -> companion -> hit clip -> stat auras -> ailment, one clip at
// a time) in 1/60 s ticks; that controller itself is tied to the overlay and
// wild encounters, so it is mirrored here rather than reused. File-backed
// clips need OfficialEffects.isReady; the synthetic ones (stat auras,
// confusion orbit, Leech Seed drain) and the screen flash always play.

import WinSDK
import Foundation

private let battleViewClass = w16("PMFBattleView")
private var battleViewRegistered = false

/// Upstream's playback tick (EoS native rate).
private let tickMs = 1000.0 / 60.0

private func battleViewProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let view = BattleView.instance, view.hwnd == hwnd else {
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
    switch msg {
    case WM.paint:
        view.paint()
        return 0
    case WM.eraseBkgnd:
        return 1
    case WM.timer:
        view.tick()
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

final class BattleView {
    static weak var instance: BattleView?

    private(set) var hwnd: HWND?
    private let k: Double
    private let canvas = Canvas()
    private var fontName: HFONT?
    private var fontSmall: HFONT?
    private var fontLog: HFONT?
    private var fontBanner: HFONT?

    /// Fired once when the timeline's end step has finished playing.
    var onFinished: (() -> Void)?

    // timeline
    private var battle: PvPBattle?
    private var steps: [PvPStep] = []
    private var cursor = -1
    private var stepElapsed = 0.0         // ms into the current step
    private var stepDuration = 0.0
    private var speed = 1.0
    private var finishedFired = false
    private var lastTick: UInt64 = 0
    private var animClock = 0.0           // ms, drives idle frames

    // scene
    private var mySide: PvPSide = .a
    private var trainerNames: [PvPSide: String] = [:]
    private struct Slot {
        var index = -1
        var shownHP = 0.0                 // animated
        var targetHP = 0
        var maxHP = 1
        var fainted = false
        var asleep = false
        var fadeIn = 1.0
    }
    private var slots: [PvPSide: Slot] = [.a: Slot(), .b: Slot()]
    private var hp: [PvPSide: [Int]] = [:]            // per-member HP as last seen
    private var down: [PvPSide: Set<Int>] = [.a: [], .b: []]
    private var logLines: [String] = []
    private var pendingLines: [(at: Double, text: String)] = []
    private var pendingHP: (at: Double, side: PvPSide, hp: Int, fainted: Bool)?
    private var shake: (side: PvPSide, from: Double, until: Double)?
    private var banner: String?

    // effects (all times in ms into the current step)
    /// Body motion: a contact lunge peaking at the impact, or a small nudge
    /// toward the foe when the move leaves from range.
    private struct Motion {
        let side: PvPSide
        let from: Double, peak: Double, until: Double
        let reach: Double                 // px toward the foe at the peak
    }
    private var motion: Motion?
    /// Clips play one after another, as upstream draws only its first.
    private struct ScheduledEffect {
        var run: RunningEffect
        let start: Double
        let length: Double
        let scale: Int
    }
    private var effects: [ScheduledEffect] = []
    /// Full-screen moves and Explosion: tinted veil + quake for 20 ticks.
    private var veil: (from: Double, color: UInt32, explosion: Bool)?

    init(parent: HWND?, k: Double, x: Int32, y: Int32, w: Int32, h: Int32) {
        self.k = k
        if !battleViewRegistered {
            var wc = WNDCLASSW()
            wc.lpfnWndProc = { battleViewProc($0, $1, $2, $3) }
            wc.hInstance = GetModuleHandleW(nil)
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            battleViewClass.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
            RegisterClassW(&wc)
            battleViewRegistered = true
        }
        hwnd = battleViewClass.withUnsafeBufferPointer { cls in
            CreateWindowExW(0, cls.baseAddress, nil, DWORD(WS_CHILD),
                            x, y, w, h, parent, nil, GetModuleHandleW(nil), nil)
        }
        fontName = makeFont(15, weight: 700, k: k)
        fontSmall = makeFont(12, k: k)
        fontLog = makeFont(15, k: k)
        fontBanner = makeFont(30, weight: 800, k: k)
        BattleView.instance = self
    }

    deinit {
        for f in [fontName, fontSmall, fontLog, fontBanner] { if let f { DeleteObject(f) } }
    }

    private func px(_ v: Double) -> Int { Int((v * k).rounded()) }

    // MARK: - control

    func play(battle: PvPBattle, steps: [PvPStep], mySide: PvPSide,
              myName: String, foeName: String) {
        self.battle = battle
        self.steps = steps
        self.mySide = mySide
        trainerNames = [mySide: myName, mySide.other: foeName]
        cursor = -1
        stepElapsed = 0
        stepDuration = 0
        finishedFired = false
        banner = nil
        logLines = ["\(foeName) 님과의 대전이 시작됐다!"]
        pendingLines = []
        pendingHP = nil
        shake = nil
        clearEffects()
        slots = [.a: Slot(), .b: Slot()]
        down = [.a: [], .b: []]
        hp = [:]
        for side in [PvPSide.a, .b] {
            let n = battle.parties[side]?.count ?? 0
            hp[side] = (0..<n).map { battle.battler(side, $0).maxHP }
        }
        lastTick = GetTickCount64()
        SetTimer(hwnd, 1, 16, nil)
        InvalidateRect(hwnd, nil, false)
    }

    /// Manual mode hook: more steps arrive while playing.
    func append(_ more: [PvPStep]) { steps += more }

    func setFast(_ fast: Bool) { speed = fast ? 2.5 : 1.0 }

    /// Jump to the end state (skip button).
    func skipToEnd() {
        while cursor < steps.count - 1 {
            flushPending()
            beginStep(cursor + 1)
        }
        flushPending()
        stepElapsed = stepDuration
        shake = nil
        clearEffects()
        for side in [PvPSide.a, .b] {
            if var s = slots[side] { s.shownHP = Double(s.targetHP); s.fadeIn = 1; slots[side] = s }
        }
        InvalidateRect(hwnd, nil, false)
    }

    func stop() {
        KillTimer(hwnd, 1)
        battle = nil
        steps = []
        clearEffects()
    }

    var isFinished: Bool { finishedFired }

    private func clearEffects() {
        motion = nil
        effects = []
        veil = nil
    }

    // MARK: - timeline

    fileprivate func tick() {
        let now = GetTickCount64()
        let dt = Double(now &- lastTick)
        lastTick = now
        animClock += dt
        guard battle != nil else { return }

        let adv = min(dt, 100) * speed
        stepElapsed += adv
        // due lines / HP
        while let first = pendingLines.first, first.at <= stepElapsed {
            pushLog(first.text)
            pendingLines.removeFirst()
        }
        if let p = pendingHP, p.at <= stepElapsed { applyHP(p.side, p.hp, p.fainted); pendingHP = nil }

        if stepElapsed >= stepDuration, cursor < steps.count - 1 {
            flushPending()
            beginStep(cursor + 1)
        } else if stepElapsed >= stepDuration, cursor == steps.count - 1, !finishedFired, isEndStep(cursor) {
            finishedFired = true
            onFinished?()
        }

        // HP bars glide toward their targets
        for side in [PvPSide.a, .b] {
            guard var s = slots[side] else { continue }
            let target = Double(s.targetHP)
            if abs(s.shownHP - target) > 0.01 {
                let step = max(0.5, Double(s.maxHP) * 0.0025 * adv)
                s.shownHP = s.shownHP < target ? min(target, s.shownHP + step) : max(target, s.shownHP - step)
            }
            if s.fadeIn < 1 { s.fadeIn = min(1, s.fadeIn + adv / 300) }
            slots[side] = s
        }
        InvalidateRect(hwnd, nil, false)
    }

    private func isEndStep(_ i: Int) -> Bool {
        guard steps.indices.contains(i) else { return false }
        if case .end = steps[i] { return true }
        return false
    }

    private func flushPending() {
        for l in pendingLines { pushLog(l.text) }
        pendingLines = []
        if let p = pendingHP { applyHP(p.side, p.hp, p.fainted); pendingHP = nil }
    }

    private func beginStep(_ i: Int) {
        guard let battle, steps.indices.contains(i) else { return }
        cursor = i
        stepElapsed = 0
        shake = nil
        clearEffects()
        switch steps[i] {
        case .sendOut(let side, let index, let reason):
            let wire = battle.wire(side, index)
            let maxHP = battle.battler(side, index).maxHP
            let cur = hp[side]?[index] ?? maxHP
            slots[side] = Slot(index: index, shownHP: Double(cur), targetHP: cur, maxHP: maxHP,
                               fainted: false, asleep: false, fadeIn: 0)
            let who = trainerNames[side] ?? ""
            let mine = side == mySide
            switch reason {
            case .lead, .replaceFainted:
                if mine {
                    // upstream's mainline-style call ("가랏! X!"), worded by the foe's HP
                    let foe = slots[side.other]
                    let frac = foe.map { $0.index >= 0 ? Double($0.targetHP) / Double(max(1, $0.maxHP)) : 1 } ?? 1
                    pushLog(BattleLog.sendOutLine(playerName: wire.displayName, foeHPFraction: frac))
                } else {
                    pushLog("\(who) 님이 \(wire.displayName)를(을) 내보냈다!")
                }
            case .forced:
                pushLog(BattleLog.draggedOutLine(playerName: label(side)))
            }
            stepDuration = 750

        case .event(let e):
            let target: PvPSide = e.targetIsPlayer ? .a : .b
            let entries = BattleLog.lines(for: e, playerName: label(.a), wildName: label(.b))
            let beat = choreograph(e)
            stepDuration = max(beat.end, entries.isEmpty ? 350 : 1000)
            for entry in entries {
                let at: Double
                switch entry.phase {
                case .start: at = 0
                case .impact: at = beat.impact
                case .resolve: at = beat.hit
                }
                if at == 0 { pushLog(entry.text) } else { pendingLines.append((at: at, text: entry.text)) }
            }
            if e.damage > 0, e.kind != .recover {
                shake = (side: target, from: beat.impact, until: beat.impact + 250)
            }
            if var a = slots[.a] { a.asleep = e.playerAsleep; slots[.a] = a }
            if var b = slots[.b] { b.asleep = e.wildAsleep; slots[.b] = b }
            pendingHP = (at: beat.hit, side: target, hp: e.targetHP, fainted: e.fainted)

        case .end(let winner, let byDecision):
            stepDuration = 400
            if let w = winner {
                banner = w == mySide ? "승리!" : "패배…"
                if byDecision { pushLog("시간 초과! 남은 HP로 승부를 가렸다.") }
                pushLog(w == mySide ? "\(trainerNames[mySide.other] ?? "상대") 님과의 승부에서 이겼다!"
                                    : "\(trainerNames[mySide.other] ?? "상대") 님에게 졌다…")
            } else {
                banner = "무승부"
                pushLog("승부가 나지 않았다.")
            }
        }
    }

    private func applyHP(_ side: PvPSide, _ value: Int, _ fainted: Bool) {
        guard var s = slots[side] else { return }
        s.targetHP = max(0, value)
        if fainted {
            s.fainted = true
            down[side, default: []].insert(s.index)
        }
        if s.index >= 0 { hp[side]?[s.index] = max(0, value) }
        slots[side] = s
    }

    private func pushLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 4 { logLines.removeFirst(logLines.count - 4) }
    }

    /// Battle-log name for the side's active mon: the opponent's carries a
    /// "상대" prefix so mirror matches stay readable.
    private func label(_ side: PvPSide) -> String {
        guard let battle, let s = slots[side], s.index >= 0 else { return "?" }
        let name = battle.wire(side, s.index).displayName
        return side == mySide ? name : "상대 \(name)"
    }

    // MARK: - effect choreography

    /// Ailment tag -> status clip key (upstream BattleController.ailmentLanding).
    private static let ailmentClip: [String: String] = [
        "paralysis": "paralyzed", "burn": "burn", "poison": "poison", "badPoison": "poison",
        "sleep": "asleep", "freeze": "frozen", "confusion": "confused", "infatuation": "infatuated",
    ]

    /// Queues this event's clips/motion/veil; returns its beat in ms:
    /// `impact` (hit lands: flinch, impact lines), `hit` (HP starts moving,
    /// resolve lines) and `end` (next step may start).
    private func choreograph(_ e: BattleEvent) -> (impact: Double, hit: Double, end: Double) {
        let files = OfficialEffects.isReady
        let actor: PvPSide = e.actorIsPlayer ? .a : .b
        let target: PvPSide = e.targetIsPlayer ? .a : .b
        var queue: [(RunningEffect, Int)] = []
        func play(_ clip: EffectClip, at side: PvPSide, maxTicks: Int, delay: Int = 0) {
            queue.append((RunningEffect(clip: clip, anchor: anchor(side), maxTicks: maxTicks, delay: delay),
                          spriteScale(side)))
        }
        func statusClip(_ key: String) -> EffectClip? {
            key == "confused" || files ? EffectPlayer.statusClip(key) : nil
        }
        let explosion = e.moveId > 0 && EffectPlayer.isExplosionMove(e.moveId)
        var impactAt = 0, hitAt = 0, endAt = 0

        switch e.kind {
        case .attack, .miss:
            let from = anchor(actor), to = anchor(target), foe = anchor(actor.other)
            let travel = 18, windup = e.followUp ? 6 : 20
            let move = GameData.moves[e.moveId]
            let statusCry = move?.sound == true && move?.category == "Status"
            // Self-targeted cries (Howl) still ring out toward the foe.
            let aim = target == actor && statusCry ? foe : to
            let octant = abs(aim.x - from.x) > 0.01 || abs(aim.y - from.y) > 0.01
                ? Sprite.octant(dx: aim.x - from.x, dy: aim.y - from.y) : 6
            let proj = files && e.moveId > 0 ? EffectPlayer.projectile(forMove: e.moveId, octant: octant) : nil
            var total = windup
            if let proj {
                queue.append((RunningEffect(clip: proj, from: from, to: to, maxTicks: travel), spriteScale(target)))
                total = travel
            }
            // Status cries with no projectile ring just ahead of the user.
            let cry = proj == nil && statusCry
            let front = CGPoint(x: from.x + (aim.x - from.x) * 0.3, y: from.y + (aim.y - from.y) * 0.3)
            func playHit(_ clip: EffectClip, at point: CGPoint, side: PvPSide, maxTicks: Int, delay: Int) {
                queue.append((RunningEffect(clip: clip, anchor: point, maxTicks: maxTicks, delay: delay),
                              spriteScale(side)))
            }
            // One multi-hit strike per event: its visual raps 3 quick times.
            let strikeReps = e.multiStrike ? 3 : 1
            var coTicks = 0
            if files, e.moveId > 0, !explosion,
               let co = EffectPlayer.coClip(forMove: e.moveId, octant: octant) {
                let ticks = min(co.loop ? 24 : co.totalTicks, e.multiStrike ? 8 : 36)
                let delay = proj == nil ? windup : 0
                // Drain gathers collect on the caster, cries ring ahead of it.
                let drain: Bool
                if case .drain = MoveMechanics.mechanic(for: e.moveId) { drain = true } else { drain = false }
                let (point, side) = drain ? (from, actor) : cry ? (front, actor) : (to, target)
                for i in 0..<strikeReps {
                    playHit(co, at: point, side: side, maxTicks: (i == 0 ? delay : 0) + ticks, delay: i == 0 ? delay : 0)
                }
                coTicks = ticks * strikeReps
                total += coTicks
            }
            impactAt = total
            // Explosion moves boomed on the selfHit beat; this one only lands damage.
            if files, e.moveId > 0, !explosion,
               let clip = EffectPlayer.clip(forMove: e.moveId, octant: octant) {
                let reps = coTicks > 0 ? 1 : strikeReps
                let hitTicks = min(clip.loop ? 40 : clip.totalTicks, reps > 1 ? 8 : 54)
                let delay = proj == nil && coTicks == 0 ? windup : 0
                for i in 0..<reps {
                    playHit(clip, at: cry ? front : to, side: cry ? actor : target,
                            maxTicks: (i == 0 ? delay : 0) + hitTicks, delay: i == 0 ? delay : 0)
                }
                total += hitTicks * reps
            }
            // Stat changes ("ATK +1" tokens) stream an aura on whose stats moved.
            if let tag = e.statusApplied {
                let side = tag.hasPrefix("self ") ? actor : target
                for (stat, delta) in BattleController.statChanges(in: tag).prefix(3) {
                    if let aura = EffectPlayer.statAura(stat, rising: delta > 0) {
                        let ticks = min(aura.totalTicks, 30)
                        play(aura, at: side, maxTicks: ticks)
                        total += ticks
                    }
                }
            }
            hitAt = max(impactAt, min(total, 72))
            if e.moveId > 0, EffectPlayer.isScreen(e.moveId) {
                hitAt = impactAt + 20
                veil = (from: Double(impactAt) * tickMs, color: rgb(TypeStyle.rgba(move?.type)), explosion: false)
            }
            let resolve = e.damage > 0 ? (e.multiStrike && e.statusApplied == nil ? 14 : 26)
                                       : (e.kind == .miss ? 24 : 10)
            endAt = hitAt + resolve + 16
            // An inflicted ailment shows its condition clip after the move's own.
            if e.kind == .attack, let s = e.statusApplied, let key = Self.ailmentClip[s] {
                if let clip = statusClip(key) {
                    play(clip, at: target, maxTicks: min(clip.loop ? 30 : clip.totalTicks, 44))
                }
                endAt = max(endAt, hitAt + resolve + 52)
            }
            // Only a landed (or whiffed damaging) contact move rams the foe;
            // the rest leave from range with a small nudge.
            if e.moveId > 0, !explosion, !EffectPlayer.isScreen(e.moveId) {
                let contact = (e.damage > 0 || (e.kind == .miss && BattleEngine.isDamaging(e.moveId)))
                    && !BattleController.rangedVisual(e.moveId)
                if contact {
                    let peak = Double(impactAt) * tickMs
                    motion = Motion(side: actor, from: max(0, peak - Double(windup) * tickMs), peak: peak,
                                    until: peak + 12 * tickMs, reach: Double(px(22)))
                } else {
                    let launch = Double(proj == nil ? windup : 0) * tickMs
                    motion = Motion(side: actor, from: 0, peak: max(launch, 6 * tickMs),
                                    until: max(launch, 6 * tickMs) + 10 * tickMs, reach: Double(px(8)))
                }
            }

        case .residual:
            // End-of-round chip damage: the condition's clip over the victim.
            impactAt = 8
            hitAt = 22
            if e.moveName == "leech seed", let clip = EffectPlayer.drainClip {
                // The stolen HP flies victim -> seeder.
                let travel = 26
                queue.append((RunningEffect(clip: clip, from: anchor(target), to: anchor(target.other),
                                            maxTicks: travel), spriteScale(target)))
                hitAt = max(hitAt, travel)
            } else if let clip = statusClip(e.moveName) {
                let ticks = min(clip.loop ? 30 : clip.totalTicks, 44)
                play(clip, at: target, maxTicks: ticks)
                hitAt = max(hitAt, ticks)
            }
            endAt = hitAt + 24 + 12

        case .selfHit:
            if explosion {
                // Detonation beat: blast over the USER, flash + quake, then its gauge drains.
                impactAt = 6
                hitAt = 6
                if files, let clip = EffectPlayer.clip(forMove: e.moveId) {
                    let ticks = min(clip.loop ? 40 : clip.totalTicks, 54)
                    play(clip, at: actor, maxTicks: 6 + ticks, delay: 6)
                    hitAt = 6 + ticks
                }
                veil = (from: 6 * tickMs, color: 0xFFA84D, explosion: true)
                endAt = hitAt + 26 + 12
            } else {
                impactAt = 6
                hitAt = 6
                endAt = hitAt + 24 + 12
            }

        case .skip:
            // A lost turn (paralyzed / frozen / asleep / in love) plays its condition over the actor.
            impactAt = 4
            endAt = 34
            if let clip = statusClip(e.moveName) {
                let ticks = min(clip.loop ? 30 : clip.totalTicks, 44)
                play(clip, at: actor, maxTicks: ticks, delay: 4)
                endAt = max(endAt, ticks + 16)
            }
            if e.moveName == "asleep" { endAt = 46 }

        case .recover:
            // Heal moves play their clip(s) over the healer before the gauge fills.
            impactAt = 6
            hitAt = 8
            if files, e.moveId > 0 {
                var t = 0
                if let co = EffectPlayer.coClip(forMove: e.moveId) {
                    let ticks = min(co.loop ? 24 : co.totalTicks, 36)
                    play(co, at: target, maxTicks: ticks)
                    t += ticks
                }
                if let clip = EffectPlayer.clip(forMove: e.moveId) {
                    let ticks = min(clip.loop ? 30 : clip.totalTicks, 44)
                    play(clip, at: target, maxTicks: ticks)
                    t += ticks
                }
                hitAt = max(hitAt, t)
            }
            endAt = hitAt + 22 + 12

        case .item, .ball:
            // Never emitted in PvP (no items, no balls).
            impactAt = 6
            hitAt = 6
            endAt = 30
        }

        var start = 0.0
        for (run, scale) in queue {
            let ticks = run.clip.loop || run.from != run.to
                ? run.maxTicks : min(run.maxTicks, run.delay + run.clip.totalTicks)
            effects.append(ScheduledEffect(run: run, start: start, length: Double(ticks) * tickMs, scale: scale))
            start += Double(ticks) * tickMs
        }
        return (Double(impactAt) * tickMs, Double(hitAt) * tickMs, Double(endAt) * tickMs)
    }

    private func rgb(_ c: RGBA) -> UInt32 {
        func ch(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return (ch(c.r) << 16) | (ch(c.g) << 8) | ch(c.b)
    }

    // MARK: - layout

    private struct Layout {
        let fieldH: Int
        let foeBase: (x: Int, y: Int)
        let myBase: (x: Int, y: Int)
    }

    private func layout(w: Int, h: Int) -> Layout {
        let fieldH = h - px(92)
        return Layout(fieldH: fieldH,
                      foeBase: (x: w * 72 / 100, y: fieldH * 50 / 100),
                      myBase: (x: w * 27 / 100, y: fieldH * 88 / 100))
    }

    private func currentLayout() -> Layout {
        var rc = RECT()
        GetClientRect(hwnd, &rc)
        return layout(w: Int(rc.right - rc.left), h: Int(rc.bottom - rc.top))
    }

    private func spriteScale(_ side: PvPSide) -> Int {
        side == mySide ? max(2, px(3.2)) : max(2, px(2.6))
    }

    private func facing(_ side: PvPSide) -> SpriteCache.Facing {
        side == mySide ? .upRight : .downLeft
    }

    /// Where the side's idle frame goes (top-left), without motion offsets.
    private func spriteOrigin(_ side: PvPSide, _ idle: SpriteCache.Idle, _ frame: RGBABuffer,
                              _ L: Layout) -> (x: Int, y: Int) {
        let base = side == mySide ? L.myBase : L.foeBase
        let scale = spriteScale(side)
        // Feet (lowest opaque row) rest slightly below the platform's center line.
        return (base.x - frame.width * scale / 2, base.y - idle.footY * scale + px(6))
    }

    /// Effect anchor: the center of the side's sprite cell, in upstream's
    /// y-up world convention (RunningEffect math and Sprite.octant use it).
    private func anchor(_ side: PvPSide) -> CGPoint {
        let L = currentLayout()
        let base = side == mySide ? L.myBase : L.foeBase
        var cy = Double(base.y - px(40))
        if let battle, let s = slots[side], s.index >= 0 {
            let idle = SpriteCache.idle(dex: battle.wire(side, s.index).dex, facing: facing(side))
            if let frame = idle.frames.first {
                let o = spriteOrigin(side, idle, frame, L)
                cy = Double(o.y + frame.height * spriteScale(side) / 2)
            }
        }
        return CGPoint(x: Double(base.x), y: -cy)
    }

    // MARK: - paint

    fileprivate func paint() {
        guard let hwnd else { return }
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }
        var rc = RECT()
        GetClientRect(hwnd, &rc)
        let w = Int(rc.right - rc.left), h = Int(rc.bottom - rc.top)
        guard canvas.ensure(width: w, height: h) else { return }
        drawScene(w: w, h: h)
        canvas.present(to: hdc)
    }

    /// 0...1 while the veil is up (sin-shaped), else nil.
    private func veilStrength() -> Double? {
        guard let v = veil else { return nil }
        let t = (stepElapsed - v.from) / (20 * tickMs)
        guard t >= 0, t < 1 else { return nil }
        return sin(t * Double.pi)
    }

    private func drawScene(w: Int, h: Int) {
        let L = layout(w: w, h: h)
        let logH = h - L.fieldH
        let fieldH = L.fieldH
        // sky + ground
        canvas.gradient(x: 0, y: 0, w: w, h: fieldH * 55 / 100, top: 0xBFE6FF, bottom: 0xEAF7FF)
        canvas.gradient(x: 0, y: fieldH * 55 / 100, w: w, h: fieldH - fieldH * 55 / 100,
                        top: 0xBDE5A1, bottom: 0x8CCB6E)

        let foeSide = mySide.other
        canvas.fillEllipse(cx: L.foeBase.x, cy: L.foeBase.y, rx: px(90), ry: px(20), 0x9AD27F)
        canvas.fillEllipse(cx: L.myBase.x, cy: L.myBase.y, rx: px(110), ry: px(24), 0x9AD27F)

        // Quake during a full-screen move: the two combatants jolt apart.
        var quake = 0
        if let v = veil, veilStrength() != nil {
            let t = (stepElapsed - v.from) / (20 * tickMs)
            let amplitude = Double((v.explosion ? 6 : 3) * spriteScale(foeSide))
            quake = Int(sin(stepElapsed / tickMs * 1.9) * amplitude * (1 - t))
        }
        drawMon(side: foeSide, L: L, towardX: -1, quake: -quake)
        drawMon(side: mySide, L: L, towardX: 1, quake: quake)

        drawInfoBox(side: foeSide, x: px(16), y: px(16), showNumbers: false)
        drawInfoBox(side: mySide, x: w - px(16) - px(250), y: fieldH - px(78), showNumbers: true)

        drawEffects()
        if let v = veil, let s = veilStrength() {
            canvas.tint(x: 0, y: 0, w: w, h: fieldH, v.color, alpha: s * 0.22)
        }

        // log panel (drawn after the effects so big clips never spill into it)
        canvas.fillRect(x: 0, y: fieldH, w: w, h: logH, 0x2B2F3A)
        canvas.fillRect(x: 0, y: fieldH, w: w, h: px(3), 0x4D5568)
        for (i, line) in logLines.enumerated() {
            canvas.text(line, x: px(16), y: fieldH + px(8) + i * px(20), w: w - px(32), h: px(20),
                        font: fontLog, color: i == logLines.count - 1 ? 0xFFFFFF : 0xB8BECC)
        }

        if let banner {
            let bw = px(260), bh = px(64)
            let bx = (w - bw) / 2, by = fieldH / 2 - bh / 2 - px(20)
            canvas.fillRect(x: bx, y: by, w: bw, h: bh, 0x1F2430)
            canvas.fillRect(x: bx, y: by, w: bw, h: px(4),
                            banner.hasPrefix("승리") ? 0xF6C343 : banner.hasPrefix("패배") ? 0x8892A6 : 0x7FB3FF)
            canvas.text(banner, x: bx, y: by + px(4), w: bw, h: bh - px(4), font: fontBanner,
                        color: 0xFFFFFF, align: 1)
        }
    }

    private func drawMon(side: PvPSide, L: Layout, towardX: Int, quake: Int) {
        guard let battle, let s = slots[side], s.index >= 0, !s.fainted else { return }
        let idle = SpriteCache.idle(dex: battle.wire(side, s.index).dex, facing: facing(side))
        guard !idle.frames.isEmpty else { return }
        let frame = idle.frames[Int(animClock / 140) % idle.frames.count]
        let scale = spriteScale(side)
        var ox = quake, oy = 0
        if let m = motion, m.side == side, stepElapsed >= m.from, stepElapsed < m.until {
            let f = stepElapsed < m.peak
                ? sin((stepElapsed - m.from) / max(1, m.peak - m.from) * Double.pi / 2)
                : cos((stepElapsed - m.peak) / max(1, m.until - m.peak) * Double.pi / 2)
            let amt = f * m.reach
            ox += Int(amt) * towardX
            oy -= Int(amt * 0.4) * towardX
        }
        if let sh = shake, sh.side == side, stepElapsed >= sh.from, stepElapsed < sh.until {
            ox += (Int(stepElapsed / 40) % 2 == 0) ? px(5) : -px(5)
        }
        let o = spriteOrigin(side, idle, frame, L)
        canvas.blit(frame, x: o.x + ox, y: o.y + oy, scale: scale, alpha: s.fadeIn)
    }

    /// The scheduled clip playing right now (at most one), centered on its
    /// RunningEffect position.
    private func drawEffects() {
        for var fx in effects where stepElapsed >= fx.start && stepElapsed < fx.start + fx.length {
            fx.run.tick = Int((stepElapsed - fx.start) / tickMs)
            guard let current = fx.run.current(scale: CGFloat(fx.scale)) else { continue }
            let (image, pos) = current
            let img = image.buffer
            canvas.blit(img, x: Int(pos.x.rounded()) - img.width * fx.scale / 2,
                        y: Int((-pos.y).rounded()) - img.height * fx.scale / 2, scale: fx.scale)
        }
    }

    private func drawInfoBox(side: PvPSide, x: Int, y: Int, showNumbers: Bool) {
        guard let battle, let s = slots[side], s.index >= 0 else { return }
        let wire = battle.wire(side, s.index)
        let bw = px(250), bh = showNumbers ? px(66) : px(54)
        canvas.fillRect(x: x + px(3), y: y + px(3), w: bw, h: bh, 0x5A6B4A)   // shadow
        canvas.fillRect(x: x, y: y, w: bw, h: bh, 0xF8F8F0)
        canvas.fillRect(x: x, y: y, w: px(4), h: bh, side == mySide ? 0x4C8DF6 : 0xE5534B)

        canvas.text(wire.displayName, x: x + px(12), y: y + px(4), w: bw - px(80), h: px(22),
                    font: fontName, color: 0x222222)
        canvas.text("Lv.\(wire.level)", x: x + bw - px(70), y: y + px(4), w: px(60), h: px(22),
                    font: fontSmall, color: 0x444444, align: 2)

        // HP bar
        let barX = x + px(40), barY = y + px(30), barW = bw - px(52), barH = px(8)
        canvas.text("HP", x: x + px(12), y: barY - px(5), w: px(26), h: px(18), font: fontSmall, color: 0xE59A2E)
        canvas.fillRect(x: barX - 1, y: barY - 1, w: barW + 2, h: barH + 2, 0x3A3A3A)
        canvas.fillRect(x: barX, y: barY, w: barW, h: barH, 0x5C5C5C)
        let frac = max(0, min(1, s.shownHP / Double(max(1, s.maxHP))))
        let color: UInt32 = frac > 0.5 ? 0x4CD964 : frac > 0.2 ? 0xF5C542 : 0xF0533F
        canvas.fillRect(x: barX, y: barY, w: Int(Double(barW) * frac), h: barH, color)

        if showNumbers {
            canvas.text("\(Int(s.shownHP.rounded()))/\(s.maxHP)", x: barX, y: barY + px(10),
                        w: barW, h: px(18), font: fontSmall, color: 0x333333, align: 2)
        }
        if s.asleep {
            canvas.text("잠듦", x: x + bw - px(118), y: y + px(4), w: px(44), h: px(22),
                        font: fontSmall, color: 0x7A6FD0, align: 2)
        }
        // party balls
        let count = battle.parties[side]?.count ?? 0
        for i in 0..<count {
            let cx = x + px(14) + i * px(14)
            let cy = y + bh - px(9)
            let fainted = down[side]?.contains(i) ?? false
            canvas.fillEllipse(cx: cx, cy: cy, rx: px(4), ry: px(4), fainted ? 0x9A9A9A : 0xE5534B)
        }
    }
}
