// Connection lifecycle + typed sends. Every callback is delivered on the UI
// thread (through MainThread.post), so the app controller never sees the
// socket's reader thread.

import Foundation

final class LobbyClient {
    enum State { case disconnected, connecting, connected }

    private(set) var state: State = .disconnected
    private var socket: LineSocket?
    private var generation = 0      // drops callbacks from a superseded socket
    // Keep-alive pings are driven by the main window's Win32 timer:
    // Foundation timers never fire under the hand-rolled Win32 message loop.

    var onMessage: ((ServerMessage) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?

    func connect(host: String, port: UInt16, hello: HelloMsg) {
        disconnect()
        generation += 1
        let gen = generation
        let sock = LineSocket()
        socket = sock
        state = .connecting
        sock.onLine = { [weak self] line in
            guard let msg = ServerMessage.decode(line) else { return }
            MainThread.post {
                guard let self, self.generation == gen else { return }
                self.onMessage?(msg)
            }
        }
        sock.onClose = { [weak self] reason in
            MainThread.post {
                guard let self, self.generation == gen else { return }
                self.state = .disconnected
                self.socket = nil
                self.onDisconnected?(reason)
            }
        }
        let helloLine = encodeLine(hello)
        Thread.detachNewThread { [weak self] in
            do {
                try sock.connect(host: host, port: port)
            } catch {
                MainThread.post {
                    guard let self, self.generation == gen else { return }
                    self.state = .disconnected
                    self.socket = nil
                    self.onDisconnected?("\(error)")
                }
                return
            }
            if let helloLine { sock.send(line: helloLine) }
            MainThread.post {
                guard let self, self.generation == gen else { return }
                self.state = .connected
                self.onConnected?()
            }
            sock.runReadLoop()
        }
    }

    func disconnect() {
        generation += 1
        socket?.close()
        socket = nil
        if state != .disconnected {
            state = .disconnected
        }
    }

    // MARK: - typed sends

    func sendParty(_ party: [WireMon]) { send(PartyMsg(party: party)) }
    func challenge(_ userId: String) { send(ChallengeMsg(to: userId)) }
    func cancelChallenge() { send(CancelChallengeMsg()) }
    func respond(to userId: String, accept: Bool) { send(RespondMsg(from: userId, accept: accept)) }
    func battleDone(id: String, winner: PvPSide?, digest: String) {
        send(BattleDoneMsg(battleId: id, winner: winner?.rawValue ?? "draw", digest: digest))
    }
    func ping() { send(PingMsg()) }

    private func send<T: Encodable>(_ msg: T) {
        guard state == .connected || state == .connecting, let line = encodeLine(msg) else { return }
        socket?.send(line: line)
    }
}
