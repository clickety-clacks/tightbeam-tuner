import SwiftUI

/// What changed in each release, newest first. Each build number identifies the app build
/// associated with that entry.
enum ReleaseNotes {
    static var history: [ReleaseNote] {
        guard
            let url = Bundle.main.url(forResource: "ReleaseNotesHistory", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let notes = try? JSONDecoder().decode([ReleaseNote].self, from: data)
        else {
            return []
        }
        return notes
    }

    private static let lastSeenKey = "releaseNotesLastSeenBuild"

    /// The bundled author-written note is included only when it names this exact build.
    /// Local development keeps an unnumbered draft out of the release list.
    static var all: [ReleaseNote] {
        notes(including: currentBuildNote())
    }

    static func notes(including currentBuildNote: ReleaseNote?) -> [ReleaseNote] {
        ([currentBuildNote].compactMap { $0 } + history).sorted { $0.build > $1.build }
    }

    static func compatibilityStatement(in note: ReleaseNote?) -> String? {
        note?.items.first(where: { $0.title.caseInsensitiveCompare("Compatibility") == .orderedSame })?.detail
    }

    static var currentCompatibilityStatement: String? {
        compatibilityStatement(in: currentBuildNote())
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
                Text(item.title).font(TunerTypography.title)
                Text(item.detail)
                    .font(TunerTypography.compactBody)
                    .foregroundStyle(Color.nordicSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: item.symbol)
                .font(TunerTypography.symbolTitle)
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
                .font(TunerTypography.body)
            }
            .foregroundStyle(Color.nordicText)
            .background(Color.nordicSurface)
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
