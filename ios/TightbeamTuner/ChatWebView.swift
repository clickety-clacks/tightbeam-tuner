import SwiftUI
import WebKit

struct ChatRecoveryBackoff {
    private(set) var nextInterval: TimeInterval = 1
    private let maximumInterval: TimeInterval = 120

    func delay(minimum: TimeInterval = 0) -> TimeInterval {
        max(minimum, nextInterval)
    }

    mutating func advance(minimum: TimeInterval = 0) {
        nextInterval = min(max(minimum, nextInterval) * 2, maximumInterval)
    }

    mutating func nextDelay(minimum: TimeInterval = 0) -> TimeInterval {
        let delay = self.delay(minimum: minimum)
        advance(minimum: minimum)
        return delay
    }

    mutating func reset() {
        nextInterval = 1
    }
}

enum ChatRecoveryAction: Equatable {
    case wait
    case reload
    case reconnect
}

enum ChatRecoveryPolicy {
    static let resumeHealthCheckDelay: TimeInterval = 20

    static func action(
        isReady: Bool,
        connection: ChatHostBridge.Connection,
        canReconnectInPlace: Bool,
        reconnectIsPending: Bool,
        chatReconnectIsPending: Bool = false,
        isUnavailable: Bool = false
    ) -> ChatRecoveryAction {
        guard !reconnectIsPending, !chatReconnectIsPending else { return .wait }

        switch connection {
        case .connected:
            return .wait
        case .reconnecting:
            return isUnavailable ? .reload : .wait
        case .unsupported, .unauthorized:
            return .wait
        case .connecting:
            if isUnavailable { return .reload }
            return isReady ? .wait : .reload
        case .disconnected:
            if isReady {
                return canReconnectInPlace ? .reconnect : .reload
            }
            return .reload
        }
    }
}

/// Hosts Chat in a web view. The page reads its safe area as `env(safe-area-inset-*)`.
/// SwiftUI's own safe areas reach the web view through UIKit, but a SwiftUI `safeAreaInset`
/// does not, so the floating composer's height is added to the page's bottom safe area here.
/// Chat then keeps its newest message and Latest messages clear of the composer.
struct ChatWebView: UIViewControllerRepresentable {
    let url: URL
    let reloadToken: Int
    let bridge: ChatHostBridge
    /// Height of the native composer floating over the bottom of the page.
    var composerInset: CGFloat = 0

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
        // Chat scrolls its own conversation inside the page, so the system's blurred edge under
        // the toolbar would sit over the conversation as a fixed band. Let the toolbar float.
        webView.scrollView.topEdgeEffect.isHidden = true
        // Match Chat's page color so loading and overscroll show linen, not white.
        webView.isOpaque = false
        webView.backgroundColor = UIColor(resource: .chatBackground)
        webView.underPageBackgroundColor = UIColor(resource: .chatBackgroundEnd)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        bridge.webView = webView
        context.coordinator.bridge = bridge
        context.coordinator.webView = webView
        bridge.recoveryStateObserver = { [weak coordinator = context.coordinator] in
            coordinator?.bridgeStateDidChange()
        }
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        let controller = UIViewController()
        controller.view.backgroundColor = UIColor(resource: .chatBackground)
        controller.view.clipsToBounds = true
        let pageController = UIViewController()
        pageController.view = webView
        pageController.additionalSafeAreaInsets.bottom = composerInset
        context.coordinator.pageController = pageController
        controller.addChild(pageController)
        pageController.view.frame = controller.view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(pageController.view)
        pageController.didMove(toParent: controller)
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        if let pageController = context.coordinator.pageController,
           pageController.additionalSafeAreaInsets.bottom != composerInset {
            pageController.additionalSafeAreaInsets.bottom = composerInset
        }
        guard let webView = context.coordinator.webView else { return }
        if context.coordinator.loadedURL != url {
            context.coordinator.cancelRecovery(resetBackoff: true)
            context.coordinator.cancelReconnectAttempt()
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        } else if context.coordinator.reloadToken != reloadToken {
            context.coordinator.cancelRecovery(resetBackoff: true)
            context.coordinator.cancelReconnectAttempt()
            context.coordinator.reloadToken = reloadToken
            webView.reload()
        }
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.stopRecovery()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var loadedURL: URL?
        var reloadToken = 0
        var pageController: UIViewController?
        weak var bridge: ChatHostBridge?
        private var wasInactive = false
        private var recoveryTask: Task<Void, Never>?
        private var recoveryGeneration = 0
        private var recoveryBackoff = ChatRecoveryBackoff()
        private var reconnectIsPending = false
        private var reconnectPendingTimeoutElapsed = false
        private var reconnectTimeoutTask: Task<Void, Never>?

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
            cancelRecovery(resetBackoff: false)
            cancelReconnectAttempt()
            bridge?.pageStarted()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            bridge?.pageEnded()
            scheduleRecovery()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            bridge?.pageEnded()
            scheduleRecovery()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse
        ) async -> WKNavigationResponsePolicy {
            guard navigationResponse.isForMainFrame,
                  let response = navigationResponse.response as? HTTPURLResponse,
                  (500...599).contains(response.statusCode) else { return .allow }
            bridge?.pageEnded()
            scheduleRecovery()
            return .allow
        }

        // iOS can discard a background page's content process. A dead process is an immediate
        // failure signal; otherwise, foreground return gets a delayed health check.
        weak var webView: WKWebView?
        private var needsReload = false
        private var needsHealthCheck = false

        override init() {
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(willResignActive),
                                                   name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                                   name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        @objc private func willResignActive() {
            wasInactive = true
            cancelRecovery(resetBackoff: false)
        }

        @objc private func becameActive() {
            guard let webView else { return }
            let shouldCheckHealth = wasInactive || needsHealthCheck
            wasInactive = false
            needsHealthCheck = false
            if needsReload || webView.url == nil {
                restart(webView)
                return
            }
            // A page whose content process is gone cannot run script.
            webView.evaluateJavaScript("1") { [weak self, weak webView] _, error in
                guard let self, let webView else { return }
                if error != nil {
                    self.restart(webView)
                } else if shouldCheckHealth {
                    self.scheduleRecovery(minimumDelay: ChatRecoveryPolicy.resumeHealthCheckDelay)
                }
            }
        }

        private func restart(_ webView: WKWebView) {
            needsReload = false
            needsHealthCheck = false
            if webView.url == nil, let loadedURL {
                webView.load(URLRequest(url: loadedURL))
            } else {
                webView.reload()
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            cancelRecovery(resetBackoff: false)
            cancelReconnectAttempt()
            bridge?.pageEnded()
            if UIApplication.shared.applicationState == .active {
                restart(webView)
            } else {
                needsReload = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A reload starts from the size chosen when this view opened; reapply the latest.
            webView.evaluateJavaScript("window.__tunerSetTextZoom?.(\(savedZoom))")
            if isReadyAndConnected {
                cancelRecovery(resetBackoff: true)
            } else if bridge?.hostModeDeclined != true {
                // Give Chat longer than its Gateway request budget before resetting an unready page.
                scheduleRecovery(minimumDelay: ChatRecoveryPolicy.resumeHealthCheckDelay)
            }
        }

        func bridgeStateDidChange() {
            if bridge?.hostModeDeclined == true {
                cancelReconnectAttempt()
                cancelRecovery(resetBackoff: true)
            } else if isReadyAndConnected {
                cancelReconnectAttempt()
                cancelRecovery(resetBackoff: true)
            } else if bridge?.connection == .unsupported || bridge?.connection == .unauthorized {
                cancelReconnectAttempt()
                cancelRecovery(resetBackoff: false)
            } else if bridge?.isReconnectInProgress == true
                        || (bridge?.isReady == true && bridge?.connection == .connecting) {
                // Chat is already making progress; don't reset its page or queue another command.
                cancelRecovery(resetBackoff: false)
            } else if bridge?.connection == .disconnected || bridge?.phaseIsUnavailable == true {
                if reconnectIsPending {
                    guard reconnectPendingTimeoutElapsed else { return }
                    cancelReconnectAttempt()
                }
                scheduleRecovery(minimumDelay: ChatRecoveryPolicy.resumeHealthCheckDelay)
            }
        }

        private var isReadyAndConnected: Bool {
            bridge?.isReady == true && bridge?.connection == .connected
        }

        private func scheduleRecovery(minimumDelay: TimeInterval = ChatRecoveryPolicy.resumeHealthCheckDelay) {
            guard recoveryTask == nil else { return }
            guard bridge?.hostModeDeclined != true else { return }
            guard UIApplication.shared.applicationState == .active, let webView else {
                needsHealthCheck = true
                return
            }
            guard !isReadyAndConnected else {
                cancelRecovery(resetBackoff: true)
                return
            }
            guard !reconnectIsPending,
                  bridge?.isReconnectInProgress != true,
                  !(bridge?.isReady == true && bridge?.connection == .connecting) else { return }

            let generation = recoveryGeneration
            let scheduledDelay = recoveryBackoff.delay(minimum: minimumDelay)
            recoveryTask = Task { @MainActor [weak self, weak webView] in
                do {
                    try await Task.sleep(for: .milliseconds(Int64(scheduledDelay * 1_000)))
                } catch {
                    return
                }
                guard let self, self.recoveryGeneration == generation else { return }
                self.recoveryTask = nil
                guard let webView, UIApplication.shared.applicationState == .active else {
                    self.needsHealthCheck = true
                    return
                }
                guard !self.isReadyAndConnected else {
                    self.cancelRecovery(resetBackoff: true)
                    return
                }

                let action = ChatRecoveryPolicy.action(
                    isReady: self.bridge?.isReady == true,
                    connection: self.bridge?.connection ?? .connecting,
                    canReconnectInPlace: self.bridge?.canReconnectInPlace == true,
                    reconnectIsPending: self.reconnectIsPending,
                    chatReconnectIsPending: self.bridge?.isReconnectInProgress == true,
                    isUnavailable: self.bridge?.phaseIsUnavailable == true
                )
                switch action {
                case .wait:
                    return
                case .reload:
                    self.recoveryBackoff.advance(minimum: minimumDelay)
                    webView.reload()
                case .reconnect:
                    self.recoveryBackoff.advance(minimum: minimumDelay)
                    self.beginReconnect()
                }
            }
        }

        private func beginReconnect() {
            guard !reconnectIsPending, let bridge else { return }
            reconnectIsPending = true
            reconnectPendingTimeoutElapsed = false
            bridge.reconnect()
            reconnectTimeoutTask?.cancel()
            reconnectTimeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(ChatRecoveryPolicy.resumeHealthCheckDelay))
                } catch {
                    return
                }
                guard let self else { return }
                if self.bridge?.connection == .reconnecting || self.bridge?.connection == .connecting {
                    self.reconnectPendingTimeoutElapsed = true
                    self.reconnectTimeoutTask = nil
                    return
                }
                if self.bridge?.connection == .disconnected {
                    self.cancelReconnectAttempt()
                    self.scheduleRecovery(minimumDelay: ChatRecoveryPolicy.resumeHealthCheckDelay)
                } else {
                    self.reconnectPendingTimeoutElapsed = true
                    self.reconnectTimeoutTask = nil
                }
            }
        }

        private func cancelReconnectAttempt() {
            reconnectTimeoutTask?.cancel()
            reconnectTimeoutTask = nil
            reconnectIsPending = false
            reconnectPendingTimeoutElapsed = false
        }

        func cancelRecovery(resetBackoff: Bool) {
            recoveryGeneration &+= 1
            recoveryTask?.cancel()
            recoveryTask = nil
            if resetBackoff { recoveryBackoff.reset() }
        }

        func stopRecovery() {
            cancelRecovery(resetBackoff: true)
            cancelReconnectAttempt()
            bridge?.recoveryStateObserver = nil
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

