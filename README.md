# Claude History Viewer

一个只读的本地工具，用来浏览 Claude Code 在 `~/.claude/projects/` 下存的会话历史。

## 进度

- [x] Day 1 — 数据层（扫目录 / 解析 jsonl / 模型）
- [x] Day 2 — UI 骨架（NavigationSplitView 三栏：项目 / 会话 / 对话）
- [x] Day 3 — 对话渲染（user / assistant / thinking / tool_use / tool_result）
- [x] Day 4 — 全局搜索（SQLite FTS5 + BM25 + 时间衰减）
- [x] 恢复命令：每条搜索结果 / 会话右键菜单可一键复制 `cd <cwd> && claude --resume <id>`
- [x] 会话元数据持久化（title/cwd/count/start_time）—— DB 优先读取，切项目近瞬开
- [x] 实时跟随：FSEvents 监听 `~/.claude/projects`，当前会话变化自动追加消息
- [x] 导出 Markdown：当前会话一键导出为 `.md`
- [x] 收藏 / 标签：会话级 star + 自定义标签，顶部支持过滤
- [x] 国际化：UI 跟随系统语言（英 / 中 / 日 / 韩 / 德），未识别语言默认英文

## 搜索语法（FTS5 原生）

工具栏的搜索框直接接受 FTS5 查询语法：

| 查询 | 含义 |
|---|---|
| `swift build` | 同时包含两个词（隐式 AND） |
| `"swift build"` | 精确短语 |
| `swift OR build` | 任一词 |
| `swift NOT build` | 包含 swift 但不包含 build |
| `fluidsyn*` | 前缀匹配 |
| `NEAR(foo bar, 5)` | 5 个词内邻近 |
| `searching` | Porter 词干，会匹配 `search` / `searched` |

### 排序公式

```
最终分 = 0.8 × 归一化 BM25  +  0.2 × 时间衰减
时间衰减 = 0.5 ^ (距今天数 / 30)   # 30 天半衰期
```

BM25 在结果集内 min-max 归一化到 [0, 1]。结果列表里每行右下角会显示这三个分数。

### 已知限制

- **中文子串不工作**：`porter unicode61` tokenizer 把连续中文当成一个 token，搜 "这个" 不会匹配 "这个是什么库"。中文里的"词"如果两边有标点或空格（包括 markdown 符号、句号、空格、英文等）就能正常匹配。如果需要中文任意子串，下一轮换 `trigram` tokenizer（会失去英文词干）。
- **首次启动构建索引**：~9000 条消息 ~10 秒，存在 `~/Library/Caches/ClaudeHistoryViewer/index.db`。后续启动按 mtime+size 增量更新。

## 恢复命令

每条搜索结果下方有一行 `cd "<cwd>" && claude --resume <session-id>`，旁边按钮一键复制到剪贴板，粘到终端可直接续接对话。
中间栏会话列表也支持右键 → 复制恢复命令 / 复制 session ID。

cwd 来自 JSONL 用户消息里的 `cwd` 字段（即会话开始时的真实工作目录），由 IndexBuilder 抽取入 `sessions` 表。
没拿到 cwd 时退化为只有 `claude --resume <id>`（需手动 cd）。

## 国际化

UI 跟随系统语言，支持：
- English (默认 / fallback)
- 简体中文 `zh-Hans`
- 日本語 `ja`
- 한국어 `ko`
- Deutsch `de`

未列出的语言（如法语、西班牙语）→ 自动 fallback 到英文。

资源走 SPM `.process` 机制：`Sources/ClaudeHistoryViewer/Resources/<lang>.lproj/Localizable.strings`，发布脚本会把生成的 resource bundle 拷进 `.app/Contents/Resources/` 并在 Info.plist 声明 `CFBundleLocalizations`。

**注意**：导出的 Markdown 文件**保持英文**（"You" / "Claude" / "Tool result" 等），不跟随 UI 语言 —— 导出文件常常跨人传，英文最通用。要本地化导出可以单独提需求。

测试某个特定语言（不切系统语言）：

```bash
ClaudeHistoryViewer.app/Contents/MacOS/ClaudeHistoryViewer -AppleLanguages "(ja)"
```

## 实时跟随、导出、收藏/标签

- **实时跟随**：app 启动后用 FSEvents 递归监听 `~/.claude/projects`，1 秒批延迟聚合事件。
  - 当前打开的会话文件被写入 → 立即重新解析消息（追加显示）
  - 当前项目下任意 jsonl 改动 → 刷新会话列表（并保留你设的收藏 / 标签）
  - 任何文件变化 → 后台增量索引（按 mtime+size 跳过未变文件）
  - 注意：本 app 自己也在监听 `~/.claude/projects`，所以**它能看见自己所在的会话**——你切到另一个终端跑 `claude` 时，新消息几秒内出现在 viewer 里。
- **导出 Markdown**：右上角工具栏的 ↥ 按钮，弹 `NSSavePanel`，默认文件名 `yyyyMMdd-HHmm-<title>.md`。thinking 块用 `<details>` 折叠，tool_use 用 ```json 代码块，tool_result 用 `<details>` 包住。
- **收藏 / 标签**：
  - 会话列表每行左侧 ★ 切换收藏；右侧 🏷 弹出 popover 编辑标签（逗号分隔）
  - 顶部过滤栏：★ Only 按钮 + 标签关键字输入（不区分大小写、子串匹配）
  - 持久化在 sessions 表的 `is_favorite` / `tags` 两列，schema v2 自动迁移
  - **重要**：IndexBuilder 重新索引时不会覆盖这两列（`ON CONFLICT DO UPDATE` 故意只更新非用户字段）

## 运行

需要 macOS 14+ 和 Xcode 命令行工具（或 Xcode）。

```bash
cd ~/Documents/ClaudeHistoryViewer
swift run
```

第一次会编译几秒，之后窗口直接打开。
左栏选项目，中栏选会话，右栏看对话。

## 项目结构

```
Sources/ClaudeHistoryViewer/
├── ClaudeHistoryViewerApp.swift    # @main 入口
├── Models/
│   ├── Project.swift               # 项目（一个目录）
│   ├── Session.swift               # 会话（一个 .jsonl 文件）
│   ├── Message.swift               # 消息（一个内容块）
│   └── SearchResult.swift          # SearchHit + IndexState
├── Services/
│   ├── ProjectScanner.swift        # 扫 ~/.claude/projects
│   ├── SessionParser.swift         # 解析 jsonl
│   ├── SearchIndex.swift           # SQLite + FTS5 actor（schema v2: 含 is_favorite/tags）
│   ├── IndexBuilder.swift          # 增量构建 + 排序融合
│   ├── FileWatcher.swift           # FSEvents 包装（实时跟随）
│   └── MarkdownExporter.swift      # 会话 → .md 渲染
└── Views/
    ├── AppModel.swift              # @MainActor ObservableObject
    ├── ContentView.swift           # 三栏布局 + .searchable
    ├── ProjectListView.swift
    ├── SessionListView.swift
    ├── ConversationView.swift      # ScrollViewReader + 跳转高亮
    ├── MessageView.swift
    └── SearchResultsView.swift     # 搜索结果列表
```

## 几个设计决策

- **只读**：永远不修改 `~/.claude/projects/` 里的任何文件。
- **JSONL 一行 → 多条 Message**：assistant 的一条消息里可能同时包含 thinking + 多个 text + 多个 tool_use 块，我们把每个块拍平成独立的 Message，便于折叠和滚动。
- **会话标题取首条用户消息前 80 字符**：比 uuid 直观，跟 Claude Code `/resume` 的列表风格一致。
- **tool_use / tool_result / thinking 默认折叠**：工具输出常常几百行，全展开会淹没主线对话。
- **项目目录名反编码是有损的**：原路径里的 `/` 和 `-` 在编码后无法区分（例如 `EY-EnyaMusic2` 到底是 `EY/EnyaMusic2` 还是 `EY-EnyaMusic2`），目前简单地全部还原成 `/`，仅供显示。
- **Markdown 走 `AttributedString(markdown:)` 内联模式**：原生、零依赖，支持加粗/斜体/行内代码/链接；代码块和列表会按纯文本展示。等后续真有需要再换 `MarkdownUI`。

## 下一步

- 中文 trigram 双索引（如果中文搜索体验不够好）
- 会话级备注（独立长文本，区别于短标签）
- 把工具结果里的图片/二进制 base64 折叠摘要化
- 导出多会话为单个 Markdown / Zip
- 按收藏 / 标签做项目级聚合视图
