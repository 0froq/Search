import AppKit
import SwiftUI
import WebKit
import Combine

// Chrome extensions, on WebKit.
//
// The engine is Apple's: WKWebExtension, the same one Safari runs its
// extensions on, reading the same manifest.json a Chrome extension ships.
// What is here is the browser's half of the contract — which tabs exist and
// which one is in front, what a new tab or a popup means in this window, who
// is asked for a permission and how — plus the Chrome Web Store install
// (Crx.swift) and the APIs WebKit doesn't have, filled in natively
// (ExtensionShims.swift, ExtensionNative.swift).
//
// Tab is a Swift class and the protocols are Objective-C ones, so each tab
// is represented to WebKit by a small adapter kept here. A tab can be in the
// row with no web view at all — asleep, or put down — and is reported with
// none; `built` is read, never `web`, which would make one.

/// One installed extension, as the list in Settings shows it.
struct Installed: Codable, Identifiable, Equatable {
    /// The Chrome Web Store id, or "local-…" for one loaded from a folder.
    let id: String
    var name: String
    var version: String
    var enabled: Bool
    var fromStore: Bool
    /// The permissions it was installed with, so an update that asks for more
    /// is asked about rather than slipped through.
    var permissions: [String]
}

@available(macOS 15.4, *)
@MainActor
final class Extensions: NSObject, ObservableObject {
    static let shared = Extensions()

    /// Every page view built for a tab is handed the controller at birth —
    /// it can't be given one later.
    static func attach(_ configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = shared.controller
    }

    let controller: WKWebExtensionController
    @Published private(set) var installed: [Installed] = []
    /// The loaded ones, by id.
    @Published private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Bumped when any extension's button changes — icon, badge, enabled.
    @Published private(set) var actionsChanged = 0
    @Published private(set) var busy: String?
    /// Errors an extension's pages and worker ran into, newest last, a few
    /// dozen at most per extension.
    @Published private(set) var errors: [String: [String]] = [:]

    func noteError(_ text: String, for id: String) {
        var list = errors[id] ?? []
        list.append(text)
        errors[id] = Array(list.suffix(40))
    }

    weak var browser: Browser?
    private var adapters: [Tab.ID: ExtensionTab] = [:]
    private var order: [Tab.ID] = []
    private var watching: [Tab.ID: [AnyCancellable]] = [:]
    private var bag = Set<AnyCancellable>()
    private(set) lazy var window = ExtensionWindow(owner: self)
    /// Where each extension's button is on screen, for its popup to hang from.
    var anchors: [String: WeakView] = [:]

    static var folder: URL { Store.folder.appendingPathComponent("Extensions", isDirectory: true) }
    private static var list: URL { folder.appendingPathComponent("installed.json") }
    static func folder(for id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }

    private override init() {
        // A test run keeps its extensions' storage apart, as it does its
        // cookies and passwords.
        let configuration: WKWebExtensionController.Configuration = Store.testing
            ? .init(identifier: UUID(uuidString: "5E4C0000-0000-4000-8000-000000000002")!)
            : .default()
        configuration.defaultWebsiteDataStore = Store.websites
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        installed = (try? JSONDecoder().decode([Installed].self, from: Data(contentsOf: Extensions.list))) ?? []
    }

    // MARK: - starting

    func start(for browser: Browser) {
        self.browser = browser
        controller.didOpenWindow(window)
        browser.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in self?.follow(tabs) }
            .store(in: &bag)
        browser.$activeID
            .removeDuplicates()
            .scan((nil, nil)) { ($0.1, $1) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pair in self?.activated(from: pair.0, to: pair.1) }
            .store(in: &bag)
        Task {
            for item in installed where item.enabled { await load(item) }
            checkForUpdates()
        }
    }

    // MARK: - the row, as WebKit sees it

    func adapter(for tab: Tab) -> ExtensionTab {
        if let known = adapters[tab.id] { return known }
        let made = ExtensionTab(tab: tab, owner: self)
        adapters[tab.id] = made
        return made
    }

    /// Private tabs keep nothing and see no extensions.
    var visibleTabs: [Tab] { browser?.tabs.filter { !$0.shy } ?? [] }

    var activeAdapter: ExtensionTab? {
        guard let tab = browser?.active, !tab.shy else { return nil }
        return adapter(for: tab)
    }

    private func follow(_ tabs: [Tab]) {
        let now = tabs.filter { !$0.shy }
        let ids = now.map(\.id)
        let gone = order.filter { !ids.contains($0) }
        for id in gone {
            if let adapter = adapters[id] { controller.didCloseTab(adapter, windowIsClosing: false) }
            adapters[id] = nil
            watching[id] = nil
        }
        for tab in now where !order.contains(tab.id) {
            controller.didOpenTab(adapter(for: tab))
            watch(tab)
        }
        // Moves: anything whose position changed among the ones that stayed.
        let stayed = order.filter { ids.contains($0) }
        let newOrder = ids.filter { stayed.contains($0) }
        for (index, id) in stayed.enumerated() where newOrder.firstIndex(of: id) != index {
            if let adapter = adapters[id] { controller.didMoveTab(adapter, from: index, in: window) }
        }
        order = ids
    }

    private func watch(_ tab: Tab) {
        let id = tab.id
        func changed(_ properties: WKWebExtension.TabChangedProperties) {
            guard let adapter = adapters[id] else { return }
            controller.didChangeTabProperties(properties, for: adapter)
        }
        watching[id] = [
            tab.$title.dropFirst().removeDuplicates().sink { _ in changed(.title) },
            tab.$address.dropFirst().removeDuplicates().sink { _ in changed(.URL) },
            tab.$loading.dropFirst().removeDuplicates().sink { _ in changed(.loading) },
            tab.$pin.dropFirst().map { $0 != nil }.removeDuplicates().sink { _ in changed(.pinned) },
        ]
    }

    private func activated(from old: Tab.ID?, to new: Tab.ID?) {
        guard let new, let tab = browser?.tabs.first(where: { $0.id == new }), !tab.shy else { return }
        let previous = old.flatMap { id in browser?.tabs.first(where: { $0.id == id }) }.map(adapter(for:))
        controller.didActivateTab(adapter(for: tab), previousActiveTab: previous)
        actionsChanged += 1
    }

    // MARK: - loading

    @discardableResult
    private func load(_ item: Installed) async -> Bool {
        // The shim this build of Search carries, in place of whatever the
        // build that installed it carried.
        try? ExtensionShims.prepare(Extensions.folder(for: item.id))
        do {
            let found = try await WKWebExtension(resourceBaseURL: Extensions.folder(for: item.id))
            let context = WKWebExtensionContext(for: found)
            context.uniqueIdentifier = item.id
            // The same origin every launch. WebKit picks a fresh one
            // otherwise, and everything an extension keeps in its own pages
            // — localStorage, IndexedDB — is filed under its origin.
            if let stable = URL(string: "webkit-extension://\(item.id)/") { context.baseURL = stable }
            context.isInspectable = true
            // Installing was the consent: everything it asked for then is
            // granted each time it loads. Optional ones are asked for when
            // the extension asks.
            for permission in found.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
            for pattern in found.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller.load(context)
            contexts[item.id] = context
            actionsChanged += 1
            return true
        } catch {
            NSLog("Extensions: couldn't load %@: %@", item.id, error.localizedDescription)
            return false
        }
    }

    private func unload(_ id: String) {
        guard let context = contexts[id] else { return }
        try? controller.unload(context)
        contexts[id] = nil
        actionsChanged += 1
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed).write(to: Extensions.list, options: .atomic)
    }

    // MARK: - installing

    /// A store link or an id, from the field in Settings or the bar that
    /// shows on a store page.
    /// `confirm: false` is for the bench in a test run only — there is no
    /// way to reach it from the real browser.
    func install(from text: String, confirm: Bool = true) {
        guard let id = Crx.id(in: text) else {
            browser?.announce(Crx.Refused.notAnID.localizedDescription)
            return
        }
        if installed.contains(where: { $0.id == id }) {
            browser?.announce("Already installed")
            return
        }
        busy = id
        Task {
            defer { busy = nil }
            do {
                let crx = try await Crx.fetch(id)
                let zip = try Crx.verifiedZip(crx, id: id)
                let target = Extensions.folder(for: id)
                let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
                try Crx.unpack(zip, into: staged)
                try ExtensionShims.prepare(staged)
                try await admit(staged, as: id, fromStore: true, finalFolder: target, confirm: confirm || !Store.testing)
            } catch {
                browser?.announce(error.localizedDescription)
            }
        }
    }

    /// An unpacked extension from disk — a developer's own, or one exported
    /// from another browser. Copied in, so moving the original breaks nothing.
    func installFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load Extension"
        panel.message = "Choose the folder that holds the extension's manifest.json."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        installFolder(at: source)
    }

    func installFolder(at source: URL, confirm: Bool = true) {
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            browser?.announce("That folder has no manifest.json")
            return
        }
        let id = "local-" + String(UUID().uuidString.prefix(8)).lowercased()
        let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: source, to: staged)
            try ExtensionShims.prepare(staged)
        } catch {
            browser?.announce("Couldn't copy the extension")
            return
        }
        Task { try? await admit(staged, as: id, fromStore: false, finalFolder: Extensions.folder(for: id), confirm: confirm || !Store.testing) }
    }

    /// Reads what was unpacked, asks, and — on yes — moves it into place and
    /// loads it. On no, nothing is left behind.
    private func admit(_ staged: URL, as id: String, fromStore: Bool, finalFolder: URL, confirm: Bool = true) async throws {
        let files = FileManager.default
        let found: WKWebExtension
        do {
            found = try await WKWebExtension(resourceBaseURL: staged)
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
        let name = found.displayName ?? id
        let wants = Extensions.describe(found)
        guard !confirm || ask(install: name, wants: wants, icon: found.icon(for: CGSize(width: 64, height: 64))) else {
            try? files.removeItem(at: staged)
            return
        }
        try? files.removeItem(at: finalFolder)
        try files.moveItem(at: staged, to: finalFolder)
        let item = Installed(
            id: id, name: name, version: found.version ?? "?", enabled: true, fromStore: fromStore,
            permissions: found.requestedPermissions.map(\.rawValue).sorted()
        )
        installed.removeAll { $0.id == id }
        installed.append(item)
        save()
        if await load(item) {
            browser?.announce("\(name) is installed")
        } else {
            browser?.announce("\(name) is installed, but WebKit couldn't start it")
        }
    }

    func remove(_ id: String) {
        unload(id)
        errors[id] = nil
        installed.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: Extensions.folder(for: id))
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = on
        save()
        if on {
            Task { await load(installed[index]) }
        } else {
            unload(id)
        }
    }

    func openOptions(_ id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        browser?.open(url, foreground: true)
    }

    // MARK: - updates

    /// Once a day, the store is asked whether anything installed from it has
    /// a newer version; if so it is fetched, checked and swapped in. One that
    /// asks for more than it was installed with is asked about first.
    func checkForUpdates() {
        let key = "extensions.checked"
        let last = Store.settings.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 20 else { return }
        Store.settings.set(Date(), forKey: key)
        for item in installed where item.fromStore {
            Task { await update(item) }
        }
    }

    private func update(_ item: Installed) async {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "updatecheck"),
            URLQueryItem(name: "prodversion", value: Crx.chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(item.id)&v=\(item.version)&uc"),
        ]
        guard let url = parts.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8),
              xml.contains("status=\"ok\""),
              let version = xml.range(of: #"version="([^"]+)""#, options: .regularExpression)
                .map({ String(xml[$0].dropFirst(9).dropLast()) }),
              version != item.version
        else { return }
        do {
            let zip = try Crx.verifiedZip(try await Crx.fetch(item.id), id: item.id)
            let staged = Extensions.folder.appendingPathComponent(".staging-\(item.id)", isDirectory: true)
            try Crx.unpack(zip, into: staged)
            try ExtensionShims.prepare(staged)
            let found = try await WKWebExtension(resourceBaseURL: staged)
            let wants = Set(found.requestedPermissions.map(\.rawValue))
            if !wants.isSubset(of: Set(item.permissions)) {
                guard ask(install: "An update to \(item.name)", wants: Extensions.describe(found), icon: found.icon(for: CGSize(width: 64, height: 64))) else {
                    try? FileManager.default.removeItem(at: staged)
                    return
                }
            }
            unload(item.id)
            let target = Extensions.folder(for: item.id)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: staged, to: target)
            if let index = installed.firstIndex(where: { $0.id == item.id }) {
                installed[index].version = found.version ?? version
                installed[index].permissions = wants.sorted()
                save()
                if installed[index].enabled { await load(installed[index]) }
            }
        } catch {
            NSLog("Extensions: update of %@ failed: %@", item.id, error.localizedDescription)
        }
    }

    /// The page the manifest names for the button, when WebKit hasn't said.
    static func popupURL(for context: WKWebExtensionContext) -> URL? {
        let manifest = context.webExtension.manifest
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        guard let path = action?["default_popup"] as? String, !path.isEmpty else { return nil }
        return context.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    // MARK: - asking

    /// What an extension wants, in words.
    static func describe(_ found: WKWebExtension) -> [String] {
        var out: [String] = []
        let patterns = found.allRequestedMatchPatterns
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            out.append("Read and change everything on every website")
        } else if !patterns.isEmpty {
            let hosts = patterns.compactMap(\.host).filter { !$0.isEmpty }
            out.append("Read and change what's on " + (hosts.prefix(4).joined(separator: ", ")) + (hosts.count > 4 ? " and \(hosts.count - 4) more" : ""))
        }
        let words: [WKWebExtension.Permission: String] = [
            .tabs: "See your open tabs and their addresses",
            .cookies: "Read and change cookies",
            .webNavigation: "See where you go",
            .webRequest: "See the requests pages make",
            .declarativeNetRequest: "Block or change requests pages make",
            .clipboardWrite: "Write to the clipboard",
            .nativeMessaging: "Talk to apps on this Mac",
            .scripting: "Run scripts in pages",
        ]
        for (permission, sentence) in words where found.requestedPermissions.contains(permission) {
            out.append(sentence)
        }
        return out
    }

    private func ask(install name: String, wants: [String], icon: NSImage?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(name)” to Search?"
        alert.informativeText = wants.isEmpty
            ? "It doesn't ask for anything special."
            : "It will be able to:\n• " + wants.joined(separator: "\n• ")
        if let icon { alert.icon = icon }
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func ask(_ question: String, detail: String, context: WKWebExtensionContext) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(context.webExtension.displayName ?? "An extension") \(question)"
        alert.informativeText = detail
        if let icon = context.webExtension.icon(for: CGSize(width: 64, height: 64)) { alert.icon = icon }
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - the buttons

    struct Button: Identifiable {
        let id: String
        let label: String
        let icon: NSImage?
        let badge: String
        let enabled: Bool
    }

    /// One per loaded extension that has something to press, in install order.
    var buttons: [Button] {
        _ = actionsChanged
        let tab = activeAdapter
        return installed.compactMap { item in
            guard let context = contexts[item.id], let action = context.action(for: tab) else { return nil }
            return Button(
                id: item.id,
                label: action.label.isEmpty ? item.name : action.label,
                icon: action.icon(for: CGSize(width: 16, height: 16)),
                badge: action.badgeText,
                enabled: action.isEnabled
            )
        }
    }

    func press(_ id: String) {
        guard let context = contexts[id] else { return }
        if let tab = activeAdapter { context.userGesturePerformed(in: tab) }
        // An extension that asked for its button to open its side panel.
        if ExtensionShims.panelOnClick.contains(id), context.action(for: activeAdapter)?.presentsPopup != true {
            ExtensionShims.openPanel(context, owner: self)
            return
        }
        context.performAction(for: activeAdapter)
    }

    /// A keystroke an extension registered for.
    func take(_ event: NSEvent) -> Bool {
        for context in contexts.values where context.command(for: event) != nil {
            return context.performCommand(for: event)
        }
        return false
    }

    /// Right-click items an extension added, for the page's menu.
    func menuItems(for tab: Tab) -> [NSMenuItem] {
        guard !tab.shy else { return [] }
        let adapter = adapter(for: tab)
        return contexts.values.flatMap { $0.menuItems(for: adapter) }
    }
}

// MARK: - WebKit asks, the browser answers

@available(macOS 15.4, *)
extension Extensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let browser else { return nil }
        let url = configuration.url ?? URL(string: "about:blank")!
        let tab = browser.open(url, foreground: configuration.shouldBeActive, atEnd: true)
        if configuration.shouldBePinned { browser.pin(tab) }
        return adapter(for: tab)
    }

    /// One window, on purpose. A new window's pages become tabs in this one.
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        guard let browser else { return nil }
        for (index, url) in configuration.tabURLs.enumerated() {
            browser.open(url, foreground: index == 0 && configuration.shouldBeFocused, atEnd: true)
        }
        return window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let url = extensionContext.optionsPageURL else { return }
        browser?.open(url, foreground: true)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let detail = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        return ask("asks for more access", detail: detail, context: extensionContext) ? (permissions, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        let hosts = Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", ")
        return ask("wants to read and change \(hosts)", detail: "Only on these sites, until you remove the extension.", context: extensionContext) ? (urls, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let all = matchPatterns.contains { $0.matchesAllHosts || $0.matchesAllURLs }
        let what = all ? "every website" : matchPatterns.map(\.string).sorted().joined(separator: ", ")
        return ask("wants to read and change \(what)", detail: "Until you remove the extension.", context: extensionContext) ? (matchPatterns, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actionsChanged += 1
    }

    /// The popup page, in a popover of the browser's own (ExtensionPopup
    /// says why): WebKit's view is only asked which page it would show.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        let url = action.popupWebView?.url ?? Extensions.popupURL(for: context)
        action.closePopup()
        guard let url else { return }
        ExtensionPopup.shared.show(url, for: context, from: anchors[context.uniqueIdentifier]?.view)
    }

    /// `runtime.sendNativeMessage`. To "search" — the APIs WebKit doesn't
    /// have, answered by this app. To anything else — a Chrome native
    /// messaging host installed on this Mac, spoken to the way Chrome would.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
        if applicationIdentifier == nil || applicationIdentifier == ExtensionShims.application {
            return try await ExtensionShims.answer(message, from: extensionContext, owner: self)
        }
        return try await ExtensionNative.send(message, to: applicationIdentifier!, from: extensionContext.uniqueIdentifier)
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext) async throws {
        try ExtensionNative.connect(port, from: extensionContext.uniqueIdentifier)
    }
}

// MARK: - adapters

/// A weak hold on an NSView, for the anchors.
final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    unowned let owner: Extensions

    init(tab: Tab, owner: Extensions) {
        self.tab = tab
        self.owner = owner
    }

    private var browser: Browser? { owner.browser }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner.window }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab else { return NSNotFound }
        return owner.visibleTabs.firstIndex { $0.id == tab.id } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.built }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.address }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.loading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab?.id == browser?.activeID }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.pin != nil }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.noisy ?? false }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(tab?.built?.pageZoom ?? 1) }
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.built?.bounds.size ?? .zero }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        guard let tab, let browser else { return }
        if pinned, tab.pin == nil { browser.pin(tab) }
        if !pinned, tab.pin != nil { browser.unpin(tab) }
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        tab?.magnify(to: CGFloat(zoomFactor))
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws { tab?.go(to: url) }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { tab?.reload() }
    func goBack(for context: WKWebExtensionContext) async throws { tab?.back() }
    func goForward(for context: WKWebExtensionContext) async throws { tab?.forward() }

    func activate(for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        browser?.select(tab)
    }

    func close(for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        browser?.close(tab)
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let web = tab?.built else { return nil }
        return try await web.takeSnapshot(configuration: configuration)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    unowned let owner: Extensions
    init(owner: Extensions) { self.owner = owner }

    private var nsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frameAutosaveName == "search" }
            ?? NSApp.mainWindow
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        owner.visibleTabs.map(owner.adapter(for:))
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { owner.activeAdapter }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null }

    func focus(for context: WKWebExtensionContext) async throws {
        NSApp.activate(ignoringOtherApps: true)
        nsWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - the buttons in the row

/// Every extension's button, beside the bookmarks. Nothing at all below
/// macOS 15.4 or with nothing installed.
struct ExtensionSlot: View {
    var body: some View {
        if #available(macOS 15.4, *) {
            ExtensionButtons(extensions: .shared)
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionButtons: View {
    @ObservedObject var extensions: Extensions

    var body: some View {
        HStack(spacing: 2) {
            ForEach(extensions.buttons) { button in
                ActionButton(button: button) { extensions.press(button.id) }
                    .background(Anchor(id: button.id))
                    .contextMenu {
                        if extensions.contexts[button.id]?.optionsPageURL != nil {
                            SwiftUI.Button("Options…") { extensions.openOptions(button.id) }
                        }
                        SwiftUI.Button("Remove “\(button.label)”…") {
                            let alert = NSAlert()
                            alert.messageText = "Remove “\(button.label)”?"
                            alert.informativeText = "Its settings and data go with it."
                            alert.addButton(withTitle: "Remove")
                            alert.addButton(withTitle: "Cancel")
                            if alert.runModal() == .alertFirstButtonReturn { extensions.remove(button.id) }
                        }
                    }
            }
        }
    }

    private struct ActionButton: View {
        let button: Extensions.Button
        let press: () -> Void
        @State private var hovering = false

        var body: some View {
            SwiftUI.Button(action: press) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let icon = button.icon {
                            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 15, height: 15)
                        } else {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .frame(width: 26, height: 26)
                    .opacity(button.enabled ? 1 : 0.4)
                    if !button.badge.isEmpty {
                        Text(button.badge)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.ground)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 11)
                            .background(Palette.ink, in: Capsule())
                            .offset(x: 2, y: 1)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(button.label)
        }
    }

    /// A real view under the button, so the popup has something to hang from.
    private struct Anchor: NSViewRepresentable {
        let id: String
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            Extensions.shared.anchors[id] = WeakView(view)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {
            Extensions.shared.anchors[id] = WeakView(view)
        }
    }
}
