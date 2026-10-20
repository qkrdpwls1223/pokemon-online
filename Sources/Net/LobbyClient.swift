// Connection lifecycle + typed sends. Every callback is delivered on the UI
// thread (through MainThread.post), so the app controller never sees the
// WebSocket's receive thread.

import Foundation

final class LobbyClient {
    enum State { case disconnected, connecting, connected }

    private(set) var state: State = .disconnected
    private var socket: WebSocketConnection?
    private var generation = 0      // drops callbacks from a superseded connection
    // Keep-alive pings are driven by the main window's Win32 timer:
    // Foundation timers never fire under the hand-rolled Win32 message loop.

    var onMessage: ((ServerMessage) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?

    func connect(to address: ServerAddress, hello: HelloMsg) {
        disconnect()
        generation += 1
        let gen = generation
        let sock = WebSocketConnection()
        socket = sock
        state = .connecting
        sock.onMessage = { [weak self] text in
            guard let msg = ServerMessage.decode(text) else { return }
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
        let helloText = encodeJSON(hello)
        Thread.detachNewThread { [weak self] in
            do {
                try sock.connect(to: address)
            } catch {
                MainThread.post {
                    guard let self, self.generation == gen else { return }
                    self.state = .disconnected
                    self.socket = nil
                    self.onDisconnected?("\(error)")
                }
                return
            }
            if let helloText { sock.send(text: helloText) }
            MainThread.post {
                guard let self, self.generation == gen else { return }
                self.state = .connected
                self.onConnected?()
            }
            sock.runReceiveLoop()
        }
    }

    func disconnect() {
        generation += 1
        socket?.close()
        socket = nil
        state = .disconnected
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
        guard state == .connected || state == .connecting, let text = encodeJSON(msg) else { return }
        socket?.send(text: text)
    }
}
