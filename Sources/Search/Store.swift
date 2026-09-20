import Foundation
import WebKit

// Where everything this browser keeps is kept.
//
// One place, and one rule: a run started for testing never touches the folder
// or the settings of the browser somebody is actually using. Sharing them once
// cost a person their pinned tabs, which is not a mistake worth being able to
// make twice.

enum Store {
    /// A run is a test run if it says so, or if it is being run straight out
    /// of the build folder rather than from an installed app. The second half
    /// is not belt and braces: a development build launched from a terminal
    /// once wrote over somebody's real session, and asking a person to
    /// remember a flag is not a safeguard.
    static var testing: Bool {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] != nil { return true }
        return Bundle.main.executablePath?.contains("/.build/") == true
    }

    /// Cookies, sign-ins, caches. WebKit keeps its default store per bundle,
    /// not per folder, so a test run got every site already signed in — and
    /// "sign out of everything" in a test run signed the real browser out.
    /// A test run gets a store of its own, under a fixed name so it persists
    /// between probes the way the real one does. Wiping the test store is
    /// then as safe as wiping its folder.
    static var websites: WKWebsiteDataStore {
        guard testing else { return .default() }
        return WKWebsiteDataStore(forIdentifier: probeStore)
    }

    private static let probeStore = UUID(uuidString: "5E4C0000-0000-4000-8000-000000000001")!

    /// The app was called Office Browser until September 2026. Everything it
    /// kept — the session, the pins, the history, what is hidden on each site
    /// — moves to the new name the first time the new name runs, and the
    /// settings are copied across. Nothing is left to be lost.
    static let folder: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let home = support.appendingPathComponent(testing ? "Search (test)" : "Search", isDirectory: true)
        if !testing {
            let old = support.appendingPathComponent("Office Browser", isDirectory: true)
            let files = FileManager.default
            if !files.fileExists(atPath: home.path), files.fileExists(atPath: old.path) {
                try? files.moveItem(at: old, to: home)
            }
        }
        return home
    }()

    static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// A file that didn't decode is set aside rather than overwritten the
    /// next time something is saved over it — bookmarks, history and a
    /// session are the kind of thing nobody wants to lose to a bad read with
    /// no trace of what was there. Failing to move it is fine: the read
    /// already came back empty either way, and there's nothing further to
    /// do about a folder that won't take a rename.
    static func quarantine(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: file, to: aside)
    }

    /// Settings live apart too: a test that changes what the tabs wear or
    /// where the tabs go must not change yours.
    static let settings: UserDefaults = {
        guard testing else {
            carryOver(into: .standard)
            return .standard
        }
        return UserDefaults(suiteName: "com.officecommun.search.test") ?? .standard
    }()

    /// The old bundle's defaults, read once and written under the new one.
    private static func carryOver(into fresh: UserDefaults) {
        guard !fresh.bool(forKey: "carried"),
              let old = UserDefaults(suiteName: "com.driceroland.officebrowser")
        else { return }
        for (key, value) in old.dictionaryRepresentation()
        where fresh.object(forKey: key) == nil && !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
            fresh.set(value, forKey: key)
        }
        // The window comes back where it was, under its new name.
        if let frame = old.string(forKey: "NSWindow Frame office-browser") {
            fresh.set(frame, forKey: "NSWindow Frame search")
        }
        fresh.set(true, forKey: "carried")
    }
}
