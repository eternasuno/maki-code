# maki-code

Two independent Maki Lua plugins for reviewing code in the current workspace.

## Commands and layout

- `/review` reviews Git changes relative to `HEAD` (staged, unstaged, and untracked) and up to 200 recent commits. Its left column contains **Files**, **Commits**, and **Comments**; the right pane displays a syntax-highlighted diff, commit summary, or comment detail. The `TurnEnd` reminder flashes when a nonempty changed-file list differs from the last notified list.
- `/code` browses workspace files, not just changes. Its left column contains **Files** and **Comments**; the right **Source** pane displays actual file contents with line numbers, syntax highlighting, cursor/range highlighting, comment markers, and inline comments.

Both UIs use a native root window configured with `width = "90%"` and `height = "90%"`. Maki resolves its dimensions, and the panels are arranged within that area. Source always soft-wraps long lines with two columns of right-side spacing before the pane edge/scrollbar, preserving syntax highlighting and whitespace (tabs display as four spaces). Continuation rows use `↪` instead of repeating the line number; navigation, range selection, and comments still use original source lines. No wrap toggle is needed.

Both UIs use kanban-style single-line panel borders with a one-column gap between the file lists and Source/Diff. The active pane uses purple (`#bb9af7`); inactive panes use the theme’s dim foreground, without a `>` title marker. Since the native Maki window API lacks border colors, a fixed custom buffer frame surrounds each borderless content window. Titles and footer hints are fitted in display cells, keeping complete corners and preventing window widening from covering adjacent borders. Only the active pane shows footer hints, and hints that do not fit are omitted; all key bindings remain available.

Both file trees are collapsible and compress single-directory chains such as `src/foo/bar/`. `/code` lists tracked and non-ignored untracked files using `git ls-files --cached --others --exclude-standard`, scoped to the current directory, excluding tracked paths reported by `git ls-files --deleted`. Deleted files disappear when reopening `/code` or refreshing with `r`. It does not filter by extension: configuration and other text files are also available. Outside a Git working tree, it shows an explicit error.

Mouse-wheel and touchpad scrolling are handled by Maki for the focused pane when the pointer is inside it (requires terminal mouse-event support). Select Source with `3` in `/code`, or Diff with `4` in `/review`, before scrolling there. Scrolling moves the viewport, not the selected source line. Pane switches transfer native focus by recreating only the destination content window, because the host has no focus-switch API. Buffers and comments are retained; the destination viewport returns to its selected row.

## Key bindings

| Key | Action |
| --- | --- |
| `j` / `Down`, `k` / `Up` | Move through files, comments, or source/diff lines |
| `PageUp` / `PageDown` | Move one page |
| `g` / `Home`, `G` / `End` | First / last item or line |
| `1` / `2` / `3` | `/code`: Files / Comments / Source; `/review`: Files / Commits / Comments |
| `4` | `/review`: focus Diff (only when a diff is available) |
| `Enter` / `Right` | Toggle directory or open file; `/review`: open commit; `/code` Comments: jump to the source line, file start, or directory tree node |
| `l` | Toggle directory; `/review` Commits: enter the selected commit's files (does not switch panes) |
| `h` | Collapse selected directory; `/review` Commits: return to the commit list (does not switch panes) |
| `Left` | Collapse selected directory, return to the commit list, or return from source/diff to the left |
| `/` | `/code` Files: edit the filename search query |
| `Esc` | Clear `/code` Files search if active; otherwise cancel selection/editor, return left, or close |
| `e` | Files: edit the selected working-tree file; `/code` Source: edit the displayed file in the default external editor |
| `c` | Files (including commit files): add a file/directory comment; Source/Diff: add or edit a line/range comment; Comments: edit the selected comment |
| `v` | Toggle range selection; move to the other end, then press `c` |
| `d` | Delete the current line's comment or the selected Comments entry |
| `s` | Fill the current Maki chat input with this plugin’s comments; review and send manually |
| `r` | Refresh; `/code` reloads the file tree and selected source; `/review` accepts this in the left panes |
| `q` / `Ctrl-C` | Quit (in an editor, `Ctrl-C` cancels instead) |

In `/code` Files, `/` starts a case-insensitive, literal substring search of filenames only (not directory names or file contents). The query appears in the Files title, and matching files retain their parent tree and collapsed-directory state. Typing and navigation use the cached file list; `r` refreshes the full Git listing and reapplies the query. While editing the query, shortcuts such as `j`, `k`, `r`, and digits are ordinary text; TextInput handles editing keys, and pasted text is sanitized to a single line. `Enter` keeps the filter and restores normal navigation; `Esc` / `Ctrl-C` clears it and leaves editing. `/` reopens the existing query. Outside search editing, `Esc` in Files clears a nonempty query before a subsequent `Esc` closes the browser. No matches clears the source preview.

In Files, `e` opens the selected existing regular file using `VISUAL`, falling back to `EDITOR`. In `/code` Source, it opens the displayed file independently of the Files selection, then refreshes its contents while keeping Source focused and preserving the current line (clamped if the file shrinks). Comments ignores `e`; in the inline comment editor it is ordinary text. Maki suspends the TUI and waits for the editor to exit, then reloads source/diffs even after a nonzero exit. Directories, missing files, and historical commit versions are not opened; editor failures are reported.

In the inline comment editor, `Enter` saves and `Esc` / `Ctrl-C` cancels. TextInput handles editing keys, digits, and pasted text; number shortcuts do not switch panes while editing. Outside the editor, number shortcuts select the numbered panes and clear range selection on a pane change. `Tab` no longer switches panes; `j` / `k` still move rows. Blank comments are not saved. Editing an existing comment preserves its original target, range, commit, and context snapshot. File/directory editors also work without readable source or a diff. Deletion updates the UI immediately.

Comments entries distinguish line/range locations (`file:line` or `file:start-end`), files (`path`), and directories (`path/`), with a short text preview when space permits. `/code` `Enter` / `Right` jumps to the source line, the file's first line, or the directory in Files; missing directory nodes remain safe to select and edit. `/review` retains its comment detail view. File tree badges count file plus line comments; directory badges include directory comments and all descendants, including compressed directory chains.

## Comments and submission

Stores are independent, with one mixed comment list per plugin. New records use `{target = {kind = "line" | "file" | "dir", path = "..."}, text = "..."}`. `/code` line records additionally keep `start_line`, `end_line`, and `snippet`; `/review` line records retain old/new diff anchors and snippets, and commit reviews retain `commit`. Path-level records need no line numbers or snippets. Source snippets capture context at creation time, not at submission time.

Comments are **memory-only**. They survive closing and reopening the same plugin's UI, but disappear on `/reload` or process exit. They are never saved to disk. Refresh does not delete comments, including comments on files that have since disappeared.

Submission only fills the **current chat input**: it never creates a session or sends automatically. Existing nonempty drafts are preserved, with two newlines before the appended prompt. `/code` prompts distinguish `Target: source`, `Target: file`, and `Target: directory`; only source comments include lines and context snapshots. `/review` uses File/Directory comment headings for path targets and preserves diff ranges, snippets, and commit context for line comments. Both ask the agent to verify the current workspace because paths and snapshots may be stale. File/directory requests may rename, move, delete, reorganize, or create related files/directories; the plugins themselves never perform these operations. Successful submission clears only the submitting plugin's comments and closes its UI. Failed submission retains comments, restores the plugin windows and focus, and allows retrying. `/code` without comments flashes `No comments to submit`.

Before filling the input, the plugin closes its windows to release focus and briefly waits for the UI to process the close commands. If the input remains off screen, it retries a limited number of times. Switching sessions during this operation cancels the edit; failures retain comments and reopen the plugin UI.

`/code` source reading reports missing, binary/control-character, or invalid UTF-8 files. Files larger than **1 MiB** are not opened; files with more than **10,000 lines** display the first 10,000 with a notice. Both plugins report Git errors and truncated subprocess output rather than using partial lists; failed refreshes retain usable prior data. `/review` uses repository-root-relative paths for tracked, untracked, and historical changes, including renames and filenames containing tabs or newlines, even when started in a subdirectory.

## Package layout

```text
plugin/
├── review.lua             require("review").setup()
└── code.lua               require("code").setup()
lua/
├── review/
│   ├── init.lua           Registration and TurnEnd reminder
│   ├── browser.lua        Events, navigation, comment editing
│   ├── git.lua            Root-relative Git commands and NUL path parsing
│   ├── files.lua          Preview cache and refresh
│   ├── diff.lua           Diff parsing and highlight mapping
│   ├── comments.lua       Independent store, anchors, and prompts
│   ├── render.lua         Panel invalidation and draw coordination
│   ├── render_lists.lua   Prepared tree maps and left lists
│   ├── render_diff.lua    Diff, commit, and comment details
│   └── windows.lua        Window layout and lifecycle
├── code/
│   ├── init.lua           Registration
│   ├── browser.lua        State, navigation, and events
│   ├── files.lua          Listing, source reading, search, and tree maps
│   ├── comments.lua       Independent store, editing, and prompts
│   └── render.lua         Cached panel rendering and window layout
└── common/
    ├── tree.lua           Business-neutral compressed trees
    ├── comments.lua       Caller-owned CRUD and derived path indexes
    ├── highlight.lua      Language inference and highlighting fallback
    ├── layout.lua         Panel frames, sizing, spans, and colors
    ├── shell.lua          Quoting and checked subprocess execution
    ├── text.lua           Unicode, wrapping, summaries, and path fitting
    └── input.lua          Guarded chat input filling
plugin.toml                Package permission request
```

Requiring either module alone registers nothing. Both `setup()` functions are idempotent; only `review.setup()` registers the `TurnEnd` reminder. The former `maki_review` module name has been replaced by `review`; update explicit configuration imports when upgrading.

## Installation and permissions

Requires Git on `PATH`, a POSIX shell environment, and Maki's Lua UI, TextInput, filesystem, and chat input APIs (`input` / `input_edit`). Start Maki in the project directory you want to browse.

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

Choose one installation method to avoid loading separate copies. The package requests `run` for Git subprocesses and `fs_read` for source metadata/content. It does not request filesystem write or network access; approve the requested permissions in Maki. Agent modification from comments begins only after you manually send the filled prompt, under the current session’s permissions. The `e` shortcut independently allows editing through your external editor.

## Verification

From the repository root, using Lua 5.2 or later:

```sh
just test-lua
```

This runs `tests/review_keys.lua`, `tests/review_git.lua`, `tests/code.lua`, and `tests/common.lua`. Feature suites execute the original modules directly, including event handlers; no source extraction or syntax rewriting is used. `tests/code_search.lua` and `tests/common_text.lua` are invoked by their parent suites, while `tests/support/` holds the code and review host mocks. Tests cover navigation, comments, setup idempotency, Git errors and unusual paths, queued window closure, draft preservation, bounded retries, and session/version guards. Hotspot regressions assert tree, file-read, rendering, and text-measurement call counts, not fixed timing thresholds.

The Rust harness follows the Maki repository’s default branch without a fixed `rev` in `Cargo.toml`; `Cargo.lock` records the resolved commit for reproducible runs. It tests package loading, registered commands, shared APIs, permissions, and Git fixtures:

```sh
just test
```

Neither suite validates real terminal rendering or the native chat-input submission flow; those require manual checks below.

Additional development checks:

```sh
just check-fmt-lua
just lint-lua
just check
just lint
```

`just fmt-lua` and `just fmt` format Lua/Luau and Rust respectively. See `AGENTS.md` for agent-facing development guidance.

Run `/reload` after installation. Manually check both commands, syntax colors, pane focus and scrolling, line/range comments, reopening retention, and current-input filling, draft preservation, and failed-edit retry. After an agent turn that changes files, check the `/review` reminder.

## Acknowledgments

Adapted from [Asaf51/maki-review](https://github.com/Asaf51/maki-review); the review workflow is preserved with idempotent registration and shared primitives.
