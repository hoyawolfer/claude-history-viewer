import Foundation

/// 一条搜索命中。snippet 里用 ⟦…⟧ 包围匹配片段。
struct SearchHit: Identifiable, Hashable {
    var id: String { "\(sessionId)#\(messageIndex)" }

    let projectId: String
    let sessionId: String
    let messageIndex: String   // 与 Message.id 对齐
    let kind: String           // "user" / "assistant" / "thinking" / "tool_use" / "tool_result"
    let toolName: String?
    let timestamp: Date?
    let snippet: String        // 含 ⟦matched⟧ 标记
    let bm25: Double           // FTS5 原始分（已取反，大=更相关）
    let normalizedRelevance: Double  // 0..1
    let recency: Double              // 0..1
    let combinedScore: Double        // 最终排序分（大=更靠前）
    let cwd: String?           // 会话原始工作目录，用于拼恢复命令
}

/// 生成可直接粘进终端执行的恢复命令。
/// 形如 `cd "<cwd>" && claude --resume <session-id>`。
/// 没拿到 cwd 时退化为只带 `claude --resume <id>`（用户得自己 cd）。
enum ResumeCommand {
    static func build(cwd: String?, sessionId: String) -> String {
        let resume = "claude --resume \(sessionId)"
        guard let cwd, !cwd.isEmpty else { return resume }
        // 简单的 shell 转义：把 cwd 里的双引号转义。绝大多数路径不含双引号。
        let escaped = cwd.replacingOccurrences(of: "\"", with: "\\\"")
        return "cd \"\(escaped)\" && \(resume)"
    }
}

enum IndexState: Equatable {
    case idle
    case building(processed: Int, total: Int)
    case ready(messageCount: Int)
    case failed(String)
}
