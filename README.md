# maki-code

Two independent Maki Lua plugins for reviewing code in the current workspace.

## Commands and layout

- `/review` reviews Git changes relative to `HEAD` (staged, unstaged, and untracked) and recent commits. Its left column contains **Files**, **Commits**, and **Comments**; the right pane displays a syntax-highlighted diff, commit summary, or comment detail. The `TurnEnd` reminder flashes when changed files are detected.
- `/code` browses workspace files, not just changes. Its left column contains **Files** and **Comments**; the right **Source** pane displays actual file contents with line numbers, syntax highlighting, cursor/range highlighting, comment markers, and inline comments.

Both file trees are collapsible and compress single-directory chains such as `src/foo/bar/`. `/code` lists tracked and non-ignored untracked files using `git ls-files --cached --others --exclude-standard`, scoped to the current directory. It does not filter by extension: configuration and other text files are also available. Outside a Git working tree, it shows an explicit error.

## Key bindings

| Key | Action |
| --- | --- |
| `j` / `Down`, `k` / `Up` | Move through files, comments, or source/diff lines |
| `PageUp` / `PageDown` | Move one page |
| `g` / `Home`, `G` / `End` | First / last item or line |
| `Tab` | `/review`: cycle left panels (from diff, return left); `/code`: Files → Comments → Source → Files |
| `Enter` / `l` / `Right` | Toggle directory or open file; `/review`: open commit; `/code` Comments: jump to the comment's file and line |
| `h` / `Left` | Collapse selected directory or return from source/diff to the left |
| `Esc` | Cancel selection/editor, return left, or close |
| `c` | Add or edit a comment on the current source/diff line |
| `v` | Toggle range selection; move to the other end, then press `c` |
| `d` | Delete the current line's comment or the selected Comments entry |
| `s` | Submit all comments from this plugin to a new focused Maki session |
| `r` | Refresh; `/code` reloads both the file tree and selected source |
| `q` / `Ctrl-C` | Quit (in the editor, `Ctrl-C` cancels instead) |

In the inline comment editor, `Enter` saves and `Esc` / `Ctrl-C` cancels. TextInput handles editing keys and pasted text. Blank comments are not saved. Editing an existing comment preserves its original range and context snapshot. Deletion updates the UI immediately.

`/code` Comments entries show `file:line` or `file:start-end`, plus a short text preview when space permits. `Enter` / `l` jumps to the corresponding source line. `/review` retains its comment detail view.

## Comments and submission

Stores are independent: `/review` uses old/new diff anchors; `/code` uses `{file, start_line, end_line, text, snippet}`. Source snippets capture context at creation time, not at submission time.

Comments are **memory-only**. They survive closing and reopening the same plugin's UI, but disappear on `/reload` or process exit. They are never saved to disk. Refresh does not delete comments, including comments on files that have since disappeared.

Submission opens a new **focused** Maki session. `/review` describes the diff/commit context. `/code` explicitly asks the agent to locate requests by file and line/range, read actual current files, and modify the workspace; saved snippets may be stale and must not be assumed current. Successful submission clears only the submitting plugin's comments and closes its UI. Failed submission retains them. `/code` without comments flashes `No comments to submit`.

Source reading gracefully reports missing, binary/control-character, or invalid UTF-8 files. Files larger than **1 MiB** are not opened; files with more than **10,000 lines** display the first 10,000 with a notice. Git listing errors and truncated subprocess output are reported rather than silently using a partial list.

## Package layout

```text
plugin/
├── review.lua             require("review").setup()
└── code.lua               require("code").setup()
lua/
├── review/init.lua        Git/diff review and TurnEnd reminder
├── code/init.lua          Workspace/source review
└── common/
    ├── tree.lua           Business-neutral compressed trees
    ├── comments.lua       Caller-owned comment list operations
    ├── highlight.lua      Language inference and highlighting fallback
    ├── layout.lua         Sizing, spans, backgrounds, colors
    ├── shell.lua          Quoting and checked subprocess execution
    └── utils.lua          Unicode, wrapping, path fitting
plugin.toml                Package permission request
```

Requiring either module alone registers nothing. Both `setup()` functions are idempotent; only `review.setup()` registers the `TurnEnd` reminder. The former `maki_review` module name has been replaced by `review`; update explicit configuration imports when upgrading.

## Installation and permissions

Requires Git on `PATH`, a POSIX shell environment, and Maki's Lua UI, TextInput, filesystem, and session APIs. Start Maki in the project directory you want to browse.

### Managed package

Add to your global Maki `init.lua`:

```lua
maki.pack.add({"https://github.com/eternasuno/maki-code"})
```

### Local package

Place the repository at:

```text
<maki-data>/site/pack/<group>/start/maki-code
```

Use your Maki data directory and a group such as `local`, not the reserved `core`. Keep the layout intact. Maki autoloads both files under `plugin/`; no explicit setup calls are necessary.

### Module-copy alternative

Copy `lua/review/`, `lua/code/`, and `lua/common/` into your Maki configuration's `lua/` directory. Grant permissions with a `plugin.toml` next to each copied module file (including the common modules), containing:

```toml
[permissions]
run = true
fs_read = true
```

Then load both in your user `init.lua`:

```lua
require("review").setup()
require("code").setup()
```

Choose one installation method to avoid loading separate copies. The package requests `run` for Git subprocesses and `fs_read` for source metadata/content. It does not request filesystem write or network access; approve the requested permissions in Maki. Code modification after submission is performed by the new agent session under that session's permissions.

## Verification

From the repository root, using Lua 5.2 or later:

```sh
lua tests/review_keys.lua
lua tests/code.lua
lua tests/common.lua
```

Tests exercise review editor regressions, complete code-module handlers with a mocked Maki host, setup idempotency, and shared primitives. The review setup test adapts Luau `continue` for standalone Lua without exercising those branches. These are not native terminal integration tests.

Run `/reload` after installation. Manually check both commands, syntax colors, pane focus and scrolling, line/range comments, reopening retention, and focused-session submission. After an agent turn that changes files, check the `/review` reminder.

## Acknowledgments

Adapted from [Asaf51/maki-review](https://github.com/Asaf51/maki-review); the review workflow is preserved with idempotent registration and shared primitives.
