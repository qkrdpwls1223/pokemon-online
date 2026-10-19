// Minimal blocking TCP client over Winsock with newline framing.
//
// connect() and the read loop run on a background thread; callbacks fire on
// that thread, so the owner must hop to the UI thread itself (LobbyClient
// does, via PostMessageW). send() is safe from any thread.

import WinSDK
import Foundation

// File-scope shims: inside LineSocket the names connect/send would resolve to
// its own methods, so the Winsock calls go through these.
private func wsConnect(_ s: SOCKET, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: Int32) -> Int32 {
    connect(s, addr, len)
}
private func wsSend(_ s: SOCKET, _ buf: UnsafePointer<CChar>?, _ len: Int32) -> Int32 {
    send(s, buf, len, 0)
}

final class LineSocket {
    enum ConnectError: Error, CustomStringConvertible {
        case winsock
        case resolve(String)
        case connect(String)

        var description: String {
            switch self {
            case .winsock: return "네트워크 초기화(WSAStartup)에 실패했습니다."
            case .resolve(let h): return "서버 주소를 찾을 수 없습니다: \(h)"
            case .connect(let h): return "서버에 연결할 수 없습니다: \(h)"
            }
        }
    }

    private static let invalid = SOCKET.max            // INVALID_SOCKET
    private static let started: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()

    private var sock: SOCKET = LineSocket.invalid
    private let sendLock = NSLock()
    private var closed = false

    /// One complete line (without the newline), on the reader thread.
    var onLine: ((String) -> Void)?
    /// Connection ended (nil = closed by us), on the reader thread.
    var onClose: ((String?) -> Void)?

    /// Blocking: resolve + connect. Call from a background thread.
    func connect(host: String, port: UInt16) throws {
        guard LineSocket.started else { throw ConnectError.winsock }
        var hints = ADDRINFOW()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = 6   // IPPROTO_TCP
        var result: UnsafeMutablePointer<ADDRINFOW>? = nil
        let hostW = Array(host.utf16) + [0]
        let portW = Array(String(port).utf16) + [0]
        let rc = hostW.withUnsafeBufferPointer { h in
            portW.withUnsafeBufferPointer { p in
                GetAddrInfoW(h.baseAddress, p.baseAddress, &hints, &result)
            }
        }
        guard rc == 0, let first = result else { throw ConnectError.resolve(host) }
        defer { FreeAddrInfoW(first) }

        var cursor: UnsafeMutablePointer<ADDRINFOW>? = first
        while let ai = cursor {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s != LineSocket.invalid {
                if wsConnect(s, ai.pointee.ai_addr, Int32(ai.pointee.ai_addrlen)) == 0 {
                    sock = s
                    return
                }
                closesocket(s)
            }
            cursor = ai.pointee.ai_next
        }
        throw ConnectError.connect("\(host):\(port)")
    }

    /// Blocking read loop until the peer closes or close() is called.
    func runReadLoop() {
        var pending = [UInt8]()
        var buf = [CChar](repeating: 0, count: 8192)
        var reason: String? = nil
        while true {
            let n = buf.withUnsafeMutableBufferPointer { recv(sock, $0.baseAddress, Int32($0.count), 0) }
            if n <= 0 {
                if !closed { reason = n == 0 ? "서버가 연결을 끊었습니다." : "연결이 끊어졌습니다." }
                break
            }
            for i in 0..<Int(n) { pending.append(UInt8(bitPattern: buf[i])) }
            while let nl = pending.firstIndex(of: 0x0A) {
                var lineBytes = Array(pending[..<nl])
                pending.removeSubrange(...nl)
                if lineBytes.last == 0x0D { lineBytes.removeLast() }
                if !lineBytes.isEmpty { onLine?(String(decoding: lineBytes, as: UTF8.self)) }
            }
            if pending.count > 1 << 20 { reason = "서버 메시지가 너무 깁니다."; break }   // 1 MiB guard
        }
        close()
        onClose?(reason)
    }

    @discardableResult
    func send(line: String) -> Bool {
        sendLock.lock(); defer { sendLock.unlock() }
        guard sock != LineSocket.invalid, !closed else { return false }
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { p -> Int32 in
                p.baseAddress!.advanced(by: offset).withMemoryRebound(to: CChar.self, capacity: bytes.count - offset) {
                    wsSend(sock, $0, Int32(bytes.count - offset))
                }
            }
            if n <= 0 { return false }
            offset += Int(n)
        }
        return true
    }

    func close() {
        sendLock.lock(); defer { sendLock.unlock() }
        guard !closed else { return }
        closed = true
        if sock != LineSocket.invalid {
            _ = shutdown(sock, 2)   // SD_BOTH: unblocks a pending recv
            closesocket(sock)
            sock = LineSocket.invalid
        }
    }
}
