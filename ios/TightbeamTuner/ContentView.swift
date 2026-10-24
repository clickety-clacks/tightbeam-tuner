import SwiftUI

struct ContentView: View {
    @State private var store = TunerStore()
    @State private var showingSettings = false
    @State private var reloadToken = 0
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationSplitView {
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
                    ChatWebView(url: url, reloadToken: reloadToken)
                        .id(agent.id)
                        .navigationTitle(agent.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Reload Chat", systemImage: "arrow.clockwise") { reloadToken += 1 }
                            }
                        }
                } else {
                    ContentUnavailableView("Choose an agent", systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store, showing: $showingSettings)
                .interactiveDismissDisabled(!store.connection.isComplete)
        }
        .task {
            if store.connection.isComplete { await store.refresh() }
            else { showingSettings = true }
        }
        .onChange(of: store.selectedID) { _, value in
            if let value, let agent = store.agents.first(where: { $0.id == value }) {
                store.select(agent)
            }
        }
    }
}

private struct AgentSidebar: View {
    @Bindable var store: TunerStore
    @State private var query = ""
    @State private var selectedArchetypes: Set<String> = []
    @State private var expanded: Set<String> = []

    private var words: [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private var byID: [String: Agent] {
        Dictionary(uniqueKeysWithValues: store.agents.map { ($0.id, $0) })
    }

    private var children: [String: [Agent]] {
        Dictionary(grouping: store.agents.filter { $0.parent != nil && byID[$0.parent!] != nil }, by: { $0.parent! })
            .mapValues { $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    }

    private var roots: [Agent] {
        store.agents.filter { $0.parent == nil || byID[$0.parent!] == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var archetypes: [String] {
        Array(Set(store.agents.compactMap(\.archetype))).sorted()
    }

    private func matches(_ agent: Agent) -> Bool {
        (selectedArchetypes.isEmpty || selectedArchetypes.contains(agent.archetype ?? ""))
            && words.allSatisfy { agent.name.localizedCaseInsensitiveContains($0) }
    }

    private func containsMatch(_ agent: Agent, visited: Set<String> = []) -> Bool {
        guard !visited.contains(agent.id) else { return false }
        if matches(agent) { return true }
        let seen = visited.union([agent.id])
        return (children[agent.id] ?? []).contains { containsMatch($0, visited: seen) }
    }

    var body: some View {
        List(selection: $store.selectedID) {
            if !store.recentAgents.isEmpty {
                Section("Recent") {
                    ForEach(store.recentAgents.filter(matches)) { agent in
                        NavigationLink(value: agent.id) {
                            Label(agent.name, systemImage: "clock")
                        }
                    }
                }
            }
            Section("Agents") {
                ForEach(roots.filter { containsMatch($0) }) { agent in
                    branch(agent, visited: [])
                }
            }
            if store.isLoading { ProgressView("Loading agents…") }
            if let error = store.error {
                ContentUnavailableView("Could not load agents", systemImage: "wifi.exclamationmark", description: Text(error))
            }
        }
        .refreshable { await store.refresh() }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter agents", text: $query)
                    .textInputAutocapitalization(.never)
                Menu {
                    ForEach(archetypes, id: \.self) { archetype in
                        Button {
                            if selectedArchetypes.contains(archetype) { selectedArchetypes.remove(archetype) }
                            else { selectedArchetypes.insert(archetype) }
                        } label: {
                            Label(archetype, systemImage: selectedArchetypes.contains(archetype) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .accessibilityLabel("Filter archetypes")
                }
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }

    private func branch(_ agent: Agent, visited: Set<String>) -> AnyView {
        if !visited.contains(agent.id) {
            let descendants = (children[agent.id] ?? []).filter { containsMatch($0) }
            let seen = visited.union([agent.id])
            if descendants.isEmpty {
                return AnyView(NavigationLink(value: agent.id) {
                    Text(agent.name)
                        .foregroundStyle(matches(agent) ? .primary : .secondary)
                })
            } else {
                return AnyView(DisclosureGroup(isExpanded: Binding(
                    get: { !words.isEmpty || !selectedArchetypes.isEmpty || expanded.contains(agent.id) },
                    set: { if $0 { expanded.insert(agent.id) } else { expanded.remove(agent.id) } }
                )) {
                    ForEach(descendants) { child in branch(child, visited: seen) }
                } label: {
                    NavigationLink(value: agent.id) {
                        Text(agent.name)
                            .foregroundStyle(matches(agent) ? .primary : .secondary)
                    }
                })
            }
        }
        return AnyView(EmptyView())
    }
}
