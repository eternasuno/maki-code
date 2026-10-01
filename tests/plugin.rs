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
        for _, name in ipairs({ "tree", "comments", "highlight", "layout", "shell", "utils" }) do
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
fn comments_support_ranges_updates_removal_and_invalid_indices() {
    let (_registry, host) = plugin_host();
    run_lua(
        &host,
        r##"
        local comments = require("common.comments")
        local store = {}
        local first = { file = "lua/code/init.lua", start_line = 3, end_line = 5, text = "fix range" }
        assert(comments.add(store, first) == 1)
        assert(comments.add(store, { file = "lua/review/init.lua", text = "review" }) == 2)
        assert(comments.add(store, { file = first.file, text = "second" }) == 3)
        assert(comments.list(store) == store)
        assert(comments.count_for_file(store, first.file) == 2)
        local replacement = { file = first.file, start_line = 4, end_line = 6, text = "updated" }
        assert(comments.update(store, 1, replacement) == replacement)
        assert(store[1].start_line == 4 and store[1].end_line == 6)
        assert(comments.update(store, 9, first) == nil)
        assert(comments.remove(store, 9) == nil)
        assert(#store == 3)
        assert(comments.remove(store, 1) == replacement)
        assert(#store == 2 and store[1].file == "lua/review/init.lua")
        assert(comments.count_for_file(store, first.file) == 1)
    "##,
    );
}

#[test]
fn tree_supports_code_paths_review_records_and_collapsing() {
    let (_registry, host) = plugin_host();
    run_lua(
        &host,
        r##"
        local tree = require("common.tree")
        for _, changes in ipairs({
            { "src/nested/a.rs", "src/nested/b.rs", "README.md" },
            { { path = "src/nested/a.rs" }, { path = "src/nested/b.rs" }, { path = "README.md" } },
        }) do
            local root = tree.build_tree(changes)
            local collapsed = {}
            local rows = tree.flatten(root, collapsed)
            assert(#rows == 4 and rows[1].dir == "src/nested" and rows[1].name == "src/nested")
            assert(rows[2].idx == 1 and rows[2].depth == 1)
            assert(rows[3].idx == 2 and rows[4].idx == 3)
            assert(tree.toggle_dir(collapsed, "src/nested") == true)
            rows = tree.flatten(root, collapsed)
            assert(#rows == 2 and rows[2].name == "README.md")
            assert(tree.toggle_dir(collapsed, "src/nested") == nil)
            assert(#tree.flatten(root, collapsed) == 4)
        end
        assert(#tree.flatten(tree.build_tree({})) == 0)
    "##,
    );
}

#[test]
fn unicode_layout_and_highlighting_use_real_host_apis() {
    let (_registry, host) = plugin_host();
    run_lua(
        &host,
        r##"
        local utils = require("common.utils")
        local layout = require("common.layout")
        local highlight = require("common.highlight")
        assert(utils.sanitize_utf8("a" .. string.char(255) .. "中") == "a中")
        assert(utils.display_len("中a") == maki.ui.display_width("中a"))
        assert(utils.display_len("中a") == 3)
        local wrapped = utils.wrap("中文ab", 4)
        assert(#wrapped == 2 and wrapped[1] == "中文" and wrapped[2] == "ab")
        assert(utils.fit_path("long/path/文件.rs", 6) == "…件.rs")
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
        assert(source ~= nil and read_err == nil and source:find('require("common.comments")', 1, true))
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
        for _ in 0..if command == "/code" { 3 } else { 4 } {
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
