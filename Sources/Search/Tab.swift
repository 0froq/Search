import SwiftUI
import WebKit

// One web view per tab, kept alive for as long as the tab is. Switching tabs
// takes the old view out of the window and puts the new one in — the page does
// not reload, does not lose its scroll position, and does not forget what you
// typed into it. That is the whole trick behind switching feeling instant.

enum Web {
    /// Modern WebKit pools processes by data store on its own — every tab
    /// asking for the same one is what gets the second tab a warm process, and
    /// the old WKProcessPool knob does nothing now.
    static func configuration(shy: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // The real store, not the ephemeral one: staying signed in between
        // launches is the difference between a browser and a preview pane. A
        // shy tab gets its own store, which exists only while it does — its own
        // cookies, its own sign-ins, and nothing left behind when it closes.
        config.websiteDataStore = shy ? .nonPersistent() : Store.websites
        // Left alone, WKWebView says only "AppleWebKit … (KHTML, like Gecko)" —
        // no browser, no version. Google reads that as something it doesn't
        // recognise and serves the stripped-back page from a decade ago:
        // no side panel, no dark mode, none of the modern tabs. Naming a
        // version turns it into the same string Safari sends, and the modern
        // page comes back.
        config.applicationNameForUserAgent = "Version/26.5 Safari/605.1.15"
        config.allowsAirPlayForMediaPlayback = true
        // Off by default on macOS, which is why a full-screen button on a video
        // did nothing at all: the page asks, and WebKit refuses without a word.
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = .audio
        return config
    }
}

@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()

    /// The page. Built the first time anyone asks for it, not when the tab
    /// is — a session of twenty tabs coming back is twenty objects, not
    /// twenty web views and their processes fighting the first frame.
    var web: PageView {
        if let built { return built }
        let view = build()
        built = view
        return view
    }
    /// The web view if there is one yet, for the callers that must not be
    /// the reason there is.
    private(set) var built: PageView?
    private let configuration: WKWebViewConfiguration
    /// Whoever handles navigation and windows for this page; applied when
    /// the page is built, whenever that is.
    weak var delegate: (WKNavigationDelegate & WKUIDelegate)? {
        didSet {
            built?.navigationDelegate = delegate
            built?.uiDelegate = delegate
        }
    }
    /// The stylesheet a page not yet built is to be armed with.
    private var veils = ""

    @Published private(set) var title = ""
    @Published private(set) var address: URL?
    @Published private(set) var progress: Double = 0
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// Set when the page never arrived — no host, no network, a refused
    /// connection. Shown in place of the page rather than in a dialog.
    @Published var failure: String?
    /// How far down the page you are, nought to one. The tab's own pill fills
    /// with it.
    @Published var reading: Double = 0

    /// True while the page has been stripped back to its article.
    @Published private(set) var reader = false

    /// Leaving reading mode reloads rather than putting the old markup back:
    /// restoring the HTML gives you a page that looks right and does nothing,
    /// because every listener the page had was thrown away with it.
    func toggleReader(_ done: @escaping (Bool) -> Void) {
        guard !isBlank else {
            done(false)
            return
        }
        guard !reader else {
            reader = false
            web.reload()
            done(true)
            return
        }
        web.evaluateJavaScript(Reader.script) { [weak self] answer, _ in
            let worked = (answer as? String) == "read"
            if worked { self?.reader = true }
            done(worked)
        }
    }

    /// The site's icon, for tabs set to wear one. From the cache the moment
    /// the tab has an address, and from the page a moment after it loads.
    @Published var icon: NSImage?

    /// The letter a pinned tab is reduced to, and what a tab shows in place of
    /// an icon it doesn't have yet.
    var monogram: String {
        let host = address?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        return host.first.map { String($0).uppercased() } ?? "•"
    }

    private func adoptIcon() {
        guard let host = address?.host()?.lowercased() else { return }
        icon = Favicons.shared.cached(host)
    }

    /// True while the caret is in something on the page that takes typing.
    @Published var typing = false
    /// True while the page has taken over the screen.
    @Published var immersed = false

    /// True while this tab's page is out in the little window.
    @Published var floating = false

    /// A sideways swipe in progress, for the disc that shows it.
    @Published var pull: Pull?

    /// Remembered for the site, not for the tab: setting a paper's type to
    /// 125% once should be the last time you think about it.
    func rememberZoom() {
        guard let host = address?.host(), !shy else { return }
        if abs(zoom - 1) < 0.01 {
            Store.settings.removeObject(forKey: "zoom." + host)
        } else {
            Store.settings.set(Double(zoom), forKey: "zoom." + host)
        }
    }

    func applyRememberedZoom() {
        guard let host = address?.host() else { return }
        let kept = Store.settings.object(forKey: "zoom." + host) as? Double ?? 1
        guard abs(CGFloat(kept) - web.pageZoom) > 0.004 else { return }
        web.pageZoom = CGFloat(kept)
        zoom = CGFloat(kept)
    }

    /// How much bigger the page is being drawn. Not a magnifying glass over
    /// the rendered page — the page is laid out again at this size, so text
    /// stays as sharp at 200% as it was at 100%.
    @Published private(set) var zoom: CGFloat = 1

    /// Where the page is and which way it just went, for anything that wants
    /// to follow along.
    var onScroll: ((Tab, Double, Double) -> Void)?
    var onZoom: ((Tab, CGFloat) -> Void)?

    /// True while something on the page is making noise, so the row can say
    /// which tab it is coming from.
    @Published var noisy = false

    /// What the page hands back when you point at something and click it.
    var onPick: ((Tab, String, String, String) -> Void)?
    /// The page has a sign-in on it; the page has just sent one.
    var onSignIn: ((Tab) -> Void)?
    /// The caret has entered or left one of the sign-in boxes; where the box
    /// is, in the web view's points, or nil when it has left.
    var onField: ((Tab, CGRect?) -> Void)?
    /// The site the sign-in was sent from — not the one it landed on —
    /// then the name and the password.
    var onCredentials: ((Tab, String, String, String) -> Void)?
    var onPickEnd: ((Tab) -> Void)?
    var onPickTrouble: ((Tab, String) -> Void)?
    /// Right-click landed on an image. WebKit's own menu offers to copy or
    /// download it and then, on at least some sites, does neither — see
    /// ImageMenu.swift for why this is built rather than patched.
    var onImageMenu: ((Tab, URL) -> Void)?

    private let relay = ScrollRelay()
    private let veils_ = VeilRelay()
    private let forms = FormRelay()
    private let images = ImageRelay()
    private let ears = AudioWatch()
    private var lastY: Double = 0

    /// A tab that keeps nothing: its own cookies, no history, no place in the
    /// session. Signed in as nobody, and forgotten when it goes.
    let shy: Bool

    /// A tab a script opened through the bench, beside yours. Signed in as
    /// you, so it sees what you see — but never selected for you, never in
    /// the session or the history, and gone when the script is done.
    let bench: Bool

    /// The tab whose page opened this one, when a script did. Sign-in flows
    /// hand you back to it when they are done.
    var opener: Tab.ID?

    /// One letter, when the tab has been pinned. A pinned tab keeps its place
    /// at the head of the row and gives up its title for that letter — which
    /// is all you need for the five or six pages you keep open all day.
    @Published var pin: String?

    /// When you last looked at it. The summon lists pages by this, because
    /// what you were just reading is what you are most likely to want back.
    private(set) var touched = Date()

    /// Set on a tab brought back from the last session and not yet opened. It
    /// has a name and an address in the row, and costs nothing until you go to
    /// it — which is the difference between a browser that starts in half a
    /// second with twenty tabs and one that doesn't.
    private(set) var pending: URL?

    private var watch: [NSKeyValueObservation] = []

    /// A tab that has never been anywhere shows the address field instead of a
    /// page. It still owns a web view — built now, warm by the time it's needed.
    var isBlank: Bool { address == nil }

    /// The title if the page has offered one, the address until it does. A tab
    /// that says nothing at all for the first second of every load is a tab you
    /// can't find your way back to.
    var label: String {
        if !title.isEmpty { return title }
        if let address { return Address.pretty(address) }
        return "New Tab"
    }

    init(shy: Bool = false, bench: Bool = false, configuration: WKWebViewConfiguration? = nil) {
        self.shy = shy
        self.bench = bench
        self.configuration = configuration ?? Web.configuration(shy: shy)
    }

    private func build() -> PageView {
        let web = PageView(frame: .zero, configuration: configuration)
        // The trackpad pinch is WebKit's own: it magnifies what is on screen
        // and lets you move around inside it, the way pinching does everywhere
        // else on a Mac. ⌘+ and ⌘- are the other thing — they lay the page out
        // again at a bigger size — and both are worth having.
        web.allowsMagnification = true
        // WebKit's own two-finger swipe stays off. It drags the page across
        // the window with a picture of the last one behind it; ours is in
        // PageView, and it moves nothing but a disc.
        web.allowsBackForwardNavigationGestures = false
        web.onPull = { [weak self] pull in self?.pull = pull }
        // Pages follow the appearance of the window they are drawn in, and the
        // window follows Settings › Appearance — so a site that honours
        // prefers-color-scheme goes dark with the frame, and not otherwise.
        // Right-click, Inspect Element. The public way to say so since 13.3.
        if #available(macOS 13.3, *) { web.isInspectable = true }
        web.navigationDelegate = delegate
        web.uiDelegate = delegate

        // A tab opened by a link inherits its opener's configuration, handlers
        // included, so each name is cleared before being claimed — registering
        // one twice is a hard crash rather than an error.
        let controller = web.configuration.userContentController
        controller.removeScriptMessageHandler(forName: ScrollRelay.name)
        controller.removeScriptMessageHandler(forName: VeilRelay.name)
        controller.removeScriptMessageHandler(forName: FormRelay.name)
        controller.removeScriptMessageHandler(forName: ImageRelay.name)
        controller.add(relay, name: ScrollRelay.name)
        controller.add(veils_, name: VeilRelay.name)
        controller.add(images, name: ImageRelay.name)
        controller.add(forms, name: FormRelay.name)
        Shield.shared.protect(controller)
        built = web
        arm(hiding: veils)

        watch = [
            web.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.title = self?.built?.title ?? "" }
            },
            web.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let fresh = self.built?.url else { return }
                    // about:blank is never a destination. Putting a pinned tab
                    // to sleep loads it deliberately to make WebKit give the
                    // page back — and letting that overwrite the address is how
                    // a pinned tab lost the only thing that could bring it
                    // back, and vanished from the session altogether.
                    guard fresh.absoluteString != "about:blank" else { return }
                    let moved = fresh.host() != self.address?.host()
                    self.address = fresh
                    if moved { self.adoptIcon() }
                }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.progress = self?.built?.estimatedProgress ?? 0 }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.loading = self?.built?.isLoading ?? false }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoBack = self?.built?.canGoBack ?? false }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoForward = self?.built?.canGoForward ?? false }
            },
        ]

        relay.tab = self
        veils_.tab = self
        forms.tab = self
        images.tab = self
        ears.watch(web) { [weak self] on in self?.noisy = on }
        return web
    }

    /// Between two fifths and three times, which is as far as a page is worth
    /// pushing in either direction.
    func magnify(to value: CGFloat) {
        let wanted = min(3, max(0.4, value))
        guard abs(wanted - web.pageZoom) > 0.004 else { return }
        web.pageZoom = wanted
        zoom = wanted
        rememberZoom()
        onZoom?(self, wanted)
    }

    func magnify(by factor: CGFloat) { magnify(to: web.pageZoom * factor) }

    /// ⌘0 undoes both kinds of zoom at once — whichever one you reached for.
    func resetZoom() {
        magnify(to: 1)
        guard web.magnification != 1 else { return }
        web.magnification = 1
        onZoom?(self, 1)
    }

    // MARK: - taking things off the page

    /// What gets injected into the *next* document: the scroll reporter, the
    /// pointing mode, and this site's stylesheet of things you have hidden. The
    /// stylesheet goes in before the document has a body, so nothing is ever
    /// seen arriving and then leaving again.
    func arm(hiding css: String) {
        veils = css
        guard let built else { return }
        let controller = built.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(
            WKUserScript(source: ScrollRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        controller.addUserScript(
            WKUserScript(source: Veiling.picker, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        controller.addUserScript(
            WKUserScript(source: FormRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        controller.addUserScript(
            WKUserScript(source: Swipe.calm, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // Every frame: a swipe over an embedded map is the map's, and only the
        // map's own document can say so.
        controller.addUserScript(
            WKUserScript(source: Swipe.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        controller.addUserScript(
            WKUserScript(source: ImageRelay.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        if !FormRelay.passkeysOffered {
            controller.addUserScript(
                WKUserScript(
                    source: FormRelay.withoutPasskeys,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }
        guard !css.isEmpty else { return }
        controller.addUserScript(
            WKUserScript(source: Veiling.style(css), injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
    }

    /// The same stylesheet, for the page that is already up.
    func applyVeils(_ css: String) {
        built?.evaluateJavaScript(Veiling.style(css))
    }

    func startPicking() { web.evaluateJavaScript("window.__officeVeil && window.__officeVeil.on()") }
    func stopPicking() { web.evaluateJavaScript("window.__officeVeil && window.__officeVeil.off()") }

    func foundSignIn() { onSignIn?(self) }

    /// From the page, in CSS pixels; passed on in points. Page zoom is the
    /// only scale between the two that matters here.
    func fieldFocused(_ rect: CGRect?) {
        guard let rect else {
            onField?(self, nil)
            return
        }
        let zoom = built?.pageZoom ?? 1
        onField?(self, CGRect(
            x: rect.minX * zoom, y: rect.minY * zoom,
            width: rect.width * zoom, height: rect.height * zoom
        ))
    }

    /// A name and password the page has just sent — held, not yet offered.
    /// Whether the sign-in worked is only known afterwards: a page that
    /// comes back without a password box took it, one that still has the
    /// box refused it, and only the first is worth remembering.
    private var sent: (host: String, user: String, password: String, at: Date)?

    func sentSignIn(user: String, password: String) {
        // The host now, while the page is still the sign-in page: a moment
        // later it may be somewhere else entirely, and that is not where
        // the password belongs.
        guard let host = address?.host()?.lowercased() else { return }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        sent = (bare, user, password, Date())
    }

    /// The page has moved on — a new document has loaded, or the sign-in
    /// fields have gone. If a password went out recently and there is no
    /// longer a box for it, that is a sign-in that took.
    ///
    /// A new document is judged at once. Fields that a page removed by
    /// itself are given a moment first: a sign-in built into the page closes
    /// its form the instant you press the button and puts it back if the
    /// server says no — and offering in between is offering a password that
    /// may be wrong.
    func settleSignIn(navigated: Bool = true) {
        guard let sent else { return }
        guard Date().timeIntervalSince(sent.at) < 45 else {
            self.sent = nil
            return
        }
        guard navigated else {
            let stamp = sent.at
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Only if nothing newer went out in the meantime.
                guard let self, self.sent?.at == stamp else { return }
                self.settleSignIn(navigated: true)
            }
            return
        }
        web.evaluateJavaScript("!!(window.__officeForms && window.__officeForms.hasPassword())") { [weak self] still, _ in
            MainActor.assumeIsolated {
                guard let self, let sent = self.sent else { return }
                // The box is still there: a refused sign-in, or the second
                // step of one. Kept for a moment longer, in case the page is
                // still on its way.
                if (still as? Bool) == true { return }
                self.sent = nil
                self.onCredentials?(self, sent.host, sent.user, sent.password)
            }
        }
    }

    /// Puts a remembered name and password where a person would have typed
    /// them. Nothing is echoed back and nothing is written down here.
    /// `done`, when given, hears back `false` for the one case worth saying
    /// something about: the sign-in fields that were there a moment ago,
    /// when this was offered, are gone by the time it actually runs.
    func fill(user: String, password: String, done: ((Bool) -> Void)? = nil) {
        web.evaluateJavaScript(
            "window.__officeForms && window.__officeForms.fill(`\(escape(user))`, `\(escape(password))`)"
        ) { result, _ in
            done?((result as? Bool) ?? false)
        }
    }

    func picked(selector: String, label: String, note: String) {
        onPick?(self, selector, label, note)
    }

    /// Show one hidden thing while the pointer rests on its row in the list.
    func peek(_ selector: String, keeping css: String) {
        web.evaluateJavaScript(
            "window.__officeVeil && window.__officeVeil.peek(`\(escape(css))`, `\(escape(selector))`)"
        )
    }

    func unpeek(_ css: String) {
        web.evaluateJavaScript("window.__officeVeil && window.__officeVeil.unpeek(`\(escape(css))`)")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }
    func pickingEnded() { onPickEnd?(self) }
    func pickingFailed(_ reason: String) { onPickTrouble?(self, reason) }

    /// Called from the page, a few dozen times a second at most — the script
    /// already waits for a frame before it says anything.
    func scrolled(to y: Double, of ceiling: Double) {
        reading = ceiling > 0 ? min(1, max(0, y / ceiling)) : 0
        let delta = y - lastY
        lastY = y
        onScroll?(self, y, delta)
    }

    func go(to url: URL) {
        // Set straight away rather than waiting for the observer: the tab has to
        // stop being blank in the same frame the field disappears, or the empty
        // state flashes back for an instant on its way out.
        address = url
        title = ""
        failure = nil
        reading = 0
        lastY = 0
        reader = false
        typing = false
        immersed = false
        adoptIcon()
        web.load(URLRequest(url: url))
    }

    /// Brought back from the last session: everything the row needs to draw it,
    /// and nothing fetched.
    func restore(url: URL, title: String) {
        address = url
        self.title = title
        pending = url
        adoptIcon()
    }

    /// True for a tab that has a place and an address but is holding no page —
    /// brought back from the last session, or put down with ⌘W while pinned.
    var asleep: Bool { pending != nil }

    /// ⌘W on a pinned tab. The letter keeps its place in the row and the
    /// address is remembered; everything the page was holding is let go, so a
    /// pin you are not reading costs a line in a file and nothing else.
    func rest() {
        guard let url = address else { return }
        pending = url
        reading = 0
        lastY = 0
        noisy = false
        guard let built else { return }
        built.stopLoading()
        // The surest way to make WebKit give a page back is to give it another.
        built.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// Set when WebKit said the page's process went away while nobody was
    /// looking at the tab. Coming back to it loads the page again rather
    /// than showing the white that is left.
    var stale = false

    /// The process behind this page just died while it was the one on
    /// screen. `reload()`/`reloadFromOrigin()` lean on state the dead
    /// process was keeping — asking for the address back instead is the
    /// same trick `revive()` and the hollow branch of `reload()` already
    /// use, and the one that doesn't depend on anything the crash took with
    /// it. Tried twice: right after a process dies, WebKit doesn't always
    /// accept the very next load, which is what a reload that looks like it
    /// did nothing actually was.
    func recoverFromCrash() {
        guard let address else { return }
        failure = nil
        loadAndVerify(address)
    }

    /// `web.load`, checked a moment later rather than trusted outright: a
    /// load handed to WebKit right after a process just died, or as the
    /// very first thing a freshly-built view is asked to do, doesn't always
    /// take — no error, no navigation, just a view that goes on sitting on
    /// about:blank with nothing left to say so. Still there, or still
    /// answering for a process that's already gone, is asked once more.
    private func loadAndVerify(_ url: URL, tries: Int = 0) {
        // Wait for the stage to take the view back before loading into it. A
        // page loaded while its view is off any window boots as a hidden tab,
        // and a site that holds everything until it is shown — x.com does,
        // right down to making no request at all — can then miss being shown a
        // moment later and sit on its placeholder for good. Coming back to a
        // pinned tab after ⌘W is exactly that: select() asks for the view back
        // and wakes the page in the same breath, one synchronous step ahead of
        // SwiftUI actually putting the view on screen. Bounded at about a
        // second, so a wake with no stage waiting for it still loads rather
        // than hanging on one that will never come.
        let view = web
        if view.window == nil, tries < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.loadAndVerify(url, tries: tries + 1)
            }
            return
        }
        view.load(URLRequest(url: url))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard built?.url?.absoluteString != "about:blank" else {
                web.load(URLRequest(url: url))
                return
            }
            web.evaluateJavaScript("document.readyState") { [weak self] _, error in
                MainActor.assumeIsolated {
                    guard let self, let error = error as NSError? else { return }
                    guard error.domain == WKErrorDomain,
                          error.code == WKError.webContentProcessTerminated.rawValue
                    else { return }
                    self.web.load(URLRequest(url: url))
                }
            }
        }
    }

    /// Coming back to a tab. A page whose process was taken away out of sight
    /// — memory pressure, a long sleep — comes back as a white rectangle, and
    /// WebKit does not always say so for a view that was out of its window.
    /// Asked anything at all, the page answers with one particular error, and
    /// the answer to that is to load it again.
    func revive() {
        if stale {
            stale = false
            recoverFromCrash()
            return
        }
        guard !isBlank, pending == nil, !loading, failure == nil else { return }
        // A view with no document behind an address: whatever emptied it, the
        // address is what to show, and reload alone would have nothing to do.
        if hollow, let address {
            web.load(URLRequest(url: address))
            return
        }
        web.evaluateJavaScript("document.readyState") { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self, let error = error as NSError? else { return }
                guard error.domain == WKErrorDomain,
                      error.code == WKError.webContentProcessTerminated.rawValue
                else { return }
                self.recoverFromCrash()
            }
        }
    }

    /// Opened for the first time since the app started, or coming back from
    /// ⌘W while pinned. Answers whether there was anything to wake — the
    /// caller's own `revive()`, right after this, is for a tab that went
    /// quiet a different way, and firing it too here raced this very load
    /// with a second one of its own for the same address.
    @discardableResult
    func wake() -> Bool {
        guard let url = pending else { return false }
        pending = nil
        failure = nil
        reading = 0
        lastY = 0
        reader = false
        typing = false
        immersed = false
        loadAndVerify(url)
        return true
    }

    /// A tab opened by a link is not blank, even though WebKit hasn't started
    /// loading it yet. Saying so now keeps the empty state from flashing up in
    /// the frame between the tab appearing and the page committing.
    func setAddressOptimistically(_ url: URL) {
        address = url
        failure = nil
        adoptIcon()
    }

    func touch() { touched = Date() }

    /// True when the web view holds nothing — never loaded, or emptied —
    /// while the tab still names a page. The white page, in other words.
    var hollow: Bool {
        guard let built else { return address != nil }
        guard let there = built.url else { return address != nil }
        return there.absoluteString == "about:blank" && pending == nil && address != nil
    }

    /// Again from the network. A view that has lost its document is given
    /// the address back instead: there is nothing else for it to reload.
    func reload() {
        if hollow, let address {
            web.load(URLRequest(url: address))
        } else {
            web.reloadFromOrigin()
        }
    }
    func stop() { web.stopLoading() }
    /// Straight through, every time. A page that has to be fetched again is
    /// fetched again — nothing is kept behind to make that look otherwise.
    func back() { web.goBack() }
    func forward() { web.goForward() }

    /// Called when the tab is thrown away. Without it the view keeps running
    /// whatever the page left behind — timers, video, sockets.
    func close() {
        watch = []
        ears.stop()
        onScroll = nil
        onZoom = nil
        onPick = nil
        onPickEnd = nil
        onSignIn = nil
        onField = nil
        onCredentials = nil
        guard let web = built else { return }
        let controller = web.configuration.userContentController
        controller.removeScriptMessageHandler(forName: ScrollRelay.name)
        controller.removeScriptMessageHandler(forName: VeilRelay.name)
        controller.removeScriptMessageHandler(forName: FormRelay.name)
        controller.removeAllUserScripts()
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
    }
}


/// Whether the page is making noise.
///
/// WebKit knows, but only says so through a name that isn't part of the public
/// framework — so it is asked whether it answers to that name at all before
/// anyone listens, and the tab simply goes without the indicator if it doesn't.
final class AudioWatch: NSObject {
    private static let key = "_isPlayingAudio"

    private weak var web: WKWebView?
    private var tell: ((Bool) -> Void)?

    func watch(_ web: WKWebView, _ tell: @escaping (Bool) -> Void) {
        guard web.responds(to: NSSelectorFromString(AudioWatch.key)) else { return }
        self.web = web
        self.tell = tell
        web.addObserver(self, forKeyPath: AudioWatch.key, options: [.new], context: nil)
    }

    func stop() {
        guard let web, tell != nil else { return }
        web.removeObserver(self, forKeyPath: AudioWatch.key)
        tell = nil
        self.web = nil
    }

    override func observeValue(
        forKeyPath path: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard path == AudioWatch.key else { return }
        let on = (change?[.newKey] as? Bool) ?? false
        DispatchQueue.main.async { self.tell?(on) }
    }

    deinit { stop() }
}

/// A web view that reads the two-finger swipe for itself.
final class PageView: WKWebView {
    /// Told where a sideways swipe has got to, and nil when there is none.
    var onPull: ((Pull?) -> Void)?

    // MARK: - two fingers sideways

    private enum Axis { case across, down }

    private var sideways: CGFloat = 0
    private var gatheredX: CGFloat = 0
    private var gatheredY: CGFloat = 0
    private var axis: Axis?
    /// Which way the gesture set off, decided once and kept. Turning round
    /// mid-swipe pulls the disc back; it never becomes the other disc.
    private var back = true
    /// The page's word on whether this swipe is its own. Nil until it says.
    private var free: Bool?
    private var asked: Date?
    /// Already went somewhere, or was refused: nothing more this gesture.
    private var spent = false
    private var armedNow = false
    private var showing = false
    private var going = false
    private var pulls = 0

    /// How far the fingers travel before letting go means it.
    private static let arm: CGFloat = 110
    /// Less than this and there is nothing to show yet — or nothing left to.
    private static let show: CGFloat = 6

    override func scrollWheel(with event: NSEvent) {
        // The page gets every event first and scrolls as it always did. The
        // swipe is only read, never taken.
        super.scrollWheel(with: event)
        // Only a live trackpad gesture — not its glide afterwards, and not a
        // mouse wheel, which has no beginning or end to speak of.
        guard event.momentumPhase == [] else { return }

        switch event.phase {
        case .mayBegin, .began:
            sideways = 0
            gatheredX = 0
            gatheredY = 0
            axis = nil
            free = nil
            asked = nil
            spent = false
            armedNow = false
            showing = false
            // A disc still on its way out belongs to the last gesture. It is
            // already invisible; it is only taken off the stage so the next
            // one arrives fresh rather than fading back in.
            pulls += 1
            if going {
                going = false
                onPull?(nil)
            }
        case .changed:
            guard !spent else { return }
            if axis == nil {
                // A few points in, the gesture has shown which way it means
                // to go. Only a clearly sideways one is read further.
                gatheredX += abs(event.scrollingDeltaX)
                gatheredY += abs(event.scrollingDeltaY)
                sideways += event.scrollingDeltaX
                guard gatheredX + gatheredY > 6 else { return }
                axis = gatheredX > gatheredY * 1.3 ? .across : .down
                if axis == .down {
                    spent = true
                    return
                }
                back = sideways > 0
                // Nowhere to go that way: nothing to show, and nothing more
                // to read from this gesture.
                if back ? !canGoBack : !canGoForward {
                    spent = true
                    return
                }
                asked = Date()
                tell()
                return
            }
            sideways += event.scrollingDeltaX
            tell()
        case .ended:
            release()
        case .cancelled:
            spent = true
            settle(nil)
        default:
            break
        }
    }

    /// The page has said whether the swipe would scroll something.
    func answer(free yes: Bool) {
        guard axis != .down, !spent else { return }
        guard yes else {
            free = false
            spent = true
            settle(nil)
            return
        }
        guard free == nil else { return }
        free = true
        tell()
    }

    /// Only the distance in the direction it set off in. Past the origin the
    /// other way is just nought.
    private var travel: CGFloat { max(0, back ? sideways : -sideways) }

    private func tell() {
        if free == nil, let asked, Date().timeIntervalSince(asked) > 0.18 {
            // A page that never answers — a PDF, a page that failed to load —
            // still has to be leavable by hand.
            free = true
        }
        guard free == true else { return }

        let travel = travel
        // Drawn all the way back, the disc goes; drawn out again, it returns.
        // Nothing is decided until the fingers lift.
        guard travel >= PageView.show else {
            if showing { settle(nil) }
            return
        }

        let armed = travel >= PageView.arm
        if armed != armedNow {
            // Two different taps: one for reaching it, a lighter one for
            // stepping back from it, so you know without looking that
            // letting go now is safe.
            NSHapticFeedbackManager.defaultPerformer.perform(
                armed ? .levelChange : .alignment, performanceTime: .now
            )
        }
        armedNow = armed
        settle(Pull(back: back, travel: travel, armed: armed, going: false))
    }

    private func release() {
        defer { spent = true }
        guard !spent, free == true, armedNow else {
            settle(nil)
            return
        }
        going = true
        settle(Pull(back: back, travel: travel, armed: true, going: true))
        if back { goBack() } else { goForward() }
        pulls += 1
        let mine = pulls
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, pulls == mine else { return }
            going = false
            settle(nil)
        }
    }

    private func settle(_ pull: Pull?) {
        showing = pull != nil
        onPull?(pull)
    }

}

/// Carries the page's scroll position back to its tab.
///
/// A content controller holds its handlers strongly, so this stands between the
/// two rather than the tab registering itself — otherwise a closed tab is kept
/// alive by the very page it was told to stop showing.
final class ScrollRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeScroll"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        if let side = body["side"] as? String {
            MainActor.assumeIsolated { tab?.web.answer(free: side == "free") }
            return
        }
        guard let y = body["y"] as? Double,
              let ceiling = body["max"] as? Double
        else { return }
        MainActor.assumeIsolated { tab?.scrolled(to: y, of: ceiling) }
    }

    /// Reports at most once a frame, and passively, so a page that scrolls
    /// smoothly without us keeps scrolling smoothly with us.
    static let script = """
    (function () {
      var waiting = false;
      function tell() {
        var root = document.documentElement;
        var y = window.scrollY || root.scrollTop || 0;
        var ceiling = Math.max(1, (root.scrollHeight || 0) - window.innerHeight);
        window.webkit.messageHandlers.\(name).postMessage({ y: y, max: ceiling });
      }
      window.addEventListener('scroll', function () {
        if (waiting) return;
        waiting = true;
        requestAnimationFrame(function () { waiting = false; tell(); });
      }, { passive: true });
      tell();
    })();
    """
}


