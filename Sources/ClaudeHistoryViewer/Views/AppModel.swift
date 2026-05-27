import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var sessions: [Session] = []
    @Published var messages: [Message] = []
    @Published var selectedProjectId: String?
    @Published var selectedSessionId: String?
    @Published var isLoadingMessages: Bool = false

    // 搜索相关
    @Published var searchQuery: String = ""
    @Published var searchResults: [SearchHit] = []
    @Published var isSearching: Bool = false
    @Published var searchError: String? = nil
    @Published var indexState: IndexState = .idle
    /// 从搜索结果跳转过来时，要滚到的消息 id
    @Published var pendingScrollMessageId: String? = nil

    // 过滤器（会话列表）
    @Published var favoritesOnly: Bool = false
    @Published var tagFilter: String = ""

    let searchIndex: SearchIndex
    private var indexBuiltOnce: Bool = false
    private let watcher: FileWatcher
    private var watcherStarted: Bool = false
    /// 仅在当前显示的会话文件变化时才自动刷新；防止用户切走后被旧数据覆盖。
    private var followCurrentSessionURL: URL? = nil

    init() {
        let cacheDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let dbPath = (cacheDir as NSString)
            .appendingPathComponent("ClaudeHistoryViewer/index.db")
        self.searchIndex = SearchIndex(dbPath: dbPath)
        self.watcher = FileWatcher(directory: ProjectScanner.projectsDir)
        print("[AppModel] index db at: \(dbPath)")
    }

    // MARK: - 项目/会话/消息

    func loadProjects() {
        let scanned = ProjectScanner.scan()
        self.projects = scanned
        print("[Scanner] \(scanned.count) projects")
        if selectedProjectId == nil, let first = scanned.first {
            selectedProjectId = first.id
            loadSessions()
        }
        // 首次加载完项目，启动后台索引构建 + 文件监听
        if !indexBuiltOnce {
            indexBuiltOnce = true
            Task { await rebuildIndex() }
        }
        if !watcherStarted {
            watcherStarted = true
            watcher.start { [weak self] urls in
                Task { @MainActor in self?.handleFileChanges(urls) }
            }
        }
    }

    private func loadMessagesFromCurrent(autoFollow: Bool = false) {
        // 由 watcher 调用，重新解析当前文件并替换 messages
        guard let url = followCurrentSessionURL else { return }
        Task.detached(priority: .userInitiated) {
            let parsed = SessionParser.parseMessages(url: url)
            await MainActor.run {
                guard self.followCurrentSessionURL == url else { return }
                self.messages = parsed
            }
        }
    }

    /// 处理 FSEvents 批量变化事件。
    private func handleFileChanges(_ urls: [URL]) {
        let jsonl = urls.filter { $0.pathExtension == "jsonl" }
        if jsonl.isEmpty { return }

        // 1) 当前显示的会话文件变了 → 立刻重新解析消息
        if let current = followCurrentSessionURL,
           jsonl.contains(where: { $0.path == current.path }) {
            loadMessagesFromCurrent()
        }

        // 2) 当前项目内有任何 jsonl 变化 → 刷新会话列表
        if let pid = selectedProjectId,
           let project = projects.first(where: { $0.id == pid }) {
            let projectChanged = jsonl.contains { url in
                url.deletingLastPathComponent().path == project.url.path
            }
            if projectChanged {
                Task.detached(priority: .utility) {
                    let fresh = SessionParser.listSessions(in: project)
                    await MainActor.run {
                        guard self.selectedProjectId == pid else { return }
                        // 保留用户数据：合并 DB 的 isFavorite/tags
                        var merged: [Session] = []
                        for s in fresh {
                            if let existing = self.sessions.first(where: { $0.id == s.id }) {
                                var copy = s
                                copy.isFavorite = existing.isFavorite
                                copy.tags = existing.tags
                                merged.append(copy)
                            } else {
                                merged.append(s)
                            }
                        }
                        self.sessions = merged
                    }
                }
            }
        }

        // 3) 后台增量索引（IndexBuilder 内部按 mtime+size 判断，未变就跳过）
        Task { await IndexBuilder.buildAll(index: self.searchIndex) { _, _ in } }
    }

    func loadSessions() {
        guard let pid = selectedProjectId,
              let project = projects.first(where: { $0.id == pid }) else {
            sessions = []
            messages = []
            selectedSessionId = nil
            return
        }

        // 先从 DB 缓存取（瞬开），再后台扫文件系统校正（新会话 / mtime 变了）。
        Task { @MainActor in
            let cached = await self.searchIndex.sessionsForProject(pid).map { meta -> Session in
                Session(
                    id: meta.sessionId,
                    url: project.url.appendingPathComponent("\(meta.sessionId).jsonl"),
                    projectId: meta.projectId,
                    title: meta.title.isEmpty ? "(空会话)" : meta.title,
                    messageCount: meta.userMessageCount,
                    startTime: meta.startTime,
                    lastModified: meta.lastModified,
                    cwd: meta.cwd,
                    isFavorite: meta.isFavorite,
                    tags: meta.tags
                )
            }
            if !cached.isEmpty {
                self.sessions = cached
                if self.selectedSessionId == nil {
                    self.selectedSessionId = cached.first?.id
                    self.loadMessages()
                }
            }

            // 后台扫一遍文件系统校正 — 让新建/更新的会话也能立刻看到
            Task.detached(priority: .utility) {
                let fresh = SessionParser.listSessions(in: project)
                await MainActor.run {
                    // 只在 still 是同一个 project 时覆盖，避免用户切走后被旧数据回写
                    guard self.selectedProjectId == pid else { return }
                    self.sessions = fresh
                    if self.selectedSessionId == nil {
                        self.selectedSessionId = fresh.first?.id
                        self.loadMessages()
                    }
                }
            }
        }
    }

    func loadMessages() {
        guard let sid = selectedSessionId,
              let session = sessions.first(where: { $0.id == sid }) else {
            messages = []
            followCurrentSessionURL = nil
            return
        }
        isLoadingMessages = true
        let url = session.url
        followCurrentSessionURL = url
        Task.detached(priority: .userInitiated) {
            let parsed = SessionParser.parseMessages(url: url)
            await MainActor.run {
                guard self.followCurrentSessionURL == url else { return }
                self.messages = parsed
                self.isLoadingMessages = false
            }
        }
    }

    // MARK: - 搜索索引

    func rebuildIndex() async {
        indexState = .building(processed: 0, total: 0)
        await IndexBuilder.buildAll(index: searchIndex) { [weak self] processed, total in
            guard let self else { return }
            if processed < total {
                self.indexState = .building(processed: processed, total: total)
            } else {
                Task {
                    let count = await self.searchIndex.totalMessageCount()
                    await MainActor.run {
                        self.indexState = .ready(messageCount: count)
                        print("[Index] ready, \(count) messages")
                    }
                }
            }
        }
        // total==0 时上面不会进 ready 分支，兜底一下
        if case .building = indexState {
            let count = await searchIndex.totalMessageCount()
            indexState = .ready(messageCount: count)
        }
    }

    // MARK: - 搜索

    func performSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        searchError = nil
        let raw = await searchIndex.rawSearch(q, limit: 500)
        let ranked = IndexBuilder.rank(raw)
        // 取前 100 条
        searchResults = Array(ranked.prefix(100))
        isSearching = false
        if raw.isEmpty {
            // FTS5 语法错误也会返回空，给个轻提示（不区分确实没匹配 vs 语法错误，
            // 因为 SQLite C API 已经在 console 打错误了；这里就只在结果空时不显式报错）
            searchError = nil
        }
    }

    // MARK: - 收藏 / 标签

    func toggleFavorite(sessionId: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].isFavorite.toggle()
        let newValue = sessions[idx].isFavorite
        Task { await searchIndex.setFavorite(sessionId: sessionId, isFavorite: newValue) }
    }

    func setTags(sessionId: String, tags: [String]) {
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].tags = cleaned
        Task { await searchIndex.setTags(sessionId: sessionId, tags: cleaned) }
    }

    /// 应用 favoritesOnly + tagFilter 之后的会话列表（视图层用这个，不直接用 sessions）
    var filteredSessions: [Session] {
        var list = sessions
        if favoritesOnly { list = list.filter { $0.isFavorite } }
        let f = tagFilter.trimmingCharacters(in: .whitespaces).lowercased()
        if !f.isEmpty {
            list = list.filter { s in
                s.tags.contains { $0.lowercased().contains(f) }
            }
        }
        return list
    }

    /// 点击一条搜索结果：切换到对应项目/会话，并请求滚动到对应消息
    func jumpTo(hit: SearchHit) {
        if selectedProjectId != hit.projectId {
            selectedProjectId = hit.projectId
            // loadSessions() 会被 onChange 触发
            // 但 selectedSessionId 会被重置为第一个，所以这里要在 sessions 加载后再设置
            Task { @MainActor in
                // 等会话列表加载（loadSessions 是同步的，但通过 onChange 触发，
                // 直接调用一次确保数据就绪）
                if let project = projects.first(where: { $0.id == hit.projectId }) {
                    sessions = SessionParser.listSessions(in: project)
                }
                selectedSessionId = hit.sessionId
                loadMessages()
                pendingScrollMessageId = hit.messageIndex
            }
        } else if selectedSessionId != hit.sessionId {
            selectedSessionId = hit.sessionId
            loadMessages()
            pendingScrollMessageId = hit.messageIndex
        } else {
            pendingScrollMessageId = hit.messageIndex
        }
    }
}
