// Battle playback view: replays a precomputed PvP timeline with idle
// sprites, HP bars and upstream's own battle-log wording.
//
// The view never simulates — it only plays PvPStep values. Spectator mode
// hands it the whole timeline at once; manual mode (later) will append steps
// round by round through `append(_:)`.

import WinSDK
import Foundation

private let battleViewClass = w16("PMFBattleView")
private var battleViewRegistered = false

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
    private var lunge: (side: PvPSide, until: Double)?
    private var shake: (side: PvPSide, from: Double, until: Double)?
    private var banner: String?

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
        lunge = nil
        shake = nil
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
        lunge = nil; shake = nil
        for side in [PvPSide.a, .b] {
            if var s = slots[side] { s.shownHP = Double(s.targetHP); s.fadeIn = 1; slots[side] = s }
        }
        InvalidateRect(hwnd, nil, false)
    }

    func stop() {
        KillTimer(hwnd, 1)
        battle = nil
        steps = []
    }

    var isFinished: Bool { finishedFired }

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
        lunge = nil
        shake = nil
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
            let actor: PvPSide = e.actorIsPlayer ? .a : .b
            let target: PvPSide = e.targetIsPlayer ? .a : .b
            let entries = BattleLog.lines(for: e, playerName: label(.a), wildName: label(.b))
            stepDuration = entries.isEmpty ? 350 : 1100
            for entry in entries {
                let at: Double
                switch entry.phase {
                case .start: at = 0
                case .impact: at = stepDuration * 0.35
                case .resolve: at = stepDuration * 0.7
                }
                if at == 0 { pushLog(entry.text) } else { pendingLines.append((at: at, text: entry.text)) }
            }
            if e.kind == .attack || e.kind == .miss {
                lunge = (side: actor, until: stepDuration * 0.35)
            }
            if e.damage > 0, e.kind != .recover {
                shake = (side: target, from: stepDuration * 0.35, until: stepDuration * 0.6)
            }
            if var a = slots[.a] { a.asleep = e.playerAsleep; slots[.a] = a }
            if var b = slots[.b] { b.asleep = e.wildAsleep; slots[.b] = b }
            pendingHP = (at: stepDuration * 0.35, side: target, hp: e.targetHP, fainted: e.fainted)

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

    private func drawScene(w: Int, h: Int) {
        let logH = px(92)
        let fieldH = h - logH
        // sky + ground
        canvas.gradient(x: 0, y: 0, w: w, h: fieldH * 55 / 100, top: 0xBFE6FF, bottom: 0xEAF7FF)
        canvas.gradient(x: 0, y: fieldH * 55 / 100, w: w, h: fieldH - fieldH * 55 / 100,
                        top: 0xBDE5A1, bottom: 0x8CCB6E)

        let foeSide = mySide.other
        let foeBase = (x: w * 72 / 100, y: fieldH * 50 / 100)
        let myBase = (x: w * 27 / 100, y: fieldH * 88 / 100)
        canvas.fillEllipse(cx: foeBase.x, cy: foeBase.y, rx: px(90), ry: px(20), 0x9AD27F)
        canvas.fillEllipse(cx: myBase.x, cy: myBase.y, rx: px(110), ry: px(24), 0x9AD27F)

        drawMon(side: foeSide, base: foeBase, facing: .downLeft, scale: max(2, px(2.6)), towardX: -1)
        drawMon(side: mySide, base: myBase, facing: .upRight, scale: max(2, px(3.2)), towardX: 1)

        drawInfoBox(side: foeSide, x: px(16), y: px(16), showNumbers: false)
        drawInfoBox(side: mySide, x: w - px(16) - px(250), y: fieldH - px(78), showNumbers: true)

        // log panel
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

    private func drawMon(side: PvPSide, base: (x: Int, y: Int), facing: SpriteCache.Facing,
                         scale: Int, towardX: Int) {
        guard let battle, let s = slots[side], s.index >= 0, !s.fainted else { return }
        let idle = SpriteCache.idle(dex: battle.wire(side, s.index).dex, facing: facing)
        guard !idle.frames.isEmpty else { return }
        let frame = idle.frames[Int(animClock / 140) % idle.frames.count]
        var ox = 0, oy = 0
        if let l = lunge, l.side == side, stepElapsed < l.until {
            let t = stepElapsed / l.until
            let amt = sin(t * Double.pi) * Double(px(22))
            ox += Int(amt) * towardX
            oy -= Int(amt * 0.4) * towardX
        }
        if let sh = shake, sh.side == side, stepElapsed >= sh.from, stepElapsed < sh.until {
            ox += (Int(stepElapsed / 40) % 2 == 0) ? px(5) : -px(5)
        }
        let dw = frame.width * scale
        // Feet (lowest opaque row) rest slightly below the platform's center line.
        canvas.blit(frame, x: base.x - dw / 2 + ox, y: base.y - idle.footY * scale + px(6) + oy,
                    scale: scale, alpha: s.fadeIn)
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
