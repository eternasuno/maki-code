package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local passed, failed = 0, 0
local function eq(a, b)
  assert(a == b, tostring(a) .. " ~= " .. tostring(b))
end
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
  end
  print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or ": " .. tostring(err)))
end
local Shell = require("common.shell")
local Tree = require("common.tree")
local Utils = require("common.utils")
local Highlight = require("common.highlight")
local Layout = require("common.layout")
local Comments = require("common.comments")
local function jobs(result)
  local f = { stopped = 0 }
  maki = {
    fn = {
      jobstart = function(cmd, opts)
        f.cmd, f.opts = cmd, opts
        return 17
      end,
      jobwait = function(id, timeout)
        eq(id, 17)
        f.timeout = timeout
        return result
      end,
      jobstop = function(id)
        eq(id, 17)
        f.stopped = f.stopped + 1
      end,
    },
  }
  return f
end

test("shell exit zero default timeout quoting cwd and environment", function()
  local f = jobs({ exit_code = 0, stdout = "raw\0output\n", stderr = "ignored" })
  local cmd = "printf '%s' 'space and '\"'\"'quote'"
  eq(Shell.run(cmd, { cwd = "/a b", env = { VALUE = "x y" } }), "raw\0output\n")
  eq(f.cmd, cmd)
  eq(f.opts.cwd, "/a b")
  eq(f.opts.env.VALUE, "x y")
  eq(f.timeout, 15000)
  eq(f.stopped, 0)
end)

test("shell quote escapes literal single quotes", function()
  eq(Shell.quote(""), "''")
  eq(Shell.quote("a'b $HOME"), "'a'\\''b $HOME'")
end)

test("shell exit one rejected by default accepted when configured", function()
  jobs({ exit_code = 1, stdout = "partial", stderr = "  rejected\n " })
  local out, err = Shell.run("command")
  eq(out, nil)
  eq(err, "rejected")
  eq(Shell.run("command", { ok_exit_codes = { 0, 1 } }), "partial")
end)

test("shell configured acceptance replaces defaults and empty stderr fallback", function()
  jobs({ exit_code = 0, stderr = " \n" })
  local out, err = Shell.run("command", { ok_exit_codes = { 1 } })
  eq(out, nil)
  eq(err, "exit 0")
end)

test("shell timeout stops job configurable timeout", function()
  local f = jobs(nil)
  local out, err = Shell.run("command", { timeout = 37 })
  eq(out, nil)
  eq(err, "timed out: command")
  eq(f.timeout, 37)
  eq(f.stopped, 1)
end)

test("shell wait error stops even if stop throws", function()
  local f = jobs(nil)
  maki.fn.jobwait = function()
    return nil, "wait denied"
  end
  maki.fn.jobstop = function()
    f.stopped = f.stopped + 1
    error("stop denied")
  end
  local out, err = Shell.run("command")
  eq(out, nil)
  eq(err, "wait denied")
  eq(f.stopped, 1)
end)

test("shell wait exception stops", function()
  local f = jobs(nil)
  maki.fn.jobwait = function()
    error("wait panic")
  end
  local out, err = Shell.run("command")
  eq(out, nil)
  assert(err:find("wait panic", 1, true))
  eq(f.stopped, 1)
end)

test("shell start errors and exceptions never wait", function()
  jobs(nil)
  maki.fn.jobwait = function()
    error("must not wait")
  end
  maki.fn.jobstart = function()
    return nil, "start denied"
  end
  local out, err = Shell.run("command")
  eq(out, nil)
  eq(err, "start denied")
  maki.fn.jobstart = function()
    error("start panic")
  end
  out, err = Shell.run("command")
  eq(out, nil)
  assert(err:find("start panic", 1, true))
  maki.fn.jobstart = function()
    return nil
  end
  out, err = Shell.run("command")
  eq(out, nil)
  eq(err, "failed to start job")
end)

test("shell result error truncation and empty output", function()
  jobs({ exit_code = 0, error = "process error" })
  local out, err = Shell.run("command")
  eq(out, nil)
  eq(err, "process error")
  jobs({ exit_code = 0, truncated = true, stdout = "partial" })
  out, err = Shell.run("command")
  eq(out, nil)
  eq(err, "job output truncated")
  jobs({ exit_code = 0 })
  eq(Shell.run("command"), "")
end)

test("tree arbitrary records compression identity collapse without Git", function()
  maki = nil
  local records = { { path = "one/two/a", extra = 7 }, { path = "one/two/b" }, { path = "root" }, { path = "three/c" } }
  local tree = Tree.build_tree(records)
  local rows = Tree.flatten(tree)
  eq(#rows, 6)
  eq(rows[1].name, "one/two")
  eq(rows[1].dir, "one/two")
  eq(rows[1].depth, 0)
  eq(rows[2].idx, 1)
  eq(rows[2].depth, 1)
  eq(rows[3].idx, 2)
  eq(rows[4].dir, "three")
  eq(rows[5].idx, 4)
  eq(rows[6].idx, 3)
  eq(records[1].extra, 7)
  local collapsed = {}
  eq(Tree.toggle_dir(collapsed, "one/two"), true)
  eq(#Tree.flatten(tree, collapsed), 4)
  eq(Tree.toggle_dir(collapsed, "one/two"), nil)
  eq(#Tree.flatten(tree, collapsed), 6)
  eq(#Tree.flatten(Tree.build_tree({})), 0)
end)

test("tree strings and branch depth", function()
  local rows = Tree.flatten(Tree.build_tree({ "a/x", "a/b/y", "z" }))
  eq(rows[1].dir, "a")
  eq(rows[2].dir, "a/b")
  eq(rows[3].depth, 2)
  eq(rows[4].idx, 1)
  eq(rows[5].idx, 3)
end)

test("Unicode sanitation rejects malformed encodings preserves valid scalars", function()
  eq(Utils.sanitize_utf8("é界😀é"), "é界😀é")
  eq(Utils.sanitize_utf8("a\255\192\175\237\160\128\244\144\128\128b"), "ab")
  eq(Utils.sanitize_utf8("a\226\130"), "a")
  eq(Utils.sanitize_utf8(nil), nil)
end)

test("Unicode fallback cell widths and wrapping", function()
  maki = nil
  eq(Utils.display_len("é界😀é"), 6)
  local lines = Utils.wrap("界界éé\n\nhello world", 4)
  eq(lines[1], "界界")
  eq(lines[2], "éé")
  eq(lines[3], "")
  for _, line in ipairs(lines) do
    assert(Utils.display_len(line) <= 4)
    eq(Utils.sanitize_utf8(line), line)
  end
  eq(table.concat(Utils.wrap("界", 0)), "界")
  eq(Utils.wrap("", 4)[1], "")
end)

test("Unicode fit uses cells keeps suffix and handles zero", function()
  maki = nil
  eq(Utils.fit_path("folder/界é", 4), "…界é")
  eq(Utils.fit_path("é界", 3), "é界")
  eq(Utils.fit_path("anything", 0), "")
  eq(Utils.fit_path("anything", 1), "…")
  eq(Utils.fit_path("\255abc", 3), "abc")
end)

test("display width native result and error fallback", function()
  maki = { ui = {
    display_width = function(text)
      eq(text, "é")
      return 7
    end,
  } }
  eq(Utils.display_len("é"), 7)
  maki.ui.display_width = function()
    error("unavailable")
  end
  eq(Utils.display_len("界"), 2)
  maki.ui.display_width = function()
    return "bad"
  end
  eq(Utils.display_len("é"), 1)
end)

test("highlight successful full-file independent language", function()
  local styled = { { { "one", "keyword" } }, { { "two", "item" } } }
  maki = {
    ui = {
      highlight = function(code, lang, opts)
        eq(code, "one\ntwo")
        eq(lang, "lua")
        eq(opts.independent, true)
        return styled
      end,
    },
  }
  eq(Highlight.highlight_file("a.lua", { "one", "two" }), styled)
end)

test("highlight maps source extensions and filenames", function()
  for path, expected in pairs({
    ["foo.ts"] = "typescript",
    ["foo.py"] = "python",
    ["foo.rs"] = "rust",
    Dockerfile = "dockerfile",
  }) do
    maki = { ui = {
      highlight = function(_, lang)
        eq(lang, expected)
        return { {} }
      end,
    } }
    assert(Highlight.highlight_file(path, { "source" }))
  end
end)

test("highlight unavailable errors malformed result and mismatch fallback", function()
  maki = nil
  eq(Highlight.highlight_file("a", { "one" }), nil)
  for _, callback in ipairs({
    function()
      error("unsupported")
    end,
    function()
      return "bad"
    end,
    function()
      return {}
    end,
    function()
      return { {}, {} }
    end,
  }) do
    maki = { ui = { highlight = callback } }
    eq(Highlight.highlight_file("a", { "one" }), nil)
  end
  maki.ui.highlight = function()
    error("empty must not highlight")
  end
  eq(Highlight.highlight_file("a", {}), nil)
end)

test("comments add update remove list and per-file count", function()
  local store = {}
  local record = { file = "a", text = "first" }
  eq(Comments.add(store, record), 1)
  eq(Comments.add(store, { file = "b" }), 2)
  eq(Comments.count_for_file(store, "a"), 1)
  eq(Comments.count_for_file(store, "missing"), 0)
  eq(Comments.list(store), store)
  local replacement = { file = "a", text = "edited" }
  eq(Comments.update(store, 1, replacement), replacement)
  eq(Comments.update(store, 3, replacement), nil)
  eq(Comments.remove(store, 1), replacement)
  eq(Comments.remove(store, 4), nil)
  eq(#store, 1)
  eq(store[1].file, "b")
end)

test("layout spans are padded and styles copied without mutation", function()
  maki = nil
  local spans = { { "界", { fg = "red", bold = true } }, { "é", "item" } }
  eq(Layout.spans_len(spans), 3)
  local changed = Layout.with_bg(spans, "blue")
  eq(changed[1][2].fg, "red")
  eq(changed[1][2].bg, "blue")
  eq(spans[1][2].bg, nil)
  local selected = Layout.restyle(spans, "selected")
  eq(selected[1][2], "selected")
  eq(spans[2][2], "item")
  Layout.pad_spans(changed, 5, "pad")
  eq(Layout.spans_len(changed), 5)
  eq(changed[3][2], "pad")
  eq(Layout.blend("#000000", "#ffffff", 0.5), "#808080")
end)

test("layout sizing uses terminal dimensions", function()
  maki = { ui = {
    terminal_size = function()
      return { cols = 120, rows = 30 }
    end,
  } }
  local size = Layout.sizing()
  eq(size.lw, 33)
  eq(size.rw, 79)
  eq(size.h, 25)
  eq(size.row, 1)
  eq(size.col, 4)
end)

test("layout keeps both columns positive on narrow terminals", function()
  for _, width in ipairs({ 20, 30, 60 }) do
    maki = { ui = {
      terminal_size = function()
        return { cols = width, rows = 20 }
      end,
    } }
    local size = Layout.sizing()
    assert(size.lw > 0 and size.rw > 0)
    assert(size.lw + size.rw <= width)
  end
end)

print(string.format("common: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
