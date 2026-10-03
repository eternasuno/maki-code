package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local Shell = require("common.shell")
local Git = require("review.git")
local passed, failed = 0, 0
local root = "/repo 'quote\tline\n"
local prefix = "git --literal-pathspecs -C " .. Shell.quote(root) .. " "
local responses, calls

local function eq(a, b)
  assert(a == b, tostring(a) .. " ~= " .. tostring(b))
end

local function contains(text, part)
  assert(text:find(part, 1, true), "missing " .. part .. " in " .. text)
end

local function mock(...)
  responses, calls = { ... }, {}
  Shell.run = function(cmd, opts)
    calls[#calls + 1] = { cmd = cmd, opts = opts }
    local response = responses[#calls]
    assert(response, "unexpected command: " .. cmd)
    return response[1], response[2]
  end
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

local function check_commands()
  eq(#calls, #responses)
  for _, call in ipairs(calls) do
    eq(call.cmd:sub(1, #prefix), prefix)
  end
end

local old_path = "old\t'quote\nname"
local new_path = ':(glob)new*[x]\t"\\\nname'
local binary = "binary\nfile"
local untracked = "untracked\t'\"\\\nfile"
local names = "R098\0" .. old_path .. "\0" .. new_path .. "\0M\0" .. binary .. "\0"
local stats = "2\t3\t\0" .. old_path .. "\0" .. new_path .. "\0-\t-\t" .. binary .. "\0"

local function find(changes, path)
  for _, change in ipairs(changes) do
    if change.path == path then
      return change
    end
  end
  error("missing path " .. path)
end

test("root removes one newline only and preserves whitespace", function()
  mock({ root .. "\n" })
  eq(Git.root(), root)
  eq(calls[1].cmd, "git --literal-pathspecs rev-parse --show-toplevel")
  mock({ "/repo\r\n" })
  eq(Git.root(), "/repo\r")
  mock({ "/repo" })
  eq(Git.root(), "/repo")
end)

test("root propagates failures and rejects empty roots", function()
  mock({ nil, "not a repository" })
  local value, err = Git.root()
  eq(value, nil)
  eq(err, "not a repository")
  mock({ "\n" })
  value, err = Git.root()
  eq(value, nil)
  eq(err, "empty Git root")
end)

test("changes parse NUL rename binary and untracked root-relative paths", function()
  mock({ names }, { stats }, { untracked .. "\0" .. new_path .. "\0" })
  local changes = assert(Git.changes(root))
  eq(#changes, 3)
  local rename = find(changes, new_path)
  eq(rename.old_path, old_path)
  eq(rename.status, "R")
  eq(rename.adds, 2)
  eq(rename.dels, 3)
  eq(rename.commit, nil)
  eq(find(changes, binary).binary, true)
  eq(find(changes, untracked).untracked, true)
  eq(find(changes, untracked).status, "?")
  for i = 2, #changes do
    assert(changes[i - 1].path < changes[i].path)
  end
  contains(calls[1].cmd, "--name-status -z HEAD")
  contains(calls[2].cmd, "--numstat -z HEAD")
  contains(calls[3].cmd, "ls-files --others --exclude-standard --full-name -z")
  check_commands()
end)

test("working tree queries sort exactly once after merging paths", function()
  local sort, sorts = table.sort, 0
  rawset(table, "sort", function(values, compare)
    sorts = sorts + 1
    return sort(values, compare)
  end)
  local ok, err = pcall(function()
    for _, entries in ipairs({
      { "", "", "", "" },
      { "M\0z\0A\0a\0", "1\t0\tz\0" .. "2\t0\ta\0", "", "az" },
      { "", "", "z\0a\0", "az" },
      { "M\0z\0A\0a\0", "1\t0\tz\0" .. "2\t0\ta\0", "b\0a\0", "abz" },
    }) do
      mock({ entries[1] }, { entries[2] }, { entries[3] })
      sorts = 0
      local changes = assert(Git.changes(root))
      eq(sorts, 1)
      local paths = {}
      for _, change in ipairs(changes) do
        paths[#paths + 1] = change.path
      end
      eq(table.concat(paths), entries[4])
      check_commands()
    end
  end)
  rawset(table, "sort", sort)
  assert(ok, err)
end)

test("ordinary paths preserve tabs newlines quotes and backslashes", function()
  mock({ "A\0" .. untracked .. "\0" }, { "10\t0\t" .. untracked .. "\0" }, { "" })
  local changes = assert(Git.changes(root))
  eq(changes[1].path, untracked)
  eq(changes[1].adds, 10)
  eq(changes[1].dels, 0)
  eq(changes[1].old_path, nil)
end)

test("empty successful working tree is distinct from failed queries", function()
  mock({ "" }, { "" }, { "" })
  eq(#assert(Git.changes(root)), 0)
  for stage = 1, 3 do
    local entries = {}
    for i = 1, stage - 1 do
      entries[i] = { "" }
    end
    entries[stage] = { nil, "failure " .. stage }
    mock(table.unpack(entries))
    local changes, err = Git.changes(root)
    eq(changes, nil)
    eq(err, "failure " .. stage)
    eq(#calls, stage)
  end
  mock({ nil, "unborn HEAD" })
  local changes, err = Git.changes(root)
  eq(changes, nil)
  eq(err, "unborn HEAD")
end)

test("malformed NUL records and numstat counts fail explicitly", function()
  local cases = {
    { "M\0unterminated", "" },
    { "R100\0old\0", "" },
    { "M\0\0", "" },
    { "bad\0path\0", "" },
    { "M\0path\0", "" },
    { "M\0path\0", "1\t0\tpath\0" .. "1\t0\tpath\0" },
    { "M\0path\0", "x\t0\tpath\0" },
    { "M\0path\0", "1\t0\tother\0" },
    { "M\0path\0", "1\t0\tpath" },
    { names, "2\t3\t\0wrong\0" .. new_path .. "\0" },
  }
  for _, case in ipairs(cases) do
    mock({ case[1] }, { case[2] })
    local changes, err = Git.changes(root)
    eq(changes, nil)
    assert(type(err) == "string" and err ~= "")
  end
  mock({ "" }, { "" }, { "bad" })
  local changes, err = Git.changes(root)
  eq(changes, nil)
  eq(err, "unterminated Git record")
end)

test("commit changes retain commit and both rename paths", function()
  local sha = "abc'123"
  mock({ "A\0z-last\0" .. names }, { "4\t0\tz-last\0" .. stats })
  local changes = assert(Git.commit_changes(root, sha))
  eq(#changes, 3)
  eq(changes[1].path, new_path)
  eq(changes[2].path, binary)
  eq(changes[3].path, "z-last")
  for _, change in ipairs(changes) do
    eq(change.commit, sha)
  end
  eq(changes[3].adds, 4)
  local rename = find(changes, new_path)
  eq(rename.commit, sha)
  eq(rename.old_path, old_path)
  contains(calls[1].cmd, "diff-tree -r --root --no-commit-id")
  contains(calls[1].cmd, "--name-status -z --end-of-options " .. Shell.quote(sha))
  contains(calls[2].cmd, "--numstat -z --end-of-options " .. Shell.quote(sha))
  check_commands()
end)

test("commit queries propagate failures without partial changes", function()
  mock({ nil, "names failed" })
  local value, err = Git.commit_changes(root, "abc")
  eq(value, nil)
  eq(err, "names failed")
  mock({ names }, { nil, "stats failed" })
  value, err = Git.commit_changes(root, "abc")
  eq(value, nil)
  eq(err, "stats failed")
end)

test("log uses NUL fields so subjects can contain tabs", function()
  mock({ "abc\0subject\twith tab\0one hour ago\0def\0next\0two hours ago\0" })
  local commits = assert(Git.log(root))
  eq(#commits, 2)
  eq(commits[1].sha, "abc")
  eq(commits[1].subject, "subject\twith tab")
  eq(commits[2].when, "two hours ago")
  contains(calls[1].cmd, "-n 200 -z --format=" .. Shell.quote("%h%x00%s%x00%ar"))
  check_commands()
  mock({ "" })
  eq(#assert(Git.log(root)), 0)
  mock({ nil, "log failed" })
  local value, err = Git.log(root)
  eq(value, nil)
  eq(err, "log failed")
  mock({ "abc\0incomplete\0" })
  value, err = Git.log(root)
  eq(value, nil)
  eq(err, "invalid Git log record")
end)

test("raw tracked and historical diffs include literal old and new paths", function()
  local paths = " -- " .. Shell.quote(old_path) .. " " .. Shell.quote(new_path)
  mock({ "raw worktree" })
  eq(Git.raw_diff(root, { path = new_path, old_path = old_path }), "raw worktree")
  contains(calls[1].cmd, "-M HEAD" .. paths)
  eq(calls[1].opts, nil)
  check_commands()
  mock({ "raw historical" })
  eq(Git.raw_diff(root, { path = new_path, old_path = old_path, commit = "abc" }), "raw historical")
  contains(calls[1].cmd, "--format= --end-of-options 'abc'" .. paths)
  eq(calls[1].opts, nil)
  check_commands()
end)

test("untracked no-index uses absolute path and accepts only zero and one", function()
  mock({ "new file diff" })
  eq(Git.raw_diff(root, { path = untracked, untracked = true }), "new file diff")
  contains(calls[1].cmd, "--no-index -- /dev/null " .. Shell.quote(root .. "/" .. untracked))
  eq(#calls[1].opts.ok_exit_codes, 2)
  eq(calls[1].opts.ok_exit_codes[1], 0)
  eq(calls[1].opts.ok_exit_codes[2], 1)
  check_commands()
  eq(Git.path(root, { path = new_path }), root .. "/" .. new_path)
  eq(Git.path("/", { path = new_path }), "/" .. new_path)
end)

test("raw diff failures are never replaced with empty text", function()
  for _, change in ipairs({
    { path = new_path },
    { path = new_path, commit = "abc" },
    { path = new_path, untracked = true },
  }) do
    mock({ nil, "diff failed" })
    local value, err = Git.raw_diff(root, change)
    eq(value, nil)
    eq(err, "diff failed")
  end
end)

test("commit info quotes revisions and propagates errors", function()
  mock({ "commit summary" })
  eq(Git.commit_info(root, "-evil'argument"), "commit summary")
  contains(
    calls[1].cmd,
    "show --no-color --format=medium --stat --end-of-options " .. Shell.quote("-evil'argument") .. " --"
  )
  check_commands()
  mock({ nil, "info failed" })
  local value, err = Git.commit_info(root, "abc")
  eq(value, nil)
  eq(err, "info failed")
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
