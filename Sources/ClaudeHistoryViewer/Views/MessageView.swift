import SwiftUI

struct MessageView: View {
    let message: Message

    var body: some View {
        switch message.kind {
        case .userText(let text):
            BubbleView(roleText: T("role.you"), color: .blue, text: text, alignment: .trailing)
        case .assistantText(let text):
            BubbleView(roleText: T("role.claude"), color: .green, text: text, alignment: .leading)
        case .assistantThinking(let text):
            CollapsibleBlock(
                titleText: T("role.thinking"),
                symbol: "brain",
                color: .purple,
                content: text,
                monospaced: false,
                defaultExpanded: false
            )
        case .toolUse(let name, let input, _):
            CollapsibleBlock(
                titleText: Text(verbatim: Lf("role.tool.named", name)),
                symbol: "wrench.and.screwdriver",
                color: .orange,
                content: input,
                monospaced: true,
                defaultExpanded: false
            )
        case .toolResult(_, let content, let isError):
            CollapsibleBlock(
                titleText: isError ? T("role.tool_result.error") : T("role.tool_result"),
                symbol: isError ? "exclamationmark.triangle" : "arrow.down.doc",
                color: isError ? .red : .gray,
                content: content,
                monospaced: true,
                defaultExpanded: false
            )
        }
    }
}

// MARK: - 普通气泡（user / assistant text）

private struct BubbleView: View {
    let roleText: Text
    let color: Color
    let text: String
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            roleText
                .font(.caption2.bold())
                .foregroundStyle(color)
            renderedText
                .textSelection(.enabled)
                .padding(10)
                .background(color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(color.opacity(0.15), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }

    @ViewBuilder
    private var renderedText: some View {
        // 内联 markdown 渲染（**粗体**、`代码`、链接等）。不支持代码块/列表，
        // 但对绝大多数 Claude 输出足够。复杂的我们就当纯文本展示。
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
                .font(.body)
                .frame(maxWidth: 720, alignment: .leading)
        } else {
            Text(text)
                .font(.body)
                .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

// MARK: - 折叠块（thinking / tool_use / tool_result）

private struct CollapsibleBlock: View {
    let titleText: Text
    let symbol: String
    let color: Color
    let content: String
    let monospaced: Bool
    let defaultExpanded: Bool

    @State private var expanded: Bool

    init(titleText: Text, symbol: String, color: Color, content: String, monospaced: Bool, defaultExpanded: Bool) {
        self.titleText = titleText
        self.symbol = symbol
        self.color = color
        self.content = content
        self.monospaced = monospaced
        self.defaultExpanded = defaultExpanded
        _expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Image(systemName: symbol)
                        .font(.caption)
                    titleText
                        .font(.caption.bold())
                    Spacer()
                    Text(verbatim: Lf("chars.count.format", content.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                ScrollView {
                    Text(content)
                        .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 320)
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .background(color.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: 720, alignment: .leading)
    }
}
