# Claude History Viewer

A native macOS app to browse, search, and export your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) conversation history stored under `~/.claude/projects/`.

**Read-only by design** — it never writes to your `~/.claude/` directory.

[English](README.md) · 简体中文 · 日本語 · 한국어 · Deutsch (UI follows your system language)

---

## Features

- 🗂  **Three-pane browser** — projects · sessions · conversation, like a mail client.
- 🔍 **Full-text search** with SQLite FTS5 + BM25 ranking + 30-day half-life time decay.
- ⏯  **One-click resume** — every result and session has a copy-paste-able `cd <cwd> && claude --resume <id>`.
- ⭐ **Favorites & tags** — star sessions, add free-form tags, filter the list.
- 📤 **Markdown export** — current session → `.md` with collapsible thinking / tool blocks.
- 🔴 **Live follow** — FSEvents watches `~/.claude/projects/`; new messages appear within ~1 s while another `claude` process is writing.
- 🌐 **Localized UI** — English, Simplified Chinese, Japanese, Korean, German. Unknown locales fall back to English.
- 📦 **Zero dependencies** — pure SwiftPM, no CocoaPods/Carthage/Homebrew.

## Screenshots

> _TODO: drop screenshots into `docs/screenshots/` and link them here._

## Requirements

- macOS **14.0** (Sonoma) or later
- Intel **or** Apple Silicon (the prebuilt binary is a universal binary)
- Xcode Command Line Tools (only if you build from source)

## Installation

### Option A — Prebuilt binary (recommended)

1. Download the latest `.zip` from the [Releases page](https://github.com/hoyawolfer/claude-history-viewer/releases) (or grab `dist/ClaudeHistoryViewer-*.zip` from this repo if no release is published yet).
2. Unzip → drag `ClaudeHistoryViewer.app` into `/Applications`.
3. **First launch only** — the binary is ad-hoc signed (no Apple Developer ID), so Gatekeeper will block a plain double-click. Use one of these:

   - **Right-click the app → Open → click "Open" in the dialog.** (Apple's official escape hatch.)
   - **Or** run once in Terminal to strip the quarantine flag:
     ```bash
     xattr -dr com.apple.quarantine /Applications/ClaudeHistoryViewer.app
     ```

4. After that, the app launches like any other.

### Option B — Build from source

```bash
git clone git@github.com:hoyawolfer/claude-history-viewer.git
cd claude-history-viewer
swift run
```

First build compiles in ~10 s; subsequent runs are instant. The app window opens with your projects pre-loaded.

To produce a distributable `.app` bundle (universal binary + ad-hoc sign + zip):

```bash
./scripts/make-dist.sh
# → dist/ClaudeHistoryViewer-<version>-universal.zip
```

For a quick dev `.app` (current architecture, debug build):

```bash
./scripts/make-app.sh
open ./ClaudeHistoryViewer.app
```

## Usage

### Browsing

| Pane (left → right) | What it shows | Selection |
|---|---|---|
| **Projects** | One row per directory under `~/.claude/projects/` | Click to load its sessions |
| **Sessions** | One row per `.jsonl` file in that project | Click to load the conversation |
| **Conversation** | Flattened messages (user / assistant / thinking / tool_use / tool_result) | Scrolls, blocks are collapsible |

The session list shows the **first meaningful user message** as the title (truncated to 80 chars) — much friendlier than UUIDs.

### Searching

Type into the toolbar search field. Search runs across **all sessions in all projects** with a 300 ms debounce. Clicking a result jumps you to the exact message with a brief yellow highlight.

The search box accepts native [FTS5 syntax](https://www.sqlite.org/fts5.html#full_text_query_syntax):

| Query | Meaning |
|---|---|
| `swift build` | Both words (implicit AND) |
| `"swift build"` | Exact phrase |
| `swift OR build` | Either word |
| `swift NOT build` | Has `swift`, not `build` |
| `fluidsyn*` | Prefix match |
| `NEAR(foo bar, 5)` | Within 5 tokens of each other |
| `searching` | Porter stemming — also matches `search`, `searched` |

**Ranking formula:**

```
score = 0.8 × normalizedBM25  +  0.2 × recency
recency = 0.5 ^ (ageInDays / 30)        # 30-day half-life
```

BM25 is min-max normalized within the result set. Each result row shows all three scores (combined / relevance / recency) so you can see *why* it ranked where it did.

### Resuming a session

Every search result has a one-line command strip:

```bash
cd "/path/from/cwd" && claude --resume <session-id>
```

Click **Copy**, paste into Terminal — you're back in the same session.

The session list also exposes this via right-click → **Copy resume command**.

The `cwd` is extracted from the original JSONL (the working directory at session start). If it's missing, the strip falls back to `claude --resume <id>` and you cd manually.

### Favorites & tags

- **Star** any session by clicking the ☆ on the left of the row.
- **Tag** any session by clicking the 🏷 on the right — type comma-separated tags in the popover.
- The top of the session list has a **★-only** toggle and a **tag-filter** text field (case-insensitive substring match).
- Favorites and tags survive re-indexing — `IndexBuilder` deliberately doesn't touch the `is_favorite` / `tags` columns on conflict.

### Exporting

Toolbar → ↥ button → choose a destination. Defaults to `<yyyyMMdd-HHmm>-<title>.md`. The exporter renders:

- 👤 `## You` for user messages
- 🤖 `## Claude` for assistant text
- 💭 Thinking blocks → `<details>` with `>` blockquotes
- 🔧 Tool use → fenced ```json``` code block
- 📤 Tool result → `<details>` + fenced code block

The Markdown export **stays in English** even when the UI is localized — it's optimized for sharing files with people whose locale you don't know.

### Live follow

The app keeps an FSEvents stream on `~/.claude/projects/` with a 1-second debounce. While the app is open:

- Changes to the **currently viewed** session → conversation refreshes in place.
- New / modified JSONLs in the **current project** → session list refreshes (favorites/tags preserved).
- Any change → background incremental re-index (only files whose `mtime + size` changed are touched).

Run `claude` in another terminal and new messages appear here automatically.

### Choosing a language

The UI follows the system language (`zh-Hans`, `ja`, `ko`, `de`, anything else falls back to `en`).

To preview a specific language without changing your whole system:

```bash
ClaudeHistoryViewer.app/Contents/MacOS/ClaudeHistoryViewer -AppleLanguages "(ja)"
```

## Architecture

```
Sources/ClaudeHistoryViewer/
├── ClaudeHistoryViewerApp.swift    # @main entry point
├── Models/
│   ├── Project.swift               # one directory under ~/.claude/projects/
│   ├── Session.swift               # one .jsonl file
│   ├── Message.swift               # one content block (user/assistant/thinking/tool_*)
│   └── SearchResult.swift          # SearchHit + IndexState
├── Services/
│   ├── ProjectScanner.swift        # ls ~/.claude/projects
│   ├── SessionParser.swift         # JSONL → [Message]
│   ├── SearchIndex.swift           # SQLite + FTS5 actor (schema v2: favorites/tags)
│   ├── IndexBuilder.swift          # incremental indexing + BM25/time-decay ranking
│   ├── FileWatcher.swift           # FSEvents wrapper for live follow
│   └── MarkdownExporter.swift      # session → .md
├── Resources/
│   ├── en.lproj/Localizable.strings
│   ├── zh-Hans.lproj/Localizable.strings
│   ├── ja.lproj/Localizable.strings
│   ├── ko.lproj/Localizable.strings
│   └── de.lproj/Localizable.strings
└── Views/
    ├── AppModel.swift              # @MainActor ObservableObject (single source of truth)
    ├── ContentView.swift           # NavigationSplitView + toolbar + .searchable
    ├── ProjectListView.swift
    ├── SessionListView.swift       # filter bar + rows + tag editor popover
    ├── ConversationView.swift      # ScrollViewReader + scroll-to-hit highlight
    ├── MessageView.swift           # role-specific bubble / collapsible block
    ├── SearchResultsView.swift     # hits + resume-command strip
    └── Localized.swift             # T() / L() / Lf() helpers for Bundle.module
```

### Data flow

1. `ProjectScanner` walks `~/.claude/projects/`.
2. `SessionParser` parses each `.jsonl` lazily for display, fully for indexing.
3. `IndexBuilder` upserts messages into FTS5; sessions metadata goes into a separate table with `mtime + size` as a fingerprint for incremental updates.
4. `SearchIndex` is an `actor` — all SQLite access serializes through it.
5. `FileWatcher` notifies `AppModel`, which re-parses the visible session and kicks off a background re-index.
6. `IndexBuilder.rank()` combines normalized BM25 with an exponential recency score and returns the top 100.

### Index location

`~/Library/Caches/ClaudeHistoryViewer/index.db` — safe to delete; the app will rebuild on next launch. ~9000 messages indexes in ~10 s.

## Design decisions

- **Read-only.** The app never opens any file under `~/.claude/projects/` for write. The index is in `~/Library/Caches/` so it's reproducible.
- **Flatten on parse.** One JSONL line from Claude may contain thinking + multiple text + multiple tool_use blocks. We flatten into independent `Message`s so each can be collapsed and addressed individually.
- **Default-collapsed tool I/O.** Tool blocks are often hundreds of lines. Defaulting them collapsed keeps the conversation readable.
- **Project directory decoding is lossy.** The on-disk encoding replaces `/` with `-`, so `EY-EnyaMusic2` could mean `EY/EnyaMusic2` or literally `EY-EnyaMusic2`. We treat all `-` as `/` for display only.
- **Inline Markdown only.** Body text goes through `AttributedString(markdown:)` in inline mode — bold/italic/code/link work, code blocks and lists render as plain text. Zero dependencies, ~adequate fidelity.
- **User data is sticky.** `IndexBuilder` never overwrites `is_favorite` / `tags` on re-index — these are owned by the user, not the indexer.

## Known limitations

- **No CJK substring search.** The `porter unicode61` tokenizer treats consecutive CJK characters as a single token, so searching `这个` won't match `这个是什么库`. CJK "words" surrounded by punctuation/whitespace/markdown work fine. A future option: a parallel `trigram` index for CJK substring (at the cost of losing English stemming).
- **Ad-hoc signing only.** No Apple Developer ID → Gatekeeper requires right-click-Open or `xattr -d` on first launch.
- **No app icon yet.** The Dock shows the generic placeholder. If you have a 1024×1024 PNG, drop it into `Resources/` and we can wire up `.icns`.

## Roadmap

- [ ] CJK trigram secondary index for substring search
- [ ] Per-session notes (long-form, separate from short tags)
- [ ] Summarize / fold base64 blobs in tool results
- [ ] Multi-session export (single Markdown or zip)
- [ ] Project-level aggregations grouped by favorite / tag
- [ ] App icon
- [ ] GitHub Release artifacts (currently `dist/*.zip` only)

## Contributing

Contributions welcome — open an issue first to discuss substantial changes.

```bash
git clone git@github.com:hoyawolfer/claude-history-viewer.git
cd claude-history-viewer
swift build           # compile
swift run             # run (debug)
swift test            # (no tests yet — PRs welcome)
```

The codebase is intentionally small. The README's "Architecture" section maps every file to its responsibility — start there.

## License

TBD — to be confirmed by the maintainer. The intent is permissive (MIT or similar); until a `LICENSE` file is added, treat the code as "all rights reserved" and ask before redistributing.
