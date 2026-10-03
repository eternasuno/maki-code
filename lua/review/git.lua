local Shell = require("common.shell")
local M = {}

local function command(root, args, opts)
  return Shell.run("git --literal-pathspecs -C " .. Shell.quote(root) .. " " .. args, opts)
end

local function fields(raw)
  local out, start = {}, 1
  while start <= #raw do
    local stop = raw:find("\0", start, true)
    if not stop then
      return nil, "unterminated Git record"
    end
    out[#out + 1] = raw:sub(start, stop - 1)
    start = stop + 1
  end
  return out
end

local function compare_paths(a, b)
  return a.path < b.path
end

local function parse_changes(names, stats, commit)
  local records, err = fields(names)
  if not records then
    return nil, err
  end
  local changes, seen, i = {}, {}, 1
  while i <= #records do
    local status, path = records[i], records[i + 1]
    local kind = status:sub(1, 1)
    local old_path
    if kind == "R" or kind == "C" then
      old_path, path = path, records[i + 2]
      i = i + 1
    end
    if not status:match("^[ACDMRTUXB]%d*$") or not path or path == "" or old_path == "" then
      return nil, "invalid Git name-status record"
    end
    local change = { path = path, old_path = old_path, status = kind, adds = 0, dels = 0, commit = commit }
    changes[#changes + 1], seen[path] = change, change
    i = i + 2
  end
  records, err = fields(stats)
  if not records then
    return nil, err
  end
  local counted = {}
  i = 1
  while i <= #records do
    local adds, dels, path = records[i]:match("^([^\t]+)\t([^\t]+)\t(.*)$")
    local old_path
    if path == "" then
      old_path, path = records[i + 1], records[i + 2]
      i = i + 2
    end
    local change = path and seen[path]
    if not change or counted[path] or old_path ~= change.old_path then
      return nil, "invalid Git numstat path"
    end
    if adds == "-" and dels == "-" then
      change.binary = true
    elseif adds and dels and adds:match("^%d+$") and dels:match("^%d+$") then
      change.adds, change.dels = tonumber(adds), tonumber(dels)
    else
      return nil, "invalid Git numstat counts"
    end
    counted[path] = true
    i = i + 1
  end
  for _, change in ipairs(changes) do
    if not counted[change.path] then
      return nil, "missing Git numstat record"
    end
  end
  return changes, seen
end

function M.root()
  local root, err = Shell.run("git --literal-pathspecs rev-parse --show-toplevel")
  if not root then
    return nil, err
  end
  root = root:gsub("\n$", "")
  if root == "" then
    return nil, "empty Git root"
  end
  return root
end

local function changed(root, args, commit)
  local revision = commit and (" --end-of-options " .. Shell.quote(commit)) or " HEAD"
  local names, err = command(root, args .. " --name-status -z" .. revision)
  if not names then
    return nil, err
  end
  local stats
  stats, err = command(root, args .. " --numstat -z" .. revision)
  if not stats then
    return nil, err
  end
  return parse_changes(names, stats, commit)
end

function M.changes(root)
  local changes, seen = changed(root, "diff --no-color --no-ext-diff --no-textconv -M")
  if not changes then
    return nil, seen
  end
  local raw, err = command(root, "ls-files --others --exclude-standard --full-name -z")
  if not raw then
    return nil, err
  end
  local paths
  paths, err = fields(raw)
  if not paths then
    return nil, err
  end
  for _, path in ipairs(paths) do
    if path == "" then
      return nil, "empty Git untracked path"
    end
    if not seen[path] then
      changes[#changes + 1] = { path = path, status = "?", adds = 0, dels = 0, untracked = true }
    end
  end
  table.sort(changes, compare_paths)
  return changes
end

function M.log(root)
  local raw, err = command(root, "log --no-color -n 200 -z --format=" .. Shell.quote("%h%x00%s%x00%ar"))
  if not raw then
    return nil, err
  end
  local records
  records, err = fields(raw)
  if not records then
    return nil, err
  end
  if #records % 3 ~= 0 then
    return nil, "invalid Git log record"
  end
  local commits = {}
  for i = 1, #records, 3 do
    commits[#commits + 1] = { sha = records[i], subject = records[i + 1], when = records[i + 2] }
  end
  return commits
end

function M.commit_changes(root, sha)
  local changes, err =
    changed(root, "diff-tree -r --root --no-commit-id --no-color --no-ext-diff --no-textconv -M", sha)
  if not changes then
    return nil, err
  end
  table.sort(changes, compare_paths)
  return changes
end

function M.path(root, change)
  return (root == "/" and root or root .. "/") .. change.path
end

function M.raw_diff(root, change)
  local args
  if change.commit then
    args = "show --no-color --no-ext-diff --no-textconv -M --format= --end-of-options " .. Shell.quote(change.commit)
  elseif change.untracked then
    return command(
      root,
      "diff --no-color --no-ext-diff --no-textconv --no-index -- /dev/null " .. Shell.quote(M.path(root, change)),
      { ok_exit_codes = { 0, 1 } }
    )
  else
    args = "diff --no-color --no-ext-diff --no-textconv -M HEAD"
  end
  args = args .. " -- "
  if change.old_path then
    args = args .. Shell.quote(change.old_path) .. " "
  end
  return command(root, args .. Shell.quote(change.path))
end

function M.commit_info(root, sha)
  return command(root, "show --no-color --format=medium --stat --end-of-options " .. Shell.quote(sha) .. " --")
end

return M
