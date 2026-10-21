// Main window + app controller: lobby (connect, trainer list, challenges,
// my party) and battle mode (BattleView + playback controls).

import WinSDK
import Foundation

private let mainClass = w16("PMFBattleMain")

private enum ID {
    static let url: Int32 = 101
    static let password: Int32 = 102
    static let name: Int32 = 103
    static let connect: Int32 = 104
    static let users: Int32 = 110
    static let challenge: Int32 = 111
    static let cancel: Int32 = 112
    static let reload: Int32 = 120
    static let fast: Int32 = 130
    static let skip: Int32 = 131
    static let back: Int32 = 132
}

private enum TimerID {
    static let ping: UINT_PTR = 7
}

private func mainProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let app = AppWindow.shared, app.hwnd == hwnd else {
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
    switch msg {
    case WM.command:
        app.command(id: Int32(loWord(wParam)), code: hiWord(wParam))
        return 0
    case WM.drainMainQueue:
        MainThread.drain()
        return 0
    case WM.timer:
        if UINT_PTR(wParam) == TimerID.ping { app.client.ping() }
        return 0
    case WM.ctlColorStatic:
        // Static labels on the window background instead of dialog gray.
        let hdc = HDC(bitPattern: UInt(wParam))
        SetBkColor(hdc, GetSysColor(COLOR_WINDOW))
        return LRESULT(Int(bitPattern: GetSysColorBrush(COLOR_WINDOW)))
    case WM.close:
        DestroyWindow(hwnd)
        return 0
    case WM.destroy:
        app.client.disconnect()
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

final class AppWindow {
    static var shared: AppWindow?

    private(set) var hwnd: HWND?
    let client = LobbyClient()
    private var k: Double = 1
    private var font: HFONT?
    private var fontBold: HFONT?
    private var fontSmall: HFONT?
    private var config = ClientConfig.load()

    // lobby controls
    private var lobbyControls: [HWND?] = []
    private var urlEdit: HWND?
    private var passwordEdit: HWND?
    private var nameEdit: HWND?
    private var connectButton: HWND?
    private var statusLabel: HWND?
    private var usersList: HWND?
    private var challengeButton: HWND?
    private var cancelButton: HWND?
    private var partyLabel: HWND?
    private var preview: PartyPreview?
    // battle controls
    private var battleView: BattleView?
    private var battleControls: [HWND?] = []
    private var fastButton: HWND?
    private var backButton: HWND?

    // state
    private var party: [WireMon] = []
    private var myId: String?
    private var users: [LobbyUser] = []
    private var outgoing: (id: String, name: String)?
    private var promptOpen = false
    private var updateOffered = false
    /// Why the server is about to close us (wrong password, old client...),
    /// shown instead of the generic "disconnected" line.
    private var rejection: String?
    private var fast = false
    private struct Running {
        let battleId: String
        let battle: PvPBattle
        let mySide: PvPSide
        var reported = false
    }
    private var running: Running?

    init() {
        AppWindow.shared = self
        var wc = WNDCLASSW()
        wc.lpfnWndProc = { mainProc($0, $1, $2, $3) }
        wc.hInstance = GetModuleHandleW(nil)
        wc.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        wc.hIcon = LoadIconW(GetModuleHandleW(nil), UnsafePointer<WCHAR>(bitPattern: 1))
        mainClass.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
        RegisterClassW(&wc)

        let style = DWORD(WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX)
        hwnd = mainClass.withUnsafeBufferPointer { cls in
            w16("포켓몬 대전 (PMF Battle)").withUnsafeBufferPointer { title in
                CreateWindowExW(DWORD(WS_EX_CONTROLPARENT), cls.baseAddress, title.baseAddress, style,
                                Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 100, 100,
                                nil, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let hwnd else { return }
        MainThread.hwnd = hwnd
        k = Double(GetDpiForWindow(hwnd)) / 96.0
        font = makeFont(13, k: k)
        fontBold = makeFont(13, weight: 700, k: k)
        fontSmall = makeFont(11, k: k)

        var rc = RECT(left: 0, top: 0, right: px(1080), bottom: px(560))
        AdjustWindowRect(&rc, style, false)
        SetWindowPos(hwnd, nil, 0, 0, rc.right - rc.left, rc.bottom - rc.top,
                     UINT(SWP_NOMOVE | SWP_NOZORDER))

        buildLobby()
        buildBattle()
        wireClient()
        reloadParty(announce: false)
        setMode(battle: false)
        refreshLobbyUI()
        SetTimer(hwnd, TimerID.ping, 20_000, nil)
        ShowWindow(hwnd, SW_SHOW)
        UpdateWindow(hwnd)
    }

    private func px(_ v: Double) -> Int32 { Int32((v * k).rounded()) }

    // MARK: - layout

    private func buildLobby() {
        let editStyle = DWORD(WS_TABSTOP | ES_AUTOHSCROLL)
        let edge = DWORD(WS_EX_CLIENTEDGE)
        func add(_ h: HWND?) -> HWND? { lobbyControls.append(h); return h }

        _ = add(makeChild("STATIC", "서버", parent: hwnd, id: 0, x: px(12), y: px(15), w: px(34), h: px(20), font: font))
        urlEdit = add(makeChild("EDIT", config.url, parent: hwnd, id: ID.url,
                                x: px(46), y: px(12), w: px(400), h: px(24), style: editStyle, exStyle: edge, font: font))
        _ = add(makeChild("STATIC", "비밀번호", parent: hwnd, id: 0, x: px(456), y: px(15), w: px(56), h: px(20), font: font))
        passwordEdit = add(makeChild("EDIT", config.password, parent: hwnd, id: ID.password,
                                     x: px(512), y: px(12), w: px(150), h: px(24),
                                     style: editStyle | DWORD(ES_PASSWORD), exStyle: edge, font: font))
        _ = add(makeChild("STATIC", "닉네임", parent: hwnd, id: 0, x: px(672), y: px(15), w: px(46), h: px(20), font: font))
        nameEdit = add(makeChild("EDIT", config.name, parent: hwnd, id: ID.name,
                                 x: px(718), y: px(12), w: px(200), h: px(24), style: editStyle, exStyle: edge, font: font))
        SendMessageW(nameEdit, EM.setLimitText, 16, 0)
        connectButton = add(makeChild("BUTTON", "접속", parent: hwnd, id: ID.connect,
                                      x: px(928), y: px(11), w: px(140), h: px(26), style: DWORD(WS_TABSTOP), font: fontBold))
        statusLabel = add(makeChild("STATIC", "", parent: hwnd, id: 0,
                                    x: px(12), y: px(46), w: px(1056), h: px(20), font: font))

        _ = add(makeChild("STATIC", "접속 중인 트레이너", parent: hwnd, id: 0,
                          x: px(12), y: px(76), w: px(360), h: px(20), font: fontBold))
        usersList = add(makeChild("LISTBOX", "", parent: hwnd, id: ID.users,
                                  x: px(12), y: px(98), w: px(360), h: px(362),
                                  style: DWORD(WS_TABSTOP | WS_VSCROLL) | DWORD(LBS_NOTIFY | LBS_NOINTEGRALHEIGHT),
                                  exStyle: edge, font: font))
        challengeButton = add(makeChild("BUTTON", "대전 신청", parent: hwnd, id: ID.challenge,
                                        x: px(12), y: px(468), w: px(176), h: px(34), style: DWORD(WS_TABSTOP), font: fontBold))
        cancelButton = add(makeChild("BUTTON", "신청 취소", parent: hwnd, id: ID.cancel,
                                     x: px(196), y: px(468), w: px(176), h: px(34), style: DWORD(WS_TABSTOP), font: font))

        _ = add(makeChild("STATIC", "내 파티 (공식 세이브, 읽기 전용)", parent: hwnd, id: 0,
                          x: px(392), y: px(76), w: px(270), h: px(20), font: fontBold))
        _ = add(makeChild("BUTTON", "다시 불러오기", parent: hwnd, id: ID.reload,
                          x: px(664), y: px(72), w: px(104), h: px(26), style: DWORD(WS_TABSTOP), font: font))
        partyLabel = add(makeChild("STATIC", "", parent: hwnd, id: 0,
                                   x: px(392), y: px(104), w: px(376), h: px(230), font: font))
        _ = add(makeChild("STATIC",
                          "· 대전은 자동으로 진행됩니다(관전형). 기술은 원본처럼 랜덤으로 골라요.\n"
                          + "· 모든 포켓몬은 HP 가득 찬 상태로 싸우고, 공식 세이브는 바뀌지 않습니다.\n"
                          + "· 목록에서 트레이너를 더블클릭해도 대전을 신청할 수 있어요.\n"
                          + "· 공식 프로그램 버전이 다른 상대와는 대전할 수 없습니다.\n"
                          + "· 서버 주소 예: https://10.10.33.36:7777\n"
                          + "· 새 버전 받기: 서버 주소 뒤에 /download",
                          parent: hwnd, id: 0, x: px(392), y: px(344), w: px(376), h: px(120), font: fontSmall))

        _ = add(makeChild("STATIC", "상대 파티", parent: hwnd, id: 0,
                          x: px(788), y: px(76), w: px(280), h: px(20), font: fontBold))
        preview = PartyPreview(parent: hwnd, k: k, x: px(788), y: px(98), w: px(280), h: px(404))
        _ = add(preview?.hwnd)
        _ = add(makeChild("STATIC",
                          "엔진 \(EngineInfo.upstreamCommit) (공식 \(AppVersion.string) 기준) · 클라이언트 \(ClientInfo.version) (빌드 \(BuildInfo.id))",
                          parent: hwnd, id: 0, x: px(12), y: px(530), w: px(1056), h: px(18), font: fontSmall))
    }

    private func buildBattle() {
        battleView = BattleView(parent: hwnd, k: k, x: 0, y: 0, w: px(1080), h: px(506))
        battleView?.onFinished = { [weak self] in self?.battleFinished() }
        battleControls.append(battleView?.hwnd)
        fastButton = makeChild("BUTTON", "2배속", parent: hwnd, id: ID.fast,
                               x: px(12), y: px(514), w: px(110), h: px(34), style: DWORD(WS_TABSTOP), font: font)
        battleControls.append(fastButton)
        battleControls.append(makeChild("BUTTON", "건너뛰기", parent: hwnd, id: ID.skip,
                                        x: px(130), y: px(514), w: px(110), h: px(34), style: DWORD(WS_TABSTOP), font: font))
        backButton = makeChild("BUTTON", "로비로 돌아가기", parent: hwnd, id: ID.back,
                               x: px(898), y: px(514), w: px(170), h: px(34), style: DWORD(WS_TABSTOP), font: fontBold)
        battleControls.append(backButton)
    }

    private func setMode(battle: Bool) {
        for c in lobbyControls { show(c, !battle) }
        for c in battleControls { show(c, battle) }
        if battle { enable(backButton, false) }
        InvalidateRect(hwnd, nil, true)
    }

    // MARK: - commands

    func command(id: Int32, code: Int) {
        switch id {
        case ID.connect: toggleConnect()
        case ID.challenge: challengeSelected()
        case ID.cancel: client.cancelChallenge()
        case ID.users where code == LB.notifySelChange: refreshPreview()
        case ID.users where code == LB.notifyDblClk: challengeSelected()
        case ID.reload: reloadParty(announce: true)
        case ID.fast:
            fast.toggle()
            battleView?.setFast(fast)
            setText(fastButton, fast ? "보통 속도" : "2배속")
        case ID.skip: battleView?.skipToEnd()
        case ID.back: returnToLobby()
        default: break
        }
    }

    private func toggleConnect() {
        if client.state != .disconnected {
            client.disconnect()
            myId = nil
            users = []
            outgoing = nil
            setStatus("접속을 끊었습니다.")
            refreshLobbyUI()
            return
        }
        let name = getText(nameEdit).trimmingCharacters(in: .whitespaces)
        let password = getText(passwordEdit)
        guard let address = ServerAddress(getText(urlEdit)) else {
            setStatus("서버 주소가 올바르지 않습니다. 예: \(ClientConfig.defaultURL)")
            return
        }
        guard !name.isEmpty else { setStatus("닉네임을 입력해 주세요."); return }
        guard !party.isEmpty else {
            reloadParty(announce: true)
            if party.isEmpty { return }
            return toggleConnect()
        }
        config.url = address.display
        config.name = name
        config.password = password
        config.save()
        setText(urlEdit, address.display)
        rejection = nil
        setStatus("\(address.display) 에 접속하는 중…")
        client.connect(to: address,
                       hello: HelloMsg(password: password, name: name, engine: ClientInfo.engineKey,
                                       client: ClientInfo.version, party: party))
        refreshLobbyUI()
    }

    private func challengeSelected() {
        guard client.state == .connected else { setStatus("먼저 서버에 접속해 주세요."); return }
        guard outgoing == nil else { setStatus("이미 대전을 신청했습니다. 응답을 기다리는 중이에요."); return }
        guard let i = listSelection(usersList), users.indices.contains(i) else {
            setStatus("목록에서 대전할 트레이너를 골라 주세요.")
            return
        }
        let u = users[i]
        guard u.compatible else { setStatus("\(u.name) 님은 다른 버전의 엔진을 쓰고 있어 대전할 수 없습니다."); return }
        guard u.status == "idle" else { setStatus("\(u.name) 님은 지금 대전할 수 없는 상태입니다."); return }
        client.challenge(u.id)
    }

    private func reloadParty(announce: Bool) {
        do {
            party = try OfficialSave.loadParty()
            setText(partyLabel, party.enumerated().map { i, m in
                let moves = m.moves.compactMap { GameData.moves[$0]?.displayName }.joined(separator: ", ")
                return "\(i == 0 ? "★" : "  ")\(m.displayName)  Lv.\(m.level)\n      \(moves)"
            }.joined(separator: "\n"))
            if announce { setStatus("파티를 다시 불러왔습니다 (\(party.count)마리).") }
            if client.state == .connected { client.sendParty(party) }
        } catch {
            party = []
            setText(partyLabel, "\(error)")
            if announce { setStatus("파티를 불러오지 못했습니다.") }
        }
    }

    // MARK: - network events

    private func wireClient() {
        client.onConnected = { [weak self] in
            self?.setStatus("접속했습니다. 로비 정보를 받는 중…")
            self?.refreshLobbyUI()
        }
        client.onDisconnected = { [weak self] reason in
            guard let self else { return }
            self.myId = nil
            self.users = []
            self.outgoing = nil
            if let why = self.rejection {
                self.setStatus("접속 거부: \(why)")
            } else {
                self.setStatus("연결 끊김" + (reason.map { ": \($0)" } ?? ""))
            }
            self.rejection = nil
            self.refreshLobbyUI()
        }
        client.onMessage = { [weak self] msg in self?.handle(msg) }
    }

    private func handle(_ msg: ServerMessage) {
        switch msg {
        case .welcome(let w):
            myId = w.id
            if w.name != getText(nameEdit) { setText(nameEdit, w.name) }
            setStatus("접속됨 · \(w.name) 님으로 입장했습니다.")
            refreshLobbyUI()
            if let latest = w.latestClient, latest.build > BuildInfo.id { offerUpdate(latest) }

        case .lobby(let l):
            users = l.users
            refreshLobbyUI()

        case .challenged(let c):
            if promptOpen || running != nil {
                client.respond(to: c.from, accept: false)
                return
            }
            promptOpen = true
            FlashWindow(hwnd, true)
            let ok = askYesNo(hwnd, "\(c.fromName) 님이 대전을 신청했습니다.\n수락할까요? (\(c.expiresIn)초 안에 응답)",
                              title: "대전 신청")
            promptOpen = false
            client.respond(to: c.from, accept: ok)

        case .challengeSent(let s):
            outgoing = (id: s.to, name: s.toName)
            setStatus("\(s.toName) 님에게 대전을 신청했습니다. 응답을 기다리는 중… (\(s.expiresIn)초)")
            refreshLobbyUI()

        case .challengeEnded(let e):
            let who = e.peerName ?? "상대"
            if outgoing?.id == e.peer { outgoing = nil }
            let text: String
            switch e.reason {
            case "declined": text = "\(who) 님이 대전을 거절했습니다."
            case "expired": text = "\(who) 님과의 대전 신청 시간이 지났습니다."
            case "cancelled": text = "\(who) 님과의 대전 신청이 취소됐습니다."
            case "busy": text = "\(who) 님은 지금 다른 대전 중이거나 신청을 처리하고 있어요."
            case "incompatible": text = "\(who) 님과는 엔진 버전이 달라 대전할 수 없습니다."
            case "offline": text = "\(who) 님이 접속을 종료했습니다."
            default: text = "대전 신청이 종료됐습니다 (\(e.reason))."
            }
            setStatus(text)
            refreshLobbyUI()

        case .battleStart(let b):
            outgoing = nil
            startBattle(b)

        case .battleCheck(let c):
            if !c.consistent {
                alert(hwnd, "두 사람의 화면에서 계산된 전투 결과가 서로 다릅니다.\n"
                          + "양쪽 모두 같은 버전으로 다시 빌드했는지 확인해 주세요.", title: "결과 불일치")
            }

        case .peerLeft(let p):
            setStatus("\(p.name ?? "상대") 님이 접속을 종료했습니다. 이 대전은 끝까지 볼 수 있어요.")

        case .error(let e):
            switch e.code {
            case "password", "protocol", "name", "party", "engine", "full":
                rejection = e.message
                setStatus("접속 거부: \(e.message)")
                alert(hwnd, e.message, title: "접속할 수 없습니다")
            default:
                setStatus("서버: \(e.message)")
            }

        case .pong, .unknown:
            break
        }
    }

    /// A newer build is published on the server: note it in the status line
    /// and, once per run, offer to download it in the browser.
    private func offerUpdate(_ latest: LatestClient) {
        let url = "\(config.url)/download"
        setStatus("새 클라이언트가 나왔습니다 (빌드 \(latest.build)) · 받기: \(url)")
        guard !updateOffered, !promptOpen else { return }
        updateOffered = true
        promptOpen = true
        let ok = askYesNo(hwnd, "새 클라이언트가 나왔습니다 (빌드 \(latest.build)).\n"
                              + "지금 내려받을까요? 브라우저에서 받아집니다.\n\n"
                              + "받은 압축을 풀고 이 창을 닫은 뒤 새 pmf-battle.exe를 실행하세요.\n"
                              + "설정은 그대로 이어집니다.", title: "업데이트")
        promptOpen = false
        if ok { openURL(url) }
    }

    // MARK: - battle

    private func startBattle(_ b: BattleStartMsg) {
        guard let seed = UInt64(b.seed), let mySide = PvPSide(rawValue: b.you),
              let battle = PvPBattle(seed: seed, partyA: b.a.party, partyB: b.b.party) else {
            setStatus("대전 데이터를 해석할 수 없습니다.")
            client.battleDone(id: b.battleId, winner: nil, digest: "invalid")
            return
        }
        let steps = battle.runToEnd()
        running = Running(battleId: b.battleId, battle: battle, mySide: mySide)
        let me = mySide == .a ? b.a : b.b
        let foe = mySide == .a ? b.b : b.a
        fast = false
        setText(fastButton, "2배속")
        battleView?.setFast(false)
        setMode(battle: true)
        battleView?.play(battle: battle, steps: steps, mySide: mySide, myName: me.name, foeName: foe.name)
        SetForegroundWindow(hwnd)
    }

    private func battleFinished() {
        enable(backButton, true)
        reportBattle()
    }

    /// Result + digest go to the server once per battle; the server compares
    /// both reports and frees both trainers for new challenges.
    private func reportBattle() {
        guard var r = running, !r.reported else { return }
        r.reported = true
        running = r
        client.battleDone(id: r.battleId, winner: r.battle.winner, digest: r.battle.digest)
    }

    private func returnToLobby() {
        reportBattle()
        battleView?.stop()
        running = nil
        setMode(battle: false)
        refreshLobbyUI()
    }

    // MARK: - UI refresh

    private func setStatus(_ s: String) { setText(statusLabel, s) }

    private func refreshLobbyUI() {
        let connected = client.state == .connected
        setText(connectButton, client.state == .disconnected ? "접속" : "접속 끊기")
        enable(urlEdit, client.state == .disconnected)
        enable(passwordEdit, client.state == .disconnected)
        enable(nameEdit, client.state == .disconnected)
        enable(challengeButton, connected && outgoing == nil)
        enable(cancelButton, connected && outgoing != nil)

        let selectedId = listSelection(usersList).flatMap { users.indices.contains($0) ? users[$0].id : nil }
        listReset(usersList)
        for u in users {
            var line = u.name
            if let lead = u.lead { line += "   \(Characters.displayName(dex: lead.dex)) Lv.\(lead.level)" }
            line += "  (\(u.partySize)마리)"
            switch u.status {
            case "battling": line += "  [대전 중]"
            case "challenging": line += "  [신청 처리 중]"
            default: break
            }
            if u.bot == true { line += "  [연습 봇]" }
            if !u.compatible { line += "  [버전 다름]" }
            listAdd(usersList, line)
        }
        if users.isEmpty, connected { listAdd(usersList, "(다른 접속자가 없습니다)") }
        if let selectedId, let i = users.firstIndex(where: { $0.id == selectedId }) { listSelect(usersList, i) }
        refreshPreview()
    }

    /// The opponent panel follows the list selection (and its latest lobby data).
    private func refreshPreview() {
        let i = listSelection(usersList)
        preview?.show(i.flatMap { users.indices.contains($0) ? users[$0] : nil })
    }
}
