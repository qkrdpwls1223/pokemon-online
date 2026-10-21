// Lobby opponent panel: the trainer picked in the list, with their party
// drawn as idle sprites (the same sprite data the battle view uses), levels
// and moves. A slow timer only advances the idle frames.

import WinSDK
import Foundation

private let partyPreviewClass = w16("PMFPartyPreview")
private var partyPreviewRegistered = false

private func partyPreviewProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let view = PartyPreview.instance, view.hwnd == hwnd else {
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
    switch msg {
    case WM.paint:
        view.paint()
        return 0
    case WM.eraseBkgnd:
        return 1
    case WM.timer:
        InvalidateRect(hwnd, nil, false)
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

final class PartyPreview {
    static weak var instance: PartyPreview?

    private(set) var hwnd: HWND?
    private let k: Double
    private let canvas = Canvas()
    private var fontName: HFONT?
    private var fontSmall: HFONT?
    private var fontHint: HFONT?

    private var user: LobbyUser?

    /// Idle frames plus their union opaque box: cropping to it drops the
    /// cell padding, and one box for all frames keeps the body from jittering.
    private struct Thumb {
        let frames: [RGBABuffer]
        let box: (x: Int, y: Int, w: Int, h: Int)
    }
    private var thumbs: [Int: Thumb] = [:]

    init(parent: HWND?, k: Double, x: Int32, y: Int32, w: Int32, h: Int32) {
        self.k = k
        if !partyPreviewRegistered {
            var wc = WNDCLASSW()
            wc.lpfnWndProc = { partyPreviewProc($0, $1, $2, $3) }
            wc.hInstance = GetModuleHandleW(nil)
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            partyPreviewClass.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
            RegisterClassW(&wc)
            partyPreviewRegistered = true
        }
        hwnd = partyPreviewClass.withUnsafeBufferPointer { cls in
            CreateWindowExW(0, cls.baseAddress, nil, DWORD(WS_CHILD | WS_VISIBLE),
                            x, y, w, h, parent, nil, GetModuleHandleW(nil), nil)
        }
        fontName = makeFont(13, weight: 700, k: k)
        fontSmall = makeFont(11, k: k)
        fontHint = makeFont(12, k: k)
        PartyPreview.instance = self
    }

    deinit {
        for f in [fontName, fontSmall, fontHint] { if let f { DeleteObject(f) } }
    }

    private func px(_ v: Double) -> Int { Int((v * k).rounded()) }

    /// Show this trainer's party, or the "pick someone" hint for nil.
    func show(_ user: LobbyUser?) {
        self.user = user
        if user == nil { KillTimer(hwnd, 1) } else { SetTimer(hwnd, 1, 70, nil) }
        InvalidateRect(hwnd, nil, false)
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
        draw(w: w, h: h)
        canvas.present(to: hdc)
    }

    private func draw(w: Int, h: Int) {
        canvas.fill(0xFAFBFD)
        canvas.strokeRect(x: 0, y: 0, w: w, h: h, 0xC9CED8)
        guard let user else {
            canvas.text("목록에서 트레이너를 고르면\n상대 파티를 여기서 볼 수 있어요.",
                        x: px(16), y: h / 2 - px(20), w: w - px(32), h: px(44),
                        font: fontHint, color: 0x8A93A5, align: 1, wrap: true)
            return
        }

        let headH = px(40)
        canvas.fillRect(x: 1, y: 1, w: w - 2, h: headH - 1, 0xEEF1F6)
        canvas.fillRect(x: 1, y: headH, w: w - 2, h: 1, 0xD5DAE3)
        let status = statusLabel(user)
        canvas.text(user.name, x: px(12), y: 1, w: w - px(136), h: headH - 1, font: fontName, color: 0x222222)
        canvas.text(status.text, x: w - px(124), y: 1, w: px(112), h: headH - 1,
                    font: fontSmall, color: status.color, align: 2)

        // Servers before 0.3 only send the lead.
        let mons = user.party ?? user.lead.map { [LobbyMon(dex: $0.dex, level: $0.level, moves: [])] } ?? []
        let rowH = px(58)
        let top = headH + px(4)
        let frame = Int(GetTickCount64() / 140)
        for (i, m) in mons.prefix(6).enumerated() {
            let y = top + i * rowH
            if i > 0 { canvas.fillRect(x: px(10), y: y, w: w - px(20), h: 1, 0xE6E9EF) }
            drawThumb(dex: m.dex, x: px(8), y: y + px(3), size: px(52), frame: frame)
            let tx = px(68)
            canvas.text((i == 0 ? "★ " : "") + Characters.displayName(dex: m.dex),
                        x: tx, y: y + px(4), w: w - tx - px(66), h: px(20), font: fontName, color: 0x222222)
            canvas.text("Lv.\(m.level)", x: w - px(62), y: y + px(4), w: px(52), h: px(20),
                        font: fontSmall, color: 0x555555, align: 2)
            let moves = m.moves.compactMap { GameData.moves[$0]?.displayName }.joined(separator: ", ")
            canvas.text(moves, x: tx, y: y + px(24), w: w - tx - px(10), h: px(30),
                        font: fontSmall, color: 0x5A6275, wrap: true)
        }
        if user.party == nil, user.partySize > mons.count {
            canvas.text("외 \(user.partySize - mons.count)마리 (서버를 업데이트하면 모두 보여요)",
                        x: px(12), y: top + mons.count * rowH + px(6), w: w - px(24), h: px(20),
                        font: fontSmall, color: 0x8A93A5)
        }
    }

    private func statusLabel(_ u: LobbyUser) -> (text: String, color: UInt32) {
        if !u.compatible { return ("버전 다름", 0x8A93A5) }
        switch u.status {
        case "battling": return ("대전 중", 0xE5534B)
        case "challenging": return ("신청 처리 중", 0xE59A2E)
        default: return (u.bot == true ? "연습 봇 · 대전 가능" : "대전 가능", 0x2E9D57)
        }
    }

    /// Idle sprite fitted into a `size` square, feet on the bottom edge.
    /// Upscaling stops at 2× (DPI-adjusted) so tiny species stay pixel art.
    private func drawThumb(dex: Int, x: Int, y: Int, size: Int, frame: Int) {
        canvas.fillEllipse(cx: x + size / 2, cy: y + size - px(3), rx: size * 2 / 5, ry: px(5), 0xE3E8F0)
        let t = thumb(dex)
        guard !t.frames.isEmpty else { return }
        let b = t.box
        let s = min(Double(size) / Double(b.w), Double(size) / Double(b.h), 2 * k)
        let dw = max(1, Int(Double(b.w) * s)), dh = max(1, Int(Double(b.h) * s))
        canvas.blit(t.frames[frame % t.frames.count], src: b,
                    x: x + (size - dw) / 2, y: y + size - dh, w: dw, h: dh)
    }

    private func thumb(_ dex: Int) -> Thumb {
        if let hit = thumbs[dex] { return hit }
        let frames = SpriteCache.idle(dex: dex, facing: .down).frames
        let boxes = frames.compactMap { Sprite.opaqueBBox($0) }
        var t = Thumb(frames: [], box: (0, 0, 0, 0))
        if let x0 = boxes.map({ Int($0.minX) }).min(), let y0 = boxes.map({ Int($0.minY) }).min(),
           let x1 = boxes.map({ Int($0.maxX) }).max(), let y1 = boxes.map({ Int($0.maxY) }).max(),
           x1 > x0, y1 > y0 {
            t = Thumb(frames: frames, box: (x0, y0, x1 - x0, y1 - y0))
        }
        thumbs[dex] = t
        return t
    }
}
