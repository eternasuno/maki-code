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
local Text = require("common.text")
local Input = require("common.input")
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
  eq(Text.sanitize_utf8("é界😀é"), "é界😀é")
  eq(Text.sanitize_utf8("a\255\192\175\237\160\128\244\144\128\128b"), "ab")
  eq(Text.sanitize_utf8("a\226\130"), "a")
  eq(Text.sanitize_utf8(nil), nil)
end)

test("Unicode fallback cell widths and wrapping", function()
  maki = nil
  eq(Text.display_len("é界😀é"), 6)
  local lines = Text.wrap("界界éé\n\nhello world", 4)
  eq(lines[1], "界界")
  eq(lines[2], "éé")
  eq(lines[3], "")
  for _, line in ipairs(lines) do
    assert(Text.display_len(line) <= 4)
    eq(Text.sanitize_utf8(line), line)
  end
  eq(table.concat(Text.wrap("界", 0)), "界")
  eq(Text.wrap("", 4)[1], "")
end)

test("Unicode fit uses cells keeps suffix and handles zero", function()
  maki = nil
  eq(Text.fit_path("folder/界é", 4), "…界é")
  eq(Text.fit_path("é界", 3), "é界")
  eq(Text.fit_path("anything", 0), "")
  eq(Text.fit_path("anything", 1), "…")
  eq(Text.fit_path("\255abc", 3), "abc")
  eq(Text.fit_path(string.rep("界", 2000), 2001), "…" .. string.rep("界", 1000))
  eq(Text.display("\255a\0\127\t\n界"), "a??\t\n界")
end)

test("display width native result and error fallback", function()
  maki = { ui = {
    display_width = function(text)
      eq(text, "é")
      return 7
    end,
  } }
  eq(Text.display_len("é"), 7)
  maki.ui.display_width = function()
    error("unavailable")
  end
  eq(Text.display_len("界"), 2)
  maki.ui.display_width = function()
    return "bad"
  end
  eq(Text.display_len("é"), 1)
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
    maki = {
      ui = {
        highlight = function(_, lang)
          eq(lang, expected)
          return { {} }
        end,
      },
    }
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

test("comments add update remove and versions", function()
  local store = {}
  local record = { file = "a", text = "first" }
  eq(Comments.add(store, record), 1)
  eq(Comments.add(store, { file = "b" }), 2)
  eq(Comments.version(store), 2)
  local replacement = { file = "a", text = "edited" }
  eq(Comments.update(store, 1, replacement), replacement)
  eq(Comments.update(store, 3, replacement), nil)
  eq(Comments.remove(store, 1), replacement)
  eq(Comments.remove(store, 4), nil)
  eq(#store, 1)
  eq(store[1].file, "b")
end)

test("comments mixed target locations", function()
  local line = { target = { kind = "line", path = "src/api/foo.lua" }, start_line = 2, end_line = 4 }
  local file = { target = { kind = "file", path = "src/api/foo.lua" } }
  local dir = { target = { kind = "dir", path = "src/api" } }
  eq(Comments.location(line), "src/api/foo.lua:2-4")
  eq(Comments.location(file), "src/api/foo.lua")
  eq(Comments.location(dir), "src/api/")
  eq(Comments.kind(line), "line")
  eq(Comments.path(dir), "src/api")
  eq(Comments.location({ file = "old.lua", start_line = 1, end_line = 1 }), "old.lua:1")
  eq(Comments.location({ file = "old.lua", anchor = "old", old_start = 3, old_end = 5 }), "old.lua:3-5")
  eq(Comments.location({ file = "old.lua" }), "old.lua:?")
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

test("layout sizing uses host extent and terminal centering", function()
  maki = { ui = {
    terminal_size = function()
      return { cols = 120, rows = 30 }
    end,
  } }
  local size = Layout.sizing({ width = 100, height = 24 })
  eq(size.lw, 30)
  eq(size.rw, 69)
  eq(size.gap, 1)
  eq(size.h, 24)
  eq(size.row, 2)
  eq(size.col, 10)
end)

test("root is a real native percentage background window", function()
  local root = { width = 101, height = 23 }
  local buffer = {}
  maki = {
    ui = {
      buf = function()
        return buffer
      end,
      open_win = function(buf, opts)
        eq(buf, buffer)
        eq(opts.width, "90%")
        eq(opts.height, "90%")
        eq(opts.border, "none")
        eq(opts.focus, false)
        eq(opts.zindex, 48)
        assert(opts.visible ~= false)
        return root
      end,
    },
  }
  eq(Layout.open_root(), root)
end)

test("layout keeps both columns positive on narrow terminals", function()
  for _, width in ipairs({ 2, 3, 4, 5, 6, 20, 30, 60, 120 }) do
    maki = { ui = {
      terminal_size = function()
        return { cols = width, rows = 20 }
      end,
    } }
    local w = width
    local size = Layout.sizing({ width = w, height = 18 })
    assert(size.lw > 0 and size.rw > 0)
    eq(size.gap, w >= 5 and 1 or 0)
    eq(size.lw + size.gap + size.rw, w)
    assert(size.lw + size.gap + size.rw <= width)
  end
end)

test("panel titles trim whitespace and preserve focus without changing borders", function()
  maki = nil
  for _, active in ipairs({ false, true }) do
    local cfg = Layout.panel_config(80, "  [1] Files 界é  ", active, {})
    eq(cfg.border, "none")
    eq(cfg.title, "[1] Files 界é")
    eq(cfg.active, active)
    assert(cfg.footer == nil or #cfg.footer == 0)
  end
end)

test("panel titles fit tiny widths Unicode and long paths", function()
  maki = nil
  for _, title in ipairs({ " Files ", " 界界é😀é ", " " .. string.rep("long/path/", 50) .. " " }) do
    for width = 0, 80 do
      for _, active in ipairs({ false, true }) do
        local cfg = Layout.panel_config(width, title, active, {})
        eq(cfg.border, "none")
        assert(Text.display_len(cfg.title) <= math.max(width - 2, 0))
        eq(Text.sanitize_utf8(cfg.title), cfg.title)
        eq(cfg.active, active)
      end
    end
  end
end)

test("panel footer keeps only the full prefix fitting rendered cells", function()
  maki = nil
  for _, footer in ipairs({
    { { "a", "b" }, { "c", "d" } },
    { { "界", "é" }, { "😀", "é" }, { "Esc", "close" } },
    { { "Enter", string.rep("long", 40) }, { "x", "y" } },
  }) do
    for width = 0, 200 do
      local cfg = Layout.panel_config(width, " title ", true, footer)
      local expected, cells = 0, 1
      for _, pair in ipairs(footer) do
        local next_cells = cells + Text.display_len(pair[1]) + Text.display_len(pair[2]) + 2
        if next_cells > math.max(width - 2, 0) then
          break
        end
        cells, expected = next_cells, expected + 1
      end
      eq(#(cfg.footer or {}), expected)
      for i, pair in ipairs(cfg.footer or {}) do
        eq(pair[1], footer[i][1])
        eq(pair[2], footer[i][2])
      end
      if expected > 0 then
        assert(cells <= width - 2)
      end
    end
  end
end)

test("panel frame colors corners geometry and content delegation", function()
  for _, width in ipairs({ 1, 2, 3, 8, 40 }) do
    for _, height in ipairs({ 1, 2, 3, 9 }) do
      local windows, closed = {}, {}
      maki = {
        ui = {
          theme_style = function(name)
            return { fg = name == "accent" and "#abcdef" or "#123456", bg = "#000000" }
          end,
          buf = function()
            return {
              set_lines = function(self, lines)
                self.content = lines
              end,
            }
          end,
          open_win = function(buf, opts)
            local win = { buf = buf, opts = opts, width = opts.width, height = opts.height }
            function win:recv(timeout)
              self.timeout = timeout
              return { type = "scroll", row = 17 }
            end
            function win:set_cursor(row)
              self.cursor = row
            end
            function win:close()
              self.closed = true
              closed[#closed + 1] = self
            end
            windows[#windows + 1] = win
            return win
          end,
        },
      }
      local buf = { content = { { { "unchanged source", "item" } } } }
      local original = buf.content
      local panel = Layout.open_panel(buf, { width = width, height = height, row = 4, col = 7, focus = true })
      local frame, content = windows[1], windows[2]
      eq(#windows, 2)
      eq(frame.opts.focus, false)
      eq(content.opts.focus, true)
      eq(frame.opts.zindex, 49)
      eq(content.opts.zindex, 50)
      for _, win in ipairs(windows) do
        eq(win.opts.border, "none")
        eq(win.opts.title, "")
        eq(#win.opts.footer, 0)
        assert(win.width > 0 and win.height > 0)
      end
      eq(frame.width, width)
      eq(frame.height, height)
      eq(content.buf, buf)
      eq(content.opts.row, 4 + (height >= 3 and 1 or 0))
      eq(content.opts.col, 7 + (width >= 3 and 1 or 0))
      eq(panel.width, width >= 3 and width - 2 or width)
      eq(panel.height, height >= 3 and height - 2 or height)
      for _, active in ipairs({ true, false }) do
        panel:set_config(
          Layout.panel_config(width, " [1] 界é/path/to/file ", active, { { "界", "é" }, { "q", "quit" } })
        )
        eq(#frame.buf.content, height)
        for row, spans in ipairs(frame.buf.content) do
          eq(Layout.spans_len(spans), width)
          eq(spans[1][2].fg, active and "#bb9af7" or "#123456")
          eq(spans[1][2].bg, nil)
          local text = spans[1][1]
          eq(Text.sanitize_utf8(text), text)
          assert(not text:find(">", 1, true))
          if width >= 2 then
            local left = row == 1 and "┌" or row == height and "└" or "│"
            local right = row == 1 and "┐" or row == height and "┘" or "│"
            eq(text:sub(1, #left), left)
            eq(text:sub(-#right), right)
          end
        end
      end
      eq(buf.content, original)
      local event = panel:recv(35)
      eq(event.type, "scroll")
      eq(event.row, 17)
      eq(content.timeout, 35)
      panel:set_cursor(17)
      eq(content.cursor, 17)
      eq(frame.cursor, nil)
      panel:close()
      eq(closed[1], content)
      eq(closed[2], frame)
      panel:close()
      eq(#closed, 2)
    end
  end
end)

test("comment index derives identities indices predicates and all ancestors", function()
  local store = {}
  eq(Comments.version(store), 0)
  local a = { target = { kind = "line", path = "src/api/a" } }
  local b = { target = { kind = "dir", path = "src/api" }, commit = "x" }
  Comments.add(store, a)
  Comments.add(store, b)
  Comments.add(store, { file = "src/api-other/b" })
  local index = Comments.index(store)
  eq(index.by_path["src/api/a"][1].record, a)
  eq(index.by_path["src/api/a"][1].index, 1)
  eq(index.exact["src/api/a"], 1)
  eq(index.under["src/api"], 2)
  eq(index.under.src, 3)
  eq(index.under["src/api-other"], 1)
  local filtered = Comments.index(store, function(record)
    return record.commit == "x"
  end)
  eq(filtered.by_path["src/api"][1].index, 2)
  eq(filtered.under.src, 1)
  eq(filtered.exact["src/api/a"], nil)
  eq(Comments.update(store, 8, a), nil)
  eq(Comments.remove(store, 8), nil)
  eq(Comments.version(store), 3)
  Comments.update(store, 1, b)
  Comments.remove(store, 2)
  eq(Comments.version(store), 5)
  eq(Comments.index(store).by_path["src/api"][1].index, 1)
  eq(index.by_path["src/api/a"][1].record, a)
end)

local function panel_mock()
  local f = { windows = {}, renders = 0 }
  maki = {
    ui = {
      buf = function()
        return {
          set_lines = function()
            f.renders = f.renders + 1
          end,
        }
      end,
      open_win = function(_, opts)
        if #f.windows == 1 and f.create_failure then
          error("create failed")
        end
        local win = { width = opts.width, height = opts.height, closes = 0 }
        function win:close()
          self.closes = self.closes + 1
          if self.failure then
            error("close failed")
          end
        end
        f.windows[#f.windows + 1] = win
        return win
      end,
    },
  }
  return f
end

test("focus snapshots clean buffers independently of queued old window closure", function()
  local windows = {}
  maki = {
    ui = {
      buf = function()
        local b = { lines = {}, dirty = false }
        function b:set_lines(lines)
          self.lines, self.dirty = lines, true
          if self.change then
            self.change()
          end
        end
        function b:get_lines()
          return self.lines
        end
        function b:on(event, callback)
          eq(event, "change")
          self.change = callback
        end
        return b
      end,
      open_win = function(buf, opts)
        local w = { buf = buf, width = opts.width, height = opts.height, cached = {} }
        function w:tick()
          if self.buf.dirty then
            self.cached = self.buf.lines
            self.buf.dirty = false
          end
        end
        function w:close()
          self.close_queued = true
        end
        function w:set_cursor(row)
          self.cursor = row
        end
        w:tick()
        windows[#windows + 1] = w
        return w
      end,
    },
  }
  local buf = maki.ui.buf()
  local initial = { { { "代码", { fg = "#bb9af7" } } } }
  buf:set_lines(initial)
  local panel = Layout.open_panel(buf, { width = 40, height = 8 })
  panel:set_cursor(1)
  eq(buf.dirty, false)
  for _ = 1, 3 do
    local old = windows[#windows]
    panel:focus()
    local current = windows[#windows]
    assert(old.close_queued)
    assert(current.buf ~= old.buf)
    eq(current.cached, buf:get_lines())
    eq(current.cursor, 1)
    local updated = { { { "updated content", "selected" } } }
    buf:set_lines(updated)
    for _, window in ipairs(windows) do
      window:tick()
    end
    eq(current.cached, updated)
  end
  panel:close()
end)

test("panel focus failures preserve cleanup ownership", function()
  for _, stage in ipairs({ "close", "open" }) do
    local f = panel_mock()
    local panel = Layout.open_panel({
      get_lines = function()
        return {}
      end,
    }, { width = 40, height = 8 })
    local content = f.windows[2]
    if stage == "close" then
      content.failure = true
    else
      maki.ui.open_win = function()
        error("replacement unavailable")
      end
    end
    eq(
      pcall(function()
        panel:focus()
      end),
      false
    )
    eq(#f.windows, 2)
    content.failure = false
    panel:close()
    eq(f.windows[1].closes, 1)
  end
end)

test("panel config compares content and snapshots mutable footer", function()
  local f = panel_mock()
  local footer = { { "q", "quit" } }
  local panel = Layout.open_panel({}, { width = 40, height = 8, footer = footer })
  eq(f.renders, 1)
  panel:set_config({ title = "", active = false, footer = { { "q", "quit" } } })
  eq(f.renders, 1)
  footer[1][2] = "close"
  panel:set_config({ footer = footer })
  eq(f.renders, 2)
  footer[1][2] = "exit"
  panel:set_config({ footer = footer })
  eq(f.renders, 3)
  panel:set_config({ title = "changed" })
  panel:set_config({ active = true })
  eq(f.renders, 5)
end)

test("panel close retries failed windows without repeating successful closes", function()
  for _, failed_window in ipairs({ 1, 2 }) do
    local f = panel_mock()
    local panel = Layout.open_panel({}, { width = 40, height = 8 })
    f.windows[failed_window].failure = true
    eq(
      pcall(function()
        panel:close()
      end),
      false
    )
    eq(f.windows[1].closes, 1)
    eq(f.windows[2].closes, 1)
    f.windows[failed_window].failure = false
    panel:close()
    eq(f.windows[failed_window].closes, 2)
    eq(f.windows[3 - failed_window].closes, 1)
    panel:close()
    eq(f.windows[failed_window].closes, 2)
    eq(f.windows[3 - failed_window].closes, 1)
  end
end)

test("partial panel creation closes frame even when cleanup throws", function()
  local f = panel_mock()
  f.create_failure = true
  local open = maki.ui.open_win
  maki.ui.open_win = function(...)
    local win = open(...)
    win.failure = true
    return win
  end
  local ok, err = pcall(Layout.open_panel, {}, { width = 40, height = 8 })
  eq(ok, false)
  assert(tostring(err):find("create failed", 1, true))
  eq(f.windows[1].closes, 1)
end)

local function input_mock()
  local f = { reads = 0, sleeps = 0, edits = 0, restored = 0, closed = {} }
  local state = {}
  for _, name in ipairs({ "one", "two" }) do
    state[name] = {
      close = function()
        f.closed[#f.closed + 1] = name
        if f.close_failure == name then
          error("close failed")
        end
      end,
    }
  end
  maki = {
    ui = {
      input = function()
        f.reads = f.reads + 1
        if f.read_failure then
          return nil, "read failed"
        end
        return { text = "é draft", version = f.reads, session_id = f.switched and "other" or "origin" }
      end,
      input_edit = function(opts)
        f.edits = f.edits + 1
        f.edit = opts
        if f.edit_failure then
          return nil, f.edit_failure
        end
        if f.edits <= (f.hidden or 0) then
          return nil, "the chat input is not on screen, so it cannot be edited"
        end
        return true
      end,
      flash = function(message)
        f.message = message
      end,
    },
    async = {
      sleep = function(ms)
        eq(ms, 16)
        eq(state.one, nil)
        eq(state.two, nil)
        f.sleeps = f.sleeps + 1
        if f.switch then
          f.switched = true
        end
      end,
    },
  }
  f.state = state
  function f:fill()
    return Input.fill_input(state, { "one", "two" }, "prompt", function()
      f.restored = f.restored + 1
    end)
  end
  return f
end

test("input append preserves session snapshot byte offsets and bounded waits", function()
  local f = input_mock()
  f.hidden = 2
  eq(f:fill(), true)
  eq(f.sleeps, 3)
  eq(f.edits, 3)
  eq(f.edit.start, #"é draft")
  eq(f.edit.stop, #"é draft")
  eq(f.edit.version, 4)
  eq(f.edit.session_id, "origin")
  eq(f.edit.text, "\n\nprompt")
  eq(f.restored, 0)
  f = input_mock()
  f.hidden = 10
  eq(f:fill(), false)
  eq(f.edits, 5)
  eq(f.sleeps, 5)
  eq(f.restored, 1)
end)

test("input close exceptions retain failed windows for restoration and retry", function()
  for _, name in ipairs({ "one", "two" }) do
    local f = input_mock()
    local failed_window = f.state[name]
    local other = name == "one" and "two" or "one"
    f.close_failure = name
    local restore_saw_failed = false
    eq(
      Input.fill_input(f.state, { "one", "two" }, "prompt", function()
        f.restored = f.restored + 1
        restore_saw_failed = f.state[name] == failed_window and f.state[other] == nil
      end),
      false
    )
    eq(#f.closed, 2)
    eq(f.closed[1], "one")
    eq(f.closed[2], "two")
    eq(f.state[name], failed_window)
    eq(f.state[other], nil)
    eq(restore_saw_failed, true)
    eq(f.restored, 1)
    eq(f.edits, 0)
    f.close_failure = nil
    eq(f:fill(), true)
    eq(#f.closed, 3)
    eq(f.closed[3], name)
    eq(f.state.one, nil)
    eq(f.state.two, nil)
    eq(f.restored, 1)
  end
end)

test("input cancels session switch restores rejected edits and keeps early failure UI", function()
  local f = input_mock()
  f.switch = true
  eq(f:fill(), false)
  eq(f.edits, 0)
  eq(f.restored, 1)
  f = input_mock()
  f.edit_failure = "version changed"
  eq(f:fill(), false)
  eq(f.edits, 1)
  eq(f.restored, 1)
  f = input_mock()
  f.read_failure = true
  eq(f:fill(), false)
  eq(#f.closed, 0)
  eq(f.restored, 0)
end)

require("tests.common_text")(test, eq)

print(string.format("common: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
