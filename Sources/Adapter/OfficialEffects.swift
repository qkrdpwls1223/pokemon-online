// Move-effect sprites borrowed from the installed official app.
//
// Upstream's EffectPlayer loads gamedata/effects/ next to OUR exe (the path
// is fixed in upstream's Resources), but those frames are ROM extractions
// that upstream keeps out of git — only the official app's install has them.
// So instead of shipping them in pmf-battle.zip, start-up copies them over
// from the official app (read-only on that side) — docs/design.md §6.
//
// Until the copy is in place nothing may ask EffectPlayer for a file-backed
// clip: it caches a miss for the rest of the process. `isReady` gates that.

import WinSDK
import Foundation

enum OfficialEffects {
    enum State {
        case checking
        case copying
        case ready
        case unavailable(String)

        var label: String {
            switch self {
            case .checking: return "확인 중"
            case .copying: return "공식 앱에서 복사 중"
            case .ready: return "켜짐"
            case .unavailable(let why): return "꺼짐 (\(why))"
            }
        }
    }

    /// Main thread only (the battle view reads it every beat).
    private(set) static var state: State = .checking
    static var isReady: Bool { if case .ready = state { return true }; return false }
    /// Fired on the main thread whenever `state` changes.
    static var onChange: ((State) -> Void)?

    /// Where upstream looks: <exe dir>\gamedata\effects.
    static var target: URL {
        Resources.root.appendingPathComponent("gamedata", isDirectory: true)
            .appendingPathComponent("effects", isDirectory: true)
    }
    /// Written into our copy: which official install it came from, so an
    /// official update triggers a fresh copy. A folder WITHOUT it was put
    /// there by hand (e.g. a local rom-extract build) and is never replaced.
    private static let markerName = ".pmf-battle-source"

    /// Start-up: settle the state now when nothing needs copying, otherwise
    /// copy on a background thread and report through `onChange`.
    static func prepare() {
        let source = locateSource()
        if let ready = quickCheck(source: source) {
            set(ready)
            return
        }
        set(.copying)
        Thread.detachNewThread {
            let result = OfficialEffects.copy(from: source!)
            MainThread.post { OfficialEffects.set(result) }
        }
    }

    /// Same as `prepare`, but blocking and without touching `state`
    /// (selftest / demo, which run without the main window's queue).
    static func prepareBlocking() -> State {
        let source = locateSource()
        let result = quickCheck(source: source) ?? copy(from: source!)
        state = result
        return result
    }

    private static func set(_ s: State) {
        state = s
        onChange?(s)
    }

    /// The final state when no copy is needed; nil means "copy from source"
    /// (only ever returned with a non-nil source).
    private static func quickCheck(source: URL?) -> State? {
        let fm = FileManager.default
        let have = isEffectsDir(target)
        let marker = try? String(contentsOf: target.appendingPathComponent(markerName), encoding: .utf8)
        if have, marker == nil || isReparsePoint(target) { return .ready }   // hand-placed: leave it
        guard let source else {
            return have ? .ready : .unavailable("공식 앱을 찾지 못함")
        }
        if samePath(source, target) { return .ready }
        if have, marker == signature(of: source) { return .ready }
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            return have ? .ready : .unavailable("이 폴더에 쓸 수 없음")
        }
        return nil
    }

    /// Copy into a scratch folder, then swap it in, so a crash mid-copy
    /// never leaves a half-filled effects folder that looks complete.
    private static func copy(from source: URL) -> State {
        let fm = FileManager.default
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent("effects.copying", isDirectory: true)
        do {
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
            try copyTree(from: source, to: staging)
            try Data(signature(of: source).utf8).write(to: staging.appendingPathComponent(markerName))
            if fm.fileExists(atPath: target.path) {
                // Never recurse into a link: that would delete the official files.
                guard !isReparsePoint(target) else { try? fm.removeItem(at: staging); return .ready }
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: staging, to: target)
            return .ready
        } catch {
            try? fm.removeItem(at: staging)
            return isEffectsDir(target) ? .ready : .unavailable("복사 실패: \(error.localizedDescription)")
        }
    }

    /// ~8,400 small frames in ~450 folders. Measured on a PC whose antivirus
    /// scans every new file: Foundation's per-path calls alone cost ~9 s and
    /// FileManager.copyItem ~40 s in all; a FindFirstFile walk plus 16
    /// parallel CopyFileW calls takes 6-25 s (as fast as robocopy /MT:16).
    private static func copyTree(from source: URL, to dest: URL) throws {
        struct CopyError: LocalizedError {
            let path: String
            var errorDescription: String? { "\(path) 복사 실패" }
        }
        let src = source.path.replacingOccurrences(of: "/", with: "\\")
        let dst = dest.path.replacingOccurrences(of: "/", with: "\\")
        var dirs: [String] = [], files: [String] = []
        walk(src, "", &dirs, &files)
        guard !files.isEmpty else { throw CopyError(path: src) }
        for d in [""] + dirs {
            let path = d.isEmpty ? dst : dst + "\\" + d
            let ok = w16(path).withUnsafeBufferPointer { CreateDirectoryW($0.baseAddress, nil) }
            guard ok || GetLastError() == DWORD(ERROR_ALREADY_EXISTS) else { throw CopyError(path: path) }
        }
        let workers = 16
        let lock = NSLock()
        var failed: String?
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            for i in stride(from: w, to: files.count, by: workers) {
                let ok = w16(src + "\\" + files[i]).withUnsafeBufferPointer { s in
                    w16(dst + "\\" + files[i]).withUnsafeBufferPointer { d in
                        CopyFileW(s.baseAddress, d.baseAddress, false)
                    }
                }
                if !ok {
                    lock.lock(); failed = failed ?? files[i]; lock.unlock()
                    return
                }
            }
        }
        if let failed { throw CopyError(path: failed) }
    }

    /// Relative paths (backslash-separated) of every folder and file under `dir`.
    private static func walk(_ dir: String, _ rel: String, _ dirs: inout [String], _ files: inout [String]) {
        var fd = WIN32_FIND_DATAW()
        let h = w16(dir + "\\*").withUnsafeBufferPointer { FindFirstFileW($0.baseAddress, &fd) }
        guard let h, h != HANDLE(bitPattern: -1) else { return }   // INVALID_HANDLE_VALUE
        defer { FindClose(h) }
        repeat {
            let name = withUnsafeBytes(of: &fd.cFileName) { raw -> String in
                let units = raw.bindMemory(to: WCHAR.self)
                return String(decoding: units[0..<(units.firstIndex(of: 0) ?? units.count)], as: UTF16.self)
            }
            if name == "." || name == ".." { continue }
            let path = rel.isEmpty ? name : rel + "\\" + name
            if fd.dwFileAttributes & 0x10 != 0 {   // FILE_ATTRIBUTE_DIRECTORY
                dirs.append(path)
                walk(dir + "\\" + name, path, &dirs, &files)
            } else {
                files.append(path)
            }
        } while FindNextFileW(h, &fd)
    }

    // MARK: - finding the official app

    /// Its gamedata\effects, first match wins:
    /// PMF_BATTLE_EFFECTS (the effects folder itself) > installer registry >
    /// a running PokemonMouseFollower.exe (zip users) > the default install path.
    static func locateSource() -> URL? {
        func usable(_ u: URL) -> Bool { isEffectsDir(u) && !samePath(u, target) }
        func effects(in app: URL) -> URL {
            app.appendingPathComponent("gamedata", isDirectory: true)
                .appendingPathComponent("effects", isDirectory: true)
        }
        let env = ProcessInfo.processInfo.environment
        if let p = env["PMF_BATTLE_EFFECTS"], !p.isEmpty {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            if usable(u) { return u }
        }
        if let hit = installLocations().map(effects(in:)).first(where: usable) { return hit }
        if let exe = runningOfficialExe(), case let u = effects(in: exe.deletingLastPathComponent()), usable(u) {
            return u
        }
        if let local = env["LOCALAPPDATA"] {
            let u = effects(in: URL(fileURLWithPath: local, isDirectory: true)
                .appendingPathComponent("Programs", isDirectory: true)
                .appendingPathComponent("PokemonMouseFollower", isDirectory: true))
            if usable(u) { return u }
        }
        return nil
    }

    private static func isEffectsDir(_ u: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: u.path) else { return false }
        return names.contains { $0.hasPrefix("effect_") }
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        func norm(_ u: URL) -> String {
            u.standardizedFileURL.path.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        }
        return norm(a) == norm(b)
    }

    private static func isReparsePoint(_ u: URL) -> Bool {
        let attrs = w16(u.path).withUnsafeBufferPointer { GetFileAttributesW($0.baseAddress) }
        return attrs != DWORD.max && attrs & 0x400 != 0   // INVALID_FILE_ATTRIBUTES, FILE_ATTRIBUTE_REPARSE_POINT
    }

    /// Changes whenever the official app is reinstalled or updated (the
    /// installer keeps each file's build timestamp, so the exe's changes).
    private static func signature(of source: URL) -> String {
        let fm = FileManager.default
        let count = (try? fm.contentsOfDirectory(atPath: source.path))?.filter { $0.hasPrefix("effect_") }.count ?? 0
        let exe = source.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PokemonMouseFollower.exe")
        var exeStamp = "-"
        if let a = try? fm.attributesOfItem(atPath: exe.path) {
            let size = (a[.size] as? NSNumber)?.int64Value ?? 0
            let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            exeStamp = "\(size)@\(Int64(date))"
        }
        return "\(source.standardizedFileURL.path)|\(count)|\(exeStamp)"
    }

    /// InstallLocation of every uninstall entry named "... Mouse Follower ..."
    /// (the official Inno Setup installer is per-user, but check machine-wide too).
    private static func installLocations() -> [URL] {
        let hkcu = HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001)))
        let hklm = HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0002)))
        let keyRead: REGSAM = 0x20019, wow64: REGSAM = 0x0100, wow32: REGSAM = 0x0200
        let path = w16("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall")
        var out: [URL] = []
        for (root, view) in [(hkcu, REGSAM(0)), (hklm, wow64), (hklm, wow32)] {
            var key: HKEY?
            guard path.withUnsafeBufferPointer({ RegOpenKeyExW(root, $0.baseAddress, 0, keyRead | view, &key) }) == 0,
                  let key else { continue }
            defer { RegCloseKey(key) }
            var index: DWORD = 0
            while true {
                var name = [WCHAR](repeating: 0, count: 256)
                var len = DWORD(name.count)
                guard RegEnumKeyExW(key, index, &name, &len, nil, nil, nil, nil) == 0 else { break }
                index += 1
                let sub = Array(name[0..<Int(len)]) + [0]
                guard let display = regString(key, sub, "DisplayName"),
                      display.localizedCaseInsensitiveContains("Mouse Follower"),
                      let loc = regString(key, sub, "InstallLocation"), !loc.isEmpty else { continue }
                out.append(URL(fileURLWithPath: loc, isDirectory: true))
            }
        }
        return out
    }

    private static func regString(_ key: HKEY, _ sub: [WCHAR], _ value: String) -> String? {
        var buf = [WCHAR](repeating: 0, count: 1024)
        var bytes = DWORD(buf.count * MemoryLayout<WCHAR>.size)
        let rrfRtRegSz: DWORD = 0x0000_0002
        let status = sub.withUnsafeBufferPointer { s in
            w16(value).withUnsafeBufferPointer { v in
                RegGetValueW(key, s.baseAddress, v.baseAddress, rrfRtRegSz, nil, &buf, &bytes)
            }
        }
        guard status == 0 else { return nil }
        let n = max(0, Int(bytes) / MemoryLayout<WCHAR>.size - 1)
        return String(decoding: buf[0..<min(n, buf.count)], as: UTF16.self)
    }

    /// Path of a running PokemonMouseFollower.exe (it lives in the tray).
    private static func runningOfficialExe() -> URL? {
        var pids = [DWORD](repeating: 0, count: 4096)
        var used: DWORD = 0
        guard K32EnumProcesses(&pids, DWORD(pids.count * MemoryLayout<DWORD>.size), &used) else { return nil }
        let queryLimited: DWORD = 0x1000   // PROCESS_QUERY_LIMITED_INFORMATION
        for pid in pids.prefix(Int(used) / MemoryLayout<DWORD>.size) where pid != 0 {
            guard let h = OpenProcess(queryLimited, false, pid) else { continue }
            defer { CloseHandle(h) }
            var buf = [WCHAR](repeating: 0, count: 1024)
            var len = DWORD(buf.count)
            guard QueryFullProcessImageNameW(h, 0, &buf, &len) else { continue }
            let path = String(decoding: buf[0..<Int(len)], as: UTF16.self)
            if path.lowercased().hasSuffix("\\pokemonmousefollower.exe") {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
