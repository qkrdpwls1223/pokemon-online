// pmf-battle entry point.
//   pmf-battle.exe                  GUI (lobby + battles)
//   pmf-battle.exe --selftest       headless checks (use the dev build: console)
//   pmf-battle.exe --simulate SEED  print one sample battle's digest

import WinSDK
import Foundation

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    exit(Selftest.run() ? 0 : 1)
}
if let i = arguments.firstIndex(of: "--simulate") {
    let seed = (i + 1 < arguments.count ? UInt64(arguments[i + 1]) : nil) ?? 42
    print(Selftest.simulateDigest(seed: seed))
    exit(0)
}

let app = AppWindow()
guard let mainWindow = app.hwnd else {
    alert(nil, "창을 만들 수 없습니다.")
    exit(1)
}

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {
    // Tab between controls, like a dialog.
    if IsDialogMessageW(mainWindow, &msg) { continue }
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}
