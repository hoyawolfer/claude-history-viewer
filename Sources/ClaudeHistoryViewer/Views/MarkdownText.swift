import SwiftUI

/// 轻量 markdown 块级渲染：ATX/setext 标题、围栏代码块、嵌套有序/无序列表、
/// GFM 表格、引用、分隔线、段落。行内格式（**粗体**、*斜体*、`代码`、[链接]）
/// 交给系统的 AttributedString。零第三方依赖；解析失败时回退为纯文本。
struct MarkdownText: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            MarkdownInline(text)
                .font(headingFont(level))
                .fontWeight(.bold)

        case .paragraph(let text):
            MarkdownInline(text)
                .font(.body)

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)

        case .list(let nodes):
            ListNodesView(nodes: nodes)

        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)

        case .blockquote(let lines):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                MarkdownInline(lines.joined(separator: "\n"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .horizontalRule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        case 4: return .body
        default: return .callout
        }
    }
}

// MARK: - 行内格式

/// 用 AttributedString 渲染单段行内 markdown，失败时回退纯文本。
private struct MarkdownInline: View {
    let raw: String
    var fillWidth: Bool = true
    init(_ raw: String, fillWidth: Bool = true) {
        self.raw = raw
        self.fillWidth = fillWidth
    }

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
    }

    private var attributed: AttributedString {
        if let attr = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(raw)
    }
}

// MARK: - 嵌套列表

private struct ListNodesView: View {
    let nodes: [ListNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: node.ordered ? "\(node.number)." : "•")
                            .font(node.ordered ? .body.monospacedDigit() : .body)
                            .foregroundStyle(node.ordered ? .secondary : .primary)
                        MarkdownInline(node.text).font(.body)
                    }
                    if !node.children.isEmpty {
                        ListNodesView(nodes: node.children)
                            .padding(.leading, 16)
                    }
                }
            }
        }
    }
}

// MARK: - 表格（GFM）

private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    MarkdownInline(cell, fillWidth: false).font(.body.bold())
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        MarkdownInline(cell, fillWidth: false).font(.body)
                    }
                }
            }
        }
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - 代码块

private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(verbatim: language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                Divider()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 块级模型

struct ListNode {
    let ordered: Bool
    let number: Int
    let text: String
    let children: [ListNode]
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(language: String?, code: String)
    case list([ListNode])
    case table(header: [String], rows: [[String]])
    case blockquote([String])
    case horizontalRule
}

// MARK: - 块级解析

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 围栏代码块 ``` ... ```
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 } // 跳过结束围栏
                blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang,
                                         code: code.joined(separator: "\n")))
                continue
            }

            // 空行
            if trimmed.isEmpty { i += 1; continue }

            // 分隔线（行首单独的 ---/***/___，长度 >= 3）
            if isHorizontalRule(trimmed) {
                blocks.append(.horizontalRule); i += 1; continue
            }

            // ATX 标题
            if let h = parseHeading(trimmed) {
                blocks.append(.heading(level: h.level, text: h.text)); i += 1; continue
            }

            // GFM 表格（表头行 + 分隔行）
            if let table = parseTable(lines, i) {
                blocks.append(.table(header: table.header, rows: table.rows))
                i = table.next; continue
            }

            // 引用块
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.blockquote(quote)); continue
            }

            // 列表（含嵌套）
            if isListLine(trimmed) {
                var raw: [RawListItem] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    let indent = leadingSpaces(l)
                    let stripped = String(l.dropFirst(indent))
                    if isUnorderedItem(stripped) {
                        raw.append(RawListItem(indent: indent, ordered: false, number: 0,
                                               text: String(stripped.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                    } else if let m = orderedMarker(stripped) {
                        raw.append(RawListItem(indent: indent, ordered: true, number: m.number, text: m.rest))
                    } else {
                        break // 不处理懒续行
                    }
                    i += 1
                }
                var pos = 0
                let nodes = buildNodes(raw, &pos, indent: raw.first?.indent ?? 0)
                blocks.append(.list(nodes)); continue
            }

            // 段落（吃到空行或下一个块边界；并识别 setext 标题）
            var para: [String] = []
            var emittedSetext = false
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || isBlockStart(t) { break }
                para.append(lines[i]); i += 1
                // setext：当前段落紧跟一行 === 或 ---
                if i < lines.count, let level = setextUnderline(lines[i].trimmingCharacters(in: .whitespaces)) {
                    blocks.append(.heading(level: level, text: para.joined(separator: " ")))
                    i += 1
                    emittedSetext = true
                    break
                }
            }
            if !emittedSetext, !para.isEmpty {
                blocks.append(.paragraph(para.joined(separator: "\n")))
            }
        }
        return blocks
    }

    // MARK: 列表树构建

    private struct RawListItem {
        let indent: Int
        let ordered: Bool
        let number: Int
        let text: String
    }

    private static func buildNodes(_ items: [RawListItem], _ pos: inout Int, indent: Int) -> [ListNode] {
        var nodes: [ListNode] = []
        while pos < items.count {
            let it = items[pos]
            if it.indent < indent { break }
            if it.indent > indent {
                // 深缩进但无同级父项：挂到上一个节点下
                if let last = nodes.popLast() {
                    let children = buildNodes(items, &pos, indent: it.indent)
                    nodes.append(ListNode(ordered: last.ordered, number: last.number,
                                          text: last.text, children: last.children + children))
                } else {
                    nodes.append(contentsOf: buildNodes(items, &pos, indent: it.indent))
                }
                continue
            }
            pos += 1
            var children: [ListNode] = []
            if pos < items.count, items[pos].indent > indent {
                children = buildNodes(items, &pos, indent: items[pos].indent)
            }
            nodes.append(ListNode(ordered: it.ordered, number: it.number, text: it.text, children: children))
        }
        return nodes
    }

    // MARK: 表格解析

    private static func parseTable(_ lines: [String], _ i: Int) -> (header: [String], rows: [[String]], next: Int)? {
        guard i + 1 < lines.count else { return nil }
        guard lines[i].contains("|") else { return nil }
        guard isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let header = splitRow(lines[i])
        var rows: [[String]] = []
        var j = i + 2
        while j < lines.count {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || !t.contains("|") { break }
            var cells = splitRow(lines[j])
            while cells.count < header.count { cells.append("") }
            rows.append(cells)
            j += 1
        }
        return (header, rows, j)
    }

    private static func isTableSeparator(_ s: String) -> Bool {
        guard !s.isEmpty, s.contains("-") else { return false }
        return s.allSatisfy { "-:| ".contains($0) }
    }

    private static func splitRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: 行级判定

    private static func isBlockStart(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```")
            || trimmed.hasPrefix(">")
            || isHorizontalRule(trimmed)
            || parseHeading(trimmed) != nil
            || isListLine(trimmed)
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == "-" } || trimmed.allSatisfy { $0 == "*" } || trimmed.allSatisfy { $0 == "_" }
    }

    /// setext 下划线：全 `=` -> h1，全 `-` -> h2，否则 nil。
    private static func setextUnderline(_ trimmed: String) -> Int? {
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1; idx = line.index(after: idx)
        }
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func isListLine(_ trimmed: String) -> Bool {
        isUnorderedItem(trimmed) || orderedMarker(trimmed) != nil
    }

    private static func isUnorderedItem(_ line: String) -> Bool {
        guard line.count >= 2 else { return false }
        guard let first = line.first, first == "-" || first == "*" || first == "+" else { return false }
        return line[line.index(after: line.startIndex)] == " "
    }

    private static func orderedMarker(_ line: String) -> (number: Int, rest: String)? {
        var idx = line.startIndex
        var digits = ""
        while idx < line.endIndex, line[idx].isNumber {
            digits.append(line[idx]); idx = line.index(after: idx)
        }
        guard !digits.isEmpty, idx < line.endIndex, line[idx] == "." else { return nil }
        idx = line.index(after: idx)
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        let rest = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return (Int(digits) ?? 1, rest)
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 }
            else if ch == "\t" { n += 4 }
            else { break }
        }
        return n
    }
}
