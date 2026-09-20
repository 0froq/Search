import WebKit

// What the page says about itself that a browser has to know: where the
// keyboard is, whether it is about to take the screen, and whether there is a
// sign-in on it — and when one has just been sent, so the password can be
// offered a place in the keychain.
//
// Filling goes through the field's own setter and fires the events a keystroke
// would. Assigning to .value behind a framework's back leaves it thinking the
// box is still empty, which is a sign-in button that stays grey.

final class FormRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeForms"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String
        else { return }
        MainActor.assumeIsolated {
            switch kind {
            case "form":
                tab?.foundSignIn()
            case "submit":
                tab?.sentSignIn(
                    user: body["user"] as? String ?? "",
                    password: body["password"] as? String ?? ""
                )
            case "focus":
                tab?.typing = body["typing"] as? Bool ?? false
            case "fullscreen":
                tab?.immersed = body["on"] as? Bool ?? false
            default:
                break
            }
        }
    }

    /// Whether to keep claiming passkeys are possible here.
    ///
    /// They are not, and it isn't a matter of code: Apple gates Touch ID and
    /// iCloud passkeys inside a third-party WKWebView behind a managed
    /// entitlement, and the cross-device route over Bluetooth behind the same
    /// one. Measured on this machine, WebKit answers
    /// isUserVerifyingPlatformAuthenticatorAvailable() with false.
    ///
    /// Meanwhile the API object exists, so sites feature-detect it, offer the
    /// passkey path, and strand you there. Taking the object away is what sends
    /// them straight to the password — the one that works. Turn this back on
    /// from Settings the day the app is signed with the entitlement.
    static var passkeysOffered: Bool {
        get { Store.settings.bool(forKey: "passkeys") }
        set { Store.settings.set(newValue, forKey: "passkeys") }
    }

    /// Only the passkey object goes. navigator.credentials itself stays: sites
    /// use it for stored passwords too, and that half still works.
    static let withoutPasskeys = """
    (function () {
      try {
        Object.defineProperty(window, 'PublicKeyCredential', {
          value: undefined, configurable: true, writable: true
        });
      } catch (e) {
        try { delete window.PublicKeyCredential; } catch (ignored) {}
      }
    })();
    """

    static let script = """
    (function () {
      if (window.__officeForms) return;

      // The password box, and the last box before it that could hold a name.
      function pair() {
        var boxes = document.querySelectorAll('input[type="password"]');
        var pass = null;
        for (var p = 0; p < boxes.length; p++) {
          var b = boxes[p];
          var r = b.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) { pass = b; break; }
        }
        if (!pass) return null;
        var scope = pass.form || (pass.closest && pass.closest('form')) || document;
        var all = scope.querySelectorAll('input');
        var user = null;
        for (var i = 0; i < all.length; i++) {
          if (all[i] === pass) break;
          var kind = (all[i].type || 'text').toLowerCase();
          if (kind === 'text' || kind === 'email' || kind === 'tel') user = all[i];
        }
        return { user: user, pass: pass };
      }

      function put(box, value) {
        if (!box) return;
        var setter = Object.getOwnPropertyDescriptor(
          window.HTMLInputElement.prototype, 'value'
        );
        if (setter && setter.set) { setter.set.call(box, value); } else { box.value = value; }
        box.dispatchEvent(new Event('input', { bubbles: true }));
        box.dispatchEvent(new Event('change', { bubbles: true }));
      }

      window.__officeForms = {
        fill: function (user, password) {
          var both = pair();
          if (!both) return false;
          if (both.user && !both.user.value) put(both.user, user);
          put(both.pass, password);
          return true;
        }
      };

      var offered = '';
      function offer() {
        var both = pair();
        if (!both || !both.pass.value) return;
        var user = both.user ? both.user.value : '';
        // Once per pair of values: a click on "sign in" and the form's own
        // submit are usually the same event twice.
        var stamp = user + '|' + both.pass.value;
        if (stamp === offered) return;
        offered = stamp;
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'submit', user: user, password: both.pass.value
        });
      }

      document.addEventListener('submit', offer, true);
      document.addEventListener('keydown', function (e) {
        if (e.key !== 'Enter') return;
        var both = pair();
        if (both && (document.activeElement === both.pass || document.activeElement === both.user)) offer();
      }, true);
      // Plenty of sign-in buttons aren't in a form and never fire submit.
      document.addEventListener('click', function (e) {
        var el = e.target;
        if (!el || !el.closest) return;
        if (el.closest('button, input[type="submit"], [role="button"]')) {
          setTimeout(offer, 0);
        }
      }, true);

      var told = false;
      function tell() {
        if (told || !pair()) return;
        told = true;
        window.webkit.messageHandlers.officeForms.postMessage({ kind: 'form' });
      }
      if (document.readyState === 'complete') { tell(); }
      else { window.addEventListener('load', tell); }
      // A form the page builds for itself, a moment after it loads — or the
      // password step of a sign-in that asks for the name first.
      setTimeout(tell, 700);
      setTimeout(tell, 2200);
      new MutationObserver(function () {
        if (!told) tell();
        else if (!pair()) told = false;
      }).observe(document.documentElement, { childList: true, subtree: true });

      // Whether the caret is somewhere on the page that takes typing.
      //
      // The browser gives Tab to its own row of tabs, which is right until you
      // are filling something in: plenty of fields offer a completion you take
      // with Tab, and stealing the key there would make them unusable.
      function editable(el) {
        if (!el) return false;
        var tag = (el.tagName || '').toLowerCase();
        if (tag === 'textarea') return true;
        if (el.isContentEditable === true) return true;
        if (tag !== 'input') return false;
        var kind = (el.type || 'text').toLowerCase();
        return ['text', 'search', 'email', 'url', 'tel', 'password', 'number',
                'date', 'datetime-local', 'month', 'week', 'time'].indexOf(kind) >= 0;
      }

      function caret() {
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'focus',
          typing: editable(document.activeElement)
        });
      }

      // Going full screen, announced before it happens rather than after.
      //
      // WebKit puts the video in a window of its own and slides ours away
      // behind it. For a frame or two ours is still on screen, and everything
      // this browser draws is white — which is the pale band across the top of
      // the animation. Knowing a moment early is enough to paint it black.
      function immersed() {
        var on = !!(document.fullscreenElement || document.webkitFullscreenElement);
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'fullscreen', on: on
        });
      }
      document.addEventListener('fullscreenchange', immersed, true);
      document.addEventListener('webkitfullscreenchange', immersed, true);

      // The asking, caught before the animation starts.
      ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']
        .forEach(function (name) {
          var was = Element.prototype[name];
          if (!was) return;
          Element.prototype[name] = function () {
            window.webkit.messageHandlers.officeForms.postMessage({
              kind: 'fullscreen', on: true
            });
            return was.apply(this, arguments);
          };
        });

      document.addEventListener('focusin', caret, true);
      document.addEventListener('focusout', function () { setTimeout(caret, 0); }, true);
      document.addEventListener('mouseup', function () { setTimeout(caret, 0); }, true);
      caret();
    })();
    """
}
