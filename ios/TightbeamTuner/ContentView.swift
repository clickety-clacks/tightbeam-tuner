import SwiftUI

struct ContentView: View {
    @State private var store = TunerStore()
    @State private var showingSettings = false
    @State private var reloadToken = 0
    @State private var whatsNew: [ReleaseNote] = []
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
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
            AgentSidebar(store: store)
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
                                  alignComposerWithSidebar: UIDevice.current.userInterfaceIdiom == .phone
                                      && horizontalSizeClass == .regular && !portrait && columnVisibility != .detailOnly)
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

/// One agent's chat. Chat's own composer serves until Chat reports the seam ready,
/// then Tuner's native composer takes over below the transcript.
private struct AgentChatView: View {
    let url: URL
    let reloadToken: Int
    @Binding var draft: String
    let alignComposerWithSidebar: Bool
    @State private var bridge: ChatHostBridge
    @State private var composerHeight: CGFloat = 0

    init(url: URL, reloadToken: Int, draft: Binding<String>, alignComposerWithSidebar: Bool) {
        self.url = url
        self.reloadToken = reloadToken
        _draft = draft
        self.alignComposerWithSidebar = alignComposerWithSidebar
        _bridge = State(initialValue: ChatHostBridge(chatURL: url))
    }

    var body: some View {
        // The page runs under the top bar and the floating composer, but stays clear of side
        // safe areas (a floating sidebar, a notch, a folded iPhone Duo's side bar), so anything
        // Chat centers lands in the visible part of the detail column. The composer's height
        // joins the page's bottom safe area, so Chat keeps the newest message above the glass.
        ZStack(alignment: .bottom) {
            ChatWebView(url: url, reloadToken: reloadToken, bridge: bridge,
                        floatingBottomInset: bridge.hostComposerActive ? composerHeight : 0)
                .ignoresSafeArea(edges: .vertical)
            if bridge.hostComposerActive {
                NativeChatComposer(draft: $draft, bridge: bridge)
                    // 10 pt measured against the system filter field in the landscape split.
                    .padding(.bottom, alignComposerWithSidebar ? 10 : 0)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
        }
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
            let recents = store.recentAgents.prefix(maxRecents)
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
