import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            ProjectListView(
                projects: model.projects,
                selection: $model.selectedProjectId
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            SessionListView(
                sessions: model.filteredSessions,
                selection: $model.selectedSessionId,
                favoritesOnly: $model.favoritesOnly,
                tagFilter: $model.tagFilter,
                onToggleFavorite: { sid in model.toggleFavorite(sessionId: sid) },
                onSetTags: { sid, tags in model.setTags(sessionId: sid, tags: tags) }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 420)
        } detail: {
            detailColumn
        }
        .task { model.loadProjects() }
        .onChange(of: model.selectedProjectId) { _, _ in model.loadSessions() }
        .onChange(of: model.selectedSessionId) { _, _ in model.loadMessages() }
        .searchable(
            text: $model.searchQuery,
            placement: .toolbar,
            prompt: T("search.placeholder")
        )
        // 防抖：300ms 内没新输入再发起搜索
        .task(id: model.searchQuery) {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { await model.performSearch() }
        }
        .toolbar {
            indexStatusToolbar
            exportToolbar
        }
    }

    @ToolbarContentBuilder
    private var exportToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                exportCurrentSession()
            } label: {
                Label {
                    T("toolbar.export")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(model.messages.isEmpty || model.isLoadingMessages)
            .help(T("toolbar.export.help"))
        }
    }

    private func exportCurrentSession() {
        guard let sid = model.selectedSessionId,
              let session = model.sessions.first(where: { $0.id == sid }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MarkdownExporter.defaultFilename(for: session)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.title = L("export.panel.title")
        if panel.runModal() == .OK, let url = panel.url {
            let md = MarkdownExporter.render(session: session, messages: model.messages)
            do {
                try md.data(using: .utf8)?.write(to: url, options: .atomic)
                print("[Export] wrote \(url.path)")
            } catch {
                print("[Export] failed: \(error)")
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsView(
                hits: model.searchResults,
                query: model.searchQuery,
                isSearching: model.isSearching
            ) { hit in
                model.jumpTo(hit: hit)
                model.searchQuery = ""  // 关闭搜索面板，回到对话视图
            }
        } else {
            ConversationView(
                messages: model.messages,
                isLoading: model.isLoadingMessages,
                pendingScrollMessageId: $model.pendingScrollMessageId
            )
        }
    }

    @ToolbarContentBuilder
    private var indexStatusToolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            switch model.indexState {
            case .idle:
                EmptyView()
            case .building(let processed, let total):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Group {
                        if total == 0 {
                            T("index.building.indeterminate")
                        } else {
                            Text(verbatim: Lf("index.building.progress", processed, total))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case .ready(let count):
                Text(verbatim: Lf("index.ready", count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let msg):
                Text(verbatim: Lf("index.failed", msg))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
