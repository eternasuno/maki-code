local path = arg[1] or "lua/maki_review/init.lua"
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
local dispatcher = extract("    local key = ev.key", "\n    if key ==")
dispatcher = dispatcher:gsub("      continue\n", "      return\n")

local env = setmetatable({
  comments = {},
  TextInput = { Result = { IGNORED = "ignored" } },
  redraw = function(state)
    state.redraws = state.redraws + 1
  end,
}, { __index = _G })
local dispatch = assert(load(make_comment .. save_comment
  .. "\nreturn function(state, ev)\n" .. dispatcher .. "\nend", path, "t", env))()

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
  }, input
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

for _, key in ipairs({ "x", "q", "c", "<Space>", "<BS>", "<Del>", "<Left>", "<Right>",
  "<Up>", "<Down>", "<Home>", "<End>", "<PageUp>", "<PageDown>", "<Tab>", "<C-a>" }) do
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
  for old, canonical in pairs({ enter = "<CR>", esc = "<Esc>", ["ctrl+c"] = "<C-c>",
    up = "<Up>", down = "<Down>", pageup = "<PageUp>", pagedown = "<PageDown>",
    home = "<Home>", ["end"] = "<End>", tab = "<Tab>", right = "<Right>", left = "<Left>" }) do
    assert(not navigation:find('key == "' .. old .. '"', 1, true), "legacy key: " .. old)
    assert(navigation:find('key == "' .. canonical .. '"', 1, true), "missing key: " .. canonical)
  end
end)

print(tests .. " tests passed")
