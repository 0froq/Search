import SwiftUI

// Everything there is to set, in one observable place.
//
// Each of these is a line in the settings file and nothing more; the object
// exists so that a panel can bind to them and the rest of the window can
// redraw when one changes. Defaults are chosen so that a browser nobody has
// configured behaves the way it always did.

/// What a tab wears beside its title, and what a pinned one is reduced to: a
/// letter, or the site's own icon.
enum Glyph: String, CaseIterable, Identifiable {
    case letters, icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letters: return "Letters"
        case .icons: return "Site icons"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let store = Store.settings

    /// Titles down the left instead of across the top.
    @Published var sidebar: Bool {
        didSet { store.set(sidebar, forKey: "sidebar") }
    }
    /// How wide the column is. Pulled by its edge, and remembered.
    @Published var sideWidth: CGFloat {
        didSet { store.set(Double(sideWidth), forKey: "sidebar.width") }
    }
    @Published var glyph: Glyph {
        didSet { store.set(glyph.rawValue, forKey: "glyph") }
    }
    /// The ad blocker. On unless turned off; there is nothing else to it.
    @Published var shielded: Bool {
        didSet { store.set(shielded, forKey: "shield") }
    }
    /// Kept claiming passkeys are possible, which they are not without an
    /// Apple entitlement. Off sends sites to the password instead.
    @Published var passkeys: Bool {
        didSet { store.set(passkeys, forKey: "passkeys") }
    }
    @Published var downloads: URL {
        didSet { store.set(downloads.path, forKey: "downloads") }
    }
    @Published var asksWhereToSave: Bool {
        didSet { store.set(asksWhereToSave, forKey: "downloads.ask") }
    }
    /// Offer to keep a password the first time a site sees it.
    @Published var savesPasswords: Bool {
        didSet { store.set(savesPasswords, forKey: "passwords.save") }
    }
    /// Put a kept name and password into a sign-in as soon as one appears.
    @Published var fillsPasswords: Bool {
        didSet { store.set(fillsPasswords, forKey: "passwords.fill") }
    }
    /// The first launch has been walked through. Until then the welcome
    /// stands over the window.
    @Published var welcomed: Bool {
        didSet { store.set(welcomed, forKey: "welcomed") }
    }
    /// macOS's own autocorrect, inside web pages: the little "Not ×" that
    /// capitalises what you meant to leave lower-case. Off unless asked for.
    @Published var autocorrect: Bool {
        didSet {
            store.set(autocorrect, forKey: "autocorrect")
            Preferences.tellWebKit(autocorrect: autocorrect)
        }
    }

    init() {
        // Carried over from when there were four ways of holding the browser
        // and this was one of them.
        sidebar = store.object(forKey: "sidebar") as? Bool
            ?? (store.string(forKey: "manner") == "side")
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        glyph = store.string(forKey: "glyph").flatMap(Glyph.init) ?? .letters
        shielded = store.object(forKey: "shield") as? Bool ?? true
        // Offered by default only in a build that can actually do them —
        // one with Apple's browser entitlement and its profile embedded.
        let entitled = Bundle.main.url(forResource: "embedded", withExtension: "provisionprofile") != nil
        passkeys = store.object(forKey: "passkeys") as? Bool ?? entitled
        downloads = (store.string(forKey: "downloads")).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        asksWhereToSave = store.bool(forKey: "downloads.ask")
        savesPasswords = store.object(forKey: "passwords.save") as? Bool ?? true
        fillsPasswords = store.object(forKey: "passwords.fill") as? Bool ?? true
        // Anyone who already has a session was here before the welcome
        // existed; they are not asked to sit through it.
        welcomed = store.bool(forKey: "welcomed") || store.object(forKey: "glyph") != nil
        let corrects = store.bool(forKey: "autocorrect")
        autocorrect = corrects
        // Before the first web view exists: WebKit reads these once.
        Preferences.tellWebKit(autocorrect: corrects)
        // Left behind by an assistant this browser no longer has.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open"] {
            store.removeObject(forKey: key)
        }
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults — the real ones, not the test suite, because it is WebKit
    /// reading them and not us. Smart quotes and dashes go off outright: in a
    /// browser they are wrong in every code field and wanted in almost none.
    static func tellWebKit(autocorrect: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(autocorrect, forKey: "WebAutomaticSpellingCorrectionEnabled")
        defaults.set(false, forKey: "WebAutomaticQuoteSubstitutionEnabled")
        defaults.set(false, forKey: "WebAutomaticDashSubstitutionEnabled")
    }
}
