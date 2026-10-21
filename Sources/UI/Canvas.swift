// Software canvas over a GDI DIB section (double buffer for the battle view)
// and the idle-sprite cache, both fed by upstream's sprite loader.

import WinSDK
import Foundation

/// Off-screen 32-bit BGRA surface. Pixels are written directly; GDI text is
/// drawn on `dc` afterwards; `present` blits it to the window.
final class Canvas {
    private(set) var dc: HDC?
    private var dib: HBITMAP?
    private var oldBitmap: HGDIOBJ?
    private(set) var bits: UnsafeMutablePointer<UInt32>?
    private(set) var width = 0
    private(set) var height = 0

    deinit { release() }

    func ensure(width w: Int, height h: Int) -> Bool {
        if bits != nil, w == width, h == height { return true }
        release()
        guard w > 0, h > 0 else { return false }
        let screen = GetDC(nil)
        dc = CreateCompatibleDC(screen)
        ReleaseDC(nil, screen)
        var bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bmi.bmiHeader.biWidth = Int32(w)
        bmi.bmiHeader.biHeight = -Int32(h)          // top-down
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = DWORD(BI_RGB)
        var raw: UnsafeMutableRawPointer? = nil
        dib = CreateDIBSection(dc, &bmi, UINT(DIB_RGB_COLORS), &raw, nil, 0)
        guard let dib, let raw else { release(); return false }
        oldBitmap = SelectObject(dc, dib)
        bits = raw.assumingMemoryBound(to: UInt32.self)
        width = w; height = h
        return true
    }

    private func release() {
        if let dc, let oldBitmap { SelectObject(dc, oldBitmap) }
        if let dib { DeleteObject(dib) }
        if let dc { DeleteDC(dc) }
        dc = nil; dib = nil; oldBitmap = nil; bits = nil
        width = 0; height = 0
    }

    func present(to target: HDC?) {
        guard let dc else { return }
        _ = BitBlt(target, 0, 0, Int32(width), Int32(height), dc, 0, 0, DWORD(0x00CC_0020))   // SRCCOPY
    }

    // MARK: pixel ops (colors are 0xRRGGBB)

    @inline(__always) private func bgra(_ rgb: UInt32) -> UInt32 { 0xFF00_0000 | rgb }

    func fill(_ rgb: UInt32) {
        guard let bits else { return }
        let v = bgra(rgb)
        for i in 0..<(width * height) { bits[i] = v }
    }

    func fillRect(x: Int, y: Int, w: Int, h: Int, _ rgb: UInt32) {
        guard let bits else { return }
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return }
        let v = bgra(rgb)
        for yy in y0..<y1 {
            let row = bits + yy * width
            for xx in x0..<x1 { row[xx] = v }
        }
    }

    /// Vertical gradient between two colors.
    func gradient(x: Int, y: Int, w: Int, h: Int, top: UInt32, bottom: UInt32) {
        guard h > 0 else { return }
        for i in 0..<h {
            let t = Double(i) / Double(max(1, h - 1))
            fillRect(x: x, y: y + i, w: w, h: 1, mix(top, bottom, t))
        }
    }

    func fillEllipse(cx: Int, cy: Int, rx: Int, ry: Int, _ rgb: UInt32) {
        guard rx > 0, ry > 0 else { return }
        for dy in -ry...ry {
            let f = 1.0 - Double(dy * dy) / Double(ry * ry)
            guard f >= 0 else { continue }
            let half = Int((Double(rx) * f.squareRoot()).rounded())
            fillRect(x: cx - half, y: cy + dy, w: half * 2 + 1, h: 1, rgb)
        }
    }

    /// Premultiplied-RGBA sprite, nearest-neighbor scaled, src-over.
    /// (x, y) is the destination top-left.
    func blit(_ img: RGBABuffer, x: Int, y: Int, scale: Int, alpha: Double = 1) {
        guard let bits, scale > 0 else { return }
        let dw = img.width * scale, dh = img.height * scale
        let k = UInt32(max(0, min(255, (alpha * 255).rounded())))
        img.pixels.withUnsafeBufferPointer { px in
            for dy in 0..<dh {
                let ty = y + dy
                guard ty >= 0, ty < height else { continue }
                let sy = dy / scale
                let row = bits + ty * width
                for dx in 0..<dw {
                    let tx = x + dx
                    guard tx >= 0, tx < width else { continue }
                    let s = (sy * img.width + dx / scale) * 4
                    var a = UInt32(px[s + 3])
                    guard a > 0 else { continue }
                    var r = UInt32(px[s]), g = UInt32(px[s + 1]), b = UInt32(px[s + 2])
                    if k < 255 { r = r * k / 255; g = g * k / 255; b = b * k / 255; a = a * k / 255 }
                    let d = row[tx]
                    let ia = 255 - a
                    let nr = min(255, r + ((d >> 16) & 0xFF) * ia / 255)
                    let ng = min(255, g + ((d >> 8) & 0xFF) * ia / 255)
                    let nb = min(255, b + (d & 0xFF) * ia / 255)
                    row[tx] = 0xFF00_0000 | (nr << 16) | (ng << 8) | nb
                }
            }
        }
    }

    /// Nearest-neighbor src-over of `img`'s sub-rectangle `src` into a
    /// `dw`×`dh` destination at (x, y); scales up or down by any factor.
    func blit(_ img: RGBABuffer, src: (x: Int, y: Int, w: Int, h: Int),
              x: Int, y: Int, w dw: Int, h dh: Int) {
        guard let bits, src.w > 0, src.h > 0, dw > 0, dh > 0 else { return }
        img.pixels.withUnsafeBufferPointer { px in
            for dy in 0..<dh {
                let ty = y + dy
                guard ty >= 0, ty < height else { continue }
                let sy = src.y + dy * src.h / dh
                guard sy >= 0, sy < img.height else { continue }
                let row = bits + ty * width
                for dx in 0..<dw {
                    let tx = x + dx
                    guard tx >= 0, tx < width else { continue }
                    let sx = src.x + dx * src.w / dw
                    guard sx >= 0, sx < img.width else { continue }
                    let s = (sy * img.width + sx) * 4
                    let a = UInt32(px[s + 3])
                    guard a > 0 else { continue }
                    let d = row[tx]
                    let ia = 255 - a
                    let nr = min(255, UInt32(px[s]) + ((d >> 16) & 0xFF) * ia / 255)
                    let ng = min(255, UInt32(px[s + 1]) + ((d >> 8) & 0xFF) * ia / 255)
                    let nb = min(255, UInt32(px[s + 2]) + (d & 0xFF) * ia / 255)
                    row[tx] = 0xFF00_0000 | (nr << 16) | (ng << 8) | nb
                }
            }
        }
    }

    /// Blend a flat color over a rectangle (screen-flash veil).
    func tint(x: Int, y: Int, w: Int, h: Int, _ rgb: UInt32, alpha: Double) {
        guard let bits, alpha > 0 else { return }
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return }
        let a = UInt32(max(0, min(255, (alpha * 255).rounded()))), ia = 255 - a
        let r = ((rgb >> 16) & 0xFF) * a, g = ((rgb >> 8) & 0xFF) * a, b = (rgb & 0xFF) * a
        for yy in y0..<y1 {
            let row = bits + yy * width
            for xx in x0..<x1 {
                let d = row[xx]
                let nr = (r + ((d >> 16) & 0xFF) * ia) / 255
                let ng = (g + ((d >> 8) & 0xFF) * ia) / 255
                let nb = (b + (d & 0xFF) * ia) / 255
                row[xx] = 0xFF00_0000 | (nr << 16) | (ng << 8) | nb
            }
        }
    }

    /// 1-px rectangle outline.
    func strokeRect(x: Int, y: Int, w: Int, h: Int, _ rgb: UInt32) {
        fillRect(x: x, y: y, w: w, h: 1, rgb)
        fillRect(x: x, y: y + h - 1, w: w, h: 1, rgb)
        fillRect(x: x, y: y, w: 1, h: h, rgb)
        fillRect(x: x + w - 1, y: y, w: 1, h: h, rgb)
    }

    // MARK: GDI text on the canvas

    /// Draw text into a rect. `align`: 0 left, 1 center, 2 right.
    func text(_ s: String, x: Int, y: Int, w: Int, h: Int, font: HFONT?, color: UInt32,
              align: Int = 0, wrap: Bool = false) {
        guard let dc else { return }
        if let font { SelectObject(dc, font) }
        SetBkMode(dc, TRANSPARENT)
        // COLORREF is 0x00BBGGRR
        let ref = ((color & 0xFF) << 16) | (color & 0xFF00) | ((color >> 16) & 0xFF)
        SetTextColor(dc, COLORREF(ref))
        var rc = RECT(left: Int32(x), top: Int32(y), right: Int32(x + w), bottom: Int32(y + h))
        var flags = UINT(DT_NOPREFIX)
        flags |= align == 1 ? UINT(DT_CENTER) : align == 2 ? UINT(DT_RIGHT) : UINT(DT_LEFT)
        flags |= wrap ? UINT(DT_WORDBREAK) : UINT(DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS)
        let units = Array(s.utf16)
        units.withUnsafeBufferPointer {
            _ = DrawTextW(dc, $0.baseAddress, Int32(units.count), &rc, flags)
        }
    }
}

func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
    func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
    func lerp(_ s: UInt32) -> UInt32 {
        UInt32((ch(a, s) + (ch(b, s) - ch(a, s)) * t).rounded()) << s
    }
    return lerp(16) | lerp(8) | lerp(0)
}

// MARK: - Sprites

/// Idle animation frames per species and facing, loaded once through
/// upstream's Sprite helpers from characters/<id>/ next to the exe.
enum SpriteCache {
    /// PMD sheet rows: 0 S, 1 SE, 2 E, 3 NE, 4 N, 5 NW, 6 W, 7 SW.
    enum Facing: Int { case down = 0, upRight = 3, downLeft = 7 }

    struct Idle {
        let frames: [RGBABuffer]
        /// Lowest opaque row (exclusive) across all frames: where the feet
        /// are. Cells carry species-specific padding below the body, so
        /// anchoring the cell bottom would leave sprites floating.
        let footY: Int
    }

    private static var cache: [String: Idle] = [:]

    static func idle(dex: Int, facing: Facing) -> Idle {
        let key = "\(dex)|\(facing.rawValue)"
        if let hit = cache[key] { return hit }
        let subdir = "characters/\(Characters.folder(dex: dex))"
        let xml = Sprite.loadText("AnimData", ext: "xml", subdir: subdir)
        let rows = Sprite.slicedSheetBuffers("Idle-Anim", anim: "Idle", subdir: subdir, xml: xml)
        var frames: [RGBABuffer] = []
        if !rows.isEmpty {
            frames = rows[min(facing.rawValue, rows.count - 1)]
        }
        let foot = frames.compactMap { Sprite.opaqueBBox($0).map { Int($0.maxY) } }.max()
            ?? frames.first?.height ?? 0
        let idle = Idle(frames: frames, footY: foot)
        cache[key] = idle
        return idle
    }
}
