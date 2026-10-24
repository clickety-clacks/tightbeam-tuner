import SwiftUI

struct SettingsView: View {
    let store: TunerStore
    @Binding var showing: Bool
    @State private var draft = Connection()
    @State private var discoveryError: String?
    @State private var discovering = false
    @State private var connecting = false
    @State private var publicKey = ""
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("Chat server URL", text: $draft.chatServer)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        TextField("Gateway URL", text: $draft.gateway)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        Button("Find gateway from Chat") {
                            Task { await discover() }
                        }
                        .disabled(discovering || draft.origin(draft.chatServer) == nil)
                    } header: {
                        Text("Chat")
                    } footer: {
                        Text("Chat opens the selected conversation. The gateway is usually published at the Chat server's chat-config.json endpoint.")
                    }
                    Section {
                        TextField("SSH host", text: $draft.sshHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("SSH port", value: $draft.sshPort, format: .number)
                            .keyboardType(.numberPad)
                        TextField("SSH login", text: $draft.sshUser)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Tightbeam CLI path", text: $draft.tightbeamPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Tightbeam user", text: $draft.tightbeamUser)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Server host key (ssh-ed25519 …)", text: $draft.sshHostKey, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(2...3)
                    } header: {
                        Text("Agent list over SSH")
                    } footer: {
                        Text("Paste the server's public ssh-ed25519 host key. Tuner verifies it on every connection, then runs the configured CLI with list --as-user. The SSH login needs permission to do that.")
                    }
                    Section {
                        if publicKey.isEmpty {
                            Text("Could not create a device key").foregroundStyle(Color.nordicDanger)
                        } else {
                            Text(publicKey).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Copy public key") { UIPasteboard.general.string = publicKey }
                        }
                    } header: {
                        Text("This device's SSH public key")
                    } footer: {
                        Text("Add this public key to the SSH login's authorized_keys file on the server. The private key stays in this device's Keychain.")
                    }
                    if let discoveryError {
                        Section { Text(discoveryError).foregroundStyle(Color.nordicDanger) }
                    }
                    Section("Appearance") {
                        Picker("Theme", selection: $appearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                    }
                }
                .listRowBackground(Color.nordicSurface)
            }
            .nordicListStyle()
            .navigationTitle("Tightbeam Tuner")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if store.connection.isComplete {
                        Button("Cancel") { showing = false }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(connecting ? "Connecting…" : "Save and connect") {
                        connecting = true
                        store.save(draft)
                        Task {
                            await store.refresh()
                            connecting = false
                            if let error = store.error { discoveryError = error }
                            else { showing = false }
                        }
                    }
                    .disabled(!draft.isComplete || publicKey.isEmpty || connecting)
                }
            }
            .onAppear {
                draft = store.connection
                publicKey = (try? SSHKeyStore.publicKeyLine()) ?? ""
            }
        }
    }

    private func discover() async {
        guard let base = draft.origin(draft.chatServer) else { return }
        discovering = true
        defer { discovering = false }
        do {
            let url = base.appending(path: "chat-config.json")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let config = try JSONDecoder().decode(ChatDefaults.self, from: data)
            guard draft.origin(config.gateway, allowHTTP: true) != nil else { throw URLError(.badURL) }
            draft.gateway = config.gateway
            discoveryError = nil
        } catch {
            discoveryError = error.localizedDescription
        }
    }
}

private struct ChatDefaults: Decodable {
    let gateway: String
}
