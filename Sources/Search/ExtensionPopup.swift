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
    /// The popup as WebKit is told about it: a page it can find, belonging
    /// to the browser's window — Chrome gives a popup no window of its own,
    /// so "the current window" from a popup is the browser's, and so is the
    /// last focused one.
    private var page: PopupPage?
    private var measuring: Timer?
    private(set) var extensionID: String?

    /// The popup's web view, while one is up — for the bench.
    var view: WKWebView? { web }

    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView?) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
        // The page is laid out first at Chrome's smallest popup, 25 points
        // square — measure tells a size the page names for itself apart from
        // one that only fills what it is given by that — and unseen, while
        // the popover already stands at the size this popup had last time.
        // Then it takes its own size and shows. It has to be in the window
        // while that happens: WebKit suspends a page that is in none.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 25, height: 25), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.alphaValue = 0
        web.load(URLRequest(url: url))

        let stage = NSView(frame: NSRect(origin: .zero, size: ExtensionPopup.lastSize[context.uniqueIdentifier] ?? NSSize(width: 360, height: 240)))
        stage.addSubview(web)
        let host = NSViewController()
        host.view = stage
        let popover = NSPopover()
        popover.contentViewController = host
        popover.contentSize = stage.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        self.web = web
        self.popover = popover
        extensionID = context.uniqueIdentifier
        let page = PopupPage(web: web)
        self.page = page
        Extensions.shared.controller.didOpenTab(page)

        shown = false
        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = NSApp.mainWindow?.contentView ?? NSApp.windows.first(where: { $0.isVisible })?.contentView {
            let spot = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: spot, of: content, preferredEdge: .minY)
        }
        // Shown once measured — or after a moment regardless, for a page
        // that never finishes loading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.reveal()
        }
    }

    /// Each extension's popup size, so the next opening starts there.
    private static var lastSize: [String: NSSize] = [:]
    private var shown = false

    /// The page, at the popover's size, in view.
    private func reveal() {
        guard !shown, let web, let stage = popover?.contentViewController?.view else { return }
        shown = true
        web.frame = stage.bounds
        web.autoresizingMask = [.width, .height]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            web.animator().alphaValue = 1
        }
    }

    /// From the page's first load: measured a little after, then again as
    /// it changes — a list filled in by a reply from the worker — for a few
    /// seconds.
    private func follow() {
        guard measuring == nil else { return }
        var ticks = 0
        measuring = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                ticks += 1
                self?.measure()
                if ticks > 24 { timer.invalidate() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.measure() }
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
        if let page { Extensions.shared.controller.didCloseTab(page, windowIsClosing: false) }
        page = nil
        popover = nil
        web = nil
        extensionID = nil
    }


    private func measure() {
        guard let web, let popover else { return }
        // The size the page asks for — its preferred size, which is what
        // Chrome gives a popup. Measuring the page as it is laid out can't
        // answer that: it is never narrower or shorter than the view it is
        // in. So the page is asked to size itself for the length of one
        // measurement, and put back before anything is drawn.
        //
        // A width or height the page names for itself — `html { width:
        // 380px }` — is kept. It is told apart once, at the first
        // measurement, while the view is still the 25-point square no page
        // would choose: laid out at its natural width, a page that names one
        // doesn't take the square's, and one that fills what it is given
        // (auto, 100%, 100vw) does.
        let js = """
        (() => { const d = document.documentElement, b = document.body;
          if (!b) return null;
          const memo = window.__searchPopup || (window.__searchPopup = {});
          const saved = [d.getAttribute("style"), b.getAttribute("style")];
          const set = (el, k, v) => el.style.setProperty(k, v, "important");
          const back = () => {
            saved[0] === null ? d.removeAttribute("style") : d.setAttribute("style", saved[0]);
            saved[1] === null ? b.removeAttribute("style") : b.setAttribute("style", saved[1]);
          };
          const vw = innerWidth, vh = innerHeight;
          if (memo.w === undefined) {
            const natural = d.getBoundingClientRect();
            set(d, "width", "auto"); set(d, "height", "auto");
            const loose = d.getBoundingClientRect();
            back();
            memo.w = Math.abs(natural.width - loose.width) > 1 && Math.abs(natural.width - vw) > 1 ? natural.width : null;
            memo.h = Math.abs(natural.height - loose.height) > 1 && Math.abs(natural.height - vh) > 1 ? natural.height : null;
          }
          let w = memo.w;
          if (w == null) { set(d, "width", "max-content"); w = d.getBoundingClientRect().width; back(); }
          w = Math.min(800, Math.max(25, Math.ceil(w)));
          let h = memo.h;
          if (h == null) {
            set(d, "width", w + "px"); set(d, "height", "max-content"); set(d, "min-height", "0");
            set(b, "height", "max-content"); set(b, "min-height", "0");
            h = d.getBoundingClientRect().height;
            back();
          }
          // A page built only of positioned pieces has no size of its own.
          if (w < 40) w = Math.max(b.scrollWidth, d.scrollWidth);
          if (h < 20) h = Math.max(b.scrollHeight, d.scrollHeight);
          return [Math.ceil(w), Math.ceil(h)]; })()
        """
        web.evaluateJavaScript(js) { value, _ in
            MainActor.assumeIsolated {
                guard let pair = value as? [Double], pair.count == 2, pair[0] > 0, pair[1] > 0 else { return }
                let size = NSSize(width: min(800, max(25, pair[0])), height: min(600, max(25, pair[1])))
                if abs(size.width - popover.contentSize.width) > 1 || abs(size.height - popover.contentSize.height) > 1 {
                    popover.contentSize = size
                }
                if let id = self.extensionID { ExtensionPopup.lastSize[id] = size }
                self.reveal()
            }
        }
    }

    // MARK: - the page asking

    func webViewDidClose(_ webView: WKWebView) { close() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { follow() }

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

/// The popup page, as WebKit finds it: in the browser's window, but not
/// among its tabs — which is where Chrome puts a popup too.
@available(macOS 15.4, *)
@MainActor
final class PopupPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?

    init(web: WKWebView) { self.web = web }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { Extensions.shared.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { ExtensionPopup.shared.close() }
}
