package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path
local Host = require("support.review_host")
local Comments = require("common.comments")
local tests = 0
local function eq(actual, expected)
  assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function contains(text, part)
  assert(text:find(part, 1, true), "missing " .. part .. " in " .. text)
end
local function test(name, fn)
  local h = Host.new()
  fn(h)
  if h.state then
    h.browser.close(h.state)
  end
  h:closed()
  tests = tests + 1
  print("ok - " .. name)
end
local function save(h, text)
  h:key("c")
  h:paste(text)
  h:key("<CR>")
end
local function last_flash(h)
  return h.flashes[#h.flashes] or ""
end

test("require registers nothing; setup is idempotent", function(h)
  eq(h.counts.register, nil)
  eq(h.counts.autocmd, nil)
  h.module.setup()
  h.module.setup()
  eq(h.counts.register, 1)
  eq(h.counts.autocmd, 1)
  assert(h.commands["/review"] and h.autocmds.TurnEnd)
end)

test("root-scoped Git commands and queued event lifecycle", function(h)
  h.module.setup()
  h.queue = { { type = "key", key = "q" } }
  h.commands["/review"].handler()
  eq(#h.errors, 0)
  h:closed()
  for _, cmd in ipairs(h.jobs) do
    if not cmd:find("rev-parse", 1, true) then
      contains(cmd, "-C '/project root'")
    end
  end
end)

test("TurnEnd compares nonempty path lists and root", function(h)
  h.module.setup()
  local remind = h.autocmds.TurnEnd
  remind()
  remind()
  eq(#h.flashes, 1)
  h.paths = { "new.lua" }
  remind()
  eq(#h.flashes, 2)
  h.paths = {}
  remind()
  eq(#h.flashes, 2)
  h.paths = { "new.lua" }
  remind()
  eq(#h.flashes, 3)
  h.root = "/other"
  remind()
  eq(#h.flashes, 4)
  h.git_fail = "--name-status"
  remind()
  eq(#h.flashes, 4)
end)

for _, failure in ipairs({ "rev-parse", "--name-status", " log " }) do
  test("startup Git failure: " .. failure, function(h)
    h.git_fail = failure
    h.module.setup()
    h.commands["/review"].handler()
    eq(#h.windows, 0)
    contains(last_flash(h), "Git unavailable")
  end)
end

test("real diff parser and highlighting preserve anchors", function(h)
  local Diff = require("review.diff")
  local lines = Diff.parse(
    "header\n@@ -3 +8,2 @@\n-old\n+new\n context\n\\ No newline at end of file\ndiff --git a/x b/x\n+ignored\n"
  )
  eq(#lines, 4)
  eq(lines[2].old_ln, 3)
  eq(lines[3].new_ln, 8)
  eq(lines[4].old_ln, 4)
  eq(lines[4].new_ln, 9)
  eq(Diff.highlight("x.lua", lines), nil)
  eq(h.counts.highlight, 1)
end)

test("initial preview selects a real file and starts on changed line", function(h)
  local s = h:open()
  eq(s.fcursor, 2)
  eq(s.change.path, "src/deep/b.lua")
  eq(s.dlines[s.drow_map[s.dcursor]].kind, "del")
  contains(h:text(s.rbuf), "old")
  contains(h:text(s.fbuf), "src/deep/")
  eq(h.counts.build, 1)
  eq(h.counts.flatten, 1)
end)

test("navigation and panel-only redraw reuse trees and previews", function(h)
  local s = h:open()
  local f, c, m = s.fbuf.set_calls, s.cbuf.set_calls, s.mbuf.set_calls
  local jobs, builds, flattens = #h.jobs, h.counts.build, h.counts.flatten
  h:key("4")
  h:key("j")
  h:key("k")
  h:key("<Tab>")
  eq(s.pane, "diff")
  eq(s.fbuf.set_calls, f + 1)
  eq(s.cbuf.set_calls, c)
  eq(s.mbuf.set_calls, m)
  eq(#h.jobs, jobs)
  eq(h.counts.build, builds)
  eq(h.counts.flatten, flattens)
  local right = s.rbuf.set_calls
  h:key("<Tab>")
  h:key("ignored")
  eq(s.rbuf.set_calls, right)
  h:key("1")
  h:key("G")
  h:key("g")
  eq(s.fcursor, 1)
  eq(h.counts.build, builds)
  eq(h.counts.flatten, flattens)
  eq(h.counts.diff, 2)
end)

test("compressed directory toggles flatten only and preserve pane", function(h)
  local s = h:open()
  h:key("g")
  eq(s.frow_map[s.fcursor].dir, "src/deep")
  h:key("l")
  eq(s.pane, "files")
  assert(s.fcollapsed["src/deep"])
  eq(h.counts.build, 1)
  eq(h.counts.flatten, 2)
  contains(h:text(s.fbuf), "2 files")
  h:key("<Right>")
  h:key("h")
  assert(s.fcollapsed["src/deep"])
  h:key("h")
  eq(h.counts.flatten, 4)
  h:key("l")
  h:key("j")
  h:key("<CR>")
  eq(s.pane, "diff")
  eq(s.change.path, "src/deep/b.lua")
end)

test("deep directory redraw reuses subtree counts and keeps comment badges live", function(h)
  h.paths = {}
  local path = "root"
  for i = 1, 64 do
    h.paths[#h.paths + 1] = path .. "/file.lua"
    path = path .. "/level" .. i
  end
  h.paths[#h.paths + 1] = path .. "/tail/end.lua"
  local s = h:open()
  h:key("g")
  h:key("l")
  contains(h:text(s.fbuf), "65 files")
  local builds, flattens = h.counts.build, h.counts.flatten
  local children = {}
  local function block_walk(node)
    children[node] = node.dorder
    for _, child in ipairs(node.dorder) do
      block_walk(child)
    end
    node.dorder = setmetatable({}, {
      __index = function()
        error("redraw walked cached directory children")
      end,
    })
  end
  block_walk(s.list_cache[s.working_changes].tree)
  Comments.add(h.comments.store, { target = { kind = "dir", path = path }, text = "ancestor" })
  h.browser.redraw(s)
  contains(h:text(s.fbuf), "● 1")
  contains(h:text(s.fbuf), "65 files")
  Comments.remove(h.comments.store, 1)
  h.browser.redraw(s)
  assert(not h:text(s.fbuf):find("●", 1, true))
  eq(h.counts.build, builds)
  eq(h.counts.flatten, flattens)
  for node, dorder in pairs(children) do
    node.dorder = dorder
  end
  h:key("l")
  for row, selected in ipairs(s.frow_map) do
    if type(selected) == "table" and selected.dir == path .. "/tail" then
      s.fcursor = row
      break
    end
  end
  eq(s.frow_map[s.fcursor].dir, path .. "/tail")
  h:key("l")
  contains(h:text(s.fbuf), "1 files")
  Comments.add(h.comments.store, { target = { kind = "dir", path = path }, text = "ancestor" })
  h.browser.redraw(s)
  contains(h:text(s.fbuf), "● 1")
  eq(h.counts.build, builds)
end)

test("canonical page home end arrows navigate real row maps", function(h)
  local s = h:open()
  h:key("<Down>")
  eq(s.fcursor, 3)
  h:key("<Up>")
  eq(s.fcursor, 2)
  h:key("<PageDown>")
  eq(s.fcursor, 4)
  h:key("<PageUp>")
  eq(s.fcursor, 1)
  h:key("<End>")
  eq(s.fcursor, 4)
  h:key("<Home>")
  eq(s.fcursor, 1)
  h:key("j")
  h:key("4")
  h:key("G")
  eq(s.drow_map[s.dcursor], #s.dlines)
  h:key("g")
  eq(s.dcursor, 1)
  h:key("c")
  eq(s.editor, nil)
  contains(last_flash(h), "Move onto a diff line")
  h:key("<Left>")
  eq(s.pane, "files")
end)

test("numbers clear range but preserve diff source and guard", function(h)
  local s = h:open()
  h:key("4")
  h:key("v")
  assert(s.vstart)
  h:key("1")
  eq(s.vstart, nil)
  h:key("2")
  eq(s.pane, "commits")
  eq(s.preview_pane, "commits")
  h:key("4")
  eq(s.pane, "commits")
  contains(last_flash(h), "No diff to focus")
  h:key("3")
  eq(s.pane, "comments")
  h:key("1")
  h:key("4")
  eq(s.preview_pane, "files")
  h:key("v")
  h:key("<Esc>")
  eq(s.vstart, nil)
  eq(s.pane, "diff")
  h:key("<Esc>")
  eq(s.pane, "files")
end)

for _, key in ipairs({ "l", "<CR>", "<Right>" }) do
  test("commit hierarchy enters via " .. key, function(h)
    local s = h:open()
    h:key("2")
    h:key("j")
    eq(s.ccursor, 2)
    h:key(key)
    eq(s.pane, "commits")
    eq(s.commit.sha, "def")
    eq(s.ccursor, 2)
    eq(s.change.commit, "def")
    h:key("<CR>")
    eq(s.pane, "diff")
    eq(s.preview_pane, "commits")
    h:key("<Left>")
    h:key("h")
    eq(s.commit, nil)
    eq(s.ccursor, 2)
    h:key("l")
    h:key("<Esc>")
    eq(s.commit, nil)
  end)
end

test("commit entry finds file beyond compressed directory before rendering", function(h)
  h.paths = { "src/deep/a.lua" }
  local s = h:open()
  eq(s.fcursor, 2)
  h:key("2")
  h:key("l")
  eq(s.ccursor, 2)
  eq(s.change.path, "src/deep/a.lua")
end)

test("commit entry failure keeps hierarchy unchanged", function(h)
  local s = h:open()
  h:key("2")
  h.git_fail = "diff-tree"
  h:key("l")
  eq(s.commit, nil)
  eq(s.pane, "commits")
  contains(last_flash(h), "commit diff failed")
end)

test("refresh failures retain all old lists and comments", function(h)
  local s = h:open()
  save(h, "file note")
  h:key("2")
  h:key("l")
  local changes, commits, committed = s.working_changes, s.commits, s.commit_changes
  h.git_fail = "-C"
  h:key("r")
  eq(s.working_changes, changes)
  eq(s.commits, commits)
  eq(s.commit_changes, committed)
  eq(#h.comments.store, 1)
  local failed = 0
  for _, flash in ipairs(h.flashes) do
    if flash:find("Refresh failed:", 1, true) then
      failed = failed + 1
    end
  end
  eq(failed, 3)
end)

test("failed changes refresh updates untracked counts without replacing lists or comments", function(h)
  h.paths = {}
  h.untracked = "new.lua"
  h.raw = "@@ -0,0 +1 @@\n+first\n"
  local s = h:open()
  save(h, "keep note")
  local changes, comment = s.working_changes, h.comments.store[1]
  local files = s.fbuf.set_calls
  eq(s.change.adds, 1)
  contains(h:text(s.fbuf), "+1")

  h.git_fail = "--name-status"
  h.raw = "@@ -0,0 +1,3 @@\n+first\n+second\n+third\n"
  h:key("r")
  contains(last_flash(h), "Refresh failed: Git unavailable")
  eq(s.working_changes, changes)
  eq(#h.comments.store, 1)
  eq(h.comments.store[1], comment)
  eq(s.change.adds, 3)
  contains(h:text(s.rbuf), "third")
  contains(h:text(s.fbuf), "+3")
  eq(s.fbuf.set_calls, files + 1)

  h:key("ignored")
  eq(s.fbuf.set_calls, files + 1)
  h:key("r")
  eq(s.fbuf.set_calls, files + 1)
end)

test("successful refresh invalidates trees diffs and retains disappeared comments", function(h)
  local s = h:open()
  save(h, "keep note")
  local old = s.working_changes
  h.paths = { "other.lua" }
  h.raw = "@@ -1 +1 @@\n+fresh\n"
  h:key("r")
  assert(s.working_changes ~= old)
  eq(s.change.path, "other.lua")
  contains(h:text(s.rbuf), "fresh")
  eq(#h.comments.store, 1)
  eq(h.comments.store[1].target.path, "src/deep/b.lua")
  eq(h.counts.build, 2)
  eq(h.counts.flatten, 2)
  eq(h.counts.diff, 2)
  local cached = 0
  for _ in pairs(s.list_cache) do
    cached = cached + 1
  end
  eq(cached, 1)
end)

for _, mode in ipairs({ "file", "dir", "commit file", "commit dir" }) do
  test("path comment captures " .. mode, function(h)
    h:open()
    local commit = mode:find("commit", 1, true) and "abc" or nil
    if commit then
      h:key("2")
      h:key("l")
    end
    local kind = mode:find("dir", 1, true) and "dir" or "file"
    if kind == "dir" then
      h:key("g")
    end
    save(h, "  path note  ")
    local c = h.comments.store[1]
    eq(c.target.kind, kind)
    eq(c.text, "path note")
    eq(c.commit, commit)
    eq(c.new_start, nil)
    eq(c.old_start, nil)
    eq(c.snippet, nil)
    eq(c.target.path, kind == "dir" and "src/deep" or "src/deep/b.lua")
    h:key("3")
    h:key("c")
    h:key("<C-u>")
    h:paste("   ")
    h:key("<CR>")
    eq(c.text, "path note")
    h:key("c")
    h:key("<C-u>")
    h:paste("edited")
    h:key("<CR>")
    eq(c.text, "edited")
    eq(c.commit, commit)
    contains(h.comments.prompt(), kind == "dir" and "Directory comment" or "File comment")
  end)
end

test("line range anchors snapshot and existing edit remain stable", function(h)
  local s = h:open()
  save(h, "whole file")
  h:key("4")
  h:key("v")
  h:key("j")
  h:key("j")
  save(h, "range")
  local c = h.comments.store[2]
  eq(c.old_start, 7)
  eq(c.old_end, 7)
  eq(c.new_start, 7)
  eq(c.new_end, 8)
  eq(c.anchor, "new")
  contains(c.snippet, "@@")
  contains(c.snippet, "+extra  <<< comment applies here")
  local target, snippet = c.target, c.snippet
  h:key("c")
  eq(s.editor.existing_idx, 2)
  h:key("<C-u>")
  h:paste("edited range")
  h:key("<CR>")
  eq(c.target, target)
  eq(c.snippet, snippet)
  eq(c.new_end, 8)
  h:key("1")
  h.raw = "@@ -1 +1 @@\n+replacement\n"
  h:key("r")
  eq(c.snippet, snippet)
  contains(h.comments.prompt(), "lines 7-8")
  contains(h.comments.prompt(), "Verify the actual current workspace")
end)

test("old-side comments are separate from new-side anchors and commits", function(h)
  local s = h:open()
  h:key("4")
  save(h, "removed")
  local c = h.comments.store[1]
  eq(c.anchor, "old")
  eq(c.old_start, 7)
  eq(c.new_start, nil)
  h:key("j")
  save(h, "added")
  eq(#h.comments.store, 2)
  h:key("2")
  h:key("l")
  h:key("4")
  save(h, "committed")
  eq(#h.comments.store, 3)
  eq(h.comments.store[3].commit, "abc")
  eq(h.comments.count({ path = "src/deep/b.lua" }), 2)
  eq(h.comments.count({ path = "src/deep/b.lua", commit = "abc" }), 1)
  local dl = { kind = "del", old_ln = 7 }
  eq(h.comments.at({ path = "src/deep/b.lua" }, dl), c)
  eq(h.comments.at({ path = "src/deep/b.lua", commit = "abc" }, dl), h.comments.store[3])
  contains(h.comments.prompt(), "removed line 7, commit abc")
  assert(s.change.commit == "abc")
end)

for _, key in ipairs({ "<Esc>", "<C-c>" }) do
  test("editor cancellation " .. key .. " preserves comments and pane", function(h)
    local s = h:open()
    save(h, "original")
    h:key("3")
    h:key("c")
    h:key("<C-u>")
    h:paste("discard")
    h:key(key)
    eq(s.editor, nil)
    eq(s.pane, "comments")
    eq(h.comments.store[1].text, "original")
    h:key("c")
    h:key("<C-u>")
    h:key("<CR>")
    eq(#h.comments.store, 1)
    eq(h.comments.store[1].text, "original")
  end)
end

test("editor owns number navigation and shortcut keys; ignored keys do not redraw", function(h)
  local s = h:open()
  h:key("c")
  for _, key in ipairs({ "1", "2", "3", "4", "j", "k", "r", "s", "q", "e", "v" }) do
    h:key(key)
  end
  eq(s.pane, "files")
  eq(s.editor.input:value(), "1234jkrsqev")
  local calls = s.rbuf.set_calls
  h:key("<Tab>")
  eq(s.rbuf.set_calls, calls)
  h:key("<Left>")
  eq(s.rbuf.set_calls, calls + 1)
  h:key("<CR>")
  eq(h.comments.store[1].text, "1234jkrsqev")
end)

for _, text in ipairs({ "日本語のコメント", "emoji 😀 comment", "é and café" }) do
  test("UTF8 comment production render: " .. text, function(h)
    local s = h:open()
    save(h, text)
    eq(h.comments.store[1].text, text)
    h:key("3")
    contains(h:text(s.rbuf), text)
    contains(h.comments.prompt(), text)
  end)
end

test("mixed badges include compressed ancestors and isolate commits", function(h)
  local s = h:open()
  Comments.add(h.comments.store, { target = { kind = "dir", path = "src" }, text = "ancestor" })
  Comments.add(h.comments.store, { target = { kind = "file", path = "src/deep/b.lua" }, text = "file" })
  Comments.add(
    h.comments.store,
    { target = { kind = "file", path = "src/deep/c.lua" }, commit = "abc", text = "commit" }
  )
  h.browser.redraw(s)
  contains(h:text(s.fbuf), "● 2")
  eq(h.comments.count_under("src"), 2)
  eq(h.comments.count_under("src", "abc"), 1)
  h:key("2")
  h:key("l")
  contains(h:text(s.cbuf), "● 1")
  h:key("3")
  eq(#s.mrow_map, 3)
  h:key("d")
  eq(#h.comments.store, 2)
  eq(s.mcursor, 1)
  h:key("<CR>")
  contains(last_flash(h), "d deletes")
end)

test("inline deletion skips rendered comment blocks and removes only line record", function(h)
  local s = h:open()
  save(h, "file")
  h:key("4")
  save(h, "line")
  local row = s.dcursor
  h:key("j")
  assert(s.dcursor > row + 1)
  h:key("k")
  eq(s.dcursor, row)
  h:key("d")
  eq(#h.comments.store, 1)
  eq(h.comments.store[1].target.kind, "file")
  h:key("d")
  contains(last_flash(h), "No comment on this line")
end)

for _, mode in ipairs({ "success", "missing", "directory", "metadata panic", "editor panic", "nonzero" }) do
  test("external edit: " .. mode, function(h)
    local s = h:open()
    save(h, "keep")
    if mode == "missing" then
      h.missing = true
    elseif mode == "directory" then
      h.directory = true
    elseif mode == "metadata panic" then
      h.meta_throw = true
    elseif mode == "editor panic" then
      h.editor_throw = true
    elseif mode == "nonzero" then
      h.editor_code = 2
    end
    h:key("e")
    eq(s.pane, "files")
    eq(#h.comments.store, 1)
    eq(h.edit_path, "/project root/src/deep/b.lua")
    if mode == "success" or mode == "editor panic" or mode == "nonzero" then
      eq(h.editor_path, "/project root/src/deep/b.lua")
      eq(h.counts.diff, 2)
    else
      eq(h.counts.editor, nil)
      contains(last_flash(h), "Cannot edit file")
    end
    h:key("g")
    h:key("e")
    contains(last_flash(h), "Select a working-tree file")
    h:key("3")
    local n = #h.jobs
    h:key("e")
    eq(#h.jobs, n)
  end)
end

test("untracked external edit and diff use repository-root absolute path", function(h)
  h.paths = {}
  h.untracked = "sub/new.lua"
  local s = h:open()
  eq(s.change.adds, 2)
  h:key("e")
  eq(h.editor_path, "/project root/sub/new.lua")
  local found = false
  for _, cmd in ipairs(h.jobs) do
    if cmd:find("--no-index", 1, true) then
      contains(cmd, "'/project root/sub/new.lua'")
      found = true
    end
  end
  assert(found)
end)

test("comment store survives close reopen and is independent of code", function(h)
  h:open()
  save(h, "persist")
  local code = require("code.comments")
  local count = #code.store
  h:key("q")
  h:open()
  eq(#h.comments.store, 1)
  eq(#code.store, count)
  h:key("3")
  contains(h:text(h.state.rbuf), "persist")
end)

for _, draft in ipairs({ "", "existing draft", "日本語 😀" }) do
  test("submission appends manually to draft: " .. draft, function(h)
    h.draft = draft
    h:open()
    save(h, "fix")
    local prompt = h.comments.prompt()
    eq(h:key("s"), false)
    eq(h.draft, draft .. (draft ~= "" and "\n\n" or "") .. prompt)
    eq(#h.comments.store, 0)
    eq(#h.edits, 1)
    eq(h.counts.sleep, 1)
    h:closed()
  end)
end

test("native focus and event receiver follow review panes and editor", function(h)
  local s = h:open()
  for _, entry in ipairs({
    { "2", "cwin", "cbuf" },
    { "3", "mwin", "mbuf" },
    { "1", "fwin", "fbuf" },
    { "4", "rwin", "rbuf" },
  }) do
    h:key(entry[1])
    eq(s.inputwin, s[entry[2]])
    eq(h:text(h.focused.buf), h:text(s[entry[3]]))
    eq(s.inputwin:recv(), nil)
  end
  local focused = h.focused
  h:key("j")
  eq(h.focused, focused)
  h:key("1")
  h:key("c")
  eq(s.inputwin, s.rwin)
  eq(h:text(h.focused.buf), h:text(s.rbuf))
  h:key("<Esc>")
  eq(s.inputwin, s.fwin)
  eq(h:text(h.focused.buf), h:text(s.fbuf))
end)

test("empty submission does not close windows or inspect input", function(h)
  h:open()
  eq(h:key("s"), true)
  eq(h.counts.input, nil)
  eq(h.counts.close, nil)
  contains(last_flash(h), "No review comments yet")
end)

for _, failure in ipairs({ "snapshot", "snapshot panic", "second snapshot", "edit", "edit panic" }) do
  test("submission failure restores UI: " .. failure, function(h)
    local s = h:open()
    save(h, "retain")
    if failure == "snapshot" then
      h.input_fail = true
    elseif failure == "snapshot panic" then
      h.input_throw = true
    elseif failure == "second snapshot" then
      h.input_fail_at = 2
    elseif failure == "edit" then
      h.input_edit_fail = true
    else
      h.input_edit_throw = true
    end
    eq(h:key("s"), true)
    eq(#h.comments.store, 1)
    eq(h.draft, "")
    assert(s.fwin and s.rwin)
    contains(last_flash(h), "Failed to fill chat input")
    eq(h.counts.open, failure:find("snapshot", 1, true) and failure ~= "second snapshot" and 11 or 20)
    h.input_fail, h.input_throw, h.input_fail_at, h.input_edit_fail, h.input_edit_throw = nil, nil, nil, nil, nil
    eq(h:key("s"), false)
    eq(#h.comments.store, 0)
  end)
end

for _, failures in ipairs({ 1, 4, 5, 20 }) do
  test("bounded not-on-screen retries: " .. failures, function(h)
    h:open()
    save(h, "fix")
    h.visibility_fail = failures
    eq(h:key("s"), failures >= 5)
    eq(#h.edits, math.min(failures + 1, 5))
    eq(h.counts.sleep, math.min(failures + 1, 5))
    eq(#h.comments.store, failures >= 5 and 1 or 0)
    if failures >= 5 then
      assert(h.state.fwin)
      contains(last_flash(h), "Failed to fill")
    end
  end)
end

for _, tick in ipairs({ 1, 2, 5 }) do
  test("session switch aborts after yielding tick " .. tick, function(h)
    h:open()
    save(h, "retain")
    h.visibility_fail = 20
    h.on_sleep = function()
      if h.counts.sleep == tick then
        h.session = "other"
      end
    end
    eq(h:key("s"), true)
    eq(#h.edits, tick - 1)
    eq(#h.comments.store, 1)
    eq(h.draft, "")
    contains(last_flash(h), "Focused session changed")
    assert(h.state.fwin)
  end)
end

test("failed panel close retains resources and blocks reopen until retry", function(h)
  local s = h:open()
  local Windows = require("review.windows")
  local panel = s.rwin
  local native = h.windows[2]
  local close = native.close
  local attempts = 0
  native.close = function()
    attempts = attempts + 1
    error("close unavailable")
  end
  Windows.close(s)
  eq(s.rwin, panel)
  eq(s.fwin, nil)
  eq(s.cwin, nil)
  eq(s.mwin, nil)
  assert(not native.closed)
  for i, window in ipairs(h.windows) do
    if i ~= 2 then
      assert(window.closed)
    end
  end
  eq(s.rootwin, nil)
  eq(pcall(Windows.open, s), false)
  eq(#h.windows, 9)
  eq(s.rwin, panel)
  assert(attempts >= 2)
  contains(h.errors[1], "review close failed:")
  native.close = close
  Windows.close(s)
  eq(s.rwin, nil)
  h:closed()
end)

for fail_at = 1, 9 do
  test("partial window creation cleanup at native window " .. fail_at, function(h)
    h.open_fail_at = fail_at
    local s = h.browser.create_state(h.root, assert(h.git.changes(h.root)), assert(h.git.log(h.root)))
    local ok = pcall(h.browser.open, s)
    eq(ok, false)
    h:closed()
    eq(s.fwin, nil)
    eq(s.rwin, nil)
    eq(s.rootwin, nil)
  end)
end

for _, scenario in ipairs({ "initial render", "event render", "resize", "recv", "restore", "close" }) do
  test("exception cleanup: " .. scenario, function(h)
    if scenario == "initial render" then
      h.module.setup()
      h.render_throw = function()
        return true
      end
      h.commands["/review"].handler()
      contains(last_flash(h), "review error:")
    elseif scenario == "recv" then
      h.module.setup()
      h.recv_throw = true
      h.commands["/review"].handler()
      contains(last_flash(h), "recv panic")
    else
      local s = h:open()
      local ok
      if scenario == "event render" then
        h.render_throw = function(buf)
          return buf == s.rbuf
        end
        ok = pcall(h.key, h, "4")
      elseif scenario == "resize" then
        h.open_fail_at = h.counts.open + 4
        h.size.cols = 60
        ok = pcall(h.browser.handle_event, s, { type = "resize" })
      elseif scenario == "restore" then
        save(h, "retain")
        h.input_edit_fail = true
        h.open_fail_at = h.counts.open + 6
        ok = pcall(h.key, h, "s")
        eq(#h.comments.store, 1)
      else
        h.close_throw = true
        eq(h:key("q"), false)
        assert(#h.errors > 0)
        ok = true
      end
      eq(ok, scenario == "close")
    end
    h:closed()
  end)
end

test("native percentage root owns panel extent and closes on submission", function(h)
  local open_win = maki.ui.open_win
  maki.ui.open_win = function(buf, opts)
    local win = open_win(buf, opts)
    if opts.width == "90%" then
      win.width, win.height = 100, 24
    end
    return win
  end
  local s = h:open()
  local root = s.rootwin
  eq(root.opts.width, "90%")
  eq(root.opts.height, "90%")
  eq(root.opts.focus, false)
  eq(root.opts.border, "none")
  eq(root.opts.zindex, 48)
  eq(s.panel_lwidth + s.panel_rwidth + 1, root.width)
  eq(h.windows[2].height, root.height)
  eq(root.config.row, 2)
  eq(root.config.col, 10)
  save(h, "submit")
  eq(h:key("s"), false)
  eq(s.rootwin, nil)
  assert(root.closed)
end)

test("failed root close retains resource and blocks reopen until retry", function(h)
  local s = h:open()
  local Windows = require("review.windows")
  local root = s.rootwin
  local close = root.close
  root.close = function()
    error("root close unavailable")
  end
  Windows.close(s)
  eq(s.rootwin, root)
  eq(pcall(Windows.open, s), false)
  eq(#h.windows, 9)
  root.close = close
  Windows.close(s)
  eq(s.rootwin, nil)
end)

test("resize recreates panels only when terminal dimensions change", function(h)
  local s = h:open()
  h.browser.handle_event(s, { type = "resize" })
  eq(h.counts.open, 9)
  h.size = { cols = 60, rows = 18 }
  h.browser.handle_event(s, { type = "resize" })
  eq(h.counts.open, 18)
  eq(h.counts.build, 1)
  eq(h.counts.diff, 1)
  for i = 1, 9 do
    assert(h.windows[i].closed)
  end
  local right_frame, files_frame = h.windows[11], h.windows[17]
  assert(right_frame.opts.col >= files_frame.opts.col + files_frame.opts.width + 1)
  for i = 11, 18 do
    local w = h.windows[i]
    assert(w.opts.row + w.height <= h.size.rows)
    assert(w.opts.col + w.width <= h.size.cols)
  end
end)

test("unchanged redraw has zero content frame and Git calls", function(h)
  local s = h:open()
  local counts = {}
  for _, w in ipairs(h.windows) do
    counts[w.buf] = w.buf.set_calls
  end
  local jobs, build, flatten = #h.jobs, h.counts.build, h.counts.flatten
  for _ = 1, 20 do
    h.browser.redraw(s)
  end
  for b, calls in pairs(counts) do
    eq(b.set_calls, calls)
  end
  eq(#h.jobs, jobs)
  eq(h.counts.build, build)
  eq(h.counts.flatten, flatten)
  print("perf - 20 unchanged redraws: 0 buffer writes, 0 Git calls, 0 tree builds/flattens")
end)

test("cached comment matches avoid navigation anchor rescans", function(h)
  local s = h:open()
  local at, calls = h.comments.at, 0
  h.comments.at = function(...)
    calls = calls + 1
    return at(...)
  end
  h:key("4")
  h:key("j")
  h:key("k")
  eq(calls, 0)
  save(h, "line note")
  eq(calls, #s.dlines)
  local scanned = calls
  h:key("j")
  h:key("k")
  eq(calls, scanned)
  print("perf - mutation: one " .. #s.dlines .. "-line match rebuild; navigation: 0 anchor rescans")
end)

test("submission clears only review comments", function(h)
  local code = require("code.comments")
  local record = { target = { kind = "file", path = "independent.lua" }, text = "code note" }
  Comments.add(code.store, record)
  local count = #code.store
  h:open()
  save(h, "review note")
  eq(h:key("s"), false)
  eq(#h.comments.store, 0)
  eq(#code.store, count)
  eq(code.store[count], record)
  Comments.remove(code.store, count)
end)

for _, event in ipairs({ { type = "close" }, { type = "key", key = "<C-c>" }, { type = "key", key = "<Esc>" } }) do
  test("direct event exit closes windows: " .. (event.key or event.type), function(h)
    local s = h:open()
    eq(h.browser.handle_event(s, event), false)
    h:closed()
    eq(s.fwin, nil)
    h.browser.close(s)
    eq(h.counts.close, 9)
  end)
end

test("long Unicode commit subject truncation", function(h)
  local s = h:open()
  s.commits = { { sha = "abc", subject = string.rep("日本語😀", 40), when = "one day ago" } }
  h.browser.redraw(s)
  contains(h:text(s.cbuf), "…")
  contains(h:text(s.cbuf), "日本")
end)

print(tests .. " review behavior tests passed (original modules, no source extraction)")
