use std::{path::Path, sync::Arc, time::Duration};

use serde_json::json;

use maki_agent::tools::ToolRegistry;
use maki_lua::{PluginHost, PluginPermissions};

const PLUGIN_NAME: &str = "maki-code";

fn plugin_host() -> (Arc<ToolRegistry>, PluginHost) {
    plugin_host_with_permissions(PluginPermissions::trusted())
}

fn plugin_host_with_permissions(permissions: PluginPermissions) -> (Arc<ToolRegistry>, PluginHost) {
    let registry = Arc::new(ToolRegistry::new());
    let host = PluginHost::new(Arc::clone(&registry)).unwrap();
    host.load_package(
        PLUGIN_NAME,
        Path::new(env!("CARGO_MANIFEST_DIR")),
        permissions,
        Default::default(),
    )
    .unwrap();
    (registry, host)
}

#[test]
fn package_loads_both_commands() {
    let (_registry, host) = plugin_host();
    let snapshot = host.command_reader().load().clone();
    let mut names: Vec<_> = snapshot
        .commands
        .iter()
        .map(|command| command.name.as_ref())
        .collect();
    names.sort_unstable();
    assert_eq!(names, ["/code", "/review"]);
    for command in &snapshot.commands {
        assert_eq!(command.plugin.as_ref(), PLUGIN_NAME);
        assert!(!command.description.is_empty());
        assert_eq!(command.max_args, 0);
    }
}

fn run_lua(host: &PluginHost, source: &str) {
    host.send_run_init_lua(
        source.to_owned(),
        "integration-test.lua".to_owned(),
        Some(Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf()),
    )
    .unwrap();
}

#[test]
fn both_modules_load_common_modules_without_registering_on_require() {
    let (_registry, host) = plugin_host();
    let before = host.command_reader().load().generation;
    run_lua(
        &host,
        r##"
        local code = require("code")
        local review = require("review")
        assert(type(code.setup) == "function")
        assert(type(review.setup) == "function")
        for _, name in ipairs({ "tree", "comments", "highlight", "layout", "shell", "text", "input" }) do
            assert(require("common." .. name) == require("common." .. name))
        end
    "##,
    );
    let snapshot = host.command_reader().load().clone();
    assert_eq!(snapshot.commands.len(), 2);
    assert_eq!(snapshot.generation, before);
    assert!(
        snapshot
            .commands
            .iter()
            .all(|command| command.plugin.as_ref() == PLUGIN_NAME)
    );
}

#[test]
fn unicode_layout_and_highlighting_use_real_host_apis() {
    let (_registry, host) = plugin_host();
    run_lua(
        &host,
        r##"
        local text = require("common.text")
        local layout = require("common.layout")
        local highlight = require("common.highlight")
        assert(text.sanitize_utf8("a" .. string.char(255) .. "中") == "a中")
        assert(text.display_len("中a") == maki.ui.display_width("中a"))
        assert(text.display_len("中a") == 3)
        local wrapped = text.wrap("中文ab", 4)
        assert(#wrapped == 2 and wrapped[1] == "中文" and wrapped[2] == "ab")
        assert(text.fit_path("long/path/文件.rs", 6) == "…件.rs")
        local spans = layout.pad_spans({ { "中a", "path" } }, 5)
        assert(layout.spans_len(spans) == 5 and spans[2][1] == "  ")
        assert(layout.blend("#000000", "#ffffff", 0.5) == "#808080")
        local styled = highlight.highlight_file("example.rs", { "fn main() {}" })
        assert(styled ~= nil and #styled == 1)
        assert(highlight.highlight_file("example.rs", {}) == nil)
    "##,
    );
}

#[test]
fn shared_shell_executes_success_and_error_inputs_in_real_command_context() {
    let (_registry, host) = plugin_host();
    run_lua(
        &host,
        r##"
        maki.api.register_command({ name = "/test-shell", handler = function()
        local succeeded, failure = pcall(function()
        local shell = require("common.shell")
        local text = "quote's value"
        local out, err = shell.run("printf %s " .. shell.quote(text))
        assert(out == text and err == nil, tostring(out) .. " / " .. tostring(err))
        out, err = shell.run("printf problem >&2; exit 7")
        assert(out == nil and err == "problem")
        out, err = shell.run("printf accepted; exit 1", { ok_exit_codes = { 0, 1 } })
        assert(out == "accepted" and err == nil)
        local source, read_err = maki.fs.read("lua/code/init.lua")
        assert(type(source) == "string" and #source > 0 and read_err == nil)
        end)
        maki.ui.flash(succeeded and "shell assertions passed" or tostring(failure))
        end })
    "##,
    );
    host.event_handle().run_command(
        Arc::from("integration-test.lua"),
        Arc::from("/test-shell"),
        String::new(),
        0,
    );
    let action = host
        .ui_action_rx()
        .recv_timeout(Duration::from_secs(10))
        .expect("shell assertions did not finish");
    match action {
        maki_lua::UiAction::Flash(message) => assert_eq!(message, "shell assertions passed"),
        _ => panic!("unexpected shell test UI action"),
    }
}

#[test]
fn review_git_handles_special_paths_and_history_from_subdirectory() {
    const FIXTURE_ENV: &str = "MAKI_CODE_SPECIAL_GIT_FIXTURE";
    if std::env::var_os(FIXTURE_ENV).is_none() {
        let fixture =
            std::env::temp_dir().join(format!("maki-code-special-git-test-{}", std::process::id()));
        std::fs::create_dir(&fixture).unwrap();
        let result = std::panic::catch_unwind(|| {
            let git = |args: &[&str]| {
                let output = std::process::Command::new("git")
                    .args([
                        "-c",
                        "user.name=Test",
                        "-c",
                        "user.email=test@example.invalid",
                    ])
                    .args(args)
                    .current_dir(&fixture)
                    .output()
                    .unwrap();
                assert!(
                    output.status.success(),
                    "{args:?}: {}",
                    String::from_utf8_lossy(&output.stderr)
                );
            };
            git(&["init", "--quiet"]);
            let paths = ["中文.rs", "space name.rs", "tab\tname.rs", "line\nname.rs"];
            for path in paths {
                std::fs::write(fixture.join(path), "initial content\n").unwrap();
            }
            std::fs::write(fixture.join("old 中文\tname.rs"), "rename content\n").unwrap();
            git(&["add", "--all"]);
            git(&["commit", "--quiet", "-m", "initial special paths"]);
            git(&["mv", "--", "old 中文\tname.rs", "renamed space\nname.rs"]);
            for path in paths {
                std::fs::write(fixture.join(path), "historical content\n").unwrap();
            }
            git(&["add", "--all"]);
            git(&["commit", "--quiet", "-m", "historical rename 中文"]);
            for path in paths {
                std::fs::write(fixture.join(path), "working content\n").unwrap();
            }
            std::fs::write(
                fixture.join("untracked 中文 space\tline\n.rs"),
                "untracked content\n",
            )
            .unwrap();
            std::fs::create_dir(fixture.join("nested")).unwrap();
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "review_git_handles_special_paths_and_history_from_subdirectory",
                    "--nocapture",
                ])
                .env(FIXTURE_ENV, "1")
                .current_dir(fixture.join("nested"))
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        });
        std::fs::remove_dir_all(&fixture).unwrap();
        if let Err(error) = result {
            std::panic::resume_unwind(error);
        }
        return;
    }

    let expected_root = std::env::current_dir()
        .unwrap()
        .parent()
        .unwrap()
        .canonicalize()
        .unwrap();
    let (_registry, host) =
        plugin_host_with_permissions(PluginPermissions::from_approved(["run", "fs_read"]));
    run_lua(
        &host,
        &format!(
            r##"
        maki.api.register_command({{ name = "/test-git", handler = function()
        local succeeded, failure = pcall(function()
            local git = require("review.git")
            local root, err = git.root()
            assert(root == {expected_root}, tostring(root) .. " / " .. tostring(err))
            local function contains(value, part)
                assert(type(value) == "string" and value:find(part, 1, true), tostring(value))
            end
            local function by_path(changes)
                assert(type(changes) == "table", tostring(changes))
                local found = {{}}
                for _, change in ipairs(changes) do
                    assert(found[change.path] == nil, "duplicate path")
                    found[change.path] = change
                    assert(git.path(root, change) == root .. "/" .. change.path)
                end
                return found
            end
            local paths = {{ "中文.rs", "space name.rs", "tab\tname.rs", "line\nname.rs" }}
            local changes, changes_err = git.changes(root)
            assert(changes, changes_err)
            assert(#changes == 5)
            local current = by_path(changes)
            for _, path in ipairs(paths) do
                local change = assert(current[path], path)
                assert(change.status == "M" and change.adds == 1 and change.dels == 1)
                local diff, diff_err = git.raw_diff(root, change)
                assert(diff, diff_err)
                contains(diff, "-historical content")
                contains(diff, "+working content")
            end
            local untracked = assert(current["untracked 中文 space\tline\n.rs"])
            assert(untracked.status == "?" and untracked.untracked)
            local diff, diff_err = git.raw_diff(root, untracked)
            assert(diff, diff_err)
            contains(diff, "+untracked content")
            local source, read_err = maki.fs.read(git.path(root, untracked))
            assert(source == "untracked content\n" and read_err == nil)

            local commits, log_err = git.log(root)
            assert(commits, log_err)
            assert(#commits == 2 and commits[1].subject == "historical rename 中文")
            assert(commits[2].subject == "initial special paths" and #commits[1].when > 0)
            local historical, historical_err = git.commit_changes(root, commits[1].sha)
            assert(historical, historical_err)
            assert(#historical == 5)
            local history = by_path(historical)
            for _, path in ipairs(paths) do
                local change = assert(history[path], path)
                assert(change.commit == commits[1].sha and change.status == "M")
                assert(change.adds == 1 and change.dels == 1)
                local patch, patch_err = git.raw_diff(root, change)
                assert(patch, patch_err)
                contains(patch, "-initial content")
                contains(patch, "+historical content")
                assert(not patch:find("working content", 1, true))
            end
            local renamed = assert(history["renamed space\nname.rs"])
            assert(renamed.status == "R" and renamed.old_path == "old 中文\tname.rs")
            assert(renamed.adds == 0 and renamed.dels == 0)
            local rename_diff, rename_err = git.raw_diff(root, renamed)
            assert(rename_diff, rename_err)
            contains(rename_diff, "similarity index 100%")
            contains(rename_diff, "rename from")
            contains(rename_diff, "rename to")
            local initial, initial_err = git.commit_changes(root, commits[2].sha)
            assert(initial, initial_err)
            assert(#initial == 5)
            for _, change in ipairs(initial) do
                assert(change.status == "A" and change.adds == 1 and change.dels == 0)
            end
            local info, info_err = git.commit_info(root, commits[1].sha)
            assert(info, info_err)
            contains(info, "historical rename 中文")
            contains(info, "Test")
        end)
        maki.ui.flash(succeeded and "git assertions passed" or tostring(failure))
        end }})
        "##,
            expected_root = serde_json::to_string(expected_root.to_str().unwrap()).unwrap()
        ),
    );
    host.event_handle().run_command(
        Arc::from("integration-test.lua"),
        Arc::from("/test-git"),
        String::new(),
        0,
    );
    let action = host
        .ui_action_rx()
        .recv_timeout(Duration::from_secs(30))
        .expect("Git assertions did not finish");
    match action {
        maki_lua::UiAction::Flash(message) => assert_eq!(message, "git assertions passed"),
        _ => panic!("unexpected Git test UI action"),
    }
}

#[test]
fn commands_and_turn_end_work_with_declared_permissions() {
    if std::env::var_os("MAKI_CODE_GIT_FIXTURE").is_none() {
        let fixture = std::env::temp_dir().join(format!("maki-code-test-{}", std::process::id()));
        std::fs::create_dir(&fixture).unwrap();
        let result = std::panic::catch_unwind(|| {
            for args in [
                vec!["init", "--quiet"],
                vec![
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.invalid",
                    "commit",
                    "--quiet",
                    "--allow-empty",
                    "-m",
                    "initial",
                ],
            ] {
                assert!(
                    std::process::Command::new("git")
                        .args(args)
                        .current_dir(&fixture)
                        .status()
                        .unwrap()
                        .success()
                );
            }
            std::fs::write(fixture.join("example.rs"), "fn main() {}\n").unwrap();
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "commands_and_turn_end_work_with_declared_permissions",
                    "--nocapture",
                ])
                .env("MAKI_CODE_GIT_FIXTURE", "1")
                .current_dir(&fixture)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        });
        std::fs::remove_dir_all(&fixture).unwrap();
        if let Err(error) = result {
            std::panic::resume_unwind(error);
        }
        return;
    }

    assert_eq!(
        include_str!("../plugin.toml").trim(),
        "[permissions]\nrun = true\nfs_read = true",
        "update the test grants when the package permission request changes"
    );
    let (_registry, host) =
        plugin_host_with_permissions(PluginPermissions::from_approved(["run", "fs_read"]));
    let rx = host.ui_action_rx();
    let event = host.event_handle();
    event.fire_autocmd("TurnEnd", json!({}));
    let action = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("TurnEnd reminder did not run");
    assert!(
        matches!(action, maki_lua::UiAction::Flash(message) if message == "1 file(s) changed — /review to inspect & comment")
    );
    event.fire_autocmd("TurnEnd", json!({}));
    assert!(
        rx.recv_timeout(Duration::from_millis(300)).is_err(),
        "unchanged Git signature must not flash twice"
    );

    for command in ["/code", "/review"] {
        event.run_command(Arc::from(PLUGIN_NAME), Arc::from(command), String::new(), 0);
        let mut windows = Vec::new();
        for _ in 0..if command == "/code" { 6 } else { 8 } {
            let action = rx
                .recv_timeout(Duration::from_secs(10))
                .expect("command did not open its panes");
            match action {
                maki_lua::UiAction::OpenWin {
                    event_tx, cmd_rx, ..
                } => windows.push((event_tx, cmd_rx)),
                maki_lua::UiAction::Flash(message) => panic!("{command} failed: {message}"),
                _ => panic!("unexpected UI action from {command}"),
            }
        }
        windows
            .last()
            .unwrap()
            .0
            .send(maki_lua::WinEvent::Key {
                key: maki_lua::Key::parse("q").unwrap(),
            })
            .unwrap();
        for (_, commands) in windows {
            loop {
                match commands
                    .recv_timeout(Duration::from_secs(10))
                    .expect("pane was not closed")
                {
                    maki_lua::WinCommand::Close => break,
                    _ => continue,
                }
            }
        }
    }
}
