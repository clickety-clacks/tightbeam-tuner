import SwiftUI

struct ContentView: View {
    @State private var store = TunerStore()
    @State private var repliedFeed = RepliedFeed()
    @State private var showingSettings = false
    @State private var reloadToken = 0
    @State private var whatsNew: [ReleaseNote] = []
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var sidebarSearchFrame: CGRect?
    /// In portrait on a wide screen the agent list floats over the chat instead of beside it.
    @State private var portrait = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("appearance") private var appearance = "system"
    /// Native composer drafts per agent. Kept in app defaults, not scene storage, so a draft
    /// survives a force-quit or iOS ending Tuner in the background. Send state is not kept.
    @AppStorage("composerDrafts") private var draftsData = Data()

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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            AgentSidebar(store: store, repliedFeed: repliedFeed)
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
                                  sidebarSearchFrame: sidebarSearchFrame)
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
            SidebarSearchFrameReader(prompt: "Filter agents") { frame in
                sidebarSearchFrame = frame
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
            guard store.connection.isComplete, !sessionKeys.isEmpty else { return }
            await repliedFeed.run(gateway: store.connection.gateway, user: store.connection.tightbeamUser,
                                  sessionKeys: sessionKeys)
        }
        .onChange(of: store.selectedID) { _, value in
            if let value, let agent = store.agents.first(where: { $0.id == value }) {
                store.select(agent)
                preferredCompactColumn = .detail
                // A floating agent list closes once an agent is chosen, like a popover.
                if horizontalSizeClass == .regular && portrait { columnVisibility = .detailOnly }
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            // Opening the agent list puts the keyboard away, so the list is not half covered.
            if visibility != .detailOnly {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.height > $0.size.width } action: { isPortrait in
            portrait = isPortrait
            // Side by side again in landscape: bring the list back if it was closed in portrait.
            if !isPortrait && columnVisibility == .detailOnly { columnVisibility = .automatic }
        }
    }
}

/// Reports the visible system search capsule's frame in window coordinates.
private struct SidebarSearchFrameReader: UIViewRepresentable {
    let prompt: String
    let onFrameChange: (CGRect?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = SearchFieldProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.prompt = prompt
        view.onFrameChange = onFrameChange
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let view = view as? SearchFieldProbeView else { return }
        view.prompt = prompt
        view.onFrameChange = onFrameChange
        view.scheduleRead()
    }

    private final class SearchFieldProbeView: UIView {
        var prompt = ""
        var onFrameChange: ((CGRect?) -> Void)?
        private var lastFrame: CGRect?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleRead()
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
                let frame = self.searchFrame()
                guard frame != self.lastFrame else { return }
                self.lastFrame = frame
                self.onFrameChange?(frame)
            }
        }

        private func searchFrame() -> CGRect? {
            guard let window,
                  let field = findSearchField(in: window),
                  !field.isHidden,
                  field.alpha > 0.01 else { return nil }

            let fieldFrame = field.convert(field.bounds, to: window)
            var capsuleFrame = fieldFrame
            var ancestor = field.superview
            // The text field can be shorter than its capsule; its enclosing capsule keeps the same width.
            while let view = ancestor {
                let frame = view.convert(view.bounds, to: window)
                guard abs(frame.minX - fieldFrame.minX) <= 0.5,
                      abs(frame.width - fieldFrame.width) <= 0.5 else { break }
                capsuleFrame = frame
                ancestor = view.superview
            }
            return window.bounds.intersects(capsuleFrame) ? capsuleFrame : nil
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

/// One agent's chat. Chat's own composer serves until Chat reports the seam ready,
/// then Tuner's native composer takes over below the transcript.
private struct AgentChatView: View {
    let url: URL
    let reloadToken: Int
    @Binding var draft: String
    let sidebarSearchFrame: CGRect?
    @State private var bridge: ChatHostBridge
    @State private var composerHeight: CGFloat = 0

    init(url: URL, reloadToken: Int, draft: Binding<String>, sidebarSearchFrame: CGRect?) {
        self.url = url
        self.reloadToken = reloadToken
        _draft = draft
        self.sidebarSearchFrame = sidebarSearchFrame
        _bridge = State(initialValue: ChatHostBridge(chatURL: url))
    }

    var body: some View {
        // The page runs under the top bar and the floating composer, but stays clear of side
        // safe areas (a floating sidebar, a notch, a folded iPhone Duo's side bar), so anything
        // Chat centers lands in the visible part of the detail column. The composer's height
        // joins the page's bottom safe area, so Chat keeps the newest message above the glass.
        GeometryReader { geometry in
            let detailFrame = geometry.frame(in: .global)
            let composerOffset = composerOffset(in: detailFrame)
            ZStack(alignment: .bottom) {
                ChatWebView(url: url, reloadToken: reloadToken, bridge: bridge,
                            // Preserve the clearance below the composer after moving it from the bottom anchor.
                            floatingBottomInset: bridge.hostComposerActive
                                ? max(0, composerHeight - composerOffset) : 0)
                    .ignoresSafeArea(edges: .vertical)
                if bridge.hostComposerActive {
                    NativeChatComposer(draft: $draft, bridge: bridge)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                        .offset(y: composerOffset)
                }
            }
        }
    }

    private func composerOffset(in detailFrame: CGRect) -> CGFloat {
        guard let sidebarSearchFrame,
              // A separate column means the list is beside the chat; a floating sidebar overlaps it.
              sidebarSearchFrame.maxX <= detailFrame.minX + 0.5,
              // The system puts top-placed filters above center and the bottom filter below it.
              sidebarSearchFrame.midY > detailFrame.midY,
              // A raised keyboard puts the filter below the detail's safe bottom.
              sidebarSearchFrame.maxY <= detailFrame.maxY else { return 0 }

        // The glass ends at the composer view's bottom minus its existing bottom padding.
        let composerGlassBottom = detailFrame.maxY - NativeChatComposer.bottomPadding
        return sidebarSearchFrame.maxY - composerGlassBottom
    }
}

private struct AgentNode: Identifiable {
    let agent: Agent
    let children: [AgentNode]
    let contextOnly: Bool

    var id: String { agent.id }
}

/// An agent's name with its archetype as a caption below.
private struct AgentRowLabel: View {
    let agent: Agent
    var contextOnly = false
    var symbol: String?

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
        if let symbol {
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

private struct AgentSidebar: View {
    @Bindable var store: TunerStore
    let repliedFeed: RepliedFeed
    @State private var query = ""
    @State private var selectedArchetypes: Set<String> = []
    @State private var collapsed: Set<String> = []
    @AppStorage("maxRecents") private var maxRecents = 10

    private var words: [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private var archetypes: [String] {
        Array(Set(store.agents.compactMap(\.archetype))).sorted()
    }

    private func matches(_ agent: Agent, words: [String]) -> Bool {
        (selectedArchetypes.isEmpty || selectedArchetypes.contains(agent.archetype ?? ""))
            && words.allSatisfy { agent.name.localizedCaseInsensitiveContains($0) }
    }

    private var visibleRoots: [AgentNode] {
        let agents = store.agents
        let ids = Set(agents.map(\.id))
        let terms = words
        let filtering = !terms.isEmpty || !selectedArchetypes.isEmpty
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
            let ownMatch = matches(agent, words: terms)
            guard !filtering || ownMatch || !descendants.isEmpty else { return nil }
            return AgentNode(agent: agent, children: descendants,
                             contextOnly: filtering && !ownMatch)
        }
        return roots.compactMap(project)
    }

    var body: some View {
        List(selection: $store.selectedID) {
            let replied = repliedFeed.state.agents(from: store.agents)
            let recents = store.recentAgents.prefix(maxRecents)
            if !replied.isEmpty {
                Section("Replied") {
                    ForEach(replied.filter { matches($0, words: words) }) { agent in
                        NavigationLink(value: agent.id) {
                            AgentRowLabel(agent: agent, symbol: "arrowshape.turn.up.left")
                        }
                    }
                }
            }
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents.filter { matches($0, words: words) }) { agent in
                        NavigationLink(value: agent.id) {
                            AgentRowLabel(agent: agent, symbol: "clock")
                        }
                    }
                }
            }
            Section("Agents") {
                ForEach(visibleRoots) { node in
                    AgentBranch(node: node, filtering: !words.isEmpty || !selectedArchetypes.isEmpty,
                                collapsed: $collapsed)
                }
            }
            if store.isLoading { ProgressView("Loading agents…") }
            if let error = store.error {
                ContentUnavailableView("Could not load agents", systemImage: "wifi.exclamationmark", description: Text(error))
            }
        }
        .nordicListStyle()
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
