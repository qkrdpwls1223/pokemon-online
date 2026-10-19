# pmf-battle

[Pokemon Mouse Follower](https://github.com/LimFull/pokemon-mouse-follower)의 키우기 모드에서 키운 포켓몬으로 다른 사람과 온라인 대전을 하는 Windows 프로그램입니다.

- 공식 프로그램은 그대로 설치해서 쓰면 됩니다. 이 프로그램은 공식 세이브를 **읽기만** 합니다.
- 전투 엔진은 공식 프로그램의 것을 그대로 씁니다. 원본 저장소를 git 서브모듈(`upstream/`)로 붙여서 함께 컴파일합니다.
- 지금은 관전형입니다. 기술은 원본처럼 자동으로 고르고, 두 사람 화면에서 같은 전투가 재생됩니다.

설계와 통신 규격은 [docs/design.md](docs/design.md)에 있습니다.

## 구성

| 부분 | 위치 | 설명 |
|---|---|---|
| 클라이언트 | `Sources/`, `build.ps1` | Swift + Win32. 로비, 대전 신청, 대전 화면 |
| 중계 서버 | `server/` | Node.js 18 이상, 외부 패키지 없음. 리눅스 서버에서 실행 |
| 원본 | `upstream/` | 서브모듈. 직접 수정하지 않습니다 |

## 1. 서버 띄우기 (리눅스)

Node.js 18 이상이 필요합니다.

```bash
git clone --recurse-submodules https://github.com/qkrdpwls1223/pokemon-online.git /opt/pmf-battle
cd /opt/pmf-battle/server
npm test
PORT=7777 node server.js
```

`npm test`는 서버를 임시 포트에 띄우고 가짜 클라이언트로 로비, 신청, 대전 시작, 결과 대조까지 확인합니다.

상시 실행은 systemd로 합니다. `pmf-battle-server.service` 안의 사용자와 경로를 환경에 맞게 고친 뒤 등록합니다.

```bash
sudo useradd --system --no-create-home pmfbattle
sudo mkdir -p /opt/pmf-battle/server/data && sudo chown pmfbattle /opt/pmf-battle/server/data
sudo cp pmf-battle-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pmf-battle-server
```

방화벽에서 TCP 포트(기본 7777)를 열어 주세요. 대전 결과는 `server/data/results.jsonl`에 한 줄씩 쌓입니다.

| 환경 변수 | 기본값 | 설명 |
|---|---|---|
| `PORT` | `7777` | 리슨 포트 |
| `HOST` | `0.0.0.0` | 리슨 주소 |
| `MAX_CLIENTS` | `200` | 최대 접속자 |
| `CHALLENGE_TIMEOUT_MS` | `30000` | 대전 신청 응답 대기 시간 |
| `RESULTS_FILE` | `./data/results.jsonl` | 빈 값이면 기록 안 함 |

### 혼자 테스트하기: 연습 봇

신청을 자동으로 수락하는 봇입니다. 봇은 전투를 계산하지 않으므로 결과 대조는 건너뜁니다.

```bash
node tools/bot.js 127.0.0.1 7777 연습봇
```

## 2. 클라이언트 빌드 (Windows)

원본 빌드와 같은 도구 세 가지가 필요합니다. 처음 한 번만 설치하면 되고, 설치할 때 관리자 권한 확인 창이 뜹니다.

| 도구 | 설치 명령 |
|---|---|
| Windows SDK | `winget install Microsoft.WindowsSDK.10.0.26100` |
| MSVC C++ x64 빌드 도구 | 아래 명령 |
| Swift 툴체인 | `winget install Swift.Toolchain` |

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
```

Visual Studio가 이미 있어도 "C++를 사용한 데스크톱 개발" 구성 요소가 없으면 C 런타임 헤더가 없어서 빌드가 실패합니다. 그럴 때는 위처럼 Build Tools를 따로 설치하면 됩니다. `build.ps1`이 C++ 도구가 있는 설치본을 찾아 개발자 환경(vcvars64)을 자동으로 켭니다.

저장소를 받을 때 서브모듈도 함께 받습니다.

```powershell
git clone --recurse-submodules https://github.com/qkrdpwls1223/pokemon-online.git
cd pmf-battle
.\build.ps1 selftest
.\build.ps1
```

`selftest`는 디버그 빌드로 자체 점검을 돌립니다. 같은 시드로 두 번 계산해서 결과가 같은지, 300판이 모두 정상 종료되는지, 공식 세이브를 읽을 수 있는지, 프로세스를 따로 띄워도 결과가 같은지 확인합니다.

결과물은 `build\pmf-battle\` 폴더입니다. 폴더째 복사해서 다른 PC에서 실행할 수 있습니다.

| 명령 | 동작 |
|---|---|
| `.\build.ps1` | 릴리스 빌드 |
| `.\build.ps1 run` | 빌드 후 실행 |
| `.\build.ps1 dev` | 디버그 빌드, 콘솔 로그 창과 함께 실행 |
| `.\build.ps1 selftest` | 디버그 빌드 후 자체 점검 |
| `.\build.ps1 update` | 원본을 최신 main으로 올리고 빌드 |

## 3. 사용법

1. 공식 프로그램에서 키우기 모드를 한 번이라도 시작해서 파티가 있어야 합니다.
2. `pmf-battle.exe`를 실행하고 서버 주소, 포트, 닉네임을 넣고 **접속**을 누릅니다.
3. 왼쪽 목록에서 상대를 고르고 **대전 신청**을 누르거나 더블클릭합니다.
4. 상대가 수락하면 대전이 자동으로 재생됩니다. **2배속**과 **건너뛰기**를 쓸 수 있습니다.
5. 끝나면 **로비로 돌아가기**를 누릅니다.

- 파티 순서는 공식 프로그램에서 따라다니는 포켓몬이 선두이고, 나머지는 세이브 순서입니다.
- 공식 프로그램에서 파티를 바꿨다면 **다시 불러오기**를 누르세요.
- 모든 포켓몬은 HP 가득 찬 상태로 싸웁니다. 대전 결과는 공식 세이브에 반영되지 않습니다.

## 4. 원본이 업데이트됐을 때

```powershell
.\build.ps1 update
.\build.ps1 selftest
git add upstream
git commit -m "upstream 업데이트"
```

- 엔진이 달라지면 결과가 달라질 수 있어서, 같은 원본 커밋으로 빌드한 사람끼리만 대전할 수 있습니다. 목록에 `[버전 다름]`으로 표시됩니다.
- 업데이트 후 빌드가 깨지면 `Sources/Adapter/`만 고치면 되도록 원본 의존 코드를 모아 두었습니다.

## 문제 해결

| 증상 | 확인할 것 |
|---|---|
| "세이브 파일이 없습니다" | 공식 프로그램에서 키우기 모드를 시작했는지 확인 |
| 서버에 연결할 수 없음 | 서버 실행 여부, 방화벽 포트, 회사망이라면 외부 포트 차단 여부 |
| `[버전 다름]` | 양쪽이 같은 `upstream` 커밋으로 빌드했는지 확인 |
| "결과 불일치" 경고 | 양쪽 빌드가 같은지 확인하고 `.\build.ps1 selftest` 결과를 비교 |

다른 세이브 파일로 시험하려면 환경 변수 `PMF_BATTLE_SAVE`에 파일 경로를 지정합니다.

## 저작권

포켓몬 관련 권리는 각 권리자에게 있습니다. 원본 프로젝트와 마찬가지로 비상업 개인 팬 프로젝트입니다.
