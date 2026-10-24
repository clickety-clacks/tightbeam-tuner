import SwiftUI
import WebKit

private final class ChatViewportWebView: WKWebView {
    var onLayout: ((ChatViewportWebView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onLayout?(self)
    }
}

/// Hosts Chat in a web view. The view controller carries extra bottom safe area for
/// controls floating over the page, which Chat reads as `env(safe-area-inset-bottom)`.
struct ChatWebView: UIViewControllerRepresentable {
    let url: URL
    let reloadToken: Int
    let bridge: ChatHostBridge
    var floatingBottomInset: CGFloat = 0

    private static let sideInsets = #"""
        const style = document.createElement('style');
        style.textContent = `
          html.tuner-side-insets .tb-chat-viewport {
            padding-left: calc(clamp(.85rem, 4vw, 2.2rem) + max(env(safe-area-inset-left), var(--tuner-safe-left, 0px))) !important;
            padding-right: calc(clamp(.85rem, 4vw, 2.2rem) + max(env(safe-area-inset-right), var(--tuner-safe-right, 0px))) !important;
          }
          html.tuner-side-insets .tb-chat-composer {
            left: calc(clamp(.65rem, 3vw, 1.4rem) + max(env(safe-area-inset-left), var(--tuner-safe-left, 0px))) !important;
            right: calc(clamp(.65rem, 3vw, 1.4rem) + max(env(safe-area-inset-right), var(--tuner-safe-right, 0px))) !important;
          }
        `;
        document.head.appendChild(style);
        """#

    static let pinchHandlerName = "tunerPinch"

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
        })();
        """#

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(bridge.declarationScript)
        configuration.userContentController.add(bridge, name: ChatHostBridge.messageHandlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.sideInsets,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
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
        let webView = ChatViewportWebView(frame: .zero, configuration: configuration)
        webView.onLayout = { [weak coordinator = context.coordinator] webView in
            coordinator?.updateLayout(webView)
        }
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
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        let controller = UIViewController()
        controller.view = webView
        controller.additionalSafeAreaInsets.bottom = floatingBottomInset
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        if controller.additionalSafeAreaInsets.bottom != floatingBottomInset {
            controller.additionalSafeAreaInsets.bottom = floatingBottomInset
        }
        guard let webView = controller.view as? WKWebView else { return }
        context.coordinator.updateLayout(webView)
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
        private var appliedLayout: (Bool, CGFloat, CGFloat)?

        // Text size set by pinching, shared by every chat and kept across launches.
        private static let zoomKey = "chatTextZoom"
        static let zoomRange: ClosedRange<Double> = 0.7...2.0

        var savedZoom: Double {
            let value = UserDefaults.standard.double(forKey: Self.zoomKey)
            return value > 0 ? min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) : 1
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let zoom = (body["zoom"] as? NSNumber)?.doubleValue,
                  Self.zoomRange.contains(zoom) else { return }
            UserDefaults.standard.set(zoom, forKey: Self.zoomKey)
        }

        func updateLayout(_ webView: WKWebView, force: Bool = false) {
            // Keep the transcript clear of any side bars the system reserves, in any orientation
            // (landscape notch, or the vertical bar on a folded iPhone Duo in portrait).
            guard webView.window != nil else { return }
            let leading = max(0, webView.safeAreaInsets.left)
            let trailing = max(0, webView.safeAreaInsets.right)
            let inset = leading > 0 || trailing > 0
            if !force, let appliedLayout,
               appliedLayout.0 == inset && appliedLayout.1 == leading && appliedLayout.2 == trailing { return }
            appliedLayout = (inset, leading, trailing)
            let script = "document.documentElement.classList.toggle('tuner-side-insets', \(inset)); document.documentElement.style.setProperty('--tuner-safe-left', '\(Double(leading))px'); document.documentElement.style.setProperty('--tuner-safe-right', '\(Double(trailing))px')"
            webView.evaluateJavaScript(script)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            bridge?.pageStarted()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            bridge?.pageEnded()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            bridge?.pageEnded()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateLayout(webView, force: true)
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
