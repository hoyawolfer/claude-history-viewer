import SwiftUI

struct SearchResultsView: View {
    let hits: [SearchHit]
    let query: String
    let isSearching: Bool
    let onSelect: (SearchHit) -> Void

    var body: some View {
        Group {
            if isSearching && hits.isEmpty {
                ProgressView { T("search.loading") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hits.isEmpty {
                ContentUnavailableView {
                    Label { T("search.empty.title") } icon: { Image(systemName: "magnifyingglass") }
                } description: {
                    Text(verbatim: Lf("search.empty.message", query))
                }
            } else {
                List(hits) { hit in
                    Button {
                        onSelect(hit)
                    } label: {
                        SearchHitRow(hit: hit)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(Text(verbatim: Lf("nav.search.title", query)))
        .navigationSubtitle(Text(verbatim: Lf("nav.search.subtitle", hits.count)))
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                kindBadge
                if let toolName = hit.toolName {
                    Text(toolName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let ts = hit.timestamp {
                    Text(ts, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // snippet 里 ⟦…⟧ 是匹配片段，渲染成高亮
            highlightedSnippet
                .font(.callout)
                .lineLimit(3)
            HStack(spacing: 12) {
                metricLabel(L("metric.combined"), hit.combinedScore)
                metricLabel(L("metric.relevance"), hit.normalizedRelevance)
                metricLabel(L("metric.recency"), hit.recency)
                Spacer()
                Text(hit.cwd ?? hit.projectId)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            ResumeCommandStrip(cwd: hit.cwd, sessionId: hit.sessionId)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                copyToPasteboard(ResumeCommand.build(cwd: hit.cwd, sessionId: hit.sessionId))
            } label: { T("context.copy_command") }
            Button {
                copyToPasteboard(hit.sessionId)
            } label: { T("context.copy_session_id") }
        }
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    @ViewBuilder
    private var kindBadge: some View {
        let (labelKey, color): (String, Color) = {
            switch hit.kind {
            case "user":         return ("role.you", .blue)
            case "assistant":    return ("role.claude", .green)
            case "thinking":     return ("role.thinking", .purple)
            case "tool_use":     return ("role.tool", .orange)
            case "tool_result":  return ("role.result", .gray)
            default:             return (hit.kind, .secondary)
            }
        }()
        Text(verbatim: L(labelKey))
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(Capsule())
    }

    private var highlightedSnippet: Text {
        // 解析 ⟦…⟧，匹配片段加粗 + 着色
        var result = Text("")
        var rest = hit.snippet[...]
        while let openRange = rest.range(of: "⟦") {
            let before = rest[..<openRange.lowerBound]
            result = result + Text(String(before))
            let afterOpen = rest[openRange.upperBound...]
            if let closeRange = afterOpen.range(of: "⟧") {
                let matched = afterOpen[..<closeRange.lowerBound]
                result = result + Text(String(matched))
                    .bold()
                    .foregroundColor(.accentColor)
                rest = afterOpen[closeRange.upperBound...]
            } else {
                // 找不到闭合，剩余按原样
                result = result + Text(String(afterOpen))
                return result
            }
        }
        result = result + Text(String(rest))
        return result
    }

    private func metricLabel(_ name: String, _ value: Double) -> some View {
        Text("\(name) \(String(format: "%.2f", value))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// 显示恢复命令 + 一键复制。复制后短暂显示"已复制"。
struct ResumeCommandStrip: View {
    let cwd: String?
    let sessionId: String
    @State private var copied: Bool = false

    private var command: String {
        ResumeCommand.build(cwd: cwd, sessionId: sessionId)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                copy()
            } label: {
                Label {
                    copied ? T("resume.copied") : T("resume.copy")
                } icon: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .labelStyle(.titleAndIcon)
                .font(.caption)
            }
            .buttonStyle(.borderless)
            .tint(copied ? .green : .accentColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.textBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
