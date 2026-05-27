import Foundation

enum MarkdownExporter {

    /// 把会话渲染成可读的 Markdown。
    /// - thinking → > blockquote 折叠风格
    /// - tool_use → ```json``` 代码块，标题带工具名
    /// - tool_result → ``` 代码块
    /// - user / assistant → 普通段落 + 二级标题分隔
    static func render(session: Session, messages: [Message]) -> String {
        var out: [String] = []
        out.append("# \(session.title)")
        out.append("")
        out.append("- Session: `\(session.id)`")
        if let cwd = session.cwd { out.append("- CWD: `\(cwd)`") }
        if let t = session.startTime {
            out.append("- Started: \(t.formatted(.dateTime.year().month().day().hour().minute()))")
        }
        out.append("- Resume: `\(ResumeCommand.build(cwd: session.cwd, sessionId: session.id))`")
        out.append("")
        out.append("---")
        out.append("")

        for msg in messages {
            switch msg.kind {
            case .userText(let text):
                out.append("## 👤 You")
                out.append("")
                out.append(text)
                out.append("")

            case .assistantText(let text):
                out.append("## 🤖 Claude")
                out.append("")
                out.append(text)
                out.append("")

            case .assistantThinking(let text):
                out.append("<details><summary>💭 Thinking</summary>")
                out.append("")
                // blockquote 每行前面加 >
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    out.append("> \(line)")
                }
                out.append("")
                out.append("</details>")
                out.append("")

            case .toolUse(let name, let input, _):
                out.append("### 🔧 \(name)")
                out.append("")
                out.append("```json")
                out.append(input)
                out.append("```")
                out.append("")

            case .toolResult(_, let content, let isError):
                let prefix = isError ? "⚠️ Tool result (error)" : "📤 Tool result"
                out.append("<details><summary>\(prefix)</summary>")
                out.append("")
                out.append("```")
                out.append(content)
                out.append("```")
                out.append("")
                out.append("</details>")
                out.append("")
            }
        }

        return out.joined(separator: "\n")
    }

    /// 默认文件名：以会话起始时间 + 标题前缀，文件名安全化。
    static func defaultFilename(for session: Session) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: session.startTime ?? session.lastModified)

        let safeTitle = session.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(40)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = safeTitle.isEmpty ? session.id.prefix(8).description : String(safeTitle)
        return "\(stamp)-\(trimmed).md"
    }
}
