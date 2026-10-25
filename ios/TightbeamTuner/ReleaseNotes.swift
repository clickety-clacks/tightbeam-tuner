import SwiftUI

/// What changed in each release, newest first. Every release adds an entry here, numbered
/// with the build it ships as. An entry numbered past the running build stays hidden until
/// a build that new is installed, so guessing one too high is harmless.
enum ReleaseNotes {
    static let all: [ReleaseNote] = [
        ReleaseNote(version: "1.0", build: 18, date: "October 24, 2026", items: [
            .init(symbol: "sparkles", title: "Release notes",
                  detail: "After an update, Tuner shows what changed, once. Every release's notes stay in Settings under Release Notes."),
        ]),
        ReleaseNote(version: "1.0", build: 17, date: "October 24, 2026", items: [
            .init(symbol: "rectangle.split.2x1", title: "Chat stays in its column",
                  detail: "The chat page keeps clear of the sidebar, so Latest messages and other centered controls sit in the middle of the chat."),
        ]),
        ReleaseNote(version: "1.0", build: 16, date: "October 24, 2026", items: [
            .init(symbol: "textformat.size", title: "Pinch to change text size",
                  detail: "Pinch the conversation to make its text larger or smaller. Tuner remembers the size."),
        ]),
        ReleaseNote(version: "1.0", build: 15, date: "October 24, 2026", items: [
            .init(symbol: "text.alignleft", title: "Message field fits the chat",
                  detail: "The message field centers in the chat column and stops at a comfortable line length on wide screens."),
            .init(symbol: "return", title: "Return key",
                  detail: "The keyboard's Return key now reads Return, since it starts a new line."),
        ]),
        ReleaseNote(version: "1.0", build: 14, date: "October 24, 2026", items: [
            .init(symbol: "line.3.horizontal.decrease.circle", title: "Filter while searching",
                  detail: "The archetype filter stays available while you search the agent list."),
        ]),
        ReleaseNote(version: "1.0", build: 13, date: "October 24, 2026", items: [
            .init(symbol: "paintpalette", title: "Nordic colors",
                  detail: "Tuner uses the same linen, off-black and moss palette as Tightbeam Chat, in light and dark."),
        ]),
        ReleaseNote(version: "1.0", build: 11, date: "October 24, 2026", items: [
            .init(symbol: "iphone", title: "Narrow screens",
                  detail: "Chat no longer runs under side bars on very narrow screens, such as a folded phone."),
        ]),
        ReleaseNote(version: "1.0", build: 10, date: "October 24, 2026", items: [
            .init(symbol: "bubble.left.and.text.bubble.right", title: "Liquid Glass message field",
                  detail: "A native message field floats over the conversation."),
        ]),
    ]

    private static let lastSeenKey = "releaseNotesLastSeenBuild"

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "\(version) (\(currentBuild))"
    }

    /// Notes for builds released since this device last opened Tuner, then marks them seen,
    /// so each one shows once. A first install starts with nothing to show.
    static func takeUnseen(firstInstall: Bool) -> [ReleaseNote] {
        let defaults = UserDefaults.standard
        let current = currentBuild
        let released = all.filter { $0.build <= current }
        defer { defaults.set(max(current, defaults.integer(forKey: lastSeenKey)), forKey: lastSeenKey) }
        guard defaults.object(forKey: lastSeenKey) != nil else {
            // Updated from a build that kept no record: show the latest release only.
            return firstInstall ? [] : Array(released.prefix(1))
        }
        let lastSeen = defaults.integer(forKey: lastSeenKey)
        return released.filter { $0.build > lastSeen }
    }
}

struct ReleaseNote: Identifiable {
    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    let version: String
    let build: Int
    let date: String
    let items: [Item]
    var id: Int { build }
    var label: String { "\(version) (\(build))" }
}

private struct ReleaseNoteRow: View {
    let item: ReleaseNote.Item

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.nordicSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: item.symbol)
                .font(.title2)
                .foregroundStyle(Color(.accent))
                .frame(width: 36)
        }
    }
}

/// Shown once after an update.
struct WhatsNewView: View {
    let notes: [ReleaseNote]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(notes) { note in
                        ForEach(note.items) { ReleaseNoteRow(item: $0) }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.nordicText)
            .background(Color.nordicBackground)
            .navigationTitle("What's New")
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .fontWeight(.semibold)
                .foregroundStyle(Color.nordicOnAccent)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .frame(maxWidth: 520)
                .padding(24)
            }
        }
    }
}

/// Every release's notes, from Settings.
struct ReleaseNotesView: View {
    var body: some View {
        List {
            ForEach(ReleaseNotes.all) { note in
                Section {
                    ForEach(note.items) { ReleaseNoteRow(item: $0) }
                } header: {
                    Text("\(note.label) · \(note.date)")
                }
                .listRowBackground(Color.nordicSurface)
            }
        }
        .nordicListStyle()
        .navigationTitle("Release Notes")
    }
}
