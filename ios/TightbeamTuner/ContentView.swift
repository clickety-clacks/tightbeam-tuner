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
                                  isCompact: horizontalSizeClass == .compact)
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
            .background(Color.nordicBackground)
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
    @State private var bridge: ChatHostBridge
    @State private var composerHeight: CGFloat = 0
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
        isCompact: Bool
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
        _bridge = State(initialValue: ChatHostBridge(
            chatURL: url,
            outgoingObserver: { outgoing in
                repliedFeed.observePromptStatus(outgoing.status, sessionKey: outgoing.sessionKey,
                                                correlationID: outgoing.correlationId)
            }
        ))
    }

    var body: some View {
        // The page fills the detail width and respects the toolbar. When the composer is above
        // the conversation, move the web view below its glass; when it is below, extend the
        // page's bottom safe area so content can scroll clear of the glass.
        GeometryReader { geometry in
            let detailFrame = geometry.frame(in: .global)
            let keyboardUpForComposer = composerKeyboardFocused && softwareKeyboardVisible
            let searchFrame = composerTargetFrame(in: detailFrame, keyboardIsUp: keyboardUpForComposer)
            let composerIsTopAligned = searchFrame != nil
                && sidebarSearchFrame.map { $0.maxX <= detailFrame.minX + 0.5 } == true
            // The compact Filter capsule is 38 pt high; its backing text field's bounds can be taller.
            let compactGlassBottomCorrection: CGFloat = isCompact && keyboardUpForComposer ? 1 : 0
            let composerOffset = searchFrame.map {
                $0.maxY - (detailFrame.maxY - NativeChatComposer.bottomPadding) - compactGlassBottomCorrection
            } ?? 0
            // The native row can be positioned before onGeometryChange reports its height.
            // Keep Chat's controls clear during that first layout as well as after measurement.
            let composerClearance = max(composerHeight, NativeChatComposer.minimumLayoutHeight)
            let topComposerClearance = bridge.hostComposerActive && composerIsTopAligned ? composerClearance : 0
            let floatingBottomInset = bridge.hostComposerActive && !composerIsTopAligned
                ? max(0, composerClearance - composerOffset) : 0
            ZStack(alignment: .bottom) {
                ChatWebView(url: url, reloadToken: reloadToken, bridge: bridge,
                            floatingBottomInset: floatingBottomInset)
                    .padding(.top, topComposerClearance)
                    .ignoresSafeArea(edges: .bottom)
                if bridge.hostComposerActive {
                    NativeChatComposer(
                        draft: $draft,
                        bridge: bridge,
                        glassHeight: isCompact ? NativeChatComposer.compactSearchHeight : searchFrame?.height
                    ) { focused in
                        composerKeyboardFocused = focused
                    }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                        .offset(y: composerOffset)
                }
            }
        }
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

        guard let searchFrame,
              searchFrame.maxY <= detailFrame.maxY + NativeChatComposer.bottomPadding else { return nil }
        return searchFrame
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
                    .font(.caption)
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
    @Binding var collapsed: Set<String>

    var body: some View {
        if node.children.isEmpty {
            NavigationLink(value: node.id) {
                AgentRowLabel(agent: node.agent, contextOnly: node.contextOnly)
            }
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { filtering || !collapsed.contains(node.id) },
                set: { if $0 { collapsed.remove(node.id) } else { collapsed.insert(node.id) } }
            )) {
                ForEach(node.children) { child in
                    AgentBranch(node: child, filtering: filtering, collapsed: $collapsed)
                }
            } label: {
                NavigationLink(value: node.id) {
                    AgentRowLabel(agent: node.agent, contextOnly: node.contextOnly)
                }
            }
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
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color(.accent))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.accent).opacity(0.16), in: Capsule())
        }
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
            if store.isLoading { ProgressView("Loading agents…") }
            if store.isRosterStale {
                Label("Agent list may be out of date", systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = store.error {
                ContentUnavailableView("Could not load agents", systemImage: "wifi.exclamationmark", description: Text(error))
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
                                collapsed: $collapsed)
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
