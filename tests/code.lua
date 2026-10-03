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
local Comments = require("common.comments")
local Utils = require("common.text")
local fixture = require("tests.support.code_host").new

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
  local review = require("review")
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
    contains(f:at("Files"), "15.lua")
    contains(f:text("Source"), "contents 15")
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
    contains(f:at("Source"), "source 27")
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

for index, text in ipairs({ string.rep("中文", 30), string.rep("😀🚀", 30), string.rep("中文😀", 30) }) do
  test("long UTF8 file and source comments save render and persist " .. index, function()
    local f = fixture({ "a.lua" }, { ["a.lua"] = "first\nsecond" })
    f.size.cols = 80
    local function check_render()
      local rows = f:win("Comments").buf.content
      eq(#rows, 2)
      for i, location in ipairs({ "a.lua", "a.lua:1" }) do
        local label = rows[i][1][1]
        eq(label:sub(1, #location + 1), location .. " ")
        local preview = label:sub(#location + 2):gsub("%s+$", "")
        local available = f:win("Comments").width - Utils.display_len(location) - 3
        assert(#preview > 0 and #preview < #text, "Expected a shortened narrow preview")
        eq(preview, text:sub(1, #preview))
        assert(Utils.display_len(preview) <= available)
        assert(Utils.display_len(preview) >= available - 1, "Preview lost complete characters")
      end
      local wrapped = {}
      for _, row in ipairs(f:win("Source").buf.content) do
        local body = row[1][1]:match("^    ┃ (.*)")
        if body then
          wrapped[#wrapped + 1] = body:gsub("%s+$", "")
        end
      end
      assert(#wrapped > 1, "Expected source comment wrapping")
      eq(table.concat(wrapped), text)
    end
    local function check_editor()
      local found = false
      for _, row in ipairs(f:win("Source").buf.content) do
        if row[1][1]:sub(1, #"    │ ") == "    │ " then
          eq(row[1][1], "    │ " .. text)
          found = true
        end
      end
      assert(found, "Expected complete saved text in reopened editor")
    end
    comment(f, text)
    f:key("<CR>")
    comment(f, text)
    f:check(check_render)
    f:key("q")
    f:run()

    f:check(check_render)
    f:key("2")
    f:key("c")
    f:check(check_editor)
    f:key("<Esc>")
    f:key("j")
    f:key("c")
    f:check(check_editor)
    f:key("<Esc>")
    f:key("s")
    f:run()
    eq(#f.edits, 1)
    contains(f.edits[1].text, "Target: file\nPath: a.lua\nComment: " .. text)
    contains(f.edits[1].text, "Target: source\nFile: a.lua\nLines: 1-1\nComment: " .. text)
  end)
end

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
  local review_store = require("review.comments").store
  local review_comment = { text = "review must survive code submission" }
  review_store[#review_store + 1] = review_comment
  f.draft = "已有中文草稿\n继续"
  f:key("<CR>")
  f:key("j")
  comment(f, "fix this")
  f:key("s")
  f:run()
  eq(#f.sessions, 0)
  eq(#f.edits, 1)
  eq(f.sleeps, 1)
  eq(f.focused, nil)
  eq(review_store[#review_store], review_comment)
  table.remove(review_store)
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

for _, mode in ipairs({ "submit_throw", "input_throw" }) do
  test("failed submit retains comments on reopen " .. mode, function()
    local f = fixture()
    f[mode] = true
    f:key("<CR>")
    comment(f, "retain")
    f:key("s")
    f:check(function()
      contains(f.flashes[#f.flashes], "Failed to fill chat input:")
      contains(f:text("Comments"), "retain")
      eq(f.focused, f:win("Source"))
      assert(not f:win("Files").closed)
      if mode == "submit_throw" then
        eq(#f.windows, 16)
        for i = 1, 8 do
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

test("listing excludes deleted cached paths without breaking NUL filenames or deduplication", function()
  local f = fixture({ "deleted\nfile.lua", "kept\nfile.lua", "kept\nfile.lua", "new file.txt" })
  f.deleted = { "deleted\nfile.lua" }
  local paths = assert(require("code.files").list())
  eq(#paths, 2)
  eq(paths[1], "kept\nfile.lua")
  eq(paths[2], "new file.txt")
  contains(f.last_command, "-z --cached --others --exclude-standard -- .")
end)

test("failed deleted-path refresh preserves the previous tree", function()
  local f = fixture()
  f:check(function()
    f.deleted_error = "deleted listing failed"
  end)
  f:key("r")
  f:check(function()
    contains(f:text("Files"), "a.lua")
    contains(f:text("Source"), "source 1")
    contains(f.flashes[#f.flashes], "deleted listing failed")
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
    f.deleted = { "a.lua" }
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

test("native focus follows panes and inline editors without rebuilding on navigation", function()
  local f = fixture()
  for _, entry in ipairs({ { "3", "Source" }, { "2", "Comments" }, { "1", "Files" } }) do
    f:key(entry[1])
    f:check(function()
      eq(f.focused, f:win(entry[2]))
    end)
  end
  f:key("c")
  f:check(function()
    eq(f.focused, f:win("Source"))
  end)
  f:key("<Esc>")
  f:check(function()
    eq(f.focused, f:win("Files"))
  end)
  local source
  f:key("3")
  f:check(function()
    source = f:win("Source")
  end)
  f:key("j")
  f:check(function()
    eq(f:win("Source"), source)
    eq(f.focused, source)
  end)
  f:key("q")
  f:run()
end)

test("Source soft wraps with original line navigation comments and resize", function()
  local long = string.rep("界ab  ", 30)
  local f = fixture(nil, { ["a.lua"] = long .. "\nsecond\n" })
  local function wrapped_rows(selected)
    local win = f:win("Source")
    local text, count = {}, 0
    for i = 2, #win.buf.content do
      local row = win.buf.content[i]
      if i > 2 and row[1][1] ~= "      ↪ " then
        break
      end
      count = count + 1
      local start = i == 2 and 3 or 2
      local width = 0
      for j, span in ipairs(row) do
        width = width + Utils.display_len(span[1])
        if selected then
          eq(span[2], "selected")
        end
        if j >= start and not (selected and j == #row and span[1]:match("^ +$")) then
          text[#text + 1] = span[1]
        end
      end
      assert(width <= win.width)
      if not selected then
        assert(width <= win.width - 2, "Expected two columns of right padding for source rows")
      end
    end
    assert(count > 1)
    if not selected then
      eq(table.concat(text), long)
    end
    return count
  end
  local initial
  f:check(function()
    initial = wrapped_rows(false)
  end)
  f:key("3")
  f:check(function()
    wrapped_rows(true)
  end)
  f:key("j")
  f:check(function()
    contains(f:at("Source"), "2 second")
  end)
  f:key("k")
  f:key("v")
  f:key("j")
  comment(f, "wrapped range")
  f:check(function()
    contains(f:text("Comments"), "a.lua:1-2 wrapped range")
    local record = require("code.comments").store[1]
    eq(record.start_line, 1)
    eq(record.end_line, 2)
    contains(record.snippet, long)
    f.size = { cols = 90, rows = 35 }
  end)
  f.queue[#f.queue + 1] = { type = "resize" }
  f:check(function()
    assert(wrapped_rows(false) > initial)
    contains(f:at("Source"), "2 second")
  end)
  f:key("q")
  f:run()
end)

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
    eq(#f.windows, 16)
    for i = 1, 8 do
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
    eq(#f.windows, 7)
  end)
  f.queue[#f.queue + 1] = { type = "close" }
  f:run()
end)

test("failed panel close retains resources and blocks reopen until retry", function()
  local f = fixture()
  local Render = require("code.render")
  local s = { fbuf = maki.ui.buf(), mbuf = maki.ui.buf(), sbuf = maki.ui.buf() }
  Render.open_windows(s)
  local panel = s.swin
  local native = f.windows[2]
  local close = native.close
  local attempts = 0
  native.close = function()
    attempts = attempts + 1
    error("close unavailable")
  end
  Render.close_windows(s)
  eq(s.swin, panel)
  eq(s.fwin, nil)
  eq(s.mwin, nil)
  assert(not native.closed)
  for i = 1, 7 do
    if i ~= 2 then
      assert(f.windows[i].closed)
    end
  end
  eq(pcall(Render.open_windows, s), false)
  eq(#f.windows, 7)
  eq(s.swin, panel)
  eq(attempts, 2)
  native.close = close
  Render.close_windows(s)
  eq(s.swin, nil)
  assert(native.closed)
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
  eq(#f.windows, 7)
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

require("tests.code_search")(test, eq, contains, fixture, comment)

test("Files edit still reloads source when Git refresh fails", function()
  local f = fixture()
  f.edit = function()
    f.sources["a.lua"] = "saved despite listing failure"
    f.git_error = "listing failed"
  end
  f:key("e")
  f:check(function()
    contains(f:text("Source"), "saved despite listing failure")
    contains(f.flashes[#f.flashes], "listing failed")
  end)
  f:key("q")
  f:run()
end)

test("mixed source file and directory comments render counts and submit distinct targets", function()
  local f = fixture({ "dir/a.lua", "dir/sub/b.lua", "other.lua" }, {
    ["dir/a.lua"] = "first\nsecond",
    ["dir/sub/b.lua"] = "nested",
  })
  f:key("G")
  f:key("k")
  comment(f, "whole file")
  f:key("<CR>")
  f:key("j")
  comment(f, "source range")
  f:key("1")
  f:key("g")
  comment(f, "reorganize directory")
  f:check(function()
    contains(f:text("Comments"), "dir/a.lua whole file")
    contains(f:text("Comments"), "dir/a.lua:2 source range")
    contains(f:text("Comments"), "dir/ reorganize directory")
    contains(f:text("Files"), "dir ●3")
    contains(f:text("Files"), "a.lua ●2")
    assert(not f:text("Source"):find("whole file", 1, true))
    assert(not f:text("Source"):find("reorganize directory", 1, true))
    f.sources["dir/a.lua"] = "changed"
  end)
  f:key("r")
  f:key("2")
  f:key("j")
  f:key("c")
  f:key("<C-u>")
  f:paste("edited range")
  f:key("<CR>")
  f:key("s")
  f:run()
  local prompt = f.edits[1].text
  contains(prompt, "Target: file\nPath: dir/a.lua\nComment: whole file")
  contains(prompt, "Target: source\nFile: dir/a.lua\nLines: 2-2\nComment: edited range")
  contains(prompt, "Context snapshot (may be stale):\n1: first\n2: second")
  contains(prompt, "Target: directory\nPath: dir/\nComment: reorganize directory")
  contains(prompt, "Paths and snippets may be stale")
  contains(prompt, "renaming, moving, deleting, reorganizing, or creating related paths")
end)

test("compressed directory badge retains ancestor comments after refresh", function()
  local f = fixture({ "src/a.lua", "src/deep/b.lua", "z.lua" })
  f:key("g")
  comment(f, "src comment")
  f:key("h")
  f:check(function()
    f.paths = { "src/deep/b.lua", "z.lua" }
  end)
  f:key("r")
  f:check(function()
    contains(f:text("Files"), "▸ src/deep ●1")
    assert(not f:text("Files"):find("b.lua", 1, true))
    contains(f:text("Comments"), "src/ src comment")
  end)
  f:key("q")
  f:run()
end)

test("directory comment jump selects its compressed ancestor chain after refresh", function()
  local f = fixture({ "src/a.lua", "src/deep/b.lua", "z.lua" })
  f:key("g")
  comment(f, "src comment")
  f:key("h")
  f:check(function()
    f.paths = { "src/deep/b.lua", "z.lua" }
  end)
  f:key("r")
  f:key("G")
  f:check(function()
    contains(f:at("Files"), "z.lua")
  end)
  f:key("2")
  f:key("<CR>")
  f:check(function()
    eq(f:win("Files").config.active, true)
    contains(f:at("Files"), "▾ src/deep")
    contains(f:text("Files"), "b.lua")
    contains(f:text("Comments"), "src/ src comment")
  end)
  f:key("q")
  f:run()
end)

for _, mode in ipairs({ "binary", "missing", "directory" }) do
  test("path comment editor works without readable source: " .. mode, function()
    local f = fixture({ "dir/a.bin" }, { ["dir/a.bin"] = "\0binary" })
    if mode == "missing" then
      f.missing = "dir/a.bin"
    elseif mode == "directory" then
      f:key("g")
    end
    f:key("c")
    f:paste("original")
    f:check(function()
      contains(f:text("Source"), "Comment: " .. (mode == "directory" and "dir/" or "dir/a.bin"))
      contains(f:at("Source"), "original")
    end)
    f:key("<CR>")
    f:key("2")
    f:key("c")
    f:key("<C-u>")
    f:paste("edited")
    f:key("<CR>")
    f:key("<CR>")
    f:check(function()
      eq(f:win(mode == "directory" and "Files" or "Source").config.active, true)
      if mode == "directory" then
        contains(f:at("Files"), "dir")
      end
    end)
    f:key("2")
    f:key("d")
    f:check(function()
      eq(f:text("Comments"), "No comments")
      assert(not f:text("Files"):find("●", 1, true))
    end)
    f:key("q")
    f:run()
  end)
end

test("filtered Files path comments retain targets through blank edits refresh and stale jumps", function()
  local f = fixture({ "a.txt", "dir/b.lua", "dir/c.lua" }, { ["dir/b.lua"] = "one\ntwo" })
  f:key("/")
  f:paste("b.lua")
  f:key("<CR>")
  f:key("G")
  comment(f, "selected file")
  f:key("g")
  comment(f, "selected directory")
  comment(f, "   ")
  f:key("2")
  f:key("c")
  f:key("<C-u>")
  f:paste("   ")
  f:key("<CR>")
  f:check(function()
    contains(f:text("Comments"), "dir/b.lua selected file")
    contains(f:text("Comments"), "dir/ selected directory")
    assert(not f:text("Comments"):find("a.txt", 1, true))
  end)
  f:key("<CR>")
  f:check(function()
    contains(f:at("Source"), "one")
  end)
  f:key("j")
  f:key("2")
  f:key("<CR>")
  f:check(function()
    contains(f:at("Source"), "one")
  end)
  f:key("1")
  f:key("g")
  f:key("h")
  f:key("2")
  f:key("j")
  f:key("<CR>")
  f:check(function()
    eq(f:win("Files").config.active, true)
    contains(f:at("Files"), "dir")
    contains(f:text("Files"), "c.lua")
    f.paths, f.missing = { "a.txt" }, "dir/b.lua"
  end)
  f:key("r")
  f:key("2")
  f:key("<CR>")
  f:check(function()
    eq(f:win("Files").config.active, true)
    contains(f:text("Comments"), "selected directory")
  end)
  f:key("2")
  f:key("g")
  f:key("c")
  f:key("<C-u>")
  f:paste("edited missing")
  f:key("<CR>")
  f:key("s")
  f:run()
  contains(f.edits[1].text, "Target: file\nPath: dir/b.lua\nComment: edited missing")
  assert(not f.edits[1].text:find("Context snapshot", 1, true))
end)

test("no-op keys keep tree and all panel buffers cached", function()
  local f = fixture()
  local calls, flattens, reads
  f:check(function()
    calls = { f:win("Files").buf.set_calls, f:win("Comments").buf.set_calls, f:win("Source").buf.set_calls }
    flattens, reads = f.tree_flattens, f.reads
  end)
  for _, key in ipairs({ "k", "g", "1", "<Tab>", "h", "d" }) do
    f:key(key)
  end
  f:check(function()
    eq(f.tree_flattens, flattens)
    eq(f.reads, reads)
    for i, title in ipairs({ "Files", "Comments", "Source" }) do
      eq(f:win(title).buf.set_calls, calls[i])
    end
  end)
  f:key("q")
  f:run()
end)

test("inline cursor-only moves redraw Source without invalidating other panels", function()
  local f = fixture()
  f:key("<CR>")
  f:key("c")
  f:paste("abc\ndef")
  local source_calls, file_calls, comment_calls
  f:check(function()
    source_calls = f:win("Source").buf.set_calls
    file_calls = f:win("Files").buf.set_calls
    comment_calls = f:win("Comments").buf.set_calls
    eq(f.rendered_input.line, 2)
    eq(f.rendered_input.col, 3)
  end)
  local function move(key, line, col, changed)
    f:key(key)
    f:check(function()
      source_calls = source_calls + (changed and 1 or 0)
      eq(f:win("Source").buf.set_calls, source_calls)
      eq(f:win("Files").buf.set_calls, file_calls)
      eq(f:win("Comments").buf.set_calls, comment_calls)
      eq(f.rendered_input.text, "abc\ndef")
      eq(f.rendered_input.line, line)
      eq(f.rendered_input.col, col)
      contains(f:at("Source"), line == 1 and "abc" or "def")
    end)
  end
  move("<Left>", 2, 2, true)
  move("<Right>", 2, 3, true)
  move("<Right>", 2, 3, false)
  move("<Home>", 2, 0, true)
  move("<Home>", 2, 0, false)
  move("<Left>", 1, 3, true)
  move("<Right>", 2, 0, true)
  move("<End>", 2, 3, true)
  move("<End>", 2, 3, false)
  move("<Up>", 1, 3, true)
  move("<Down>", 2, 3, true)
  move("<Up>", 1, 3, true)
  move("<Home>", 1, 0, true)
  move("<Left>", 1, 0, false)
  move("<Up>", 1, 0, false)
  f:key("<Esc>")
  f:key("q")
  f:run()
end)

test("Source navigation redraws only Source and Enter reuses preview", function()
  local f = fixture()
  f:key("<CR>")
  f:check(function()
    eq(f.reads, 1)
    f.file_calls, f.comment_calls = f:win("Files").buf.set_calls, f:win("Comments").buf.set_calls
    f.flatten_calls = f.tree_flattens
  end)
  f:key("j")
  f:key("v")
  f:key("j")
  f:check(function()
    eq(f:win("Files").buf.set_calls, f.file_calls)
    eq(f:win("Comments").buf.set_calls, f.comment_calls)
    eq(f.tree_flattens, f.flatten_calls)
    eq(f.reads, 1)
  end)
  f:key("q")
  f:run()
end)

test("search mapping never reads or mutates the displayed source", function()
  local f = fixture({ "a.lua", "b.lua" })
  local Files = require("code.files")
  local source = { "kept" }
  local state = { file_cursor = 1, collapsed = {}, file = "a.lua", lines = source, line = 8 }
  Files.index_paths(state, f.paths)
  Files.apply_search(state, "b")
  eq(f.reads, nil)
  eq(state.filtered_paths[1], "b.lua")
  eq(state.file, "a.lua")
  eq(state.lines, source)
  eq(state.line, 8)
  eq(state.paths, nil)
end)

test("source navigation reuses derived comment index", function()
  local f = fixture()
  local index = Comments.index
  local calls = 0
  Comments.index = function(...)
    calls = calls + 1
    return index(...)
  end
  f:key("<CR>")
  comment(f, "cached marker")
  f:check(function()
    f.index_calls = calls
  end)
  f:key("j")
  f:key("j")
  f:key("v")
  f:key("j")
  f:check(function()
    eq(calls, f.index_calls)
    contains(f:text("Source"), "cached marker")
  end)
  f:key("q")
  f:run()
  Comments.index = index
end)

test("Source refresh and external edit each read displayed file once", function()
  local f = fixture({ "a.lua", "b.lua" })
  f:key("<CR>")
  f:key("j")
  f:key("r")
  f:check(function()
    eq(f.reads, 2)
    contains(f:at("Source"), "source 2")
  end)
  f:key("e")
  f:check(function()
    eq(f.reads, 3)
    eq(#f.editor_paths, 1)
    contains(f:at("Source"), "source 2")
  end)
  f:key("q")
  f:run()
end)

test("search cursor moves without rebuilding results or repainting content", function()
  local f = fixture({ "目录/comments.lua" })
  local builds, reads, writes, frames
  local function cursor(expected)
    local win = f:win("Files")
    local row, cells, highlighted = win.frame.buf.content[1], 0, nil
    for _, span in ipairs(row) do
      cells = cells + Utils.display_len(span[1])
      if type(span[2]) == "table" and span[2].bg then
        highlighted = span[1]
      end
    end
    eq(cells, win.frame.width)
    eq(highlighted, expected)
  end
  f:key("/")
  f:paste("目录comment")
  f:check(function()
    cursor(" ")
    builds, reads = f.tree_builds, f.reads
    writes = f:win("Files").buf.set_calls
    frames = f:win("Files").frame.buf.set_calls
  end)
  f:key("<Home>")
  f:check(function()
    cursor("目")
    eq(f.tree_builds, builds)
    eq(f.reads, reads)
    eq(f:win("Files").buf.set_calls, writes)
    assert(f:win("Files").frame.buf.set_calls > frames)
  end)
  f:key("<Right>")
  f:check(function()
    cursor("录")
  end)
  f:key("<End>")
  f:paste(string.rep("中文abcdef", 20))
  f:check(function()
    cursor(" ")
  end)
  f:key("<Left>")
  f:check(function()
    cursor("f")
  end)
  f:key("<Home>")
  f:check(function()
    cursor("目")
  end)
  f:key("<CR>")
  f:check(function()
    cursor(nil)
  end)
  f:key("q")
  f:run()
end)

print(string.format("code: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
