// Small Win32 helpers shared by the windows (constants, strings, fonts,
// child controls) plus the UI-thread hop used by background threads.

import WinSDK
import Foundation

/// NUL-terminated UTF-16 for W-suffixed APIs.
func w16(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }

enum WM {
    static let destroy: UINT = 0x0002
    static let size: UINT = 0x0005
    static let paint: UINT = 0x000F
    static let close: UINT = 0x0010
    static let eraseBkgnd: UINT = 0x0014
    static let setFont: UINT = 0x0030
    static let command: UINT = 0x0111
    static let timer: UINT = 0x0113
    static let ctlColorStatic: UINT = 0x0138
    static let app: UINT = 0x8000
    static let drainMainQueue: UINT = 0x8000 + 1
}

enum LB {
    static let addString: UINT = 0x0180
    static let resetContent: UINT = 0x0184
    static let setCurSel: UINT = 0x0186
    static let getCurSel: UINT = 0x0188
    static let notifySelChange: Int = 1    // LBN_SELCHANGE
    static let notifyDblClk: Int = 2       // LBN_DBLCLK
}

enum EM {
    static let setLimitText: UINT = 0x00C5
}

@inline(__always) func loWord(_ w: WPARAM) -> Int { Int(w & 0xFFFF) }
@inline(__always) func hiWord(_ w: WPARAM) -> Int { Int((w >> 16) & 0xFFFF) }

func makeFont(_ size: Double, weight: Int32 = 400, k: Double, face: String = "Malgun Gothic") -> HFONT? {
    let name = w16(face)
    let height = -Int32((size * k).rounded())
    return name.withUnsafeBufferPointer { buf -> HFONT? in
        CreateFontW(height, 0, 0, 0, weight, 0, 0, 0,
                    DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                    DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                    DWORD(DEFAULT_PITCH), buf.baseAddress)
    }
}

/// Create a standard child control (BUTTON / EDIT / LISTBOX / STATIC ...).
@discardableResult
func makeChild(_ cls: String, _ text: String, parent: HWND?, id: Int32,
               x: Int32, y: Int32, w: Int32, h: Int32,
               style: DWORD = 0, exStyle: DWORD = 0, font: HFONT?) -> HWND? {
    let child = w16(cls).withUnsafeBufferPointer { c in
        w16(text).withUnsafeBufferPointer { t in
            CreateWindowExW(exStyle, c.baseAddress, t.baseAddress,
                            DWORD(WS_CHILD | WS_VISIBLE) | style,
                            x, y, w, h, parent, HMENU(bitPattern: UInt(Int(id))),
                            GetModuleHandleW(nil), nil)
        }
    }
    if let child, let font {
        SendMessageW(child, WM.setFont, WPARAM(UInt(bitPattern: UnsafeRawPointer(font))), 1)
    }
    return child
}

func setText(_ h: HWND?, _ s: String) {
    _ = w16(s).withUnsafeBufferPointer { SetWindowTextW(h, $0.baseAddress) }
}

func getText(_ h: HWND?) -> String {
    let n = GetWindowTextLengthW(h)
    guard n > 0 else { return "" }
    var buf = [WCHAR](repeating: 0, count: Int(n) + 1)
    let got = GetWindowTextW(h, &buf, Int32(buf.count))
    return String(decoding: buf[0..<Int(max(0, got))], as: UTF16.self)
}

func listReset(_ h: HWND?) { SendMessageW(h, LB.resetContent, 0, 0) }

func listAdd(_ h: HWND?, _ s: String) {
    let units = w16(s)
    units.withUnsafeBufferPointer {
        _ = SendMessageW(h, LB.addString, 0, LPARAM(Int(bitPattern: UnsafeRawPointer($0.baseAddress!))))
    }
}

func listSelection(_ h: HWND?) -> Int? {
    let r = Int(SendMessageW(h, LB.getCurSel, 0, 0))
    return r >= 0 ? r : nil
}

func listSelect(_ h: HWND?, _ index: Int?) {
    SendMessageW(h, LB.setCurSel, WPARAM(UInt(bitPattern: index ?? -1)), 0)
}

func show(_ h: HWND?, _ visible: Bool) { ShowWindow(h, visible ? SW_SHOW : SW_HIDE) }

// BOOL parameters import as WindowsBool, which only converts from literals.
func enable(_ h: HWND?, _ on: Bool) {
    if on { EnableWindow(h, true) } else { EnableWindow(h, false) }
}

/// Yes/No question box; true = Yes.
func askYesNo(_ owner: HWND?, _ text: String, title: String) -> Bool {
    let r = w16(text).withUnsafeBufferPointer { t in
        w16(title).withUnsafeBufferPointer { c in
            MessageBoxW(owner, t.baseAddress, c.baseAddress, UINT(MB_YESNO | MB_ICONQUESTION))
        }
    }
    return r == IDYES
}

func alert(_ owner: HWND?, _ text: String, title: String = "포켓몬 대전") {
    _ = w16(text).withUnsafeBufferPointer { t in
        w16(title).withUnsafeBufferPointer { c in
            MessageBoxW(owner, t.baseAddress, c.baseAddress, UINT(MB_OK | MB_ICONINFORMATION))
        }
    }
}

/// Open a URL in the default browser.
func openURL(_ url: String) {
    _ = w16("open").withUnsafeBufferPointer { verb in
        w16(url).withUnsafeBufferPointer { u in
            ShellExecuteW(nil, verb.baseAddress, u.baseAddress, nil, nil, SW_SHOWNORMAL)
        }
    }
}

// MARK: - UI-thread hop

/// Background threads queue closures here; the main window drains the queue
/// when it receives WM.drainMainQueue (posted on every enqueue).
enum MainThread {
    static var hwnd: HWND?
    private static let lock = NSLock()
    private static var queue: [() -> Void] = []

    static func post(_ work: @escaping () -> Void) {
        lock.lock()
        queue.append(work)
        lock.unlock()
        if let hwnd { PostMessageW(hwnd, WM.drainMainQueue, 0, 0) }
    }

    static func drain() {
        lock.lock()
        let work = queue
        queue.removeAll()
        lock.unlock()
        for w in work { w() }
    }
}
