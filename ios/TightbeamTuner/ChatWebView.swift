import SwiftUI
import WebKit

/// Hosts Chat in a web view. The view controller carries extra bottom safe area for
/// controls floating over the page, which Chat reads as `env(safe-area-inset-bottom)`.
struct ChatWebView: UIViewControllerRepresentable {
    let url: URL
    let reloadToken: Int
    let bridge: ChatHostBridge
    var floatingBottomInset: CGFloat = 0

    static let pinchHandlerName = "tunerPinch"

    // Page gestures: pinch for text size, and swipe down to put the keyboard away.
    // WebKit claims pinches before a native gesture recognizer can see them, so the page handles
    // its own pinch gestures. Pinching sets the text size, the same setting Safari's text size
    // control uses, so text reflows instead of the page magnifying. The app keeps the result.
    private static let pinchScript = #"""
        (() => {
          const viewport = document.querySelector('meta[name=viewport]');
          if (viewport && !/user-scalable/.test(viewport.content)) viewport.content += ', maximum-scale=1, user-scalable=no';
          let zoom = Number(window.__tunerTextZoom) || 1;
          let start = zoom;
          const apply = () => { document.documentElement.style.webkitTextSizeAdjust = Math.round(zoom * 100) + '%'; };
          window.__tunerSetTextZoom = (value) => { zoom = value; apply(); };
          apply();
          document.addEventListener('gesturestart', (event) => { event.preventDefault(); start = zoom; }, { passive: false });
          document.addEventListener('gesturechange', (event) => {
            event.preventDefault();
            // Step in 5% increments so text reflows only when its size visibly changes.
            const next = Math.min(Math.max(Math.round(start * event.scale * 20) / 20, MIN_ZOOM), MAX_ZOOM);
            if (next !== zoom) { zoom = next; apply(); }
          }, { passive: false });
          document.addEventListener('gestureend', (event) => {
            event.preventDefault();
            window.webkit.messageHandlers.tunerPinch.postMessage({ zoom });
          }, { passive: false });
          // Swiping down on the conversation puts the keyboard away, as in Messages.
          let touchY = null;
          document.addEventListener('touchstart', (event) => {
            touchY = event.touches.length === 1 ? event.touches[0].clientY : null;
          }, { passive: true });
          document.addEventListener('touchmove', (event) => {
            if (touchY === null || event.touches.length !== 1) return;
            if (event.touches[0].clientY - touchY < 24) return;
            touchY = null;
            const active = document.activeElement;
            if (active && /^(TEXTAREA|INPUT)$/.test(active.tagName)) active.blur();
            window.webkit.messageHandlers.tunerPinch.postMessage({ dismissKeyboard: true });
          }, { passive: true });
        })();
        """#

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(bridge.declarationScript)
        configuration.userContentController.add(bridge, name: ChatHostBridge.messageHandlerName)
        let zoomRange = Coordinator.zoomRange
        let pinchScript = "window.__tunerTextZoom = \(context.coordinator.savedZoom);\n" + Self.pinchScript
            .replacingOccurrences(of: "MIN_ZOOM", with: "\(zoomRange.lowerBound)")
            .replacingOccurrences(of: "MAX_ZOOM", with: "\(zoomRange.upperBound)")
        configuration.userContentController.addUserScript(WKUserScript(
            source: pinchScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController.add(context.coordinator, name: Self.pinchHandlerName)
        let webView = ChatPageView(frame: .zero, configuration: configuration)
        webView.bridge = bridge
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Match Chat's page color so loading and overscroll show linen, not white.
        webView.isOpaque = false
        webView.backgroundColor = UIColor(resource: .nordicBackground)
        webView.underPageBackgroundColor = UIColor(resource: .nordicBackground)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        bridge.webView = webView
        context.coordinator.bridge = bridge
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        let controller = UIViewController()
        controller.view = webView
        controller.additionalSafeAreaInsets.bottom = floatingBottomInset
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let webView = controller.view as? WKWebView else { return }
        if controller.additionalSafeAreaInsets.bottom != floatingBottomInset {
            controller.additionalSafeAreaInsets.bottom = floatingBottomInset
        }
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        } else if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            webView.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var loadedURL: URL?
        var reloadToken = 0
        weak var bridge: ChatHostBridge?

        // Text size set by pinching, shared by every chat and kept across launches.
        private static let zoomKey = "chatTextZoom"
        static let zoomRange: ClosedRange<Double> = 0.7...2.0

        var savedZoom: Double {
            let value = UserDefaults.standard.double(forKey: Self.zoomKey)
            return value > 0 ? min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) : 1
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any], body["dismissKeyboard"] as? Bool == true {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                return
            }
            guard let body = message.body as? [String: Any],
                  let zoom = (body["zoom"] as? NSNumber)?.doubleValue,
                  Self.zoomRange.contains(zoom) else { return }
            UserDefaults.standard.set(zoom, forKey: Self.zoomKey)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            bridge?.pageStarted()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            bridge?.pageEnded()
        }

        // iOS can discard a background page's content process, which leaves the chat blank on
        // return. Reload it as soon as Tuner is in front again.
        weak var webView: WKWebView?
        private var needsReload = false

        override init() {
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                                   name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        @objc private func becameActive() {
            guard let webView else { return }
            if needsReload || webView.url == nil { restart(webView); return }
            // A page whose content process is gone cannot run script.
            webView.evaluateJavaScript("1") { [weak self, weak webView] _, error in
                if error != nil, let webView { self?.restart(webView) }
            }
        }

        private func restart(_ webView: WKWebView) {
            needsReload = false
            if webView.url == nil, let loadedURL {
                webView.load(URLRequest(url: loadedURL))
            } else {
                webView.reload()
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            bridge?.pageEnded()
            if UIApplication.shared.applicationState == .active { restart(webView) } else { needsReload = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A reload starts from the size chosen when this view opened; reapply the latest.
            webView.evaluateJavaScript("window.__tunerSetTextZoom?.(\(savedZoom))")
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                await UIApplication.shared.open(url)
                return .cancel
            } else {
                return .allow
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { UIApplication.shared.open(url) }
            return nil
        }
    }
}

/// The Chat page. Tapping a web page normally takes the keyboard from whatever field had it.
/// While Tuner's message field is typing, a tap on the conversation (or on Latest messages)
/// leaves the keyboard with it, as in Messages.
private final class ChatPageView: WKWebView {
    weak var bridge: ChatHostBridge?

    override func becomeFirstResponder() -> Bool {
        // When Chat's own composer is in use, the page takes the keyboard as usual.
        guard let bridge, bridge.hostComposerActive, bridge.nativeComposerFocused else {
            return super.becomeFirstResponder()
        }
        return false
    }
}

