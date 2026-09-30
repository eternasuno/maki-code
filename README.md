# maki-code

A Maki Lua review plugin providing `/review`: a terminal UI for inspecting changes,
leaving inline comments, and sending them to a new focused Maki session for fixes.

## Features

- **Files** — staged, unstaged, and untracked changes versus `HEAD` in a collapsible tree.
- **Commits** — recent commits, with drill-down into their changed files.
- **Comments** — all review comments written so far.
- **Diff pane** — syntax-highlighted diffs with full-row tints, line and range comments.
- **Submit** — send all comments to a new focused Maki session that addresses them.
- **Turn reminders** — a status flash after a turn when changed files are detected.

Comments are memory-only: they survive closing and reopening the review window,
but are not saved to disk and are lost on `/reload` or process exit.

## Keys

| Key | Action |
| --- | --- |
| `Tab` | Cycle left panels |
| `Enter` / `l` | Open directory, focus diff, or open commit |
| `h` / `Esc` | Collapse or go back |
| `c` | Comment on the current diff line |
| `v` | Start range selection |
| `d` | Delete comment |
| `s` | Submit comments to Maki |
| `r` | Refresh |
| `q` | Quit |

## Package layout

```text
plugin/review.lua          Autoload entry: require("maki_review").setup()
lua/maki_review/init.lua  Module exporting setup()
plugin.toml              Package permission request
```

Requiring `maki_review` alone does not register anything. Calling `setup()`
registers `/review` and the `TurnEnd` reminder once per loaded module, even if
called more than once. The standard package entry calls it automatically.

## Installation

Requires Git on `PATH` and a POSIX shell environment. Run Maki in the Git working
tree you want to review. The root `plugin.toml` requests only `run = true`, needed
by `maki.fn.jobstart` and `maki.fn.jobwait` for Git and shell commands; approve
that permission when Maki asks.

### Managed package (once published)

Add this to your global Maki `init.lua` once the repository is published:

```lua
maki.pack.add({"https://github.com/eternasuno/maki-code"})
```

### Local clone

Place this repository at:

```text
<maki-data>/site/pack/<group>/start/maki-code
```

Use your Maki data directory for `<maki-data>` and a user-chosen group such as
`local` for `<group>`; do not use the reserved `core` group. Keep the package
layout intact. Maki autoloads `plugin/review.lua`; no explicit `require` is needed
in your config for this installation.

### Module-copy alternative

Instead of installing the package, copy `lua/maki_review/` into your Maki config
directory's `lua/` directory. Put its own `plugin.toml` alongside the copied
`init.lua` at `lua/maki_review/plugin.toml`, containing:

```toml
[permissions]
run = true
```

Then add this to your user `init.lua`:

```lua
require('maki_review').setup()
```

Choose one installation method to avoid loading separate copies of the plugin.

## Verification

Run `/reload` after installing or editing the plugin. In a Git working tree with
changes, run `/review` manually and check the file tree and diff preview. Add a
line comment with `c`, select a range with `v`, and reopen the window to confirm
comments remain in memory. Use `s` only when you want to send comments to a new
session. After an agent turn that changes files, check for the review reminder.

## Acknowledgments

Adapted from [Asaf51/maki-review](https://github.com/Asaf51/maki-review); its UI and
helpers are preserved, with registration exposed through an idempotent `setup()`.
