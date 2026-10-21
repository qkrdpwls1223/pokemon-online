# Build pmf-battle (Windows) against the upstream submodule.
#   .\build.ps1            -> release build into .\build\pmf-battle\
#   .\build.ps1 run        -> release build, then launch
#   .\build.ps1 dev        -> debug build (console window for logs), then launch
#   .\build.ps1 selftest   -> debug build, run --selftest, then a cross-process determinism check
#   .\build.ps1 update     -> git pull the upstream submodule to its latest main, then release build
#   .\build.ps1 publish [user@host]
#                          -> release build, zip it and upload it over ssh to the lobby server,
#                             which serves it at https://<server>/download. The target is
#                             remembered after the first run (build\publish-target.txt).
#
# Prereqs (same as upstream's build): VS Build Tools 2022 (MSVC + Windows SDK)
# and the Swift toolchain:  winget install Swift.Toolchain
#
# Nothing under upstream\ is modified: its sources are compiled in place.

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$mode = if ($args.Count -gt 0) { $args[0] } else { "" }

# --- publish target (checked before the long build) -----------------------------
$publishTargetFile = Join-Path $PSScriptRoot "build\publish-target.txt"
$publishTarget = $null
if ($mode -eq "publish") {
    if ($args.Count -gt 1) { $publishTarget = $args[1] }
    elseif (Test-Path $publishTargetFile) { $publishTarget = (Get-Content $publishTargetFile -Raw).Trim() }
    if (-not $publishTarget) { Write-Error "Usage: .\build.ps1 publish user@server  (remembered after the first run)" }
}

# --- upstream submodule -------------------------------------------------------
if (-not (Test-Path "upstream\Sources\Core")) {
    Write-Host "==> Fetching the upstream submodule..."
    git submodule update --init upstream
    if ($LASTEXITCODE -ne 0) { Write-Error "git submodule update failed" }
}
if ($mode -eq "update") {
    Write-Host "==> Updating upstream to origin/main..."
    git -C upstream fetch origin
    git -C upstream checkout --detach origin/main
    if ($LASTEXITCODE -ne 0) { Write-Error "upstream update failed" }
    Write-Host "    (commit the new submodule pointer when the build passes: git add upstream)"
}

# --- Swift toolchain (same discovery as upstream/build.ps1) --------------------
if (-not (Get-Command swiftc -ErrorAction SilentlyContinue)) {
    $toolchains = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Toolchains" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    $runtimes = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if (-not $toolchains -or -not $runtimes) {
        Write-Error "Swift toolchain not found. Install with: winget install Swift.Toolchain"
    }
    $env:Path = "$($toolchains[0].FullName)\usr\bin;$($runtimes[0].FullName)\usr\bin;" + $env:Path
    $platforms = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Platforms" -Directory | Sort-Object Name -Descending
    $env:SDKROOT = "$($platforms[0].FullName)\Windows.platform\Developer\SDKs\Windows.sdk\"
}

# --- MSVC developer environment ------------------------------------------------
# swiftc needs the MSVC CRT headers/libs and the Windows SDK. When several VS
# instances exist (e.g. an IDE without the C++ workload next to Build Tools),
# its own discovery can pick the incomplete one, so import vcvars64 from the
# instance that actually has the x64 C++ tools.
if (-not $env:VCToolsInstallDir) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsPath = if (Test-Path $vswhere) {
        & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -latest -property installationPath
    }
    $vcvars = if ($vsPath) { Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat" }
    if (-not $vcvars -or -not (Test-Path $vcvars)) {
        Write-Error "MSVC x64 C++ tools not found. Install: winget install Microsoft.VisualStudio.2022.BuildTools --override `"--quiet --wait --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64`""
    }
    Write-Host "==> MSVC environment: $vsPath"
    $vsEnv = cmd /c "`"$vcvars`" >nul 2>&1 && set"
    foreach ($line in $vsEnv) {
        if ($line -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
    }
}

$appName = "pmf-battle"
$outDir = Join-Path $PSScriptRoot "build\$appName"
$genDir = Join-Path $PSScriptRoot "build\gen"
New-Item -ItemType Directory -Force $outDir, $genDir | Out-Null

# --- engine identity (pairs only identical builds) -----------------------------
$commit = (git -C upstream rev-parse --short=12 HEAD 2>$null)
if (-not $commit) { $commit = "unknown" }
$dirty = [bool](git -C upstream status --porcelain 2>$null)
$dirtyLiteral = if ($dirty) { "true" } else { "false" }
if ($dirty) { Write-Warning "upstream has local changes - this build only pairs with identical dirty builds" }
# Build time doubles as the build id: clients compare it with the published one.
$buildId = Get-Date -Format "yyyyMMdd-HHmmss"
@"
// GENERATED by build.ps1 - do not edit.
enum EngineInfo {
    static let upstreamCommit = "$commit"
    static let upstreamDirty = $dirtyLiteral
}

enum BuildInfo {
    /// yyyyMMdd-HHmmss; string order is time order.
    static let id = "$buildId"
}
"@ | Set-Content -Path "$genDir\EngineInfo.swift" -Encoding UTF8
Write-Host "==> upstream $commit$(if ($dirty) { ' (dirty)' }), build $buildId"

# --- resources: manifest + upstream icon ---------------------------------------
$rcExe = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\rc.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
$resFile = $null
if ($rcExe) {
    $manifest = (Resolve-Path "res\pmf-battle.manifest").Path -replace '\\', '\\'
    $rcLines = @("1 24 `"$manifest`"")
    if (Test-Path "upstream\res\app.ico") {
        $ico = (Resolve-Path "upstream\res\app.ico").Path -replace '\\', '\\'
        $rcLines += "1 ICON `"$ico`""
    }
    Set-Content -Path "$genDir\pmf-battle.rc" -Value $rcLines -Encoding ASCII
    $resFile = Join-Path $genDir "pmf-battle.res"
    & $rcExe.FullName /nologo /fo $resFile "$genDir\pmf-battle.rc"
    if ($LASTEXITCODE -ne 0) { Write-Error "rc.exe failed" }
} else {
    Write-Warning "rc.exe not found - building without manifest/icon (classic-looking controls)"
}

# --- sources -------------------------------------------------------------------
# upstream Core (platform-neutral engine, data loaders, sprite + log helpers)
# plus the three upstream Windows files that implement the core's platform
# seams. SettingsStoreWin.swift is deliberately NOT included: it writes the
# official app's settings.json (see Sources\Adapter\PlatformSettings.swift).
$upstreamWin = @("PlatformWin.swift", "ScreenAdapterWin.swift", "ItemIconsWin.swift") |
    ForEach-Object { Join-Path "upstream\Sources\Windows" $_ }
$sources = @()
$sources += Get-ChildItem -Recurse "upstream\Sources\Core" -Filter *.swift | ForEach-Object FullName
$sources += $upstreamWin | ForEach-Object { (Resolve-Path $_).Path }
$sources += Get-ChildItem -Recurse "Sources" -Filter *.swift | ForEach-Object FullName
$sources += "$genDir\EngineInfo.swift"

$debugFlavor = $mode -eq "dev" -or $mode -eq "selftest"
[string[]]$swiftFlags = if ($debugFlavor) { @("-Onone", "-g") } else { @("-O") }
$swiftFlags += @("-lws2_32")
if ($resFile) { $swiftFlags += @("-Xlinker", $resFile) }
if (-not $debugFlavor) {
    $swiftFlags += @("-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup")
}

Write-Host "==> Compiling $($sources.Count) files..."
$rsp = Join-Path $genDir "sources.rsp"
$rspLines = @($swiftFlags) + @($sources) | ForEach-Object { '"' + ($_ -replace '\\', '/') + '"' }
[System.IO.File]::WriteAllLines($rsp, [string[]]$rspLines, (New-Object System.Text.UTF8Encoding($false)))
$log = Join-Path $genDir "build-log.txt"
cmd /c "swiftc @`"$rsp`" -o `"$outDir\$appName.exe`" >`"$log`" 2>&1"
$exit = $LASTEXITCODE
Get-Content $log -ErrorAction SilentlyContinue | Write-Host
if ($exit -ne 0) { Write-Error "swiftc failed (exit $exit) - see $log" }

# --- runtime + data next to the exe ----------------------------------------------
Write-Host "==> Bundling the Swift runtime DLLs..."
$runtimes = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
if ($runtimes) { Copy-Item "$($runtimes[0].FullName)\usr\bin\*.dll" $outDir -Force }
else { Write-Warning "Swift runtime not found - the exe will need the runtime on PATH" }

Write-Host "==> Staging game data from upstream (characters, gamedata, strings)..."
function Mirror($from, $to) {
    robocopy $from $to /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Error "robocopy $from failed ($LASTEXITCODE)" }
    $global:LASTEXITCODE = 0
}
Mirror "upstream\animations" "$outDir\characters"
Mirror "upstream\gamedata" "$outDir\gamedata"
Get-ChildItem "upstream\Localizable" -Directory | ForEach-Object { Mirror $_.FullName "$outDir\$($_.Name)" }

Write-Host "==> Built $outDir\$appName.exe"

switch ($mode) {
    "publish" {
        # Windows' own bsdtar writes zip; Git's GNU tar (often first on PATH) cannot.
        $pubDir = Join-Path $PSScriptRoot "build\publish"
        New-Item -ItemType Directory -Force $pubDir | Out-Null
        $zip = Join-Path $pubDir "pmf-battle.zip"
        $json = Join-Path $pubDir "latest.json"
        Remove-Item $zip, $json -ErrorAction SilentlyContinue
        Write-Host "==> Zipping $appName..."
        # Move-effect frames are ROM extractions copied from the official app at
        # run time (Sources\Adapter\OfficialEffects.swift) - never ship them.
        & "$env:SystemRoot\System32\tar.exe" -a -c -f $zip --exclude "*.lib" --exclude "*.exp" --exclude "*.pdb" `
            --exclude "*/gamedata/effects" --exclude "*/gamedata/effects.copying" `
            -C (Join-Path $PSScriptRoot "build") $appName
        if ($LASTEXITCODE -ne 0) { Write-Error "zip failed" }
        $version = (Select-String -Path "Sources\UI\ClientConfig.swift" -Pattern 'static let version = "([^"]+)"').Matches[0].Groups[1].Value
        $latest = [ordered]@{
            build = $buildId
            version = $version
            engine = $commit
            size = (Get-Item $zip).Length
            sha256 = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
            publishedAt = (Get-Date).ToUniversalTime().ToString("o")
        }
        [System.IO.File]::WriteAllText($json, ($latest | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

        # Upload into a staging folder, then move into place so /download never
        # serves a half-written zip. The path is relative to the ssh user's home.
        $remoteDir = if ($env:PMF_PUBLISH_DIR) { $env:PMF_PUBLISH_DIR } else { "pmf-battle/server/data/client" }
        Write-Host "==> Uploading $([math]::Round($latest.size / 1MB)) MB to ${publishTarget}:$remoteDir ..."
        ssh $publishTarget "mkdir -p '$remoteDir/.incoming'"
        if ($LASTEXITCODE -ne 0) { Write-Error "ssh $publishTarget failed" }
        # Relative names: some scp builds read "C:\..." as a host called C.
        Push-Location $pubDir
        scp pmf-battle.zip latest.json "${publishTarget}:$remoteDir/.incoming/"
        $scpExit = $LASTEXITCODE
        Pop-Location
        if ($scpExit -ne 0) { Write-Error "scp failed" }
        ssh $publishTarget "cd '$remoteDir' && mv .incoming/pmf-battle.zip . && mv .incoming/latest.json ."
        if ($LASTEXITCODE -ne 0) { Write-Error "moving the upload into place failed" }
        Set-Content -Path $publishTargetFile -Value $publishTarget -Encoding ASCII
        $serverHost = $publishTarget -replace '^.*@', ''
        Write-Host "==> Published build $buildId (client $version). Download: https://${serverHost}:7777/download"
    }
    "run" { & "$outDir\$appName.exe" }
    "dev" { & "$outDir\$appName.exe" }
    "selftest" {
        & "$outDir\$appName.exe" --selftest
        $selftestExit = $LASTEXITCODE
        Write-Host "`n==> Cross-process determinism (same seed, two processes)..."
        $fail = $false
        foreach ($seed in 1, 777, 20261019) {
            $r1 = & "$outDir\$appName.exe" --simulate $seed
            $r2 = & "$outDir\$appName.exe" --simulate $seed
            $same = $r1 -eq $r2
            Write-Host ("  {0}  seed {1}: {2}" -f $(if ($same) { "PASS" } else { "FAIL" }), $seed, $r1)
            if (-not $same) { Write-Host "         second run: $r2"; $fail = $true }
        }
        if ($selftestExit -ne 0 -or $fail) { Write-Error "selftest failed" }
        Write-Host "==> selftest OK"
    }
}
