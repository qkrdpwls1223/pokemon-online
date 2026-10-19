// Platform seam: the settings backend the upstream core asks for
// (`makePlatformSettingsBackend`, see upstream Sources/Core/Settings.swift).
//
// Upstream's own Windows backend (SettingsStoreWin.swift) reads AND WRITES
// %LOCALAPPDATA%\PokemonMouseFollower\settings.json — the official app's
// settings. pmf-battle must never touch that file, so it is NOT compiled in;
// this in-memory backend stands in. Every upstream setting therefore reads as
// its default (e.g. altColor = false), which is all the battle code needs.

import Foundation

func makePlatformSettingsBackend() -> SettingsBackend {
    InMemorySettingsBackend()
}

private final class InMemorySettingsBackend: SettingsBackend {
    private var numbers: [String: Double] = [:]
    private var flags: [String: Bool] = [:]
    private var texts: [String: String] = [:]

    func has(_ key: String) -> Bool {
        numbers[key] != nil || flags[key] != nil || texts[key] != nil
    }
    func double(_ key: String) -> Double { numbers[key] ?? 0 }
    func bool(_ key: String) -> Bool { flags[key] ?? false }
    func string(_ key: String) -> String? { texts[key] }
    func set(_ value: Double, _ key: String) { numbers[key] = value }
    func set(_ value: Bool, _ key: String) { flags[key] = value }
    func set(_ value: String, _ key: String) { texts[key] = value }
}
