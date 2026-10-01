local path = arg[1] or "lua/review/init.lua"
local file = assert(io.open(path, "r"))
local source = file:read("*a")
file:close()

local function extract(first, last)
  local start = assert(source:find(first, 1, true), "missing " .. first)
  local finish = assert(source:find(last, start + #first, true), "missing " .. last)
  return source:sub(start, finish - 1)
end

local make_comment = extract("local function make_comment(", "local function line_range_label(")
local save_comment = extract("local function save_comment(", "local function delete_comment(")
local dispatcher = extract("    local key = ev.key", "\n  end\n\n  for _, w in ipairs")
dispatcher = dispatcher:gsub("%f[%a]continue%f[%A]", "return"):gsub("%f[%a]break%f[%A]", "return")
local panes = extract("local PANE_KEYS =", "local function toggle_dir(")

local flashes = {}
local env = setmetatable({
  comments = {},
  TextInput = { Result = { IGNORED = "ignored" } },
  maki = { ui = {
    flash = function(message)
      flashes[#flashes + 1] = message
    end,
  } },
  load_preview = function(current)
    current.previews = (current.previews or 0) + 1
  end,
  active_view = function(current)
    return 1, current.rows or { 1 }
  end,
  enter_commit = function(current)
    current.commit = {}
  end,
  leave_commit = function(current)
    current.commit = nil
  end,
  toggle_dir = function(current, dir)
    current.fcollapsed[dir] = not current.fcollapsed[dir]
  end,
  move = function(current, delta)
    current.row = (current.row or 1) + delta
  end,
  redraw = function(state)
    state.redraws = state.redraws + 1
  end,
}, { __index = _G })
local dispatch = assert(
  load(
    make_comment .. save_comment .. panes .. "\nreturn function(state, ev)\n" .. dispatcher .. "\nend",
    path,
    "t",
    env
  )
)()

local function state(text, existing_idx, result)
  local input = { text = text, forwarded = {} }
  function input:value()
    return self.text
  end
  function input:handle_key(key)
    self.forwarded[#self.forwarded + 1] = key
    return result or "changed"
  end
  return {
    redraws = 0,
    change = { path = "example.lua", commit = "abc" },
    dlines = { { kind = "add", new_ln = 7, text = "new line" } },
    centry = { input = input, from = 1, to = 1, existing_idx = existing_idx },
  },
    input
end

local tests = 0
local function test(name, run)
  env.comments = {}
  run()
  tests = tests + 1
  print("ok - " .. name)
end

local function press(current, key)
  dispatch(current, { type = "key", key = key })
end

test("Enter saves a trimmed new comment", function()
  local current, input = state("  new comment \n")
  press(current, "<CR>")
  assert(current.centry == nil)
  assert(#env.comments == 1 and env.comments[1].text == "new comment")
  assert(env.comments[1].file == "example.lua" and env.comments[1].commit == "abc")
  assert(env.comments[1].new_start == 7 and env.comments[1].new_end == 7)
  assert(current.redraws == 1 and #input.forwarded == 0)
end)

test("Enter edits an existing comment without changing its range", function()
  local original = { text = "before", file = "example.lua", new_start = 3, new_end = 5 }
  env.comments[1] = original
  local current, input = state("  after  ", 1)
  press(current, "<CR>")
  assert(current.centry == nil)
  assert(#env.comments == 1 and env.comments[1] == original)
  assert(original.text == "after" and original.new_start == 3 and original.new_end == 5)
  assert(current.redraws == 1 and #input.forwarded == 0)
end)

for _, editing in ipairs({ false, true }) do
  test("blank Enter closes without storing, editing=" .. tostring(editing), function()
    local original = { text = "before" }
    if editing then
      env.comments[1] = original
    end
    local current, input = state(" \t\n ", editing and 1 or nil)
    press(current, "<CR>")
    assert(current.centry == nil)
    assert(#env.comments == (editing and 1 or 0))
    assert(original.text == "before")
    assert(current.redraws == 1 and #input.forwarded == 0)
  end)
end

for _, key in ipairs({ "<Esc>", "<C-c>" }) do
  for _, editing in ipairs({ false, true }) do
    test(key .. " cancels without forwarding, editing=" .. tostring(editing), function()
      local original = { text = "before", new_start = 3 }
      env.comments[1] = original
      local current, input = state("unsaved", editing and 1 or nil)
      press(current, key)
      assert(current.centry == nil)
      assert(#env.comments == 1 and env.comments[1] == original)
      assert(original.text == "before" and original.new_start == 3)
      assert(current.redraws == 1 and #input.forwarded == 0)
    end)
  end
end

for _, key in ipairs({
  "x",
  "1",
  "2",
  "3",
  "4",
  "q",
  "c",
  "<Space>",
  "<BS>",
  "<Del>",
  "<Left>",
  "<Right>",
  "<Up>",
  "<Down>",
  "<Home>",
  "<End>",
  "<PageUp>",
  "<PageDown>",
  "<Tab>",
  "<C-a>",
}) do
  test(key .. " forwards unchanged", function()
    local current, input = state("draft")
    local entry = current.centry
    press(current, key)
    assert(current.centry == entry and #env.comments == 0)
    assert(#input.forwarded == 1 and input.forwarded[1] == key)
    assert(current.redraws == 1)
  end)
end

test("ignored input does not redraw", function()
  local current, input = state("draft", nil, env.TextInput.Result.IGNORED)
  press(current, "<F1>")
  assert(current.centry ~= nil and current.redraws == 0)
  assert(#input.forwarded == 1 and input.forwarded[1] == "<F1>")
end)

test("navigation comparisons use canonical keys only", function()
  local navigation = extract('    if key == "<Up>" or key == "k" then', "  for _, w in ipairs")
  for old, canonical in pairs({
    enter = "<CR>",
    esc = "<Esc>",
    ["ctrl+c"] = "<C-c>",
    up = "<Up>",
    down = "<Down>",
    pageup = "<PageUp>",
    pagedown = "<PageDown>",
    home = "<Home>",
    ["end"] = "<End>",
    right = "<Right>",
    left = "<Left>",
  }) do
    assert(not navigation:find('key == "' .. old .. '"', 1, true), "legacy key: " .. old)
    assert(navigation:find('key == "' .. canonical .. '"', 1, true), "missing key: " .. canonical)
  end
end)

local editor_source = extract("local function refresh(state)", "--- pane switching")
local edit_dispatch = extract('    elseif key == "e" and state.pane == "files" then', '    elseif key == "s" then')
edit_dispatch = edit_dispatch:gsub("    elseif", "    if", 1)

for _, untracked in ipairs({ false, true }) do
  for _, code in ipairs({ 0, 9, -1, "throw" }) do
    test(
      "Files external editor refreshes diff after exit " .. tostring(code) .. ", untracked=" .. tostring(untracked),
      function()
        local opened, editor_flashes, reads = {}, {}, 0
        local contents = "before"
        local selected_path = untracked and "a file.lua" or "dir/a file.lua"
        local root_reads = 0
        local editor_env = setmetatable({
          maki = {
            fs = {
              abspath = function(file_path)
                assert(untracked and file_path == "./a file.lua")
                return "/project/dir/" .. file_path:sub(3)
              end,
              metadata = function(file_path)
                assert(file_path == "/project/dir/a file.lua")
                return { is_file = true }
              end,
            },
            ui = {
              flash = function(text)
                editor_flashes[#editor_flashes + 1] = text
              end,
              open_editor = function(file_path)
                opened[#opened + 1] = file_path
                contents = "after"
                if code == "throw" then
                  error("editor unavailable")
                end
                return code
              end,
            },
          },
          run = function(cmd)
            assert(not untracked and cmd == "git rev-parse --show-toplevel")
            root_reads = root_reads + 1
            return "/project\n"
          end,
          git_changes = function()
            reads = reads + 1
            return { { path = selected_path, untracked = untracked } }
          end,
          git_log = function()
            return {}
          end,
          redraw = function(current)
            current.frow_map = { 1 }
          end,
          load_preview = function(current)
            assert(next(current.cache) == nil)
            current.preview = contents
          end,
        }, { __index = _G })
        local edit = assert(
          load(editor_source .. "return function(state, key)\n" .. edit_dispatch .. "end\nend", path, "t", editor_env)
        )()
        local current = {
          pane = "files",
          fcursor = 1,
          frow_map = { 1 },
          wchanges = { { path = selected_path, untracked = untracked } },
          cache = { stale = true },
        }
        edit(current, "e")
        assert(#opened == 1 and opened[1] == "/project/dir/a file.lua")
        assert(reads == 1 and current.preview == "after")
        assert(root_reads == (untracked and 0 or 1))
        if code ~= 0 then
          assert(#editor_flashes == 1 and editor_flashes[1]:find("Editor", 1, true))
        end
        for _, pane in ipairs({ "commits", "comments", "diff" }) do
          current.pane = pane
          edit(current, "e")
        end
        assert(#opened == 1)
      end
    )
  end
end

for _, mode in ipairs({
  "directory row",
  "missing",
  "directory file",
  "metadata error",
  "historical",
  "root failure",
  "empty root",
  "blank root",
}) do
  test("Files external editor rejects " .. mode, function()
    local editor_flashes, opens, metadata_reads = {}, 0, 0
    local editor_env = setmetatable({
      run = function(cmd)
        assert(cmd == "git rev-parse --show-toplevel")
        if mode == "root failure" then
          return nil, "root unavailable"
        elseif mode == "empty root" then
          return ""
        elseif mode == "blank root" then
          return "\n"
        end
        return "/project\n"
      end,
      maki = {
        fs = {
          abspath = function()
            return "/project/a.lua"
          end,
          metadata = function()
            metadata_reads = metadata_reads + 1
            if mode == "missing" then
              return nil
            elseif mode == "metadata error" then
              error("metadata unavailable")
            end
            return { is_file = false }
          end,
        },
        ui = {
          flash = function(text)
            editor_flashes[#editor_flashes + 1] = text
          end,
          open_editor = function()
            opens = opens + 1
          end,
        },
      },
    }, { __index = _G })
    local edit = assert(load(editor_source .. "return edit_selected_file", path, "t", editor_env))()
    edit({
      fcursor = 1,
      frow_map = { mode == "directory row" and { dir = "dir" } or 1 },
      wchanges = { { path = "a.lua", commit = mode == "historical" and "abc" or nil } },
    })
    assert(opens == 0 and #editor_flashes == 1)
    if mode == "root failure" or mode == "empty root" or mode == "blank root" then
      assert(metadata_reads == 0)
      assert(editor_flashes[1]:find(mode == "root failure" and "root unavailable" or "root is empty", 1, true))
    end
  end)
end

test("numbers select panes and clear selection while retaining diff source", function()
  local current = { pane = "files", src = "files", dlines = {}, redraws = 0 }
  for _, pair in ipairs({ { "2", "commits" }, { "3", "comments" }, { "1", "files" }, { "4", "diff" } }) do
    current.vstart = 1
    press(current, pair[1])
    assert(current.pane == pair[2] and current.vstart == nil)
  end
  assert(current.src == "files" and current.previews == 3)
end)

test("number four preserves no-diff guard", function()
  local current = { pane = "files", src = "files", vstart = 1, redraws = 0 }
  press(current, "4")
  assert(current.pane == "files" and current.vstart == 1 and current.redraws == 0)
  assert(flashes[#flashes] == "No diff to focus")
end)

test("Tab h l do not switch panes and j k move rows", function()
  for _, pane in ipairs({ "files", "commits", "comments", "diff" }) do
    local current = { pane = pane, src = "files", commit = {}, fcollapsed = {}, ccollapsed = {}, redraws = 0 }
    for _, key in ipairs({ "<Tab>", "h", "l" }) do
      press(current, key)
      assert(current.pane == pane)
    end
    press(current, "j")
    assert(current.row == 2)
    press(current, "k")
    assert(current.row == 1)
  end
end)

test("commit hierarchy and arrow navigation remain available", function()
  local current = { pane = "commits", src = "commits", redraws = 0, fcollapsed = {}, ccollapsed = {} }
  press(current, "l")
  assert(current.commit and current.pane == "commits")
  press(current, "h")
  assert(not current.commit and current.pane == "commits")
  current.pane, current.src, current.dlines = "files", "files", {}
  press(current, "<Right>")
  assert(current.pane == "diff")
  press(current, "<Left>")
  assert(current.pane == "files")
  current.rows = { { dir = "src" } }
  press(current, "h")
  assert(current.fcollapsed.src)
  press(current, "l")
  assert(not current.fcollapsed.src and current.pane == "files")
end)

test("pane numbers appear only in bracketed titles", function()
  local code_file = assert(io.open("lua/code/init.lua", "r"))
  local code_source = code_file:read("*a")
  code_file:close()
  for _, entry in ipairs({
    { code_source, { "[1] Files", "[2] Comments", "[3] Source" } },
    { source, { "[1] Files", "[2] Commits", "[3] Comments", "[4] Diff", "[4] Commit", "[4] Comment" } },
  }) do
    for _, title in ipairs(entry[2]) do
      assert(entry[1]:find(title, 1, true), "missing title: " .. title)
    end
    assert(not entry[1]:find("1/2/3", 1, true), "numeric shortcuts remain in footer")
  end
end)

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local Layout = require("common.layout")
local Utils = require("common.utils")
local redraw_source = extract("local function render_clamped(", "--- preview loading")
local windows_source = extract("local function layout(", "--- main loop")

local function panel_fixture(cols, rows)
  local windows = {}
  local function mapped()
    return { 1 }
  end
  local panel_env = setmetatable({
    Layout = setmetatable({
      open_panel = function(buf, opts)
        local panel = Layout.open_panel(buf, opts)
        panel.opts = opts
        panel.frame = windows[#windows - 1]
        panel.content = windows[#windows]
        local set_config = panel.set_config
        function panel:set_config(cfg)
          self.config = cfg
          return set_config(self, cfg)
        end
        return panel
      end,
    }, { __index = Layout }),
    comments = {},
    fit_path = Utils.fit_path,
    display_len = Utils.display_len,
    render_change_list = mapped,
    render_commit_list = mapped,
    render_comment_list = mapped,
    render_diff = mapped,
    render_commit_info = function() end,
    render_comment_detail = function() end,
    maki = {
      ui = {
        terminal_size = function()
          return { cols = cols, rows = rows }
        end,
        buf = function()
          return {
            set_lines = function(self, lines)
              self.content = lines
            end,
          }
        end,
        open_win = function(buf, opts)
          local win = {
            buf = buf,
            opts = opts,
            width = opts.width,
            height = opts.height,
            set_config = function(self, cfg)
              self.config = cfg
            end,
            set_cursor = function(self, cursor)
              self.cursor = cursor
            end,
            close = function(self)
              self.closed = true
            end,
          }
          windows[#windows + 1] = win
          return win
        end,
      },
    },
  }, { __index = _G })
  maki = panel_env.maki
  local open_windows, redraw =
    assert(load(windows_source .. redraw_source .. "return open_windows, redraw", path, "t", panel_env))()
  local current = {
    pane = "files",
    src = "files",
    wchanges = {},
    fcursor = 1,
    ccursor = 1,
    mcursor = 1,
    dcursor = 1,
    fcollapsed = {},
    ccollapsed = {},
  }
  for _, name in ipairs({ "fbuf", "cbuf", "mbuf", "rbuf" }) do
    current[name] = {
      len = function()
        return 1
      end,
    }
  end
  open_windows(current)
  return current, redraw
end

test("review windows reserve the column gap and keep stacked heights within the screen", function()
  for _, cols in ipairs({ 2, 6, 20, 120 }) do
    for _, rows in ipairs({ 2, 5, 10, 30 }) do
      local current = panel_fixture(cols, rows)
      local base = Layout.sizing()
      assert(current.fwin.opts.height + current.cwin.opts.height + current.mwin.opts.height == base.h)
      assert(current.rwin.opts.height == base.h)
      assert(current.cwin.opts.row == current.fwin.opts.row + current.fwin.opts.height)
      assert(current.mwin.opts.row == current.cwin.opts.row + current.cwin.opts.height)
      assert(current.rwin.opts.col == current.fwin.opts.col + base.lw + base.gap)
      for _, name in ipairs({ "fwin", "cwin", "mwin", "rwin" }) do
        local win = current[name]
        assert(win.height >= 0 and win.opts.row + win.height <= base.row + base.h)
        assert(Utils.display_len(win.opts.title) <= math.max(win.opts.width - 2, 0))
      end
      if cols == 120 then
        assert(current.fwin.opts.title == " Files " and current.rwin.opts.title == " Diff ")
      end
    end
  end
end)

test("review redraw fits titles and footers while focus and editor keep single borders", function()
  for _, cols in ipairs({ 2, 6, 20, 120 }) do
    local current, redraw = panel_fixture(cols, 30)
    current.change = { path = string.rep("界/long/", 50), adds = 123456, dels = 987654 }
    for _, pane in ipairs({ "files", "commits", "comments", "diff" }) do
      current.pane = pane
      current.src = pane == "diff" and "files" or pane
      current.sel_commit = { sha = string.rep("abcdef", 30) }
      for _, editing in ipairs({ false, true }) do
        current.centry = editing and {} or nil
        redraw(current)
        for _, entry in ipairs({
          { "fwin", "files" },
          { "cwin", "commits" },
          { "mwin", "comments" },
          { "rwin", "diff" },
        }) do
          local win = current[entry[1]]
          local cfg = win.config
          local active = editing and entry[2] == "diff" or not editing and pane == entry[2]
          assert(cfg.border == "none")
          assert(Utils.display_len(cfg.title) <= math.max(win.opts.width - 2, 0))
          assert(Utils.sanitize_utf8(cfg.title) == cfg.title)
          assert(cfg.active == active)
          assert(win.frame.buf.content[1][1][2].fg == (active and "#bb9af7" or "#8b949e"))
          assert(win.frame.opts.title == "" and win.content.opts.title == "")
          local cells = 1
          for _, pair in ipairs(cfg.footer or {}) do
            cells = cells + Utils.display_len(pair[1]) + Utils.display_len(pair[2]) + 2
          end
          if #(cfg.footer or {}) > 0 then
            assert(cells <= win.opts.width - 2)
          end
          if editing and entry[2] ~= "diff" then
            assert(cfg.footer == nil or #cfg.footer == 0)
          end
        end
      end
    end
  end
end)

local submit_source = extract("local function line_range_label(", "--- rendering")
local function submission_fixture(draft)
  local f = { draft = draft or "", reads = 0, edits = {}, windows = {}, flashes = {}, forbidden = 0 }
  local current = {}
  local function open_windows()
    for _, name in ipairs({ "rwin", "cwin", "mwin", "fwin" }) do
      local win = { visible = true }
      function win:hide()
        self.visible = false
      end
      function win:show()
        self.visible = true
        f.last_shown = self
        if name == "fwin" then
          f.focused = self
        end
      end
      function win:close()
        self.closed = true
      end
      function win:recv()
        assert(not self.closed)
        return { type = "key", key = "j" }
      end
      current[name] = win
      f.windows[#f.windows + 1] = win
    end
    f.focused = current.fwin
  end
  open_windows()
  local function forbidden()
    f.forbidden = f.forbidden + 1
    error("must not create a session or auto-send")
  end
  maki = {
    session = { new = forbidden, prompt = forbidden },
    async = {
      sleep = function(ms)
        assert(ms == 16)
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
    ui = {
      action = forbidden,
      flash = function(message)
        f.flashes[#f.flashes + 1] = message
      end,
      input = function()
        f.reads = f.reads + 1
        if f.input_throw then
          error("snapshot panic")
        end
        if f.input_fail then
          return nil, "snapshot unavailable"
        end
        return { text = f.draft, cursor = 0, version = f.version or 23, session_id = f.session_id or "chat-id" }
      end,
      input_edit = function(opts)
        assert(not f.focused, "Focused overlay still covers input")
        assert(opts.start == #f.draft and opts.stop == #f.draft)
        assert(opts.version == (f.version or 23) and opts.session_id == "chat-id")
        f.edits[#f.edits + 1] = opts
        if f.notscreen and #f.edits <= f.notscreen then
          f.version = (f.version or 23) + 1
          return nil, "the chat input is not on screen, so it cannot be edited"
        end
        if f.edit_throw then
          error("edit panic")
        end
        if f.edit_fail then
          return nil, "stale input"
        end
        f.draft = f.draft .. opts.text
        return true
      end,
    },
  }
  package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
  local submit_env = setmetatable({
    maki = maki,
    Utils = require("common.utils"),
    comments = {
      { file = "example.lua", new_start = 7, new_end = 8, text = "fix it", snippet = "+line", commit = "abc" },
    },
  }, { __index = _G })
  local submit = assert(load(submit_source .. "return submit", path, "t", submit_env))()
  return f,
    current,
    submit_env,
    function(current_state)
      return submit(current_state, function()
        open_windows()
        current_state.redraws = (current_state.redraws or 0) + 1
      end)
    end
end

for _, draft in ipairs({ "", "已有中文草稿\n继续" }) do
  test("review submit fills current input, draft=" .. draft, function()
    local f, current, submit_env, submit = submission_fixture(draft)
    assert(submit(current))
    assert(#f.edits == 1 and f.forbidden == 0 and #submit_env.comments == 0)
    local prompt = f.edits[1].text
    assert(prompt:find("fix it", 1, true) and prompt:find("commit abc", 1, true))
    if draft ~= "" then
      assert(prompt:sub(1, 2) == "\n\n")
    end
    assert(f.draft == draft .. prompt)
    for _, win in ipairs(f.windows) do
      assert(win.closed)
    end
    assert(f.flashes[#f.flashes]:find("Prompt filled into chat input", 1, true))
  end)
end

for _, mode in ipairs({ "edit_fail", "edit_throw", "input_fail", "input_throw" }) do
  test("review submit restores windows and retries after " .. mode, function()
    local f, current, submit_env, submit = submission_fixture("中文草稿")
    local original = submit_env.comments[1]
    f[mode] = true
    assert(not submit(current))
    if mode == "edit_fail" or mode == "edit_throw" then
      assert(#f.edits == 1 and f.sleeps == 1)
    end
    assert(#submit_env.comments == 1 and submit_env.comments[1] == original)
    assert(f.draft == "中文草稿" and f.forbidden == 0)
    assert(current.fwin.visible and not current.fwin.closed)
    assert(current.fwin:recv().key == "j")
    assert(f.focused == current.fwin)
    if mode == "edit_fail" or mode == "edit_throw" then
      assert(#f.windows == 8 and current.redraws == 1)
      for i = 1, 4 do
        assert(f.windows[i].closed)
      end
    end
    assert(f.flashes[#f.flashes]:find("Failed to fill chat input:", 1, true))
    f[mode] = false
    assert(submit(current) and #submit_env.comments == 0)
    assert(f.draft:find("fix it", 1, true))
  end)
end

test("review snapshot failure after close restores live windows", function()
  local f, current, submit_env, submit = submission_fixture("中文草稿")
  f.on_sleep = function()
    f.input_fail = true
  end
  assert(not submit(current))
  assert(#f.edits == 0 and #submit_env.comments == 1 and #f.windows == 8)
  assert(current.redraws == 1 and current.fwin:recv().key == "j")
  assert(f.draft == "中文草稿")
end)

test("review empty comments leave input and windows untouched", function()
  local f, current, submit_env, submit = submission_fixture("中文草稿")
  submit_env.comments = {}
  assert(not submit(current))
  assert(f.reads == 0 and #f.edits == 0 and f.draft == "中文草稿" and f.forbidden == 0)
  for _, win in ipairs(f.windows) do
    assert(win.visible and not win.closed)
  end
end)

for _, failures in ipairs({ 2, 5 }) do
  test("review not-on-screen retry bound " .. failures, function()
    local f, current, submit_env, submit = submission_fixture("中文草稿")
    f.notscreen = failures
    local success = submit(current)
    assert(success == (failures < 5))
    assert(#f.edits == math.min(failures + 1, 5))
    assert(f.sleeps == #f.edits and f.reads == #f.edits + 1)
    if success then
      assert(#submit_env.comments == 0 and current.fwin == nil)
      assert(f.draft == "中文草稿" .. f.edits[#f.edits].text)
    else
      assert(#submit_env.comments == 1 and f.draft == "中文草稿")
      assert(current.fwin:recv().key == "j")
    end
  end)
end

for _, tick in ipairs({ 1, 2 }) do
  test("review session switch aborts on tick " .. tick, function()
    local f, current, submit_env, submit = submission_fixture("中文草稿")
    f.notscreen = 1
    f.on_sleep = function()
      if f.sleeps == tick then
        f.session_id = "other-chat"
      end
    end
    assert(not submit(current))
    assert(#f.edits == tick - 1 and #submit_env.comments == 1)
    assert(f.draft == "中文草稿" and current.fwin:recv().key == "j")
    assert(f.flashes[#f.flashes]:find("Focused session changed", 1, true))
  end)
end

print(tests .. " tests passed")
