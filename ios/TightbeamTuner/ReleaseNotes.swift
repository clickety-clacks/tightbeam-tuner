import SwiftUI

/// What changed in each release, newest first. Each build number identifies the app build
/// associated with that entry.
enum ReleaseNotes {
    static let history: [ReleaseNote] = [
        ReleaseNote(version: "1.0", build: 59, date: "November 11, 2026", items: [
            .init(symbol: "text.bubble", title: "Keep Chat clear during its first layout",
                  detail: "Tuner reserves space for its message field before Chat's first layout measurement, keeping the conversation controls clear."),
            .init(symbol: "person.2", title: "See your saved agents at launch",
                  detail: "Tuner shows the saved agent list as soon as it opens, then reconciles it with the current roster."),
            .init(symbol: "arrow.up.circle", title: "Send sits beside the message field",
                  detail: "Send is a separate control beside the field and stays aligned with the last line as the field grows."),
            .init(symbol: "arrowshape.turn.up.left", title: "See when an agent is replying",
                  detail: "After you send a prompt, its row moves to Replies with a spinner until a new assistant message arrives. If sending fails, the row stays where it was."),
            .init(symbol: "arrow.up.circle", title: "Send matches the message field",
                  detail: "The one-line Send control matches the 44-point field height, while multiline drafts keep it aligned with the last line."),
            .init(symbol: "checkmark.circle", title: "Release notes match the build",
                  detail: "Each numbered archive requires notes for that exact build. Tuner's What's Changed and TestFlight use the same authored notes."),
        ]),
        ReleaseNote(version: "1.0", build: 52, date: "November 7, 2026", items: [
            .init(symbol: "text.bubble", title: "Keep the compact message field full size",
                  detail: "The empty or one-line message field keeps its full height and rounded ends in compact layouts."),
            .init(symbol: "keyboard", title: "Keep Chat's layout in step with the keyboard",
                  detail: "When Tuner returns to the foreground, Chat refreshes its keyboard layout to match the keyboard's current position."),
            .init(symbol: "text.bubble", title: "Keep the message field aligned with the keyboard",
                  detail: "In compact layouts, the message field follows the keyboard's current visibility while it stays focused."),
            .init(symbol: "sidebar.left", title: "The agent list stays where you left it",
                  detail: "When you return to Tuner, the list stays open, closed, or floating where it was. Rotating while Tuner is active keeps working as before."),
            .init(symbol: "person.2", title: "The agent list stays up to date",
                  detail: "New agents appear, changed details update, and retired agents disappear while Tuner is open, without pulling to refresh."),
        ]),
        ReleaseNote(version: "1.0", build: 51, date: "November 7, 2026", items: [
            .init(symbol: "person.2", title: "The agent list stays up to date",
                  detail: "New agents appear, changed details update, and retired agents disappear while Tuner is open, without pulling to refresh."),
        ]),
        ReleaseNote(version: "1.0", build: 50, date: "November 7, 2026", items: [
            .init(symbol: "text.bubble", title: "Keep the message field aligned with the keyboard",
                  detail: "In compact layouts, the message field follows the keyboard's current visibility while it stays focused."),
            .init(symbol: "sidebar.left", title: "The agent list stays where you left it",
                  detail: "When you return to Tuner, the list stays open, closed, or floating where it was. Rotating while Tuner is active keeps working as before."),
        ]),
        ReleaseNote(version: "1.0", build: 49, date: "November 7, 2026", items: [
            .init(symbol: "keyboard", title: "Keep Chat's layout in step with the keyboard",
                  detail: "When Tuner returns to the foreground, Chat refreshes its keyboard layout to match the keyboard's current position."),
        ]),
        ReleaseNote(version: "1.0", build: 48, date: "November 7, 2026", items: [
            .init(symbol: "text.bubble", title: "Keep the compact message field full size",
                  detail: "The empty or one-line message field keeps its full height and rounded ends in compact layouts."),
        ]),
        ReleaseNote(version: "1.0", build: 47, date: "November 3, 2026", items: [
            .init(symbol: "text.bubble", title: "Keep the message field full size when the keyboard closes",
                  detail: "When the keyboard closes, the empty message field keeps room for its text and send button while its bottom stays aligned with Filter agents."),
        ]),
        ReleaseNote(version: "1.0", build: 46, date: "November 2, 2026", items: [
            .init(symbol: "text.bubble", title: "Match the message field to Filter agents",
                  detail: "On iPhone, the empty message field matches Filter agents in height and stays the same distance from the bottom as the keyboard opens or closes. Side by side, their edges line up while Chat content stays clear of the field."),
        ]),
        ReleaseNote(version: "1.0", build: 45, date: "November 2, 2026", items: [
            .init(symbol: "line.3.horizontal.decrease.circle", title: "Keep filtered iPad results above the keyboard",
                  detail: "At standard text size on iPad, the last filtered result stays visible above the keyboard, clear of Filter agents, and tappable."),
        ]),
        ReleaseNote(version: "1.0", build: 44, date: "November 1, 2026", items: [
            .init(symbol: "sidebar.left", title: "The agent list stays where you left it",
                  detail: "When you return to Tuner, the list stays open, closed, or floating where it was. Rotating while Tuner is active keeps working as before."),
        ]),
        ReleaseNote(version: "1.0", build: 43, date: "November 1, 2026", items: [
            .init(symbol: "sidebar.left", title: "Restore the standard agent-list control",
                  detail: "The standard sidebar button is back without a Replied count because this system-owned control has no supported badge mechanism."),
        ]),
        ReleaseNote(version: "1.0", build: 42, date: "October 31, 2026", items: [
            .init(symbol: "line.3.horizontal.decrease.circle", title: "Filtered results sit closer to Filter agents",
                  detail: "The last matching agent stays visible just above Filter agents, with the keyboard open or closed."),
        ]),
        ReleaseNote(version: "1.0", build: 41, date: "October 31, 2026", items: [
            .init(symbol: "sidebar.left", title: "See Replied from the list controls",
                  detail: "When the agent list is hidden, its return control shows how many agents are listed in Replied after filtering."),
        ]),
        ReleaseNote(version: "1.0", build: 40, date: "October 31, 2026", items: [
            .init(symbol: "line.3.horizontal.decrease.circle", title: "Filter results stay clear",
                  detail: "Scroll the last matching agent above Filter agents and tap it, with the keyboard open or closed."),
        ]),
        ReleaseNote(version: "1.0", build: 39, date: "October 31, 2026", items: [
            .init(symbol: "arrow.up.to.line", title: "Chat stays clear of the top bar",
                  detail: "The conversation now starts below Tuner's top toolbar, so its controls stay clear."),
        ]),
        ReleaseNote(version: "1.0", build: 38, date: "October 30, 2026", items: [
            .init(symbol: "xmark", title: "Remove a chat from Recent",
                  detail: "Swipe a Recent row to reveal X and remove it from this device. Open its chat again to add it back."),
        ]),
        ReleaseNote(version: "1.0", build: 37, date: "October 30, 2026", items: [
            .init(symbol: "bubble.left.and.bubble.right", title: "Replied opens the conversation",
                  detail: "Tapping a reply opens its chat while clearing it from Replied on this device."),
        ]),
        ReleaseNote(version: "1.0", build: 36, date: "October 30, 2026", items: [
            .init(symbol: "arrowshape.turn.up.left", title: "Replied follows the chat on screen",
                  detail: "A reply joins Replied only when Tuner receives it while its chat is off screen on this device. Replies that arrive while the chat is open stay out after you switch away, reconnect, or restart."),
        ]),
        ReleaseNote(version: "1.0", build: 35, date: "October 30, 2026", items: [
            .init(symbol: "list.bullet", title: "Collapse agent sections",
                  detail: "Replied, Recent and Agents now collapse and expand independently, and Tuner remembers each choice. Their count pills follow text and archetype filters; collapsing a section or agent branch does not change the count. Grey parent rows shown only for context are left out of the Agents count."),
        ]),
        ReleaseNote(version: "1.0", build: 34, date: "October 29, 2026", items: [
            .init(symbol: "arrow.triangle.2.circlepath", title: "Getting ready for shared read positions",
                  detail: "Once available, Tuner can pick up which replies you have read on your other devices."),
        ]),
        ReleaseNote(version: "1.0", build: 33, date: "October 29, 2026", items: [
            .init(symbol: "arrowshape.turn.up.left", title: "Replied starts with new replies",
                  detail: "When nothing has been marked as read yet, Replied starts empty and fills with replies that arrive while Tuner is open."),
            .init(symbol: "bubble.left.and.bubble.right", title: "Opening a chat clears it from Replied",
                  detail: "An agent leaves Replied when you open its chat and returns when it replies again."),
        ]),
        ReleaseNote(version: "1.0", build: 32, date: "October 29, 2026", items: [
            .init(symbol: "arrowshape.turn.up.left", title: "Replied",
                  detail: "Agents that replied to you appear at the top of the agent list, newest first, until you read their reply."),
        ]),
        ReleaseNote(version: "1.0", build: 31, date: "October 29, 2026", items: [
            .init(symbol: "rectangle.split.2x1", title: "Message field lines up with Filter agents",
                  detail: "Wherever the agent list sits beside the chat, the message field now sits level with Filter agents, including on iOS 27 and iPhone Duo."),
        ]),
        ReleaseNote(version: "1.0", build: 30, date: "October 28, 2026", items: [
            .init(symbol: "sidebar.left", title: "Swipe in from the left for agents",
                  detail: "A swipe from the left edge opens the agent list, even after Chat opens another page."),
            .init(symbol: "arrow.up.circle", title: "Send while Chat reconnects",
                  detail: "A reconnecting feed no longer disables Send. The button stays grey when Chat is unavailable, a message is still on its way to Chat, or the field is empty."),
            .init(symbol: "circle.fill", title: "The dot follows Chat's connection",
                  detail: "Green means connected, yellow means reconnecting, and red means disconnected. Connect reconnects in place and keeps your place in the conversation."),
        ]),
        ReleaseNote(version: "1.0", build: 29, date: "October 28, 2026", items: [
            .init(symbol: "keyboard", title: "The conversation moves with the keyboard",
                  detail: "When the keyboard opens or closes, the newest message slides along with it and the message field, instead of jumping first and leaving an empty gap."),
            .init(symbol: "rectangle.split.2x1", title: "Message field lines up with Filter",
                  detail: "On a large iPhone in landscape, with the agent list beside the chat, the message field sits level with the Filter agents field."),
        ]),
        ReleaseNote(version: "1.0", build: 28, date: "October 26, 2026", items: [
            .init(symbol: "circle.fill", title: "The dot shows the connection",
                  detail: "The Reconnecting banner is gone. The dot in the message field shows the connection: green when connected, yellow while reconnecting, red when disconnected. When it is red, tap it and choose Connect."),
        ]),
        ReleaseNote(version: "1.0", build: 27, date: "October 26, 2026", items: [
            .init(symbol: "arrow.up.circle", title: "Send is grey when it can't send",
                  detail: "While Chat is reconnecting, or the field is empty, the send button turns grey and can't be tapped. If Chat turns a message away because it's reconnecting, the button stays grey until Chat is back."),
        ]),
        ReleaseNote(version: "1.0", build: 26, date: "October 26, 2026", items: [
            .init(symbol: "paperplane", title: "Send the next message sooner",
                  detail: "Once Chat accepts a message, you can send another right away instead of waiting for it to arrive. A message that does not send comes back to the field so you can retry it."),
        ]),
        ReleaseNote(version: "1.0", build: 25, date: "October 26, 2026", items: [
            .init(symbol: "square.and.pencil", title: "Unsent messages are kept",
                  detail: "A message you started typing stays in the field for that agent, even after you quit Tuner or iOS closes it in the background."),
        ]),
        ReleaseNote(version: "1.0", build: 24, date: "October 26, 2026", items: [
            .init(symbol: "arrow.clockwise", title: "Chat comes back after the background",
                  detail: "When iOS clears the chat page while Tuner is in the background, Tuner reloads it as soon as you return, instead of showing a blank page."),
        ]),
        ReleaseNote(version: "1.0", build: 23, date: "October 25, 2026", items: [
            .init(symbol: "arrow.down.to.line", title: "The newest message stays in view",
                  detail: "At the bottom of a conversation, the newest message moves up above the keyboard and the message field instead of hiding behind them. Conversations also open at the newest message."),
        ]),
        ReleaseNote(version: "1.0", build: 22, date: "October 25, 2026", items: [
            .init(symbol: "keyboard", title: "Chat's own message field keeps the keyboard",
                  detail: "When Chat shows its own message field instead of Tuner's, tapping it always brings up the keyboard."),
        ]),
        ReleaseNote(version: "1.0", build: 21, date: "October 25, 2026", items: [
            .init(symbol: "arrow.up.circle", title: "Send button fits the field again",
                  detail: "The send button sits evenly inside the field's rounded end, as it did before the connection dot."),
            .init(symbol: "keyboard", title: "Keyboard stays while you read",
                  detail: "Tapping the conversation or Latest messages no longer puts the keyboard away while you type."),
        ]),
        ReleaseNote(version: "1.0", build: 20, date: "October 25, 2026", items: [
            .init(symbol: "circle.fill", title: "Connection dot",
                  detail: "The message field shows Chat's connection dot at its left again. Tap it for connection details."),
            .init(symbol: "sidebar.left", title: "Agent list closes after choosing",
                  detail: "When the agent list floats over the chat, such as in portrait, choosing an agent closes it. Opening the list puts the keyboard away."),
            .init(symbol: "keyboard.chevron.compact.down", title: "Swipe down to hide the keyboard",
                  detail: "Swipe down on the conversation to put the keyboard away."),
        ]),
        ReleaseNote(version: "1.0", build: 19, date: "October 24, 2026", items: [
            .init(symbol: "clock", title: "Choose how many recents",
                  detail: "Settings sets how many recently opened agents appear in the list, from none up to 50."),
            .init(symbol: "tag", title: "Archetype under each agent",
                  detail: "Every agent in the list shows its archetype below its name."),
        ]),
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

    /// The bundled author-written note is included only when it names this exact build.
    /// Local development keeps an unnumbered draft out of the release list.
    static var all: [ReleaseNote] {
        notes(including: currentBuildNote())
    }

    static func notes(including currentBuildNote: ReleaseNote?) -> [ReleaseNote] {
        ([currentBuildNote].compactMap { $0 } + history).sorted { $0.build > $1.build }
    }

    private static func currentBuildNote(bundle: Bundle = .main) -> ReleaseNote? {
        guard
            let url = bundle.url(forResource: "CurrentBuildReleaseNote", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let note = try? JSONDecoder().decode(ReleaseNote.self, from: data),
            note.build > 0,
            note.build == (Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0),
            note.build > (history.map(\.build).max() ?? 0),
            !note.items.isEmpty
        else {
            return nil
        }
        return note
    }

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
        let lastSeen: Int?
        if defaults.object(forKey: lastSeenKey) != nil {
            lastSeen = defaults.integer(forKey: lastSeenKey)
        } else {
            lastSeen = nil
        }
        defer { defaults.set(max(current, defaults.integer(forKey: lastSeenKey)), forKey: lastSeenKey) }
        return unseenNotes(
            in: all,
            currentBuild: current,
            lastSeenBuild: lastSeen,
            firstInstall: firstInstall
        )
    }

    /// Selects notes for the first screen after an update. This accepts the app bundle's
    /// exact CFBundleVersion and the prior marker, so a new numbered entry is selected on
    /// the first launch that contains it.
    static func unseenNotes(
        in notes: [ReleaseNote],
        currentBuild: Int,
        lastSeenBuild: Int?,
        firstInstall: Bool
    ) -> [ReleaseNote] {
        let released = notes.filter { $0.build <= currentBuild }
        guard let lastSeenBuild else {
            // Updated from a build that kept no record: show the latest release only.
            return firstInstall ? [] : Array(released.prefix(1))
        }
        return released.filter { $0.build > lastSeenBuild }
    }
}

struct ReleaseNote: Identifiable, Decodable {
    struct Item: Identifiable, Decodable {
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
