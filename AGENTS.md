# Agent guidance

## Scope and references

This repository is a Maki Lua/Luau plugin package. Rust is a non-published test harness, not the plugin implementation.

- Read `README.md` when changing user-visible behavior, installation, permissions, or key bindings; keep its descriptions aligned with the implementation.
- Read `justfile` for development commands and `Cargo.toml` for the pinned host dependencies before changing test infrastructure.
- `plugin/` contains package entry points; `lua/code/` and `lua/review/` own independent workflows and comment stores. `lua/common/` contains shared primitives.

## Behavior contracts

- Requiring a module registers nothing; each `setup()` is idempotent. Only review registers the `TurnEnd` reminder.
- Comments are memory-only and survive UI close/reopen. Preserve them on refresh and failed input edits; clear only the submitting plugin's comments after a successful edit.
- Comment submission fills the current chat input for manual sending. Preserve existing drafts and avoid creating sessions or automatically sending prompts.
- Bind input edits to the originating session and use the snapshot's version and byte offsets. A session switch during a yielding operation must cancel the edit.

## Host and filesystem boundaries

- In Maki 0.5.7, hiding a focused plugin window does not release the focus used by the input visibility guard. Close windows before filling chat input. Window commands and input requests use separate queues; allow UI processing and keep visibility retries bounded. Reopen the UI on failure.
- Model queued window closure and focus in regression tests; immediate mock effects do not establish native TUI correctness.
- Route subprocesses through `common.shell` to preserve quoting, timeout, exit-status, and truncation handling.
- Preserve `/code`'s NUL-separated Git listing and current-directory scope. Review tracked paths and untracked paths have different base directories; inspect their resolution before changing external editing.
- Package permissions are declared in `plugin.toml`. Permission changes also require updating the grants and manifest assertions in `tests/plugin.rs`.

## Validation

1. Run `just test-lua` for Lua behavior changes; run `just check-fmt-lua` and `just lint-lua` for modified Lua/Luau files.
2. Run `just test` for host integration, package loading, permissions, or Rust test changes. Use `just check` and `just lint` when changing the Rust harness.
3. Review `git diff --check` and the final diff. Report checks that failed or were not run.
4. For UI behavior, ask for `/reload` and manual verification in Maki. Mock and Rust host tests do not exercise terminal rendering or native chat-input visibility.

Review contains Luau `continue`; standalone Lua tests extract or adapt source sections. When renaming functions or moving dispatcher boundaries, inspect the test extraction markers rather than treating failures as runtime regressions.
