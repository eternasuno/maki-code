local Comments = require("common.comments")
local M = { store = {} }
local comments = M.store
local function covers(c, dl)
  if Comments.kind(c) ~= "line" then
    return false
  end
  if dl.kind == "del" then
    return c.old_start and dl.old_ln and dl.old_ln >= c.old_start and dl.old_ln <= c.old_end
  end
  return c.new_start and dl.new_ln and dl.new_ln >= c.new_start and dl.new_ln <= c.new_end
end
local function make_comment(change, dlines, from, to, text)
  local c = { target = { kind = "line", path = change.path }, commit = change.commit, text = text }
  for i = from, to do
    local dl = dlines[i]
    if dl.new_ln then
      c.new_start = math.min(c.new_start or dl.new_ln, dl.new_ln)
      c.new_end = math.max(c.new_end or dl.new_ln, dl.new_ln)
    end
    if dl.old_ln then
      c.old_start = math.min(c.old_start or dl.old_ln, dl.old_ln)
      c.old_end = math.max(c.old_end or dl.old_ln, dl.old_ln)
    end
  end
  c.anchor = dlines[to].kind == "del" and "old" or "new"

  -- Snapshot the hunk context so the prompt survives later refreshes.
  local snippet = {}
  for i = from - 1, 1, -1 do
    if dlines[i].kind == "hunk" then
      snippet[1] = dlines[i].text
      break
    end
  end
  local lo, hi = math.max(from - 2, 1), math.min(to + 2, #dlines)
  for i = lo, hi do
    if #snippet >= 80 then
      break
    end
    local dl = dlines[i]
    if dl.kind ~= "hunk" then
      local prefix = dl.kind == "add" and "+" or dl.kind == "del" and "-" or " "
      local marked = (i >= from and i <= to) and "  <<< comment applies here" or ""
      snippet[#snippet + 1] = prefix .. dl.text .. marked
    end
  end
  c.snippet = table.concat(snippet, "\n")
  return c
end

local function line_range_label(c)
  if Comments.kind(c) == "file" then
    return "File comment"
  elseif Comments.kind(c) == "dir" then
    return "Directory comment"
  end
  if c.anchor == "old" then
    if c.old_start == c.old_end then
      return "removed line " .. c.old_start
    end
    return "removed lines " .. c.old_start .. "-" .. c.old_end
  end
  if c.new_start == c.new_end then
    return "line " .. c.new_start
  end
  return "lines " .. c.new_start .. "-" .. c.new_end
end

--- submit ------------------------------------------------------------------

local function build_prompt()
  local by_file, order = {}, {}
  for _, c in ipairs(comments) do
    local path = Comments.path(c)
    if not by_file[path] then
      by_file[path] = {}
      order[#order + 1] = path
    end
    table.insert(by_file[path], c)
  end

  local p = {
    "I reviewed changes in this repository and left review comments. Comments refer either",
    "to the uncommitted diff vs HEAD, or to a specific commit's diff (noted as `commit <sha>`).",
    "Address every comment: apply the requested fix directly on the current working tree.",
    "Verify the actual current workspace before editing; saved diffs and snippets may be stale.",
    "File and directory comments apply to the whole path, not a line range.",
    "Carry out requested path modifications: rename, move, delete, reorganize, or create files/directories.",
    "If a comment is a question, answer it and apply any change the answer implies.",
    "Line numbers refer to the file content on the commented side of the diff",
    '("removed" lines refer to the pre-change file).',
    "",
  }
  for _, file in ipairs(order) do
    p[#p + 1] = "## " .. file
    for i, c in ipairs(by_file[file]) do
      p[#p + 1] = ""
      local where = line_range_label(c)
      if c.commit then
        where = where .. ", commit " .. c.commit
      end
      p[#p + 1] = "### Comment " .. i .. " (" .. where .. ")"
      for cline in (c.text .. "\n"):gmatch("(.-)\n") do
        p[#p + 1] = "> " .. cline
      end
      if Comments.kind(c) == "line" then
        p[#p + 1] = ""
        p[#p + 1] = "```diff"
        p[#p + 1] = c.snippet
        p[#p + 1] = "```"
      end
    end
    p[#p + 1] = ""
  end
  return table.concat(p, "\n")
end

local cached_version, groups = -1, {}
local function group(commit)
  local version = Comments.version(comments)
  if version ~= cached_version then
    groups = {}
    cached_version = version
  end
  local key = commit or false
  if not groups[key] then
    groups[key] = Comments.index(comments, function(record)
      return record.commit == commit
    end)
  end
  return groups[key]
end
function M.count(change)
  return group(change.commit).exact[change.path] or 0
end
function M.count_under(path, commit)
  return group(commit).under[path] or 0
end
function M.at(change, line)
  for _, entry in ipairs(group(change.commit).by_path[change.path] or {}) do
    if covers(entry.record, line) then
      return entry.record, entry.index
    end
  end
end
local matched_lines, matched_change, matched_version, matches
function M.matches(change, dlines)
  local version = Comments.version(comments)
  if matched_lines ~= dlines or matched_change ~= change or matched_version ~= version then
    matches = {}
    for i, line in ipairs(dlines) do
      local record, index = M.at(change, line)
      if record then
        matches[i] = { record = record, index = index }
      end
    end
    matched_lines, matched_change, matched_version = dlines, change, version
  end
  return matches
end
function M.clear()
  for i = #comments, 1, -1 do
    Comments.remove(comments, i)
  end
end
M.covers = covers
M.make = make_comment
M.label = line_range_label
M.prompt = build_prompt
return M
