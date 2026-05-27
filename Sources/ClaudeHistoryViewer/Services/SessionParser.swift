import Foundation

enum SessionParser {

    // MARK: - 会话列表（轻量扫一遍取标题/数量/起始时间）

    struct Summary {
        var title: String = "(空会话)"
        var userMessages: Int = 0
        var startTime: Date? = nil
        var cwd: String? = nil
    }

    struct ParsedFull {
        let messages: [Message]
        let summary: Summary
    }

    static func listSessions(in project: Project) -> [Session] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: project.url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.compactMap { url -> Session? in
            guard url.pathExtension == "jsonl" else { return nil }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let summary = scanSummary(url: url)
            return Session(
                id: url.deletingPathExtension().lastPathComponent,
                url: url,
                projectId: project.id,
                title: summary.title,
                messageCount: summary.userMessages,
                startTime: summary.startTime,
                lastModified: modDate,
                cwd: summary.cwd,
                isFavorite: false,
                tags: []
            )
        }
        .sorted { $0.lastModified > $1.lastModified }
    }

    static func scanSummary(url: URL) -> Summary {
        var s = Summary()
        guard let lines = readLines(url) else { return s }
        var titleSet = false

        for raw in lines {
            guard let obj = parseJSON(raw) else { continue }

            if s.startTime == nil, let ts = obj["timestamp"] as? String {
                s.startTime = parseDate(ts)
            }

            guard obj["type"] as? String == "user",
                  let msg = obj["message"] as? [String: Any] else { continue }

            // 顺便抓 cwd（用户消息行才有）
            if s.cwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                s.cwd = cwd
            }

            if let arr = msg["content"] as? [[String: Any]] {
                // 跳过纯 tool_result 行（这些是工具回灌，不算"用户消息"）
                let allToolResults = arr.allSatisfy { ($0["type"] as? String) == "tool_result" }
                if allToolResults { continue }
                if !titleSet {
                    let firstText = arr.compactMap {
                        ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil
                    }.first
                    if let t = firstText, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        s.title = String(t.prefix(80))
                        titleSet = true
                    }
                }
                s.userMessages += 1
            } else if let str = msg["content"] as? String {
                if !titleSet, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    s.title = String(str.prefix(80))
                    titleSet = true
                }
                s.userMessages += 1
            }
        }
        return s
    }

    /// 单遍扫描，同时产出 messages + summary。IndexBuilder 用。
    static func parseFull(url: URL) -> ParsedFull {
        guard let lines = readLines(url) else { return ParsedFull(messages: [], summary: Summary()) }

        var messages: [Message] = []
        var s = Summary()
        var titleSet = false
        var counter = 0

        for raw in lines {
            counter += 1
            guard let obj = parseJSON(raw) else { continue }
            let ts = (obj["timestamp"] as? String).flatMap(parseDate)
            let type = obj["type"] as? String ?? ""
            let baseId = "\(counter)"

            if s.startTime == nil, let t = ts { s.startTime = t }

            switch type {
            case "user":
                guard let msg = obj["message"] as? [String: Any] else { continue }
                if s.cwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                    s.cwd = cwd
                }
                if let arr = msg["content"] as? [[String: Any]] {
                    let allToolResults = arr.allSatisfy { ($0["type"] as? String) == "tool_result" }
                    if !allToolResults, !titleSet {
                        let firstText = arr.compactMap {
                            ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil
                        }.first
                        if let t = firstText,
                           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            s.title = String(t.prefix(80))
                            titleSet = true
                        }
                    }
                    if !allToolResults { s.userMessages += 1 }
                    for (idx, block) in arr.enumerated() {
                        let id = "\(baseId).\(idx)"
                        switch block["type"] as? String {
                        case "text":
                            if let t = block["text"] as? String, !t.isEmpty {
                                messages.append(.init(id: id, kind: .userText(t), timestamp: ts))
                            }
                        case "tool_result":
                            let useId = block["tool_use_id"] as? String
                            let content = extractContent(block["content"])
                            let isError = (block["is_error"] as? Bool) ?? false
                            messages.append(.init(
                                id: id,
                                kind: .toolResult(toolUseId: useId, content: content, isError: isError),
                                timestamp: ts
                            ))
                        default:
                            break
                        }
                    }
                } else if let str = msg["content"] as? String, !str.isEmpty {
                    if !titleSet,
                       !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        s.title = String(str.prefix(80))
                        titleSet = true
                    }
                    s.userMessages += 1
                    messages.append(.init(id: baseId, kind: .userText(str), timestamp: ts))
                }

            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let arr = msg["content"] as? [[String: Any]] else { continue }
                for (idx, block) in arr.enumerated() {
                    let id = "\(baseId).\(idx)"
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String, !t.isEmpty {
                            messages.append(.init(id: id, kind: .assistantText(t), timestamp: ts))
                        }
                    case "thinking":
                        if let t = block["thinking"] as? String, !t.isEmpty {
                            messages.append(.init(id: id, kind: .assistantThinking(t), timestamp: ts))
                        }
                    case "tool_use":
                        let name = block["name"] as? String ?? "?"
                        let inputAny = block["input"] ?? [:]
                        let inputStr: String = {
                            if let data = try? JSONSerialization.data(
                                withJSONObject: inputAny,
                                options: [.prettyPrinted, .sortedKeys]
                            ), let s = String(data: data, encoding: .utf8) { return s }
                            return "{}"
                        }()
                        let useId = block["id"] as? String
                        messages.append(.init(
                            id: id,
                            kind: .toolUse(name: name, input: inputStr, id: useId),
                            timestamp: ts
                        ))
                    default:
                        break
                    }
                }

            default:
                continue
            }
        }

        return ParsedFull(messages: messages, summary: s)
    }

    // MARK: - 完整解析

    static func parseMessages(url: URL) -> [Message] {
        guard let lines = readLines(url) else { return [] }

        var messages: [Message] = []
        var counter = 0

        for raw in lines {
            counter += 1
            guard let obj = parseJSON(raw) else { continue }

            let ts = (obj["timestamp"] as? String).flatMap(parseDate)
            let type = obj["type"] as? String ?? ""
            let baseId = "\(counter)"

            switch type {
            case "user":
                guard let msg = obj["message"] as? [String: Any] else { continue }
                if let arr = msg["content"] as? [[String: Any]] {
                    for (idx, block) in arr.enumerated() {
                        let id = "\(baseId).\(idx)"
                        switch block["type"] as? String {
                        case "text":
                            if let t = block["text"] as? String, !t.isEmpty {
                                messages.append(.init(id: id, kind: .userText(t), timestamp: ts))
                            }
                        case "tool_result":
                            let useId = block["tool_use_id"] as? String
                            let content = extractContent(block["content"])
                            let isError = (block["is_error"] as? Bool) ?? false
                            messages.append(.init(
                                id: id,
                                kind: .toolResult(toolUseId: useId, content: content, isError: isError),
                                timestamp: ts
                            ))
                        default:
                            break
                        }
                    }
                } else if let str = msg["content"] as? String, !str.isEmpty {
                    messages.append(.init(id: baseId, kind: .userText(str), timestamp: ts))
                }

            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let arr = msg["content"] as? [[String: Any]] else { continue }
                for (idx, block) in arr.enumerated() {
                    let id = "\(baseId).\(idx)"
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String, !t.isEmpty {
                            messages.append(.init(id: id, kind: .assistantText(t), timestamp: ts))
                        }
                    case "thinking":
                        if let t = block["thinking"] as? String, !t.isEmpty {
                            messages.append(.init(id: id, kind: .assistantThinking(t), timestamp: ts))
                        }
                    case "tool_use":
                        let name = block["name"] as? String ?? "?"
                        let inputAny = block["input"] ?? [:]
                        let inputStr: String
                        if let data = try? JSONSerialization.data(
                            withJSONObject: inputAny,
                            options: [.prettyPrinted, .sortedKeys]
                        ), let s = String(data: data, encoding: .utf8) {
                            inputStr = s
                        } else {
                            inputStr = "{}"
                        }
                        let useId = block["id"] as? String
                        messages.append(.init(
                            id: id,
                            kind: .toolUse(name: name, input: inputStr, id: useId),
                            timestamp: ts
                        ))
                    default:
                        break
                    }
                }

            default:
                // permission-mode / file-history-snapshot / attachment 等 — 忽略
                continue
            }
        }

        return messages
    }

    // MARK: - 工具方法

    private static func readLines(_ url: URL) -> [Substring]? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
    }

    private static func parseJSON(_ raw: Substring) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func parseDate(_ s: String) -> Date? {
        // Claude Code 写的格式带毫秒；ISO8601DateFormatter 默认不带，需要切换 options。
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: s) { return d }
        let basic = ISO8601DateFormatter()
        return basic.date(from: s)
    }

    private static func extractContent(_ any: Any?) -> String {
        if let str = any as? String { return str }
        if let arr = any as? [[String: Any]] {
            return arr.compactMap { item -> String? in
                if (item["type"] as? String) == "text" { return item["text"] as? String }
                return nil
            }.joined(separator: "\n")
        }
        if let any,
           let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return ""
    }
}
