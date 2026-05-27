import Foundation

enum IndexBuilder {

    /// 把 ~/.claude/projects/ 下所有 jsonl 增量同步进搜索索引。
    /// progress 回调在 MainActor 上调用，参数是 (已处理, 总数)。
    static func buildAll(
        index: SearchIndex,
        progress: @MainActor @escaping (_ processed: Int, _ total: Int) -> Void
    ) async {
        let fm = FileManager.default
        let projectsDir = ProjectScanner.projectsDir

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // 收集所有 jsonl
        var files: [(projectId: String, sessionId: String, url: URL)] = []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let projectId = dir.lastPathComponent
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for f in entries where f.pathExtension == "jsonl" {
                let sessionId = f.deletingPathExtension().lastPathComponent
                files.append((projectId, sessionId, f))
            }
        }

        let total = files.count
        await MainActor.run { progress(0, total) }

        var done = 0
        for entry in files {
            // 取当前文件指纹
            let attrs = try? fm.attributesOfItem(atPath: entry.url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? Int64) ?? 0

            // 没变就跳过
            if let existing = await index.fingerprint(for: entry.url.path),
               existing.mtime == mtime,
               existing.size == size {
                done += 1
                let snap = done
                if snap % 10 == 0 || snap == total {
                    await MainActor.run { progress(snap, total) }
                }
                continue
            }

            // 重新解析 + 写入（单遍）
            let parsed = SessionParser.parseFull(url: entry.url)
            let records: [SearchIndex.IndexRecord] = parsed.messages.map { msg in
                let kindStr: String
                let toolName: String?
                let text: String
                switch msg.kind {
                case .userText(let t):
                    kindStr = "user"; toolName = nil; text = t
                case .assistantText(let t):
                    kindStr = "assistant"; toolName = nil; text = t
                case .assistantThinking(let t):
                    kindStr = "thinking"; toolName = nil; text = t
                case .toolUse(let n, let i, _):
                    kindStr = "tool_use"; toolName = n
                    text = "\(n)\n\(i)"  // 工具名也入索引
                case .toolResult(_, let c, _):
                    kindStr = "tool_result"; toolName = nil; text = c
                }
                return SearchIndex.IndexRecord(
                    index: msg.id,
                    kind: kindStr,
                    toolName: toolName,
                    timestamp: msg.timestamp,
                    text: text
                )
            }

            await index.upsertSession(
                projectId: entry.projectId,
                sessionId: entry.sessionId,
                filePath: entry.url.path,
                fingerprint: .init(mtime: mtime, size: size),
                records: records
            )

            // 顺便把会话元数据存到 sessions 表（标题/cwd/计数 …）
            // is_favorite / tags 这两个用户字段在这里传啥都没用 — upsertSessionMeta
            // 的 SQL 故意不在 ON CONFLICT 时更新它们，新行用列默认值 0/''。
            let lastModified = (attrs?[.modificationDate] as? Date) ?? Date()
            await index.upsertSessionMeta(.init(
                sessionId: entry.sessionId,
                projectId: entry.projectId,
                title: parsed.summary.title,
                cwd: parsed.summary.cwd,
                userMessageCount: parsed.summary.userMessages,
                startTime: parsed.summary.startTime,
                lastModified: lastModified,
                isFavorite: false,
                tags: []
            ))

            done += 1
            let snap = done
            if snap % 5 == 0 || snap == total {
                await MainActor.run { progress(snap, total) }
            }
        }
    }

    // MARK: - 排序：80% 归一化 BM25 + 20% 时间衰减（30 天半衰期）

    static func rank(_ raw: [SearchIndex.RawHit], now: Date = .init()) -> [SearchHit] {
        guard !raw.isEmpty else { return [] }

        // FTS5 的 bm25 是"越小越相关"（其实是负数），先取反让"越大越相关"。
        let rels = raw.map { -$0.bm25 }
        let minR = rels.min() ?? 0
        let maxR = rels.max() ?? 1
        let span = max(maxR - minR, 1e-9)

        let halfLifeSeconds = 30.0 * 86400.0  // 30 天

        let scored: [SearchHit] = raw.enumerated().map { idx, r in
            let relNorm = (rels[idx] - minR) / span
            let recency: Double
            if let ts = r.timestamp {
                let age = max(now.timeIntervalSince(ts), 0)
                recency = pow(0.5, age / halfLifeSeconds)
            } else {
                recency = 0.3  // 没时间戳的给个保守默认
            }
            let combined = 0.8 * relNorm + 0.2 * recency
            return SearchHit(
                projectId: r.projectId,
                sessionId: r.sessionId,
                messageIndex: r.messageIndex,
                kind: r.kind,
                toolName: r.toolName,
                timestamp: r.timestamp,
                snippet: r.snippet,
                bm25: rels[idx],
                normalizedRelevance: relNorm,
                recency: recency,
                combinedScore: combined,
                cwd: r.cwd
            )
        }
        .sorted { $0.combinedScore > $1.combinedScore }

        return scored
    }
}
