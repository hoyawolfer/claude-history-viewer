import SwiftUI

struct SessionListView: View {
    let sessions: [Session]
    @Binding var selection: String?
    @Binding var favoritesOnly: Bool
    @Binding var tagFilter: String
    let onToggleFavorite: (String) -> Void
    let onSetTags: (String, [String]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            list
        }
        .navigationTitle(T("nav.sessions"))
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $favoritesOnly) {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
            }
            .toggleStyle(.button)
            .help(T("filter.favorites.help"))

            TextField(L("filter.tag.placeholder"), text: $tagFilter)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
        .padding(8)
    }

    private var list: some View {
        List(sessions, selection: $selection) { s in
            SessionRow(
                session: s,
                onToggleFavorite: { onToggleFavorite(s.id) },
                onSetTags: { newTags in onSetTags(s.id, newTags) }
            )
            .tag(s.id)
            .contextMenu {
                Button {
                    let cmd = ResumeCommand.build(cwd: s.cwd, sessionId: s.id)
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(cmd, forType: .string)
                } label: { T("context.copy_command") }
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(s.id, forType: .string)
                } label: { T("context.copy_session_id") }
                Divider()
                Button {
                    onToggleFavorite(s.id)
                } label: {
                    s.isFavorite ? T("context.unfavorite") : T("context.favorite")
                }
            }
        }
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Label { T("session.empty.title") } icon: { Image(systemName: "bubble.left.and.bubble.right") }
                } description: {
                    T("session.empty.message")
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: Session
    let onToggleFavorite: () -> Void
    let onSetTags: ([String]) -> Void

    @State private var showingTagEditor = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggleFavorite) {
                Image(systemName: session.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(session.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if session.title.isEmpty {
                        T("session.untitled")
                    } else {
                        Text(session.title)
                    }
                }
                .font(.body)
                .lineLimit(2)

                HStack(spacing: 8) {
                    if let t = session.startTime {
                        Text(t, format: .dateTime.month().day().hour().minute())
                    } else {
                        Text(session.lastModified, format: .dateTime.month().day().hour().minute())
                    }
                    Text(verbatim: "·")
                    Text(verbatim: Lf("session.count.format", session.messageCount))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !session.tags.isEmpty || showingTagEditor {
                    tagRow
                }
            }
            Spacer(minLength: 0)

            Button {
                showingTagEditor = true
            } label: {
                Image(systemName: "tag")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showingTagEditor) {
                TagEditor(initial: session.tags) { newTags in
                    onSetTags(newTags)
                    showingTagEditor = false
                }
                .frame(width: 260)
            }
        }
        .padding(.vertical, 2)
    }

    private var tagRow: some View {
        HStack(spacing: 4) {
            ForEach(session.tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(.primary)
                    .clipShape(Capsule())
            }
        }
    }
}

private struct TagEditor: View {
    let initial: [String]
    let onCommit: ([String]) -> Void

    @State private var text: String

    init(initial: [String], onCommit: @escaping ([String]) -> Void) {
        self.initial = initial
        self.onCommit = onCommit
        _text = State(initialValue: initial.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            T("tag.editor.label")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(L("tag.editor.placeholder"), text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button { onCommit(initial) } label: { T("tag.editor.cancel") }
                    .keyboardShortcut(.escape)
                Button { commit() } label: { T("tag.editor.save") }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    private func commit() {
        let tags = text.split(separator: ",").map { String($0) }
        onCommit(tags)
    }
}
