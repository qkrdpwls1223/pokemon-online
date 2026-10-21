# pmf-battle

[Pokemon Mouse Follower](https://github.com/LimFull/pokemon-mouse-follower)의 키우기 모드에서 키운 포켓몬으로 다른 사람과 온라인 대전을 하는 Windows 프로그램입니다.

- 공식 프로그램은 그대로 설치해서 쓰면 됩니다. 이 프로그램은 공식 세이브를 **읽기만** 합니다.
- 전투 엔진은 공식 프로그램의 것을 그대로 씁니다. 원본 저장소를 git 서브모듈(`upstream/`)로 붙여서 함께 컴파일합니다.
- 지금은 관전형입니다. 기술은 원본처럼 자동으로 고르고, 두 사람 화면에서 같은 전투가 재생됩니다.
- 서버와는 https/wss로 통신하고, 입장 비밀번호가 있어야 로비에 들어갈 수 있습니다.

설계와 통신 규격은 [docs/design.md](docs/design.md)에 있습니다.

## 구성

| 부분 | 위치 | 설명 |
|---|---|---|
| 클라이언트 | `Sources/`, `build.ps1` | Swift + Win32. 로비, 대전 신청, 대전 화면. 통신은 WinHTTP WebSocket |
| 중계 서버 | `server/` | Node.js 22, 외부 패키지 없음. Docker로 실행 |
| 원본 | `upstream/` | 서브모듈. 직접 수정하지 않습니다 |

## 1. 서버 띄우기 (Docker)

서버에는 `server` 폴더만 필요하므로 서브모듈 없이 받으면 됩니다.

```bash
git clone https://github.com/qkrdpwls1223/pokemon-online.git ~/pmf-battle
```

```bash
cd ~/pmf-battle/server && mkdir -p certs data
```

**인증서**: 사내 서비스와 같은 mkcert 인증 기관으로 서버 IP용 인증서를 만듭니다. 이 인증 기관을 이미 신뢰하는 PC는 추가 설정 없이 접속됩니다.

```bash
mkcert -cert-file certs/cert.pem -key-file certs/key.pem 10.10.33.36
```

**설정**: `.env`를 만들고 `SERVER_PASSWORD`를 채웁니다. `PUID`, `PGID`에는 `id -u`, `id -g` 값을 넣습니다. 컨테이너가 권한 600인 키 파일을 읽으려면 파일 주인과 같은 사용자로 떠야 하기 때문입니다.

```bash
cp .env.example .env
```

**실행**:

```bash
docker compose up -d --build
```

브라우저에서 `https://10.10.33.36:7777`을 열면 서버 상태(JSON)가 보입니다. 대전 결과는 `server/data/results.jsonl`에 한 줄씩 쌓입니다.

| 작업 | 명령 |
|---|---|
| 로그 보기 | `docker compose logs -f` |
| 업데이트 | `git pull && docker compose up -d --build` |
| 연습 봇까지 띄우기 | `docker compose --profile bot up -d --build` |
| 중지 | `docker compose down` |

연습 봇은 신청을 자동으로 수락해서 혼자서도 클라이언트를 시험할 수 있게 해 줍니다. 봇은 전투를 계산하지 않으므로 결과 대조는 건너뜁니다.

서버 코드를 고쳤다면 Node 22 이상에서 `npm test`로 확인합니다. 임시 포트에 서버를 띄워 로비, 신청, 대전 시작, 결과 대조, 비밀번호, https/wss까지 검사합니다.

| 환경 변수 | 기본값 | 설명 |
|---|---|---|
| `SERVER_PASSWORD` | 없음 | 입장 비밀번호. 비우면 비밀번호 없이 열립니다 |
| `TLS_CERT`, `TLS_KEY` | 없음 | 둘 다 있으면 https/wss, 없으면 http/ws (로컬 테스트용) |
| `PORT` | `7777` | 컨테이너 안의 리슨 포트 |
| `HOST_PORT` | `7777` | 밖으로 여는 포트 (docker-compose) |
| `MAX_CLIENTS` | `200` | 최대 접속자 |
| `CHALLENGE_TIMEOUT_MS` | `30000` | 대전 신청 응답 대기 시간 |
| `RESULTS_FILE` | `./data/results.jsonl` | 빈 값이면 기록 안 함 |
| `CLIENT_DIR` | `./data/client` | `build.ps1 publish`가 올린 클라이언트 압축 파일 위치. `GET /download`로 내려준다 |

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
cd pokemon-online
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
| `.\build.ps1 publish 사용자@10.10.33.36` | 릴리스 빌드 후 압축해서 서버에 올림 (아래 참고) |

### 다른 PC에 나눠 주기

```powershell
.\build.ps1 publish 사용자@10.10.33.36
```

빌드한 폴더를 압축해서 ssh(`scp`)로 서버의 `~/pmf-battle/server/data/client/`에 올립니다. 그러면 다른 PC에서는 브라우저로 `https://10.10.33.36:7777/download`를 열어 바로 받을 수 있습니다. 서버를 다시 띄울 필요는 없습니다.

- 대상(`사용자@호스트`)은 처음 한 번만 적으면 `build\publish-target.txt`에 기억되고, 다음부터는 `.\build.ps1 publish`만 치면 됩니다.
- 올리는 위치가 다르면 환경 변수 `PMF_PUBLISH_DIR`에 홈 기준 경로를 넣습니다.
- ssh 키를 등록해 두면 비밀번호를 세 번 묻지 않습니다.
- 이전 빌드로 접속한 사람에게는 접속할 때 새 버전이 있다는 안내가 뜨고, 확인을 누르면 브라우저에서 내려받기가 시작됩니다. 빌드마다 시각으로 된 빌드 번호가 붙고(창 아래쪽에 표시), 서버에 올라온 것이 더 새것이면 안내합니다.
- 내려받기 주소에는 입장 비밀번호가 없습니다. 사내망에서만 열리는 서버라는 전제입니다.

서버 연결만 따로 확인하려면 디버그 빌드에서 `--probe`를 씁니다. TLS, 프록시, WebSocket 연결까지 확인하고 서버의 첫 응답을 보여 줍니다.

```powershell
.\build\pmf-battle\pmf-battle.exe --probe https://10.10.33.36:7777
```

## 3. 사용법

1. 공식 프로그램에서 키우기 모드를 한 번이라도 시작해서 파티가 있어야 합니다.
2. `pmf-battle.exe`를 실행하고 서버 주소(`https://10.10.33.36:7777`), 비밀번호, 닉네임을 넣고 **접속**을 누릅니다.
3. 왼쪽 목록에서 상대를 고르고 **대전 신청**을 누르거나 더블클릭합니다.
4. 상대가 수락하면 대전이 자동으로 재생됩니다. **2배속**과 **건너뛰기**를 쓸 수 있습니다.
5. 끝나면 **로비로 돌아가기**를 누릅니다.

- 파티 순서는 공식 프로그램에서 따라다니는 포켓몬이 선두이고, 나머지는 세이브 순서입니다.
- 공식 프로그램에서 파티를 바꿨다면 **다시 불러오기**를 누르세요.
- 모든 포켓몬은 HP 가득 찬 상태로 싸웁니다. 대전 결과는 공식 세이브에 반영되지 않습니다.
- 서버 주소, 닉네임, 비밀번호는 `%LOCALAPPDATA%\pmf-battle\config.json`에 저장됩니다. 비밀번호는 Windows 계정 기준으로 암호화(DPAPI)해서 저장합니다.

### 인증서를 신뢰하지 않는 PC

서버 인증서는 사내 mkcert 인증 기관이 발급합니다. 이 인증 기관을 신뢰하지 않는 PC에서는 "서버 인증서를 신뢰할 수 없습니다" 오류가 납니다. 그럴 때는 서버에서 `mkcert -CAROOT` 폴더의 `rootCA.pem`만 받아서 현재 사용자 신뢰 저장소에 넣습니다. 관리자 권한은 필요 없습니다.

```powershell
certutil -user -addstore Root rootCA.pem
```

같은 폴더의 `rootCA-key.pem`은 절대 다른 PC로 옮기거나 공유하면 안 됩니다. 그 키가 있으면 누구나 이 PC들이 신뢰하는 인증서를 만들 수 있습니다.

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
| "서버에 연결할 수 없습니다" | 컨테이너 실행 여부(`docker compose ps`), 방화벽 포트, 회사망/VPN 접속 여부 |
| "서버 인증서를 신뢰할 수 없습니다" | 위의 "인증서를 신뢰하지 않는 PC" 참고 |
| "서버 인증서의 주소가 접속한 주소와 다릅니다" | 인증서를 만들 때 넣은 IP와 접속 주소가 같은지 확인 |
| "입장 비밀번호가 틀렸습니다" | 서버 `.env`의 `SERVER_PASSWORD`와 같은지 확인 |
| `[버전 다름]` | 양쪽이 같은 `upstream` 커밋으로 빌드했는지 확인 |
| "결과 불일치" 경고 | 양쪽 빌드가 같은지 확인하고 `.\build.ps1 selftest` 결과를 비교 |

다른 세이브 파일로 시험하려면 환경 변수 `PMF_BATTLE_SAVE`에 파일 경로를 지정합니다.

## 저작권

포켓몬 관련 권리는 각 권리자에게 있습니다. 원본 프로젝트와 마찬가지로 비상업 개인 팬 프로젝트입니다.
