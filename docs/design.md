# pmf-battle 설계

Pokemon Mouse Follower(이하 "원본")의 키우기 모드 포켓몬으로 다른 사람과 온라인 대전을 하는 별도 프로그램이다. 원본 프로그램과 세이브는 건드리지 않는다.

## 1. 원칙

- **원본 수정 없음.** 원본 저장소는 `upstream/` git 서브모듈이다. 원본 소스를 그 자리에서 함께 컴파일할 뿐, 파일을 고치거나 복사하지 않는다. 원본이 업데이트되면 서브모듈을 pull하고 다시 빌드한다.
- **세이브는 읽기 전용.** `%LOCALAPPDATA%\PokemonMouseFollower\raising.json`을 원본의 `RaisingSave` 타입으로 디코딩만 한다. 쓰기를 하는 `RaisingState`는 호출하지 않는다. 경험치, HP, 기절 상태는 대전과 무관하다.
- **설정 파일도 분리.** 원본의 Windows 설정 저장 코드(`SettingsStoreWin.swift`)는 공식 설정 파일을 덮어쓰므로 빌드에서 빼고 메모리 전용 대체 구현을 쓴다. 대전 프로그램 설정은 `%LOCALAPPDATA%\pmf-battle\config.json`에 따로 둔다.
- **서버는 계산하지 않는다.** 전투는 양쪽 클라이언트가 똑같이 계산한다. 서버는 로비, 신청, 시드 배포, 결과 대조만 한다.

## 2. 구성

```
pmf-battle/
├─ upstream/                 원본 저장소 (서브모듈, 수정 금지)
├─ Sources/
│  ├─ Adapter/               원본 엔진과 맞닿는 코드는 전부 여기
│  │  ├─ PvPBattle.swift      파티 대전 진행기 (원본 1:1 BattleSession 위에 교체 규칙)
│  │  ├─ WireMon.swift        통신용 포켓몬 데이터, 원본 Battler 생성
│  │  ├─ OfficialSave.swift   세이브 읽기 전용 로더
│  │  ├─ OfficialEffects.swift  공식 앱 설치본에서 기술 이펙트 이미지 복사
│  │  └─ PlatformSettings.swift  메모리 전용 설정 백엔드
│  ├─ Net/                   WebSocket(WinHTTP), 메시지 정의, 로비 클라이언트
│  ├─ UI/                    Win32 창, 로비, 대전 화면
│  ├─ Selftest.swift         --selftest / --simulate
│  └─ main.swift
├─ res/                      매니페스트 (비주얼 스타일, DPI)
├─ server/                   Node.js 중계 서버 (의존성 없음, Docker)
└─ build.ps1
```

빌드에 들어가는 원본 파일은 `upstream/Sources/Core/**` 전체와 Windows 플랫폼 파일 3개(`PlatformWin`, `ScreenAdapterWin`, `ItemIconsWin`)다. 원본이 Core 안에 파일을 추가해도 자동으로 포함된다.

원본을 pull한 뒤 빌드가 깨지면 고칠 곳은 `Sources/Adapter/`다. UI와 네트워크 코드는 원본 타입 중 `BattleEvent`, `BattleLog`, `Sprite`, `Characters`, `GameData`와 기술 이펙트 재생에 필요한 것(`EffectPlayer`, `RunningEffect`, `BattleController`의 정적 함수 `statChanges`/`rangedVisual`, `MoveMechanics`, `TypeStyle`)만 직접 쓴다. 이 이름들이 바뀌면 `Sources/UI/BattleView.swift`도 고쳐야 한다.

## 3. 결정적(deterministic) 전투

원본 전투 엔진은 모든 난수를 `BattleRNG`(SplitMix64) 하나에서 뽑고, 시드를 고정하면 macOS와 Windows에서 똑같이 재현되도록 만들어져 있다(원본 `design/windows-port.md` W18). 이 성질을 그대로 이용한다.

1. 서버가 64비트 시드를 만들고, 무작위로 한 명을 A(엔진의 "player"), 다른 한 명을 B(엔진의 "wild")로 정한다. A 쪽이 스피드 동률에서 먼저 움직이는 엔진 특성이 있어서 무작위로 정한다.
2. 서버는 시드와 양쪽 파티를 **둘 다에게** 똑같이 보낸다. 각 클라이언트는 자기 파티도 서버가 보낸 사본을 쓴다.
3. 양쪽은 `PvPBattle(seed:partyA:partyB:)`로 같은 전투를 계산하고, A/B 중 자기 쪽을 화면 아래에 그린다.
4. 끝나면 결과와 전체 진행의 FNV-1a 해시를 서버에 보고한다. 서버는 두 보고를 비교해서 다르면 양쪽에 경고한다.

같은 결과를 보장하려면 양쪽이 **같은 원본 커밋**으로 빌드돼야 한다. 그래서 빌드 때 원본 커밋 해시를 새기고, 그 해시와 대전 규칙 버전, 프로토콜 버전을 합친 "엔진 키"가 같은 사람끼리만 대전할 수 있다.

### 파티 대전 규칙 (PvPRules v1)

원본 엔진은 1:1 전투만 안다. 그 위에 이렇게 얹었다.

| 상황 | 처리 |
|---|---|
| 시작 | 각자 파티 첫 번째(공식 프로그램에서 따라다니는 포켓몬)가 나온다 |
| 기절 | 파티 순서상 다음으로 살아 있는 포켓몬이 나온다. 남은 쪽은 능력치 변화 등을 유지한 채 계속 싸운다 |
| 울부짖기/날려버리기 | 맞은 쪽 벤치에서 무작위로 한 마리가 끌려 나온다. 벤치가 없으면 그대로 계속 |
| 순간이동 | 벤치가 있으면 무작위로 교체, 없으면 그대로 계속 |
| 교체되어 다시 나오는 포켓몬 | 능력치 변화와 일시 상태는 초기화, HP와 주요 상태이상은 유지 |
| 한쪽이 전멸 | 다른 쪽 승리. 동시에 전멸하면 무승부 |
| 600라운드 초과 또는 1:1 구간이 200턴 초과 | 남은 HP 비율이 높은 쪽 승리, 같으면 무승부 |

포켓몬은 항상 HP 가득, 상태이상 없이 시작한다. 레벨 보정은 없다. 무작위가 필요한 규칙도 전부 `BattleRNG`에서 뽑는다.

## 4. 통신 프로토콜 v2

WebSocket 텍스트 메시지 하나에 JSON 객체 하나. 모든 메시지에 `t` 필드가 있다. 서버는 의존성 없는 Node.js(`server/server.js`, WebSocket 처리는 `server/ws.js`)다.

- **주소**: 사용자는 `https://10.10.33.36:7777`처럼 입력한다. 클라이언트는 같은 호스트와 포트의 `/ws`로 WebSocket 업그레이드를 요청한다. `GET /`는 서버 상태 JSON, `GET /health`는 `ok`를 돌려준다. `GET /download`는 `build.ps1 publish`가 `CLIENT_DIR`에 올린 최신 클라이언트 압축 파일(`pmf-battle.zip`, 정보는 `latest.json`)을 내려준다.
- **TLS**: 서버는 `TLS_CERT`, `TLS_KEY`가 있으면 https/wss, 없으면 http/ws로 뜬다. 운영에서는 사내 mkcert 인증 기관이 발급한 IP용 인증서를 쓴다. 클라이언트(WinHTTP)는 Windows 신뢰 저장소로 인증서를 검증한다.
- **입장 비밀번호**: 서버의 `SERVER_PASSWORD`. `hello.password`와 SHA-256 다이제스트를 상수 시간으로 비교하고, 틀리면 1초 뒤 `error(password)`를 보내고 연결을 닫는다. 클라이언트는 비밀번호를 DPAPI로 암호화해 저장한다.
- v1(줄바꿈 구분 TCP)과는 호환되지 않는다. `hello.proto`가 다르면 `error(protocol)` 후 연결을 닫는다.

### 클라이언트 → 서버

| t | 필드 | 설명 |
|---|---|---|
| `hello` | `proto`(2), `password`, `name`, `engine`, `client`, `party`, (`bot`) | 첫 메시지. 10초 안에 보내야 한다 |
| `party` | `party` | 파티 다시 불러오기 |
| `challenge` | `to` | 대전 신청 |
| `cancelChallenge` | | 보낸 신청 취소 |
| `respond` | `from`, `accept` | 받은 신청에 응답 |
| `battleDone` | `battleId`, `winner`(`A`/`B`/`draw`), `digest` | 재생을 마치고 로비로 돌아갈 때 |
| `ping` | | 20초마다. 90초 동안 아무 메시지가 없으면 서버가 끊는다 |

### 서버 → 클라이언트

| t | 필드 | 설명 |
|---|---|---|
| `welcome` | `id`, `name`, `serverVersion`, `latestClient` | 이름이 겹치면 `name`이 바뀌어 온다. `latestClient`는 올라온 클라이언트의 `build`, `version`이고 없으면 `null`(서버 0.4부터). 클라이언트는 자기 빌드 번호보다 새것이면 내려받기를 안내한다 |
| `lobby` | `users[]`: `id`, `name`, `status`, `lead`, `partySize`, `party`, `compatible`, `bot` | 받는 사람 기준 목록(본인 제외). `party`는 로비의 상대 파티 패널용으로 한 마리당 `dex`, `level`, `moves`만 담는다(서버 0.3부터) |
| `challenged` | `from`, `fromName`, `expiresIn` | 신청을 받음 |
| `challengeSent` | `to`, `toName`, `expiresIn` | 신청이 접수됨 |
| `challengeEnded` | `peer`, `peerName`, `reason` | `declined`, `expired`, `cancelled`, `busy`, `incompatible`, `offline` |
| `battleStart` | `battleId`, `seed`, `mode`, `you`, `a`, `b` | `seed`는 10진수 문자열. `a`/`b`는 `id`, `name`, `party` |
| `battleCheck` | `battleId`, `consistent` | 양쪽 보고가 모이면 |
| `peerLeft` | `battleId`, `name` | 대전 중 상대가 나감. 로컬 재생은 계속된다 |
| `error` | `code`, `message` | `password`, `protocol`, `name`, `party`, `engine`, `full`은 연결 종료가 뒤따른다 |
| `pong` | | |

포켓몬 한 마리(`WireMon`)는 `dex`, `level`, `moves`(최대 4), `disabledMoves`(선택), `gender`, `ivs`(선택: `hp`, `atk`, `def`, `spAtk`, `spDef`, `spe`)다. 서버는 범위를 검사하지만 세이브 조작까지 막지는 않는다. 지인끼리 쓰는 전제다.

## 5. 다음 단계: 턴마다 기술 고르기

진행기와 화면은 처음부터 "라운드 단위 입력 → 계산 → 재생" 구조로 나눠 두었다.

- `PvPBattle.nextRound()`가 한 라운드씩 계산하고, `BattleView.append(_:)`로 재생 중에 단계를 더 받을 수 있다.
- 관전형은 `runToEnd()`로 한 번에 계산해서 넘길 뿐이다.

남은 일은 "이번 라운드에 이 기술을 써라"를 엔진에 전달하는 것이다. 현재 원본 엔진은 `BattleEngine.plan()` 안에서 `chooseMove()`로 무작위 선택을 하고, 외부에서 기술을 지정할 통로가 없다. 방법은 두 가지다.

1. **원본에 작은 훅을 기여(추천).** 예를 들어 `plan()`이 `chooseMove()` 전에 확인하는 `static var moveOverride: ((Battler) -> Int?)?` 같은 몇 줄짜리 변경을 원작자에게 PR로 제안한다. 받아들여지면 서브모듈 구조가 그대로 유지된다.
2. **빌드 시점 패치.** `patches/*.patch`를 두고, `build.ps1`이 원본 소스를 `build/upstream-src`로 복사한 뒤 `git apply`로 적용해서 컴파일한다. 서브모듈은 깨끗하게 남고, pull 후 패치가 안 맞으면 빌드가 명확히 멈춘다.

프로토콜은 이렇게 늘린다(프로토콜 v3).

- `battleStart.mode = "manual"`
- 클라이언트 → 서버 `move { battleId, round, slot }` (slot 0~3, -1은 자동)
- 서버는 두 입력이 모이면(또는 30초가 지나면 자동 처리) `round { battleId, round, moves: { A, B } }`를 양쪽에 보낸다.
- 기절 후 교체할 포켓몬 고르기도 같은 방식(`switch { battleId, round, index }`)으로 추가한다.

양쪽이 같은 입력으로 같은 라운드를 계산하므로 결정성은 그대로 유지된다. 시간 초과 시 "자동"은 엔진의 무작위 선택이고, 그것도 `BattleRNG`에서 뽑으므로 양쪽이 같다.

## 6. 기술 이펙트

대전 화면은 원본의 기술 이펙트(`EffectPlayer`)를 그대로 재생한다. 원본의 재생 순서를 따라 투사체 → 보조 연출 → 타격 → 능력치 오라 → 상태이상 순으로 한 번에 하나씩 그리고, HP는 타격이 들어간 뒤에 줄어든다. 원본의 연출 컨트롤러(`BattleController`)는 오버레이와 야생 조우에 묶여 있어서 쓰지 않고, 같은 타이밍(1/60초 틱)을 `BattleView`에 옮겼다.

- **에셋 위치.** 이펙트 프레임(`gamedata/effects/`)은 롬에서 추출한 이미지라 원본 git에 없다. 공식 앱 설치본에만 들어 있다(약 220개 폴더, 8천여 개 파일, 6MB 남짓). 원본 코드는 exe 옆 `gamedata\effects`에서만 읽으므로, 시작할 때 공식 앱 폴더에서 이 위치로 복사한다. 공식 앱 쪽은 읽기만 한다.
- **공식 앱 찾는 순서.** 환경 변수 `PMF_BATTLE_EFFECTS`(이펙트 폴더 자체) → 설치 프로그램이 남긴 레지스트리(`Uninstall` 항목 중 이름에 "Mouse Follower"가 들어간 것의 `InstallLocation`) → 실행 중인 `PokemonMouseFollower.exe`의 폴더(무설치 zip 사용자) → `%LOCALAPPDATA%\Programs\PokemonMouseFollower`.
- **복사.** 백그라운드에서 `effects.copying`에 복사한 뒤 이름을 바꿔 끼운다. 복사본에는 출처 표시 파일(`.pmf-battle-source`: 경로, 폴더 수, 공식 exe 크기와 수정 시각)을 넣어서, 공식 앱이 업데이트되면 다음 실행 때 다시 복사한다. 표시 파일이 없는 폴더는 직접 넣은 것으로 보고 건드리지 않는다. 링크(정션)로 된 폴더는 지우지 않는다.
- **복사가 끝나기 전에는 파일 이펙트를 요청하지 않는다.** 원본 `EffectPlayer`는 파일이 없던 결과도 프로세스가 끝날 때까지 캐시하기 때문이다. 그동안에도 파일이 필요 없는 연출(화면 번쩍임, 능력치 오라, 혼란, 씨뿌리기 흡수)은 나온다.
- **배포.** `publish` zip에는 이펙트를 넣지 않는다(`build.ps1`의 tar 제외 항목). 받는 사람도 공식 앱이 있어야 대전할 수 있으니(세이브가 필요하다), 각자 자기 설치본에서 복사해 온다.
- **결정성과 무관.** 이펙트는 전투 계산이 끝난 타임라인을 재생할 때만 쓰고, 이펙트 코드에는 난수가 없다. 전투 결과, digest, 엔진 호환 키, 프로토콜은 그대로다.

## 7. 알려진 제한

- 세이브 파일을 직접 고치면 레벨 100 같은 파티도 만들 수 있다. 서버는 값의 범위만 본다.
- 대전 화면에는 원본의 공격·피격 포즈가 없다. 기술 이펙트와 돌진/흔들림 연출, HP 바, 원본 문구 로그로 그린다. 공식 앱을 찾지 못한 PC에서는 파일 이펙트 없이 재생된다(창 아래쪽에 "기술 이펙트 꺼짐"과 이유가 뜬다).
- 원본이 Core 밖으로 엔진 코드를 옮기거나 Windows 플랫폼 파일 이름을 바꾸면 `build.ps1`의 파일 목록을 고쳐야 한다.
- 접속 제어는 공용 비밀번호 하나뿐이다. 사용자별 계정은 없다.
- 서버 주소 `10.10.33.36`은 사설 IP라서 회사망이나 VPN 안에서만 접속된다.
- mkcert 인증 기관을 신뢰하지 않는 PC는 루트 인증서(`rootCA.pem`)를 직접 설치해야 한다.
