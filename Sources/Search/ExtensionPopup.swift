import AppKit
import WebKit

// An extension's popup, in a popover of the browser's own.
//
// WebKit offers a popover of its own for this, and it works for most
// extensions — but not all: for some, messages from WebKit's popup never
// reach the extension's worker, and the popup waits on a spinner for ever,
// while the very same page loaded in a view built from the extension's
// configuration talks to its worker perfectly well. So the popup page is
// loaded here, in such a view, in a popover that hangs from the button.
//
// Chrome sizes a popup to its content, between 25 and 800 points wide and
// up to 600 tall; the page is measured after it loads and again as it
// changes, and the popover follows. window.close() closes it.

@available(macOS 15.4, *)
@MainActor
final class ExtensionPopup: NSObject, WKUIDelegate, WKNavigationDelegate, NSPopoverDelegate {
    static let shared = ExtensionPopup()

    private var popover: NSPopover?
    private var web: WKWebView?
    /// The popup as WebKit is told about it: the one tab of a window of type
    /// popup. WebKit only carries a page's messages to the extension's worker
    /// when it can say which tab the page is in.
    private var page: PopupPage?
    private var holder: PopupWindow?
    private var measuring: Timer?
    private(set) var extensionID: String?

    /// The popup's web view, while one is up — for the bench.
    var view: WKWebView? { web }

    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView?) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 240), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.load(URLRequest(url: url))

        let host = NSViewController()
        host.view = web
        let popover = NSPopover()
        popover.contentViewController = host
        popover.contentSize = web.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        self.web = web
        self.popover = popover
        extensionID = context.uniqueIdentifier
        let holder = PopupWindow(popover: popover)
        let page = PopupPage(web: web, holder: holder)
        holder.page = page
        self.holder = holder
        self.page = page
        Extensions.shared.controller.didOpenWindow(holder)
        Extensions.shared.controller.didOpenTab(page)

        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = NSApp.mainWindow?.contentView ?? NSApp.windows.first(where: { $0.isVisible })?.contentView {
            let spot = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: spot, of: content, preferredEdge: .minY)
        }
        // Content that grows after it loads — a list filled in by a reply
        // from the worker — is followed for a few seconds.
        var ticks = 0
        measuring = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                ticks += 1
                self?.measure()
                if ticks > 24 { timer.invalidate() }
            }
        }
    }

    func close() {
        measuring?.invalidate()
        measuring = nil
        let closing = popover
        forget()
        closing?.performClose(nil)
    }

    /// Tells WebKit the popup's window and tab are gone.
    private func forget() {
        let controller = Extensions.shared.controller
        if let page { controller.didCloseTab(page, windowIsClosing: true) }
        if let holder { controller.didCloseWindow(holder) }
        page = nil
        holder = nil
        popover = nil
        web = nil
        extensionID = nil
    }

    /// The popup's window, for WebKit's list of open windows.
    var window: (any WKWebExtensionWindow)? { holder }

    private func measure() {
        guard let web, let popover else { return }
        let js = """
        (() => { const d = document.documentElement, b = document.body;
          if (!b) return null;
          return [Math.max(b.scrollWidth, d.scrollWidth, b.offsetWidth), Math.max(b.scrollHeight, d.scrollHeight, b.offsetHeight)]; })()
        """
        web.evaluateJavaScript(js) { value, _ in
            MainActor.assumeIsolated {
                guard let pair = value as? [Double], pair.count == 2, pair[0] > 0, pair[1] > 0 else { return }
                let size = NSSize(width: min(800, max(25, pair[0])), height: min(600, max(25, pair[1])))
                guard abs(size.width - popover.contentSize.width) > 1 || abs(size.height - popover.contentSize.height) > 1 else { return }
                popover.contentSize = size
            }
        }
    }

    // MARK: - the page asking

    func webViewDidClose(_ webView: WKWebView) { close() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { measure() }

    /// A link that asks for a new window becomes a tab, and the popup goes —
    /// the way it does in Chrome when you follow a link out of one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { Extensions.shared.browser?.open(url, foreground: true) }
        close()
        return nil
    }

    /// Only for the popover that is up: closing the last one animates, and
    /// its notification can land after the next one has opened.
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        measuring?.invalidate()
        measuring = nil
        forget()
    }
}

/// The popup page, as a tab.
@available(macOS 15.4, *)
@MainActor
final class PopupPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?
    weak var holder: PopupWindow?

    init(web: WKWebView, holder: PopupWindow) {
        self.web = web
        self.holder = holder
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { holder }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func close(for context: WKWebExtensionContext) async throws { ExtensionPopup.shared.close() }
}

/// The popup's window: of type popup, holding the one page.
@available(macOS 15.4, *)
@MainActor
final class PopupWindow: NSObject, WKWebExtensionWindow {
    weak var popover: NSPopover?
    var page: PopupPage?

    init(popover: NSPopover) { self.popover = popover }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { page.map { [$0] } ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { page }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .popup }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect {
        popover?.contentViewController?.view.window?.frame ?? .null
    }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { NSScreen.main?.frame ?? .null }
}
