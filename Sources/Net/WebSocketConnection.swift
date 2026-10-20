// WebSocket client over WinHTTP (wss:// and ws://).
//
// WinHTTP ships with Windows, handles TLS through the system certificate
// store and honors the system proxy settings. The Swift WinSDK module has
// no WinHTTP submodule, so the few functions needed are bound from
// winhttp.dll at run time — the same approach upstream uses for GDI+.
//
// connect() and runReceiveLoop() block: run them on a background thread.
// Callbacks fire on that thread. send() and close() are safe from any thread.

import WinSDK
import Foundation

// MARK: - server address

/// "https://10.10.33.36:7777" (or wss://, http://, ws://, or bare host:port,
/// which means https). The WebSocket endpoint is /ws unless a path is given.
struct ServerAddress {
    let secure: Bool
    let host: String
    let port: UInt16
    let path: String

    init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(),
              let host = c.host, !host.isEmpty else { return nil }
        switch scheme {
        case "https", "wss": secure = true
        case "http", "ws": secure = false
        default: return nil
        }
        self.host = host
        if let p = c.port {
            guard let p16 = UInt16(exactly: p), p16 > 0 else { return nil }
            port = p16
        } else {
            port = secure ? 443 : 80
        }
        path = (c.path.isEmpty || c.path == "/") ? "/ws" : c.path
    }

    /// Canonical form shown back to the user.
    var display: String { "\(secure ? "https" : "http")://\(host):\(port)" }
}

// MARK: - winhttp.dll binding

private enum WinHttp {
    typealias Handle = UnsafeMutableRawPointer
    typealias WStr = UnsafePointer<UInt16>

    typealias FnOpen = @convention(c) (WStr?, UInt32, WStr?, WStr?, UInt32) -> Handle?
    typealias FnConnect = @convention(c) (Handle?, WStr?, UInt16, UInt32) -> Handle?
    typealias FnOpenRequest = @convention(c) (Handle?, WStr?, WStr?, WStr?, WStr?,
                                              UnsafeMutablePointer<WStr?>?, UInt32) -> Handle?
    typealias FnSetOption = @convention(c) (Handle?, UInt32, UnsafeMutableRawPointer?, UInt32) -> Int32
    typealias FnSetTimeouts = @convention(c) (Handle?, Int32, Int32, Int32, Int32) -> Int32
    typealias FnSendRequest = @convention(c) (Handle?, WStr?, UInt32, UnsafeMutableRawPointer?,
                                              UInt32, UInt32, UInt) -> Int32
    typealias FnReceiveResponse = @convention(c) (Handle?, UnsafeMutableRawPointer?) -> Int32
    typealias FnQueryHeaders = @convention(c) (Handle?, UInt32, WStr?, UnsafeMutableRawPointer?,
                                               UnsafeMutablePointer<UInt32>?,
                                               UnsafeMutablePointer<UInt32>?) -> Int32
    typealias FnCompleteUpgrade = @convention(c) (Handle?, UInt) -> Handle?
    typealias FnWsSend = @convention(c) (Handle?, Int32, UnsafeMutableRawPointer?, UInt32) -> UInt32
    typealias FnWsReceive = @convention(c) (Handle?, UnsafeMutableRawPointer?, UInt32,
                                            UnsafeMutablePointer<UInt32>?,
                                            UnsafeMutablePointer<Int32>?) -> UInt32
    typealias FnWsShutdown = @convention(c) (Handle?, UInt16, UnsafeMutableRawPointer?, UInt32) -> UInt32
    typealias FnCloseHandle = @convention(c) (Handle?) -> Int32

    static let module: HMODULE? = "winhttp.dll".withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }

    static func proc<T>(_ name: String, _ type: T.Type) -> T? {
        guard let m = module, let p = GetProcAddress(m, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static let open = proc("WinHttpOpen", FnOpen.self)
    static let connect = proc("WinHttpConnect", FnConnect.self)
    static let openRequest = proc("WinHttpOpenRequest", FnOpenRequest.self)
    static let setOption = proc("WinHttpSetOption", FnSetOption.self)
    static let setTimeouts = proc("WinHttpSetTimeouts", FnSetTimeouts.self)
    static let sendRequest = proc("WinHttpSendRequest", FnSendRequest.self)
    static let receiveResponse = proc("WinHttpReceiveResponse", FnReceiveResponse.self)
    static let queryHeaders = proc("WinHttpQueryHeaders", FnQueryHeaders.self)
    static let completeUpgrade = proc("WinHttpWebSocketCompleteUpgrade", FnCompleteUpgrade.self)
    static let wsSend = proc("WinHttpWebSocketSend", FnWsSend.self)
    static let wsReceive = proc("WinHttpWebSocketReceive", FnWsReceive.self)
    static let wsShutdown = proc("WinHttpWebSocketShutdown", FnWsShutdown.self)
    static let closeHandle = proc("WinHttpCloseHandle", FnCloseHandle.self)

    static var available: Bool {
        open != nil && connect != nil && openRequest != nil && setOption != nil && setTimeouts != nil
            && sendRequest != nil && receiveResponse != nil && queryHeaders != nil
            && completeUpgrade != nil && wsSend != nil && wsReceive != nil && wsShutdown != nil
            && closeHandle != nil
    }

    // winhttp.h constants
    static let accessTypeDefaultProxy: UInt32 = 0
    static let accessTypeAutomaticProxy: UInt32 = 4      // Windows 8.1+
    static let flagSecure: UInt32 = 0x0080_0000
    static let optionUpgradeToWebSocket: UInt32 = 114
    static let queryStatusCode: UInt32 = 19
    static let queryFlagNumber: UInt32 = 0x2000_0000
    static let bufferBinaryMessage: Int32 = 0
    static let bufferBinaryFragment: Int32 = 1
    static let bufferUTF8Message: Int32 = 2
    static let bufferUTF8Fragment: Int32 = 3
    static let bufferClose: Int32 = 4
    static let closeNormal: UInt16 = 1000
}

// MARK: - connection

final class WebSocketConnection {
    enum ConnectError: Error, CustomStringConvertible {
        case unavailable
        case winhttp(stage: String, code: UInt32)
        case notUpgraded(status: UInt32)

        var description: String {
            switch self {
            case .unavailable:
                return "WinHTTP를 불러올 수 없습니다."
            case .winhttp(_, let code):
                return WebSocketConnection.describe(code)
            case .notUpgraded(let status):
                return "서버가 대전 서버 연결을 받지 않았습니다 (HTTP \(status)). 주소와 포트를 확인해 주세요."
            }
        }
    }

    private let lock = NSLock()
    private var session: WinHttp.Handle?
    private var connection: WinHttp.Handle?
    private var socket: WinHttp.Handle?
    private var closedByUs = false

    /// One complete text message, on the receive thread.
    var onMessage: ((String) -> Void)?
    /// Connection ended (nil = closed by us), on the receive thread.
    var onClose: ((String?) -> Void)?

    /// Blocking: TCP + TLS + HTTP upgrade. Call from a background thread.
    func connect(to address: ServerAddress) throws {
        guard WinHttp.available, let open = WinHttp.open, let connectFn = WinHttp.connect,
              let openRequest = WinHttp.openRequest, let setOption = WinHttp.setOption,
              let setTimeouts = WinHttp.setTimeouts, let sendRequest = WinHttp.sendRequest,
              let receiveResponse = WinHttp.receiveResponse, let queryHeaders = WinHttp.queryHeaders,
              let completeUpgrade = WinHttp.completeUpgrade, let closeHandle = WinHttp.closeHandle
        else { throw ConnectError.unavailable }

        let agent = w16("pmf-battle/\(ClientInfo.version)")
        var opened = agent.withUnsafeBufferPointer { open($0.baseAddress, WinHttp.accessTypeAutomaticProxy, nil, nil, 0) }
        if opened == nil {   // pre-8.1 fallback
            opened = agent.withUnsafeBufferPointer { open($0.baseAddress, WinHttp.accessTypeDefaultProxy, nil, nil, 0) }
        }
        guard let s = opened else { throw ConnectError.winhttp(stage: "open", code: GetLastError()) }
        // resolve / connect / send bounded; receive unbounded (the lobby can
        // stay quiet; the app pings every 20 s and the server drops idlers).
        _ = setTimeouts(s, 10_000, 10_000, 15_000, 0)
        store(session: s)

        let hostW = w16(address.host)
        guard let c = hostW.withUnsafeBufferPointer({ connectFn(s, $0.baseAddress, address.port, 0) }) else {
            let e = GetLastError(); cleanup(); throw ConnectError.winhttp(stage: "connect", code: e)
        }
        store(connection: c)

        let verb = w16("GET"), path = w16(address.path)
        let requestHandle = verb.withUnsafeBufferPointer { v in
            path.withUnsafeBufferPointer { p in
                openRequest(c, v.baseAddress, p.baseAddress, nil, nil, nil,
                            address.secure ? WinHttp.flagSecure : 0)
            }
        }
        guard let req = requestHandle else { let e = GetLastError(); cleanup(); throw ConnectError.winhttp(stage: "request", code: e) }
        defer { _ = closeHandle(req) }

        guard setOption(req, WinHttp.optionUpgradeToWebSocket, nil, 0) != 0,
              sendRequest(req, nil, 0, nil, 0, 0, 0) != 0,
              receiveResponse(req, nil) != 0 else {
            let e = GetLastError(); cleanup(); throw ConnectError.winhttp(stage: "handshake", code: e)
        }
        var status: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = queryHeaders(req, WinHttp.queryStatusCode | WinHttp.queryFlagNumber, nil, &status, &size, nil)
        guard status == 101 else { cleanup(); throw ConnectError.notUpgraded(status: status) }

        guard let ws = completeUpgrade(req, 0) else {
            let e = GetLastError(); cleanup(); throw ConnectError.winhttp(stage: "upgrade", code: e)
        }
        store(socket: ws)
    }

    /// Blocking receive loop until the server closes or close() is called.
    func runReceiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = [UInt8]()
        var reason: String? = nil
        while true {
            lock.lock()
            let current = socket
            lock.unlock()
            guard let ws = current, let receive = WinHttp.wsReceive else { break }
            var read: UInt32 = 0
            var type: Int32 = 0
            let err = buffer.withUnsafeMutableBytes {
                receive(ws, $0.baseAddress, UInt32($0.count), &read, &type)
            }
            if err != 0 {
                lock.lock(); let byUs = closedByUs; lock.unlock()
                reason = byUs ? nil : WebSocketConnection.describe(err)
                break
            }
            switch type {
            case WinHttp.bufferUTF8Message:
                pending.append(contentsOf: buffer[0..<Int(read)])
                let text = String(decoding: pending, as: UTF8.self)
                pending.removeAll(keepingCapacity: true)
                onMessage?(text)
            case WinHttp.bufferUTF8Fragment:
                pending.append(contentsOf: buffer[0..<Int(read)])
                if pending.count > 1 << 20 { reason = "서버 메시지가 너무 깁니다."; break }
            case WinHttp.bufferClose:
                lock.lock(); let byUs = closedByUs; lock.unlock()
                reason = byUs ? nil : "서버가 연결을 끊었습니다."
            default:
                continue   // binary frames are not part of the protocol
            }
            if reason != nil || type == WinHttp.bufferClose { break }
        }
        cleanup()
        onClose?(reason)
    }

    @discardableResult
    func send(text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let ws = socket, !closedByUs, let wsSend = WinHttp.wsSend else { return false }
        var bytes = Array(text.utf8)
        let err = bytes.withUnsafeMutableBytes {
            wsSend(ws, WinHttp.bufferUTF8Message, $0.baseAddress, UInt32($0.count))
        }
        return err == 0
    }

    /// Polite close (close frame), then release everything. Unblocks the
    /// receive loop, which then reports onClose(nil).
    func close() {
        lock.lock()
        guard !closedByUs else { lock.unlock(); return }
        closedByUs = true
        let ws = socket
        lock.unlock()
        if let ws { _ = WinHttp.wsShutdown?(ws, WinHttp.closeNormal, nil, 0) }
        cleanup()
    }

    // MARK: - handles

    private func store(session s: WinHttp.Handle) { lock.lock(); session = s; lock.unlock() }
    private func store(connection c: WinHttp.Handle) { lock.lock(); connection = c; lock.unlock() }
    private func store(socket ws: WinHttp.Handle) { lock.lock(); socket = ws; lock.unlock() }

    /// Close every handle exactly once (innermost first).
    private func cleanup() {
        lock.lock()
        let handles = [socket, connection, session]
        socket = nil; connection = nil; session = nil
        lock.unlock()
        for h in handles { if let h { _ = WinHttp.closeHandle?(h) } }
    }

    // MARK: - errors

    static func describe(_ code: UInt32) -> String {
        switch code {
        case 12002: return "서버 응답 시간이 초과됐습니다."
        case 12007: return "서버 주소를 찾을 수 없습니다."
        case 12029: return "서버에 연결할 수 없습니다. 주소, 포트, 방화벽을 확인해 주세요."
        case 12030: return "서버와의 연결이 끊어졌습니다."
        case 12017: return "연결이 취소됐습니다."
        case 12037: return "서버 인증서의 유효기간이 지났습니다."
        case 12038: return "서버 인증서의 주소가 접속한 주소와 다릅니다."
        case 12045: return "서버 인증서를 발급한 기관을 이 PC가 신뢰하지 않습니다."
        case 12152: return "서버 응답이 올바르지 않습니다. https/http 주소를 확인해 주세요."
        case 12157: return "보안 연결(TLS)을 만들 수 없습니다."
        case 12175: return "서버 인증서를 확인할 수 없습니다. 이 PC에 서버의 mkcert 루트 인증서가 설치돼 있는지, 인증서에 접속한 주소(IP)가 들어 있는지 확인해 주세요."
        default: return "네트워크 오류가 발생했습니다 (WinHTTP \(code))."
        }
    }
}
