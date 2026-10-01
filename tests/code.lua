package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local passed, failed = 0, 0
local function eq(actual, expected)
  assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function contains(text, part)
  assert(text:find(part, 1, true), "Missing " .. part .. " in " .. text)
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
local Layout = require("common.layout")
local open_panel = Layout.open_panel

local function fixture(paths, sources)
  local f = {
    paths = paths or { "a.lua" },
    sources = sources or {},
    queue = {},
    windows = {},
    flashes = {},
    sessions = {},
    edits = {},
    input_reads = 0,
    draft = "",
    commands = {},
    registrations = {},
    size = { cols = 120, rows = 30 },
    autocmds = 0,
  }
  local numbered = {}
  for i = 1, 90 do
    numbered[i] = "source " .. i
  end
  f.sources["a.lua"] = f.sources["a.lua"] or table.concat(numbered, "\n")
  local function plain(lines)
    local result = {}
    for _, line in ipairs(lines or {}) do
      local spans = {}
      for _, span in ipairs(line) do
        spans[#spans + 1] = span[1]
      end
      result[#result + 1] = table.concat(spans)
    end
    return table.concat(result, "\n")
  end
  local panels = {}
  Layout.open_panel = function(buf, opts)
    local panel = open_panel(buf, opts)
    local content = f.windows[#f.windows]
    content.frame = f.windows[#f.windows - 1]
    panels[opts.title:match("^%s*(.-)%s*$")] = content
    local set_config = panel.set_config
    function panel:set_config(config)
      content.config = config
      return set_config(self, config)
    end
    return panel
  end
  function f:win(title)
    return panels[title]
  end
  function f:text(title)
    return plain(self:win(title).buf.content)
  end
  function f:at(title)
    return plain({ self:win(title).buf.content[self:win(title).cursor] })
  end
  function f:check(fn)
    self.queue[#self.queue + 1] = fn
  end
  function f:key(key)
    self.queue[#self.queue + 1] = { type = "key", key = key }
  end
  function f:paste(text)
    self.queue[#self.queue + 1] = { type = "paste", text = text }
  end
  function f:run()
    self.commands["/code"].handler()
    eq(#self.queue, 0)
    for _, win in ipairs(self.windows) do
      assert(win.closed, "Window leaked")
    end
    for _, flash in ipairs(self.flashes) do
      assert(not flash:find("Code browser error:", 1, true), flash)
    end
  end
  maki = {
    api = {
      register_command = function(spec)
        f.registrations[spec.name] = (f.registrations[spec.name] or 0) + 1
        f.commands[spec.name] = spec
      end,
      create_autocmd = function()
        f.autocmds = f.autocmds + 1
      end,
    },
    async = {
      sleep = function(ms)
        eq(ms, 16)
        f.sleeps = (f.sleeps or 0) + 1
        for _, win in ipairs(f.windows) do
          if win.closed and f.focused == win then
            f.focused = nil
          end
        end
        if f.on_sleep then
          f.on_sleep()
        end
      end,
    },
    fn = {
      jobstart = function(cmd)
        f.last_command = cmd
        return 1
      end,
      jobwait = function()
        if f.git_error then
          return { exit_code = 1, stderr = f.git_error }
        end
        return {
          exit_code = 0,
          stdout = f.last_command:find("rev-parse", 1, true) and "true\n" or table.concat(f.paths, "\0") .. "\0",
        }
      end,
    },
    fs = {
      abspath = function(path)
        return "/project/" .. path:sub(3)
      end,
      metadata = function(path)
        if path:sub(1, 9) == "/project/" then
          path = path:sub(10)
        else
          eq(path:sub(1, 2), "./")
          path = path:sub(3)
        end
        if f.meta_error then
          error(f.meta_error)
        end
        if f.missing == path then
          return nil, "File no longer exists"
        end
        return { is_file = not f.directory, size = f.large and 1048577 or #(f.sources[path] or "") }
      end,
      read = function(path)
        f.reads = (f.reads or 0) + 1
        if f.read_error then
          error(f.read_error)
        end
        return f.sources[path:sub(3)] or ""
      end,
    },
    session = {
      prompt = function()
        error("must not auto-send")
      end,
      new = function(opts)
        f.sessions[#f.sessions + 1] = opts
        error("session.new must not be called")
      end,
    },
    ui = {
      input = function()
        f.input_reads = f.input_reads + 1
        if f.input_throw then
          error("snapshot panic")
        end
        if f.input_fail then
          return nil, "snapshot unavailable"
        end
        return { text = f.draft, cursor = 0, version = 17, session_id = f.session_id or "current-chat" }
      end,
      input_edit = function(opts)
        assert(not f.focused, "Focused overlay still covers input")
        eq(opts.start, #f.draft)
        eq(opts.stop, #f.draft)
        eq(opts.version, 17)
        eq(opts.session_id, "current-chat")
        f.edits[#f.edits + 1] = opts
        if f.notscreen and #f.edits <= f.notscreen then
          return nil, "the chat input is not on screen, so it cannot be edited"
        end
        if f.submit_throw then
          error("input panic")
        end
        if f.submit_fail then
          return nil, "input unavailable"
        end
        f.draft = f.draft .. opts.text
        return true
      end,
      action = function()
        error("must not auto-send")
      end,
      open_editor = function(path)
        f.editor_paths = f.editor_paths or {}
        f.editor_paths[#f.editor_paths + 1] = path
        if f.edit then
          f.edit(path)
        end
        if f.editor_error then
          error(f.editor_error)
        end
        return f.editor_code or 0
      end,
      terminal_size = function()
        return { cols = f.size.cols, rows = f.size.rows }
      end,
      theme_color = function()
        return "#202020"
      end,
      highlight = function()
        return nil
      end,
      flash = function(text)
        f.flashes[#f.flashes + 1] = text
      end,
      buf = function()
        return {
          content = {},
          set_lines = function(self, lines)
            self.content = lines
          end,
        }
      end,
      open_win = function(buf, opts)
        if f.open_error and #f.windows == 1 then
          error("window unavailable")
        end
        local win = { buf = buf, opts = opts, width = opts.width, height = opts.height }
        function win:set_cursor(row)
          self.cursor = row
        end
        function win:set_config(config)
          self.config = config
        end
        function win:hide()
          self.hidden = true
        end
        function win:show()
          self.hidden = false
          if self.opts.focus then
            f.focused = self
          end
          f.last_shown = self
        end
        function win:close()
          self.closed = true
        end
        function win:recv()
          assert(not self.closed, "Cannot receive events on closed window")
          while true do
            local event = table.remove(f.queue, 1)
            if type(event) == "function" then
              event(f)
            else
              return event
            end
          end
        end
        if opts.focus then
          f.focused = win
        end
        f.windows[#f.windows + 1] = win
        return win
      end,
    },
  }
  package.preload["maki.text_input"] = function()
    return {
      new = function()
        return {
          text = "",
          insert_text = function(self, text)
            self.text = self.text .. text
          end,
          value = function(self)
            return self.text
          end,
          handle_key = function(self, key)
            if key == "<BS>" then
              self.text = self.text:sub(1, -2)
            elseif key == "<C-u>" then
              self.text = ""
            elseif #key == 1 then
              self.text = self.text .. key
            end
          end,
          render = function(self, prefix)
            return { lines = { { { prefix .. self.text, "item" } } }, cursor_row = 1 }
          end,
        }
      end,
    }
  end
  package.loaded["code"] = nil
  package.loaded["maki.text_input"] = nil
  f.module = require("code")
  f.module.setup()
  return f
end
local function comment(f, text)
  f:key("c")
  f:paste(text)
  f:key("<CR>")
end

test("code and complete review setup are idempotent", function()
  local f = fixture()
  f.module.setup("ignored")
  f.module.setup({ description = "ignored" })
  eq(f.registrations["/code"], 1)
  local file = assert(io.open("lua/review/init.lua", "r"))
  local source = file:read("*a")
  file:close()
  source = source:gsub("%f[%a]continue%f[%A]", 'error("unexercised Luau continue")')
  local review = assert(load(source, "@lua/review/init.lua"))()
  review.setup()
  review.setup()
  eq(f.registrations["/review"], 1)
  eq(f.autocmds, 1)
end)

for _, code in ipairs({ 0, 7, -1 }) do
  test("Files external edit reloads actual contents, exit=" .. code, function()
    local f = fixture({ "dir/a file.lua" }, { ["dir/a file.lua"] = "before" })
    f.editor_code = code
    f.edit = function(path)
      eq(path, "/project/dir/a file.lua")
      f.sources["dir/a file.lua"] = "after editing"
      f.paths[#f.paths + 1] = "new.lua"
    end
    f:key("e")
    f:check(function()
      eq(#f.editor_paths, 1)
      contains(f:text("Source"), "after editing")
      contains(f:text("Files"), "new.lua")
      if code ~= 0 then
        contains(f.flashes[#f.flashes], code == -1 and "could not be opened" or "code 7")
      end
    end)
    f:key("q")
    f:run()
  end)
end

for _, mode in ipairs({ "missing", "directory", "meta_error" }) do
  test("Files edit rejects " .. mode, function()
    local f = fixture()
    f:check(function()
      f[mode] = mode == "missing" and "a.lua" or mode == "meta_error" and "metadata unavailable" or true
    end)
    f:key("e")
    f:check(function()
      eq(f.editor_paths, nil)
      contains(f.flashes[#f.flashes], "Cannot edit file:")
    end)
    f:key("q")
    f:run()
  end)
end

test("directory row never edits the previously previewed file", function()
  local f = fixture({ "dir/a.lua" })
  f:key("g")
  f:key("e")
  f:check(function()
    eq(f.editor_paths, nil)
    contains(f.flashes[#f.flashes], "not a directory")
  end)
  f:key("q")
  f:run()
end)

test("external editor exception still reloads changes and reports failure", function()
  local f = fixture()
  f.editor_error = "editor unavailable"
  f.edit = function()
    f.sources["a.lua"] = "saved before failure"
  end
  f:key("e")
  f:check(function()
    contains(f:text("Source"), "saved before failure")
    contains(f.flashes[#f.flashes], "Editor failed:")
  end)
  f:key("q")
  f:run()
end)

for _, pane in ipairs({ "files", "source" }) do
  test(pane .. " edit chooses its own target after a comment jump", function()
    local f = fixture({ "a.lua", "b.lua" }, { ["a.lua"] = "first\nsecond", ["b.lua"] = "other" })
    f:key("<CR>")
    f:key("j")
    comment(f, "jump here")
    f:key("1")
    f:key("j")
    f:key("2")
    f:key("<CR>")
    if pane == "files" then
      f:key("1")
    end
    f.edit = function(path)
      eq(path, pane == "files" and "/project/b.lua" or "/project/a.lua")
      f.sources["a.lua"] = "first\nchanged second"
      f.sources["b.lua"] = "changed other"
      f.paths[#f.paths + 1] = "new.lua"
    end
    f:key("e")
    f:check(function()
      eq(#f.editor_paths, 1)
      contains(f:at("Files"), "b.lua")
      contains(f:text("Files"), "new.lua")
      local config = f:win(pane == "files" and "Files" or "Source").config
      eq(config.border, "none")
      eq(config.active, true)
      contains(f:at("Source"), pane == "files" and "changed other" or "changed second")
    end)
    f:key("q")
    f:run()
  end)
end

test("Source edit ignores a selected directory", function()
  local f = fixture({ "dir/a.lua" }, { ["dir/a.lua"] = "before" })
  f:key("g")
  f:key("3")
  f.edit = function(path)
    eq(path, "/project/dir/a.lua")
    f.sources["dir/a.lua"] = "after"
  end
  f:key("e")
  f:check(function()
    eq(#f.editor_paths, 1)
    contains(f:text("Source"), "after")
    contains(f:at("Files"), "dir")
    eq(f:win("Source").config.border, "none")
    eq(f:win("Source").config.active, true)
  end)
  f:key("q")
  f:run()
end)

test("Source without a file reports feedback without opening an editor", function()
  local f = fixture({})
  f:key("3")
  f:key("e")
  f:check(function()
    eq(f.editor_paths, nil)
    contains(f.flashes[#f.flashes], "No source file to edit")
  end)
  f:key("q")
  f:run()
end)

for _, mode in ipairs({ "missing", "directory", "meta_error" }) do
  test("Source edit rejects " .. mode, function()
    local f = fixture()
    f:key("3")
    f:check(function()
      f[mode] = mode == "missing" and "a.lua" or mode == "meta_error" and "metadata unavailable" or true
    end)
    f:key("e")
    f:check(function()
      eq(f.editor_paths, nil)
      contains(f.flashes[#f.flashes], "Cannot edit file:")
    end)
    f:key("q")
    f:run()
  end)
end

test("e is text in inline comment editor and ignored in Comments", function()
  local f = fixture()
  f:key("<CR>")
  f:check(function()
    eq(f:win("Source").config.footer[1][1], "e")
  end)
  f:key("c")
  f:check(function()
    eq(f:win("Source").config.footer[1][1], "Enter")
  end)
  f:key("e")
  f:key("<CR>")
  f:key("2")
  f:key("e")
  f:check(function()
    eq(f.editor_paths, nil)
    contains(f:text("Comments"), "a.lua:1 e")
  end)
  f:key("q")
  f:run()
end)

test("project listing deduplicates sorts and compresses directories", function()
  local f = fixture({ "z.lua", "src/deep/b.lua", "a.lua", "src/deep/a.lua", "src/deep/b.lua" })
  f:check(function()
    local text = f:text("Files")
    contains(text, "src/deep")
    local a, b = text:find("a.lua", 1, true), text:find("b.lua", 1, true)
    assert(a < b)
    local _, count = text:gsub("b%.lua", "")
    eq(count, 1)
    contains(f.last_command, "--cached --others --exclude-standard -- .")
  end)
  f:key("g")
  f:key("h")
  f:check(function()
    assert(not f:text("Files"):find("b.lua", 1, true))
  end)
  f:key("l")
  f:check(function()
    contains(f:text("Files"), "b.lua")
  end)
  f:key("G")
  f:check(function()
    contains(f:at("Files"), "z.lua")
  end)
  f:key("q")
  f:run()
end)

test("file paging selection and refresh listing", function()
  local paths, sources = {}, {}
  for i = 1, 30 do
    local path = string.format("%02d.lua", i)
    paths[i], sources[path] = path, "contents " .. i
  end
  local f = fixture(paths, sources)
  f:key("<PageDown>")
  f:check(function()
    contains(f:at("Files"), "14.lua")
    contains(f:text("Source"), "contents 14")
  end)
  f:key("<PageUp>")
  f:key("<Down>")
  f:key("<Up>")
  f:key("G")
  f:key("<CR>")
  f:check(function()
    contains(f:text("Source"), "contents 30")
  end)
  f:key("1")
  f:check(function()
    f.paths[#f.paths + 1] = "31.lua"
  end)
  f:key("r")
  f:check(function()
    contains(f:at("Files"), "30.lua")
    contains(f:text("Files"), "31.lua")
  end)
  f:key("q")
  f:run()
end)

test("source selection arrows pages endpoints and pane return", function()
  local f = fixture()
  f:key("<CR>")
  f:check(function()
    contains(f:at("Source"), "source 1")
  end)
  f:key("j")
  f:key("<Down>")
  f:key("k")
  f:check(function()
    contains(f:at("Source"), "source 2")
  end)
  f:key("<PageDown>")
  f:check(function()
    contains(f:at("Source"), "source 25")
  end)
  f:key("<PageUp>")
  f:key("G")
  f:check(function()
    contains(f:at("Source"), "source 90")
  end)
  f:key("g")
  f:key("<Up>")
  f:check(function()
    contains(f:at("Source"), "source 1")
  end)
  f:key("<Left>")
  f:key("<Right>")
  f:key("<Esc>")
  f:key("q")
  f:run()
end)

test("single range edit cancel blank and delete comments", function()
  local f = fixture()
  f:key("<CR>")
  comment(f, "  single  ")
  f:check(function()
    contains(f:text("Comments"), "a.lua:1 single")
  end)
  f:key("c")
  f:key("<C-u>")
  f:paste("edited")
  f:key("<CR>")
  f:check(function()
    contains(f:text("Comments"), "edited")
    assert(not f:text("Comments"):find("single", 1, true))
  end)
  f:key("c")
  f:paste("cancelled")
  f:key("<Esc>")
  f:key("j")
  f:key("v")
  f:key("j")
  f:key("j")
  comment(f, "range")
  f:check(function()
    contains(f:text("Comments"), "a.lua:2-4 range")
    contains(f:text("Source"), "Comment 2-4")
  end)
  f:key("d")
  f:key("G")
  comment(f, "   ")
  f:check(function()
    assert(not f:text("Comments"):find("range", 1, true))
    assert(not f:text("Comments"):find("90-90", 1, true))
  end)
  f:key("g")
  f:key("d")
  f:check(function()
    eq(f:text("Comments"), "No comments")
  end)
  f:key("q")
  f:run()
end)

test("comments numbered navigation jump edit and deletion", function()
  local f = fixture()
  f:key("<CR>")
  comment(f, "first")
  f:key("G")
  comment(f, "last")
  f:key("2")
  f:key("j")
  f:check(function()
    contains(f:at("Comments"), "last")
  end)
  f:key("k")
  f:key("G")
  f:key("g")
  f:key("<PageDown>")
  f:key("<PageUp>")
  f:key("<CR>")
  f:check(function()
    contains(f:at("Source"), "source 1")
  end)
  f:key("2")
  f:key("c")
  f:key("<C-u>")
  f:paste("via comments")
  f:key("<CR>")
  f:key("2")
  f:key("d")
  f:check(function()
    assert(not f:text("Comments"):find("via comments", 1, true))
    contains(f:text("Comments"), "last")
  end)
  f:key("q")
  f:run()
end)

test("numbers focus boxes while Tab h l stay local and editor retains digits", function()
  local f = fixture()
  local function active(title)
    f:check(function()
      for _, name in ipairs({ "Files", "Comments", "Source" }) do
        local config = f:win(name).config
        eq(config.border, "none")
        eq(config.active, name == title)
        eq(f:win(name).frame.buf.content[1][1][2].fg, name == title and "#bb9af7" or "#8b949e")
        eq(f:win(name).opts.title, "")
      end
    end)
  end
  f:key("l")
  f:key("<Tab>")
  active("Files")
  f:key("3")
  active("Source")
  f:key("v")
  f:key("j")
  f:key("h")
  f:key("l")
  f:key("<Tab>")
  active("Source")
  f:key("2")
  active("Comments")
  f:key("l")
  active("Comments")
  f:key("1")
  active("Files")
  f:key("3")
  f:key("c")
  f:key("1")
  f:key("2")
  f:key("3")
  active("Source")
  f:key("<CR>")
  f:check(function()
    contains(f:text("Comments"), "a.lua:2 123")
    contains(f:win("Files").config.title, "[1] Files")
    contains(f:win("Comments").config.title, "[2] Comments")
    contains(f:win("Source").config.title, "[3] Source")
  end)
  f:key("q")
  f:run()
end)

test("no-comment submit exact flash and remains open", function()
  local f = fixture()
  f:key("s")
  f:check(function()
    eq(f.flashes[1], "No comments to submit")
    eq(#f.sessions, 0)
    eq(f.input_reads, 0)
    eq(#f.edits, 0)
  end)
  f:key("q")
  f:run()
end)

test("focused successful submit snapshots and clears reopened comments", function()
  local f = fixture()
  f.draft = "已有中文草稿\n继续"
  f:key("<CR>")
  f:key("j")
  comment(f, "fix this")
  f:key("s")
  f:run()
  eq(#f.sessions, 0)
  eq(#f.edits, 1)
  local prompt = f.edits[1].text
  eq(prompt:sub(1, 2), "\n\n")
  eq(f.draft, "已有中文草稿\n继续" .. prompt)
  contains(prompt, "Read the actual current files before making changes.")
  contains(prompt, "may be stale; verify the current contents and line locations.")
  contains(prompt, "File: a.lua\nLines: 2-2\nComment: fix this")
  contains(prompt, "Context snapshot (may be stale):\n1: source 1\n2: source 2\n3: source 3\n4: source 4")
  f:check(function()
    eq(f:text("Comments"), "No comments")
  end)
  f:key("q")
  f:run()
end)

for _, mode in ipairs({ "submit_fail", "submit_throw", "input_fail", "input_throw" }) do
  test("failed submit retains comments on reopen " .. mode, function()
    local f = fixture()
    f[mode] = true
    f:key("<CR>")
    comment(f, "retain")
    f:key("s")
    f:check(function()
      contains(f.flashes[#f.flashes], "Failed to fill chat input:")
      contains(f:text("Comments"), "retain")
      eq(f.focused, f:win("Files"))
      assert(not f:win("Files").closed)
      if mode == "submit_fail" or mode == "submit_throw" then
        eq(#f.windows, 12)
        for i = 1, 6 do
          assert(f.windows[i].closed)
        end
      end
      eq(f.draft, "")
    end)
    f:key("q")
    f:run()
    f:check(function()
      contains(f:text("Comments"), "retain")
    end)
    f:check(function()
      f[mode] = false
    end)
    f:key("s")
    f:run()
    contains(f.draft, "retain")
    eq(#f.sessions, 0)
  end)
end

test("session switch during close tick retains source comments", function()
  local f = fixture()
  f.draft = "中文草稿"
  f.on_sleep = function()
    f.session_id = "other-chat"
  end
  f:key("<CR>")
  comment(f, "retain")
  f:key("s")
  f:check(function()
    eq(#f.edits, 0)
    eq(f.draft, "中文草稿")
    contains(f:text("Comments"), "retain")
    contains(f.flashes[#f.flashes], "Focused session changed")
  end)
  f:key("q")
  f:run()
end)

test("refresh current contents and deleted file preserves comments", function()
  local f = fixture()
  f:key("<CR>")
  comment(f, "persistent")
  f:check(function()
    f.sources["a.lua"] = "changed\nsecond"
  end)
  f:key("r")
  f:check(function()
    contains(f:text("Source"), "changed")
    contains(f:text("Comments"), "persistent")
    f.paths = {}
    f.missing = "a.lua"
  end)
  f:key("r")
  f:check(function()
    contains(f:text("Source"), "File no longer exists")
    contains(f:text("Comments"), "persistent")
    eq(f:text("Files"), "No files")
  end)
  f:key("s")
  f:run()
  contains(f.edits[1].text, "1: source 1")
end)

local errors = {
  {
    "binary",
    function(f)
      f.sources["a.lua"] = "a\0b"
    end,
    "Binary or control-character",
  },
  {
    "invalid UTF-8",
    function(f)
      f.sources["a.lua"] = "a\255b"
    end,
    "Invalid UTF-8 source",
  },
  {
    "large metadata",
    function(f)
      f.large = true
    end,
    "File exceeds 1 MiB",
  },
  {
    "large read",
    function(f)
      f.sources["a.lua"] = string.rep("x", 1048577)
      maki.fs.metadata = function()
        return { is_file = true, size = 1 }
      end
    end,
    "File exceeds 1 MiB",
  },
  {
    "missing",
    function(f)
      f.missing = "a.lua"
    end,
    "File no longer exists",
  },
  {
    "directory",
    function(f)
      f.directory = true
    end,
    "Not a regular file",
  },
  {
    "read exception",
    function(f)
      f.read_error = "invalid encoding"
    end,
    "Cannot read source",
  },
  {
    "metadata exception",
    function(f)
      f.meta_error = "metadata denied"
    end,
    "metadata denied",
  },
}
for _, case in ipairs(errors) do
  test("source safety " .. case[1], function()
    local f = fixture()
    case[2](f)
    f:check(function()
      contains(f:text("Source"), case[3])
    end)
    f:key("<CR>")
    f:key("c")
    f:paste("cannot save")
    f:check(function()
      eq(f:text("Comments"), "No comments")
    end)
    f:key("q")
    f:run()
  end)
end

test("line display limit and CRLF", function()
  local f = fixture(nil, { ["a.lua"] = string.rep("line\r\n", 10001) })
  f:key("<CR>")
  f:key("G")
  f:check(function()
    contains(f:at("Source"), "10000 line")
    contains(f:text("Source"), "Showing first 10000 lines")
    assert(not f:text("Source"):find("\r", 1, true))
  end)
  f:key("q")
  f:run()
end)

test("resize recreates windows preserves editor and cleans up", function()
  local f = fixture()
  f:key("<CR>")
  f:key("c")
  f:paste("resize retained")
  f:check(function()
    f.size = { cols = 100, rows = 40 }
  end)
  f.queue[#f.queue + 1] = { type = "resize" }
  f:check(function()
    eq(#f.windows, 12)
    for i = 1, 6 do
      assert(f.windows[i].closed)
    end
    contains(f:text("Source"), "resize retained")
  end)
  f:key("<CR>")
  f:key("q")
  f:run()
end)

test("unchanged resize and close event cleanup", function()
  local f = fixture()
  f.queue[#f.queue + 1] = { type = "resize" }
  f:check(function()
    eq(#f.windows, 6)
  end)
  f.queue[#f.queue + 1] = { type = "close" }
  f:run()
end)

test("partial window creation error cleanup", function()
  local f = fixture()
  f.open_error = true
  f.commands["/code"].handler()
  eq(#f.windows, 1)
  assert(f.windows[1].closed)
  contains(f.flashes[#f.flashes], "Code browser error:")
  contains(f.flashes[#f.flashes], "window unavailable")
end)

test("event loop error closes all windows", function()
  local f = fixture()
  f:check(function()
    error("event failure")
  end)
  f.commands["/code"].handler()
  eq(#f.windows, 6)
  for _, win in ipairs(f.windows) do
    assert(win.closed)
  end
  contains(f.flashes[#f.flashes], "Code browser error:")
  contains(f.flashes[#f.flashes], "event failure")
end)

test("Git error opens no windows", function()
  local f = fixture()
  f.git_error = "not a repository"
  f:run()
  eq(#f.windows, 0)
  contains(f.flashes[1], "Not a Git working tree: not a repository")
end)

print(string.format("code: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
