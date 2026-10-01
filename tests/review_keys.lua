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

print(tests .. " tests passed")
