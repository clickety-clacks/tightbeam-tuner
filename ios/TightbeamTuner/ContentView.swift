import SwiftUI

struct ContentView: View {
    @State private var store = TunerStore()
    @State private var repliedFeed = RepliedFeed()
    @State private var showingSettings = false
    @State private var reloadToken = 0
    @State private var whatsNew: [ReleaseNote] = []
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// Retains the in-process sidebar position across background layout changes.
    @State private var visibilityBeforeInactive: NavigationSplitViewVisibility?
    @State private var sidebarSearchFrame: CGRect?
    @State private var compactSearchKeyboardDownFrame: CGRect?
    @State private var compactSearchKeyboardUpFrame: CGRect?
    @State private var softwareKeyboardVisible = false
    @State private var sidebarQuery = ""
    @State private var selectedArchetypes: Set<String> = []
    /// In portrait on a wide screen the agent list floats over the chat instead of beside it.
    @State private var portrait = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    /// Native composer drafts per agent. Kept in app defaults, not scene storage, so a draft
    /// survives a force-quit or iOS ending Tuner in the background. Send state is not kept.
    @AppStorage("composerDrafts") private var draftsData = Data()

    private var splitViewColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { columnVisibility },
            set: { visibility in
                if scenePhase != .active && visibilityBeforeInactive == nil {
                    visibilityBeforeInactive = columnVisibility
#if DEBUG
                    print("NAVIGATION_STATE_SNAPSHOT source=visibility-binding phase=\(scenePhase) visibility=\(columnVisibility)")
#endif
                }
                columnVisibility = visibility
            }
        )
    }

    private func draftBinding(for agentID: String) -> Binding<String> {
        Binding(
            get: { (try? JSONDecoder().decode([String: String].self, from: draftsData))?[agentID] ?? "" },
            set: { value in
                var drafts = (try? JSONDecoder().decode([String: String].self, from: draftsData)) ?? [:]
                drafts[agentID] = value.isEmpty ? nil : value
                draftsData = (try? JSONEncoder().encode(drafts)) ?? Data()
            }
        )
    }

    /// In compact width the sidebar replaces the detail chat. In regular width the selected
    /// detail stays on screen under a floating sidebar.
    private var shownChatSessionKey: String? {
        let selectedSessionKey = store.selectedAgent.flatMap { agent in
            store.connection.chatURL(for: agent) == nil ? nil : agent.id
        }
        return RepliedShownChat(
            selectedSessionKey: selectedSessionKey,
            compactWidth: horizontalSizeClass == .compact,
            compactDetailSelected: preferredCompactColumn == .detail,
            sceneIsActive: scenePhase == .active
        ).sessionKeyOnScreen
    }

    private func openRepliedAgent(_ id: String) {
        let selectionChanged = store.selectedID != id
        if selectionChanged {
            // Commit the split-view selection before clearing the row. The selection change
            // handler below records the recent visit and local read position.
            store.selectedID = id
        }
        preferredCompactColumn = .detail
        // A floating agent list closes once an agent is chosen, like a popover.
        if horizontalSizeClass == .regular && portrait { columnVisibility = .detailOnly }
        if !selectionChanged {
            // The selected chat can be hidden behind the compact list. Make it visible before
            // clearing a Replied row whose selection value is already current.
            repliedFeed.markOpened(id)
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: splitViewColumnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            AgentSidebar(store: store, repliedFeed: repliedFeed, openRepliedAgent: openRepliedAgent,
                         query: $sidebarQuery, selectedArchetypes: $selectedArchetypes,
                         isRegularWidthIPad: UIDevice.current.userInterfaceIdiom == .pad
                            && horizontalSizeClass == .regular)
                .navigationTitle("Agents")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    }
                }
        } detail: {
            Group {
                if let agent = store.selectedAgent, let url = store.connection.chatURL(for: agent) {
                    AgentChatView(url: url, reloadToken: reloadToken, draft: draftBinding(for: agent.id),
                                  repliedFeed: repliedFeed,
                                  sidebarSearchFrame: sidebarSearchFrame,
                                  compactSearchKeyboardDownFrame: compactSearchKeyboardDownFrame,
                                  compactSearchKeyboardUpFrame: compactSearchKeyboardUpFrame,
                                  softwareKeyboardVisible: softwareKeyboardVisible,
                                  isCompact: horizontalSizeClass == .compact,
                                  isPortrait: portrait)
                        .id(agent.id)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Reload Chat", systemImage: "arrow.clockwise") { reloadToken += 1 }
                            }
                        }
                } else {
                    ContentUnavailableView("Choose an agent", systemImage: "bubble.left.and.bubble.right")
                        .foregroundStyle(Color.nordicSecondaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if store.selectedAgent.flatMap({ store.connection.chatURL(for: $0) }) != nil {
                    Color.chatBackground
                } else {
                    TunerCanvasBackground()
                }
            }
        }
        .background {
            // SwiftUI does not expose the visible .searchable capsule's frame. Find it from
            // the text field so the composer follows the current navigation layout.
            SidebarSearchFrameReader(
                prompt: "Filter agents",
                usesCompactFieldFrame: horizontalSizeClass == .compact
            ) { measurement in
                softwareKeyboardVisible = measurement.softwareKeyboardVisible
                sidebarSearchFrame = measurement.capsule
                guard let capsule = measurement.capsule else { return }
                if measurement.keyboardFocused {
                    compactSearchKeyboardUpFrame = capsule
                } else {
                    compactSearchKeyboardDownFrame = capsule
                }
            }
            .accessibilityHidden(true)
        }
        .font(TunerTypography.body)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store, showing: $showingSettings)
                .interactiveDismissDisabled(!store.connection.isComplete)
        }
        .sheet(isPresented: Binding(get: { !whatsNew.isEmpty }, set: { if !$0 { whatsNew = [] } })) {
            WhatsNewView(notes: whatsNew)
        }
        .task {
            // A first install goes to setup instead of release notes.
            whatsNew = ReleaseNotes.takeUnseen(firstInstall: !store.connection.isComplete)
            if store.connection.isComplete { await store.refresh() }
            else { showingSettings = true }
        }
        .task(id: RepliedTaskKey(
            gateway: store.connection.gateway,
            user: store.connection.tightbeamUser,
            sessionKeys: store.agents.map(\.id).sorted()
        )) {
            let sessionKeys = store.agents.map(\.id).sorted()
            guard store.connection.isComplete else { return }
            await repliedFeed.run(gateway: store.connection.gateway, user: store.connection.tightbeamUser,
                                  sessionKeys: sessionKeys,
                                  onRosterEvent: { frame in store.applyRosterEvent(frame) },
                                  onReconnect: { await store.refresh() })
        }
        .onChange(of: shownChatSessionKey, initial: true) { _, key in
            repliedFeed.updateShownSessionKey(key)
        }
        .onChange(of: store.selectedID) { _, value in
            if let value, let agent = store.agents.first(where: { $0.id == value }) {
                store.select(agent)
                repliedFeed.markOpened(value)
                preferredCompactColumn = .detail
                // A floating agent list closes once an agent is chosen, like a popover.
                if horizontalSizeClass == .regular && portrait { columnVisibility = .detailOnly }
            }
        }
        .onChange(of: columnVisibility) { previousVisibility, visibility in
            if scenePhase != .active && visibilityBeforeInactive == nil {
                visibilityBeforeInactive = previousVisibility
#if DEBUG
                print("NAVIGATION_STATE_SNAPSHOT source=visibility-binding phase=\(scenePhase) visibility=\(previousVisibility)")
#endif
            }
#if DEBUG
            print("NAVIGATION_VISIBILITY phase=\(scenePhase) visibility=\(visibility) portrait=\(portrait) sizeClass=\(String(describing: horizontalSizeClass))")
#endif
            // Opening the agent list puts the keyboard away, so the list is not half covered.
            if visibility != .detailOnly {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
#if DEBUG
            print("NAVIGATION_SCENE old=\(oldPhase) new=\(newPhase) visibility=\(columnVisibility) portrait=\(portrait) sizeClass=\(String(describing: horizontalSizeClass))")
#endif
            if oldPhase != .active && newPhase == .active {
                Task { await store.refresh() }
            }
            if oldPhase == .active && newPhase != .active {
                // Coalesce live roster changes into one snapshot when leaving the foreground.
                store.persistRosterSnapshotIfAvailable()
                if visibilityBeforeInactive == nil {
                    visibilityBeforeInactive = columnVisibility
                }
#if DEBUG
                if let visibilityBeforeInactive {
                    print("NAVIGATION_STATE_SNAPSHOT source=scene-phase phase=\(newPhase) visibility=\(visibilityBeforeInactive)")
                }
#endif
            } else if oldPhase != .active && newPhase == .active,
                      let preservedVisibility = visibilityBeforeInactive {
                let currentVisibility = columnVisibility
                let didRestore = currentVisibility != preservedVisibility
                visibilityBeforeInactive = nil
                if didRestore {
                    columnVisibility = preservedVisibility
                }
#if DEBUG
                print("NAVIGATION_STATE_RESTORE saved=\(preservedVisibility) current=\(currentVisibility) applied=\(didRestore)")
#endif
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.height > $0.size.width } action: { isPortrait in
            portrait = isPortrait
            let wouldShowSidebar = !isPortrait && columnVisibility == .detailOnly
#if DEBUG
            let geometryDecision = scenePhase == .active
                ? (wouldShowSidebar ? "show-sidebar" : "keep-visibility")
                : (wouldShowSidebar ? "guarded-inactive" : "keep-visibility-inactive")
            print("NAVIGATION_GEOMETRY phase=\(scenePhase) portrait=\(isPortrait) visibility=\(columnVisibility) sizeClass=\(String(describing: horizontalSizeClass)) decision=\(geometryDecision)")
#endif
            // Side by side again in landscape: bring the list back if it was closed in portrait.
            if scenePhase == .active && wouldShowSidebar { columnVisibility = .automatic }
        }
    }
}

/// Reports the visible search capsule and software-keyboard state in window coordinates.
private struct SidebarSearchFrameReader: UIViewRepresentable {
    let prompt: String
    let usesCompactFieldFrame: Bool
    let onFrameChange: (Measurement) -> Void

    struct Measurement: Equatable {
        let capsule: CGRect?
        let keyboardFocused: Bool
        let softwareKeyboardVisible: Bool
    }

    func makeUIView(context: Context) -> UIView {
        let view = SearchFieldProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        view.prompt = prompt
        view.usesCompactFieldFrame = usesCompactFieldFrame
        view.onFrameChange = onFrameChange
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let view = view as? SearchFieldProbeView else { return }
        view.prompt = prompt
        view.usesCompactFieldFrame = usesCompactFieldFrame
        view.onFrameChange = onFrameChange
        view.scheduleRead()
    }

    private final class SearchFieldProbeView: UIView {
        var prompt = ""
        var usesCompactFieldFrame = false
        var onFrameChange: ((Measurement) -> Void)?
        private var lastMeasurement: Measurement?
        private var keyboardScreenFrame: CGRect?
        private weak var keyboardFrameScreen: UIScreen?
        private var keyboardVisibilitySnapshot: Bool?
        private var needsKeyboardVisibilityReconciliation = false
        private var keyboardObserverGeneration = 0
        private var keyboardObservers: [NSObjectProtocol] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            keyboardObserverGeneration += 1
            removeKeyboardObservers()
            guard let window else {
                keyboardScreenFrame = nil
                keyboardFrameScreen = nil
                keyboardVisibilitySnapshot = nil
                needsKeyboardVisibilityReconciliation = false
                scheduleRead()
                return
            }

            if let keyboardFrameScreen, keyboardFrameScreen !== window.screen {
                keyboardScreenFrame = nil
                self.keyboardFrameScreen = nil
            }
            installKeyboardObservers()
            // Notifications received while detached have no reliable window/screen context.
            // Reconcile from UIKit's current guide after this view has completed its next layout.
            keyboardVisibilitySnapshot = nil
            needsKeyboardVisibilityReconciliation = true
            scheduleRead()
        }

        private func installKeyboardObservers() {
            guard keyboardObservers.isEmpty else { return }
            let center = NotificationCenter.default
            let observerGeneration = keyboardObserverGeneration
            keyboardObservers = [
                center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                                  object: nil, queue: .main) { [weak self] notification in
                    let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                    Task { @MainActor [weak self] in
                        self?.keyboardFrameDidChange(frame, observerGeneration: observerGeneration)
                    }
                },
                center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                  object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.keyboardFrameDidChange(nil, observerGeneration: observerGeneration)
                    }
                },
            ]
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // This background fills the split view, so a window resize schedules a fresh read.
            scheduleRead()
        }

        func scheduleRead() {
            // The sidebar may lay out after this view. Read its final frame on the next turn.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.needsKeyboardVisibilityReconciliation {
                    self.reconcileKeyboardVisibilityFromLayoutGuide()
                }
                let measurement = self.searchMeasurement()
                guard measurement != self.lastMeasurement else { return }
                self.lastMeasurement = measurement
                self.onFrameChange?(measurement)
            }
        }

        deinit {
            removeKeyboardObservers()
        }

        private func searchMeasurement() -> Measurement {
            let keyboardVisible = softwareKeyboardIsVisible
            guard let window,
                  let field = findSearchField(in: window),
                  !field.isHidden,
                  field.alpha > 0.01 else {
                return Measurement(capsule: nil, keyboardFocused: false,
                                   softwareKeyboardVisible: keyboardVisible)
            }

            let fieldFrame = field.convert(field.bounds, to: window)
            if usesCompactFieldFrame {
                let visibleField = window.bounds.intersects(fieldFrame) ? fieldFrame : nil
                return Measurement(capsule: visibleField, keyboardFocused: field.isFirstResponder,
                                   softwareKeyboardVisible: keyboardVisible)
            }

            var capsuleFrame = fieldFrame
            var ancestor = field.superview
            // On iPad the search field itself is the capsule; larger ancestors are toolbar containers.
            while let view = ancestor {
                let frame = view.convert(view.bounds, to: window)
                guard frame.minX <= fieldFrame.minX + 0.5,
                      frame.minY <= fieldFrame.minY + 0.5,
                      frame.maxX >= fieldFrame.maxX - 0.5,
                      frame.maxY >= fieldFrame.maxY - 0.5 else { break }
                let insets = [
                    fieldFrame.minX - frame.minX,
                    fieldFrame.minY - frame.minY,
                    frame.maxX - fieldFrame.maxX,
                    frame.maxY - fieldFrame.maxY,
                ]
                guard insets.allSatisfy({ $0 <= 8 }) else { break }
                if insets.contains(where: { $0 > 0.5 }) {
                    capsuleFrame = frame
                    break
                }
                capsuleFrame = frame
                ancestor = view.superview
            }
            let visibleCapsule = window.bounds.intersects(capsuleFrame) ? capsuleFrame : nil
            return Measurement(capsule: visibleCapsule, keyboardFocused: field.isFirstResponder,
                               softwareKeyboardVisible: keyboardVisible)
        }

        private var softwareKeyboardIsVisible: Bool {
            if let keyboardVisibilitySnapshot { return keyboardVisibilitySnapshot }
            guard let window, let keyboardScreenFrame,
                  keyboardFrameScreen === window.screen else { return false }
            let keyboardFrame = window.convert(keyboardScreenFrame, from: window.screen.coordinateSpace)
            let intersection = window.bounds.intersection(keyboardFrame)
            return !intersection.isNull && intersection.width > 1 && intersection.height > 1
        }

        private func keyboardFrameDidChange(_ frame: CGRect?, observerGeneration: Int) {
            guard self.keyboardObserverGeneration == observerGeneration, let window else { return }
            keyboardScreenFrame = frame
            keyboardFrameScreen = frame == nil ? nil : window.screen
            keyboardVisibilitySnapshot = nil
            needsKeyboardVisibilityReconciliation = false
            scheduleRead()
        }

        private func reconcileKeyboardVisibilityFromLayoutGuide() {
            guard window != nil else {
                keyboardVisibilitySnapshot = nil
                needsKeyboardVisibilityReconciliation = false
                return
            }
            // A newly attached probe can receive this read before its first nonzero layout.
            // Keep the reconciliation pending until UIKit has usable bounds.
            guard bounds.width > 1, bounds.height > 1 else { return }

            layoutIfNeeded()
            let keyboardArea = keyboardLayoutGuide.layoutFrame
            let intersection = bounds.intersection(keyboardArea)
            // With no keyboard, UIKit places this guide at the bottom safe area.
            // Require space beyond that inset so the home-indicator area is not
            // mistaken for a visible software keyboard.
            keyboardVisibilitySnapshot = !intersection.isNull
                && intersection.width > 1
                && intersection.height > safeAreaInsets.bottom + 1
            needsKeyboardVisibilityReconciliation = false
        }

        private func removeKeyboardObservers() {
            keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
            keyboardObservers.removeAll()
        }

        private func findSearchField(in view: UIView) -> UITextField? {
            if let field = view as? UITextField,
               field.placeholder == prompt || field.accessibilityLabel == prompt {
                return field
            }
            for subview in view.subviews {
                if let field = findSearchField(in: subview) { return field }
            }
            return nil
        }
    }
}

/// Reports the docked keyboard's overlap with the sidebar, in sidebar coordinates.
private struct SidebarKeyboardOcclusionReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    fileprivate func makeUIView(context: Context) -> KeyboardOcclusionProbeView {
        let view = KeyboardOcclusionProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = onChange
        return view
    }

    fileprivate func updateUIView(_ view: KeyboardOcclusionProbeView, context: Context) {
        view.onChange = onChange
        view.updateOcclusion()
    }

    fileprivate final class KeyboardOcclusionProbeView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var keyboardScreenFrame: CGRect?
        private var observers: [NSObjectProtocol] = []
        private var lastOverlap: CGFloat = -1

        override func didMoveToWindow() {
            super.didMoveToWindow()
            removeKeyboardObservers()
            keyboardScreenFrame = nil
            guard window != nil else {
                publish(0)
                return
            }

            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                                  object: nil, queue: .main) { [weak self] notification in
                    let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                    Task { @MainActor [weak self] in
                        self?.keyboardFrameDidChange(frame)
                    }
                },
                center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                  object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.keyboardFrameDidChange(nil)
                    }
                },
            ]
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateOcclusion()
        }

        deinit {
            removeKeyboardObservers()
        }

        func updateOcclusion() {
            guard let window, let keyboardScreenFrame else {
                publish(0)
                return
            }

            let keyboardFrame = window.convert(keyboardScreenFrame, from: window.screen.coordinateSpace)
            let sidebarFrame = convert(bounds, to: window)
            let intersection = sidebarFrame.intersection(keyboardFrame)
            let keyboardIsDocked = keyboardFrame.maxY >= window.bounds.maxY - 1
            let keyboardCoversSidebarWidth = !intersection.isNull
                && intersection.width >= sidebarFrame.width - 1
            guard keyboardIsDocked, keyboardCoversSidebarWidth else {
                publish(0)
                return
            }

            publish(min(sidebarFrame.height, max(0, sidebarFrame.maxY - keyboardFrame.minY)))
        }

        private func keyboardFrameDidChange(_ frame: CGRect?) {
            keyboardScreenFrame = frame
            updateOcclusion()
        }

        private func publish(_ overlap: CGFloat) {
            guard abs(overlap - lastOverlap) > 0.5 else { return }
            lastOverlap = overlap
            onChange?(overlap)
        }

        private func removeKeyboardObservers() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
        }
    }
}

/// One agent's chat. Chat's own composer serves until Chat reports the seam ready,
/// then Tuner's native composer takes over below the transcript.
private struct AgentChatView: View {
    let url: URL
    let reloadToken: Int
    @Binding var draft: String
    let repliedFeed: RepliedFeed
    let sidebarSearchFrame: CGRect?
    let compactSearchKeyboardDownFrame: CGRect?
    let compactSearchKeyboardUpFrame: CGRect?
    let softwareKeyboardVisible: Bool
    let isCompact: Bool
    let isPortrait: Bool
    let composerInsetEdgeOverride: VerticalEdge?
    @State private var bridge: ChatHostBridge
    @State private var composerKeyboardFocused = false

    init(
        url: URL,
        reloadToken: Int,
        draft: Binding<String>,
        repliedFeed: RepliedFeed,
        sidebarSearchFrame: CGRect?,
        compactSearchKeyboardDownFrame: CGRect?,
        compactSearchKeyboardUpFrame: CGRect?,
        softwareKeyboardVisible: Bool,
        isCompact: Bool,
        isPortrait: Bool,
        composerInsetEdgeOverride: VerticalEdge? = nil
    ) {
        self.url = url
        self.reloadToken = reloadToken
        _draft = draft
        self.repliedFeed = repliedFeed
        self.sidebarSearchFrame = sidebarSearchFrame
        self.compactSearchKeyboardDownFrame = compactSearchKeyboardDownFrame
        self.compactSearchKeyboardUpFrame = compactSearchKeyboardUpFrame
        self.softwareKeyboardVisible = softwareKeyboardVisible
        self.isCompact = isCompact
        self.isPortrait = isPortrait
        self.composerInsetEdgeOverride = composerInsetEdgeOverride
        _bridge = State(initialValue: ChatHostBridge(
            chatURL: url,
            outgoingObserver: { outgoing in
                repliedFeed.observePromptStatus(outgoing.status, sessionKey: outgoing.sessionKey,
                                                correlationID: outgoing.correlationId)
            }
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            let detailFrame = geometry.frame(in: .global)
            let keyboardUpForComposer = composerKeyboardFocused && softwareKeyboardVisible
            let searchFrame = composerTargetFrame(in: detailFrame, keyboardIsUp: keyboardUpForComposer)
            let composerInsetEdge = composerInsetEdgeOverride
                ?? ChatComposerSafeAreaPlacement.edge(for: searchFrame, in: detailFrame)
            let composerIsActive = hostComposerIsActive
            let contentExtensionEdges = ChatComposerSafeAreaPlacement.contentExtensionEdges(
                isPortrait: isPortrait,
                composerActive: composerIsActive,
                composerEdge: composerInsetEdge
            )

            ChatComposerSafeAreaLayout(edge: composerInsetEdge) {
                ChatWebView(url: url, reloadToken: reloadToken, bridge: bridge)
                    .ignoresSafeArea(edges: contentExtensionEdges)
            } inset: {
                if composerIsActive {
                    NativeChatComposer(
                        draft: $draft,
                        bridge: bridge,
                        glassHeight: isCompact ? NativeChatComposer.compactSearchHeight : searchFrame?.height,
                        focusOnAppear: captureKeyboardOnAppear
                    ) { focused in
                        composerKeyboardFocused = focused
                    }
                }
            }
        }
    }

    private var hostComposerIsActive: Bool {
#if DEBUG
        bridge.hostComposerActive
            || ProcessInfo.processInfo.arguments.contains(WIb6SafeAreaCaptureFixtureConfiguration.launchArgument)
#else
        bridge.hostComposerActive
#endif
    }

    private var captureKeyboardOnAppear: Bool {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(WIb6SafeAreaCaptureFixtureConfiguration.launchArgument)
            && arguments.contains(WIb6SafeAreaCaptureFixtureConfiguration.keyboardUpArgument)
#else
        false
#endif
    }

    private func composerTargetFrame(in detailFrame: CGRect, keyboardIsUp: Bool) -> CGRect? {
        let isSideBySide = sidebarSearchFrame.map { $0.maxX <= detailFrame.minX + 0.5 } ?? false
        let searchFrame: CGRect?
        if isSideBySide {
            searchFrame = sidebarSearchFrame
        } else if isCompact {
            searchFrame = keyboardIsUp ? compactSearchKeyboardUpFrame : compactSearchKeyboardDownFrame
        } else {
            return nil
        }

        guard let searchFrame, !searchFrame.isNull, searchFrame.height > 0 else { return nil }
        return searchFrame
    }
}

enum ChatComposerSafeAreaPlacement {
    static func edge(for filterFrame: CGRect?, in detailFrame: CGRect) -> VerticalEdge {
        guard let filterFrame, !filterFrame.isNull,
              filterFrame.height > 0, detailFrame.height > 0 else { return .bottom }
        return filterFrame.midY < detailFrame.midY ? .top : .bottom
    }

    static func contentExtensionEdges(
        isPortrait: Bool,
        composerActive: Bool,
        composerEdge: VerticalEdge
    ) -> Edge.Set {
        guard composerActive else { return isPortrait ? .vertical : .bottom }

        // In unfolded landscape the inset already respects the composer edge. Let SwiftUI
        // preserve the opposite system safe area too, so a top composer leaves the conversation
        // at the normal bottom boundary without adding a second top clearance.
        guard isPortrait else { return [] }

        switch composerEdge {
        case .top: return .bottom
        case .bottom: return .top
        }
    }
}

struct ChatComposerSafeAreaLayout<Content: View, Inset: View>: View {
    let edge: VerticalEdge
    let content: Content
    let inset: Inset

    init(
        edge: VerticalEdge,
        @ViewBuilder content: () -> Content,
        @ViewBuilder inset: () -> Inset
    ) {
        self.edge = edge
        self.content = content()
        self.inset = inset()
    }

    var body: some View {
        content.safeAreaInset(edge: edge, spacing: 0) { inset }
    }
}

private struct AgentNode: Identifiable {
    let agent: Agent
    let children: [AgentNode]
    let contextOnly: Bool

    var id: String { agent.id }
}

struct AgentListFilter {
    let words: [String]
    let archetypes: Set<String>

    var isActive: Bool { !words.isEmpty || !archetypes.isEmpty }

    func matches(_ agent: Agent) -> Bool {
        (archetypes.isEmpty || archetypes.contains(agent.archetype ?? ""))
            && words.allSatisfy { agent.name.localizedCaseInsensitiveContains($0) }
    }
}

struct AgentSectionCounts {
    let replied: Int
    let recent: Int
    let agents: Int

    init(replied: [Agent], recent: [Agent], agents: [Agent], filter: AgentListFilter) {
        self.replied = replied.filter { filter.matches($0) }.count
        self.recent = recent.filter { filter.matches($0) }.count
        self.agents = agents.filter { filter.matches($0) }.count
    }
}

/// An agent's name with its archetype as a caption below.
private struct AgentRowLabel: View {
    let agent: Agent
    var contextOnly = false
    var symbol: String?
    var waitingForReply = false

    var body: some View {
        let text = VStack(alignment: .leading, spacing: 1) {
            Text(agent.name)
                .foregroundStyle(contextOnly ? Color.nordicSecondaryText : Color.nordicText)
            if let archetype = agent.archetype, !archetype.isEmpty {
                Text(archetype)
                    .font(TunerTypography.caption)
                    .foregroundStyle(Color.nordicSecondaryText)
            }
        }
        if waitingForReply {
            Label { text } icon: {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Waiting for reply")
            }
        } else if let symbol {
            Label { text } icon: { Image(systemName: symbol) }
        } else {
            text
        }
    }
}

private struct AgentBranch: View {
    let node: AgentNode
    let filtering: Bool
    let selectedID: String?
    @Binding var collapsed: Set<String>

    private var rowBackground: Color {
        selectedID == node.id ? Color.nordicSelection : Color.nordicSurface
    }

    var body: some View {
        if node.children.isEmpty {
            NavigationLink(value: node.id) {
                AgentRowLabel(agent: node.agent, contextOnly: node.contextOnly)
            }
            .listRowBackground(rowBackground)
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { filtering || !collapsed.contains(node.id) },
                set: { if $0 { collapsed.remove(node.id) } else { collapsed.insert(node.id) } }
            )) {
                ForEach(node.children) { child in
                    AgentBranch(node: child, filtering: filtering, selectedID: selectedID,
                                collapsed: $collapsed)
                }
            } label: {
                NavigationLink(value: node.id) {
                    AgentRowLabel(agent: node.agent, contextOnly: node.contextOnly)
                }
            }
            .listRowBackground(rowBackground)
        }
    }
}

private struct AgentSectionHeader: View {
    let title: LocalizedStringKey
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Text(count, format: .number)
                .font(TunerTypography.caption)
                .monospacedDigit()
                .foregroundStyle(Color.nordicInfoCount)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.nordicSelection, in: Capsule())
        }
        .font(TunerTypography.caption)
        .foregroundStyle(Color.nordicSecondaryText)
    }
}

private struct AgentSidebar: View {
    @Bindable var store: TunerStore
    let repliedFeed: RepliedFeed
    let openRepliedAgent: (String) -> Void
    @Binding var query: String
    @Binding var selectedArchetypes: Set<String>
    let isRegularWidthIPad: Bool
    @State private var collapsed: Set<String> = []
    @State private var keyboardBottomOverlap: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("maxRecents") private var maxRecents = 10
    @AppStorage("repliedSectionExpanded") private var repliedSectionExpanded = true
    @AppStorage("recentSectionExpanded") private var recentSectionExpanded = true
    @AppStorage("agentsSectionExpanded") private var agentsSectionExpanded = true

    private var words: [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private var listFilter: AgentListFilter {
        AgentListFilter(words: words, archetypes: selectedArchetypes)
    }

    private var keyboardClearance: CGFloat {
        guard isRegularWidthIPad, !dynamicTypeSize.isAccessibilitySize, listFilter.isActive else { return 0 }
        return keyboardBottomOverlap
    }

    private var archetypes: [String] {
        Array(Set(store.agents.compactMap(\.archetype))).sorted()
    }

    private var mainSectionAgents: [Agent] {
        repliedFeed.state.agentsInMainSection(from: store.agents)
    }

    private var visibleRoots: [AgentNode] {
        let agents = mainSectionAgents
        let ids = Set(agents.map(\.id))
        let filter = listFilter
        let filtering = filter.isActive
        var children: [String: [Agent]] = [:]
        var roots: [Agent] = []
        for agent in agents {
            if let parent = agent.parent, parent != agent.id, ids.contains(parent) {
                children[parent, default: []].append(agent)
            } else {
                roots.append(agent)
            }
        }
        let ordered: (Agent, Agent) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        roots.sort(by: ordered)
        for key in Array(children.keys) { children[key]?.sort(by: ordered) }

        var visited: Set<String> = []
        func project(_ agent: Agent) -> AgentNode? {
            guard visited.insert(agent.id).inserted else { return nil }
            let descendants = (children[agent.id] ?? []).compactMap(project)
            let ownMatch = filter.matches(agent)
            guard !filtering || ownMatch || !descendants.isEmpty else { return nil }
            return AgentNode(agent: agent, children: descendants,
                             contextOnly: filtering && !ownMatch)
        }
        return roots.compactMap(project)
    }

    var body: some View {
        List(selection: $store.selectedID) {
            let filter = listFilter
            let replied = repliedFeed.state.agents(from: store.agents)
            let recents = store.recentAgents.prefix(maxRecents)
            let matchingReplied = replied.filter { filter.matches($0) }
            let matchingRecents = recents.filter { filter.matches($0) }
            let counts = AgentSectionCounts(replied: replied, recent: Array(recents),
                                            agents: mainSectionAgents, filter: filter)
            if store.isLoading {
                ProgressView("Loading agents…")
                    .listRowBackground(Color.nordicSurface)
            }
            if store.isRosterStale {
                Label {
                    Text("Agent list may be out of date")
                        .foregroundStyle(Color.nordicSecondaryText)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Color.nordicCaution)
                }
                    .font(TunerTypography.supporting)
                    .listRowBackground(Color.nordicSurface)
            }
            if let error = store.error {
                ContentUnavailableView(
                    "Could not load agents",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error).foregroundStyle(Color.nordicDanger)
                )
                    .listRowBackground(Color.nordicSurface)
            }
            if !replied.isEmpty {
                Section(isExpanded: $repliedSectionExpanded) {
                    ForEach(matchingReplied) { agent in
                        let waitingForReply = repliedFeed.state.rowIndicator(for: agent.id) == .waiting
                        NavigationLink(value: agent.id) {
                            AgentRowLabel(agent: agent,
                                          symbol: waitingForReply ? nil : "arrowshape.turn.up.left",
                                          waitingForReply: waitingForReply)
                        }
                        .simultaneousGesture(TapGesture().onEnded { openRepliedAgent(agent.id) })
                        .listRowBackground(store.selectedID == agent.id
                            ? Color.nordicSelection : Color.nordicSurface)
                    }
                } header: {
                    AgentSectionHeader(title: "Replies", count: counts.replied)
                }
            }
            if !recents.isEmpty {
                Section(isExpanded: $recentSectionExpanded) {
                    ForEach(matchingRecents) { agent in
                        NavigationLink(value: agent.id) {
                            AgentRowLabel(agent: agent, symbol: "clock")
                        }
                        .listRowBackground(store.selectedID == agent.id
                            ? Color.nordicSelection : Color.nordicSurface)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                store.removeRecent(agent.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Remove from Recent")
                            .tint(Color.nordicDanger)
                        }
                    }
                } header: {
                    AgentSectionHeader(title: "Recent", count: counts.recent)
                }
            }
            Section(isExpanded: $agentsSectionExpanded) {
                ForEach(visibleRoots) { node in
                    AgentBranch(node: node, filtering: !words.isEmpty || !selectedArchetypes.isEmpty,
                                selectedID: store.selectedID, collapsed: $collapsed)
                }
            } header: {
                AgentSectionHeader(title: "Agents", count: counts.agents)
            }
        }
        .nordicListStyle()
        .background {
            GeometryReader { geometry in
                SidebarKeyboardOcclusionReader { keyboardBottomOverlap = $0 }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityHidden(true)
            }
        }
        // Let filtered rows scroll above a docked iPad keyboard. Compact devices keep their
        // existing spacing, and oversized accessibility rows keep their existing behavior.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keyboardClearance > 0 {
                Color.clear
                    .frame(height: keyboardClearance)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .refreshable { await store.refresh() }
        .searchable(text: $query, placement: .sidebar, prompt: "Filter agents")
        // Keep the archetype menu in the toolbar while searching.
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Filter archetypes", systemImage: "line.3.horizontal.decrease.circle") {
                    ForEach(archetypes, id: \.self) { archetype in
                        Toggle(archetype, isOn: Binding(
                            get: { selectedArchetypes.contains(archetype) },
                            set: { selected in
                                if selected { selectedArchetypes.insert(archetype) }
                                else { selectedArchetypes.remove(archetype) }
                            }
                        ))
                    }
                }
            }
        }
    }

}

#if DEBUG
/// Synthetic page hosted by the production AgentChatView and ChatWebView layout. It has no Chat
/// service, account, roster, or command entry, and exists only in Debug builds.
struct WIb6SafeAreaCaptureFixtureView: View {
    private let configuration: WIb6SafeAreaCaptureFixtureConfiguration
    @State private var draft = ""
    @State private var repliedFeed: RepliedFeed
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(arguments: [String]) {
        configuration = WIb6SafeAreaCaptureFixtureConfiguration(arguments: arguments)
        let defaultsSuite = "wib6.safe-area.capture.fixture"
        guard let isolatedDefaults = UserDefaults(suiteName: defaultsSuite) else {
            preconditionFailure("Unable to create isolated WIb6 fixture defaults")
        }
        isolatedDefaults.removePersistentDomain(forName: defaultsSuite)
        _repliedFeed = State(initialValue: RepliedFeed(defaults: isolatedDefaults))
    }

    var body: some View {
        GeometryReader { geometry in
            if let failureMessage = configuration.failureMessage {
                ContentUnavailableView("Safe-area fixture unavailable", systemImage: "rectangle.slash",
                                       description: Text(failureMessage))
            } else {
                let isPortrait = geometry.size.height > geometry.size.width
                let edge = configuration.edge
                Group {
                    if isPortrait {
                        NavigationStack {
                            captureLayout(isPortrait: isPortrait, edge: edge)
                                .navigationTitle("Synthetic Chat")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbarBackground(.hidden, for: .navigationBar)
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button("Agents", systemImage: "sidebar.left") { }
                                            .accessibilityIdentifier("fixture-floating-agents")
                                    }
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("Reload", systemImage: "arrow.clockwise") { }
                                            .accessibilityIdentifier("fixture-floating-reload")
                                    }
                                }
                        }
                    } else {
                        captureLayout(isPortrait: isPortrait, edge: edge)
                    }
                }
                .background(Color.chatBackground.ignoresSafeArea())
            }
        }
    }

    private func captureLayout(isPortrait: Bool, edge: VerticalEdge) -> some View {
        AgentChatView(
            url: configuration.chatURL,
            reloadToken: 0,
            draft: $draft,
            repliedFeed: repliedFeed,
            sidebarSearchFrame: nil,
            compactSearchKeyboardDownFrame: nil,
            compactSearchKeyboardUpFrame: nil,
            softwareKeyboardVisible: configuration.keyboardUp,
            isCompact: horizontalSizeClass == .compact,
            isPortrait: isPortrait,
            composerInsetEdgeOverride: edge
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.chatBackground)
    }
}

struct WIb6SafeAreaCaptureFixtureConfiguration {
    static let launchArgument = "--wib6-safe-area-fixture"
    private static let edgePrefix = "--wib6-filter-edge="
    static let keyboardUpArgument = "--wib6-keyboard-up"
    private static let scrollToLastArgument = "--wib6-scroll-to-last"

    let edge: VerticalEdge
    let keyboardUp: Bool
    let scrollToLast: Bool
    let chatURL: URL
    let failureMessage: String?

    init(arguments: [String]) {
        chatURL = Self.makeChatURL(scrollToLast: arguments.contains(Self.scrollToLastArgument))
        guard arguments.contains(Self.launchArgument),
              let edgeArgument = arguments.first(where: { $0.hasPrefix(Self.edgePrefix) }) else {
            edge = .bottom
            keyboardUp = false
            scrollToLast = false
            failureMessage = "Pass the fixture flag and a top or bottom Filter edge."
            return
        }

        switch edgeArgument.dropFirst(Self.edgePrefix.count) {
        case "top": edge = .top
        case "bottom": edge = .bottom
        default:
            edge = .bottom
            keyboardUp = false
            scrollToLast = false
            failureMessage = "The fixture Filter edge must be top or bottom."
            return
        }
        keyboardUp = arguments.contains(Self.keyboardUpArgument)
        scrollToLast = arguments.contains(Self.scrollToLastArgument)
        failureMessage = nil
    }

    private static func makeChatURL(scrollToLast: Bool) -> URL {
        let initialScroll = scrollToLast
            ? "document.getElementById('last').scrollIntoView({block:'end', behavior:'auto'});"
            : ""
        let html = """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html, body { margin: 0; min-height: 100%; background: #f3efe7; color: #27313b;
            font: 16px -apple-system, sans-serif; }
          main { display: flex; flex-direction: column; gap: 12px; padding: 16px 16px 72px; }
          .message { min-height: 54px; padding: 14px; border-radius: 14px; background: white;
            box-sizing: border-box; }
          #latest { position: fixed; z-index: 2; right: 14px; bottom: 14px; width: 38px; height: 38px;
            border: 0; border-radius: 19px; background: rgba(255,255,255,.88); color: #27313b;
            font-size: 18px; }
        </style>
        <main id="messages">
          <div class="message" id="first">First synthetic message</div>
          <div class="message">Synthetic conversation message 1</div>
          <div class="message">Synthetic conversation message 2</div>
          <div class="message">Synthetic conversation message 3</div>
          <div class="message">Synthetic conversation message 4</div>
          <div class="message">Synthetic conversation message 5</div>
          <div class="message">Synthetic conversation message 6</div>
          <div class="message">Synthetic conversation message 7</div>
          <div class="message">Synthetic conversation message 8</div>
          <div class="message">Synthetic conversation message 9</div>
          <div class="message">Synthetic conversation message 10</div>
          <div class="message">Synthetic conversation message 11</div>
          <div class="message">Synthetic conversation message 12</div>
          <div class="message">Synthetic conversation message 13</div>
          <div class="message">Synthetic conversation message 14</div>
          <div class="message">Synthetic conversation message 15</div>
          <div class="message" id="last">Last synthetic message</div>
        </main>
        <button id="latest" aria-label="Scroll to latest">↓</button>
        <script>
          document.getElementById('latest').addEventListener('click', () =>
            document.getElementById('last').scrollIntoView({block:'end', behavior:'smooth'}));
          window.addEventListener('load', () => requestAnimationFrame(() => { \(initialScroll) }));
        </script>
        """
        let encodedHTML = Data(html.utf8).base64EncodedString()
        guard let url = URL(string: "data:text/html;charset=utf-8;base64,\(encodedHTML)") else {
            preconditionFailure("Unable to construct inert WIb6 page URL")
        }
        return url
    }
}

/// A capture-only host for the content-free WI721 page. This bypasses the normal store,
/// roster refresh, release-note, and Replies tasks, and exists only in Debug builds.
struct WI721CaptureFixtureView: View {
    private let configuration: WI721CaptureFixtureConfiguration
    @State private var selectedSessionKey: String? = WI721CaptureFixtureConfiguration.sessionKey
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var draft = ""
    @State private var filterQuery = ""
    @State private var sidebarSearchFrame: CGRect?
    @State private var repliedFeed: RepliedFeed
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(arguments: [String]) {
        configuration = WI721CaptureFixtureConfiguration(arguments: arguments)
        let defaultsSuite = "wi721.capture.fixture"
        guard let isolatedDefaults = UserDefaults(suiteName: defaultsSuite) else {
            preconditionFailure("Unable to create isolated WI721 fixture defaults")
        }
        isolatedDefaults.removePersistentDomain(forName: defaultsSuite)
        _repliedFeed = State(initialValue: RepliedFeed(defaults: isolatedDefaults))
    }

    var body: some View {
        Group {
            if let failureMessage = configuration.failureMessage {
                ContentUnavailableView(
                    "WI721 capture fixture unavailable",
                    systemImage: "network.slash",
                    description: Text(failureMessage)
                )
            } else {
                NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
                    List(selection: $selectedSessionKey) {
                        Text("WI721 Fixture Agent")
                            .tag(WI721CaptureFixtureConfiguration.sessionKey)
                    }
                    .navigationTitle("Agents")
                    .searchable(text: $filterQuery, placement: .sidebar, prompt: "Filter agents")
                } detail: {
                    if selectedSessionKey == WI721CaptureFixtureConfiguration.sessionKey,
                       let chatURL = configuration.chatURL {
                        AgentChatView(
                            url: chatURL,
                            reloadToken: 0,
                            draft: $draft,
                            repliedFeed: repliedFeed,
                            sidebarSearchFrame: sidebarSearchFrame,
                            compactSearchKeyboardDownFrame: nil,
                            compactSearchKeyboardUpFrame: nil,
                            softwareKeyboardVisible: false,
                            isCompact: horizontalSizeClass == .compact,
                            isPortrait: horizontalSizeClass == .compact
                        )
                        .id(WI721CaptureFixtureConfiguration.sessionKey)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .navigationTitle("WI721 Fixture Agent")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.chatBackground)
                    } else {
                        ContentUnavailableView("Select the WI721 fixture agent", systemImage: "person.crop.circle")
                    }
                }
            }
        }
        .background {
            SidebarSearchFrameReader(
                prompt: "Filter agents",
                usesCompactFieldFrame: horizontalSizeClass == .compact
            ) { measurement in
                sidebarSearchFrame = measurement.capsule
            }
            .accessibilityHidden(true)
        }
        .preferredColorScheme(configuration.colorScheme)
    }
}

/// Debug-only launch configuration. The only accepted origin is an HTTPS loopback origin,
/// so this route cannot point at a production Chat service.
struct WI721CaptureFixtureConfiguration {
    static let launchArgument = "--wi721-chat-fixture"
    static let sessionKey = "agent:test"
    private static let originPrefix = "--wi721-chat-origin="
    private static let themePrefix = "--wi721-theme="

    let chatURL: URL?
    let colorScheme: ColorScheme?
    let failureMessage: String?

    init(arguments: [String]) {
        guard arguments.contains(Self.launchArgument),
              let originArgument = arguments.first(where: { $0.hasPrefix(Self.originPrefix) }) else {
            chatURL = nil
            colorScheme = nil
            failureMessage = "Pass the fixture flag, an HTTPS loopback origin, and a light or dark theme."
            return
        }

        let originValue = String(originArgument.dropFirst(Self.originPrefix.count))
        guard let origin = Connection().origin(originValue),
              let host = origin.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host),
              var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            chatURL = nil
            colorScheme = nil
            failureMessage = "Use an HTTPS origin on localhost or a loopback IP address."
            return
        }

        guard let themeArgument = arguments.first(where: { $0.hasPrefix(Self.themePrefix) }) else {
            chatURL = nil
            colorScheme = nil
            failureMessage = "Pass --wi721-theme=light or --wi721-theme=dark."
            return
        }

        let themeValue = String(themeArgument.dropFirst(Self.themePrefix.count))
        let requestedColorScheme: ColorScheme
        switch themeValue {
        case "light": requestedColorScheme = .light
        case "dark": requestedColorScheme = .dark
        default:
            chatURL = nil
            colorScheme = nil
            failureMessage = "The fixture theme must be light or dark."
            return
        }

        components.path = "/"
        components.queryItems = [URLQueryItem(name: "session", value: Self.sessionKey)]
        chatURL = components.url
        colorScheme = requestedColorScheme
        failureMessage = chatURL == nil ? "The fixture origin could not be formed." : nil
    }
}
#endif
