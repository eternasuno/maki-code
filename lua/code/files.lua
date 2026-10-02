local Text = require("common.text")
local Tree = require("common.tree")
local Highlight = require("common.highlight")
local Shell = require("common.shell")
local M = {}

local function display(text)
  return Text.sanitize_utf8(text):gsub("[%z\1-\8\11\12\14-\31\127]", "?")
end

local function clamp(n, count)
  return math.max(1, math.min(n, count))
end
local function files()
  local root, err = Shell.run("git rev-parse --is-inside-work-tree")
  if not root or not root:match("^true") then
    return nil, "Not a Git working tree: " .. tostring(err or root or "Git unavailable")
  end
  local deleted_out, deleted_err = Shell.run("git ls-files -z --deleted -- .")
  if not deleted_out then
    return nil, deleted_err
  end
  local deleted = {}
  for path in deleted_out:gmatch("([^%z]+)%z") do
    deleted[path] = true
  end
  local out, list_err = Shell.run("git ls-files -z --cached --others --exclude-standard -- .")
  if not out then
    return nil, list_err
  end
  local paths, seen = {}, {}
  for path in out:gmatch("([^%z]+)%z") do
    if not deleted[path] and not seen[path] then
      paths[#paths + 1] = path
      seen[path] = true
    end
  end
  table.sort(paths)
  return paths
end

local function read_source(path)
  local literal = "./" .. path
  local ok, meta, err = pcall(maki.fs.metadata, literal)
  if not ok then
    return nil, tostring(meta)
  end
  if not meta then
    return nil, tostring(err or "File no longer exists")
  end
  if not meta.is_file then
    return nil, "Not a regular file"
  end
  if meta.size > 1048576 then
    return nil, "File exceeds 1 MiB limit"
  end
  local read_ok, text, read_err = pcall(maki.fs.read, literal)
  if not read_ok then
    return nil, "Cannot read source (possibly invalid UTF-8): " .. tostring(text)
  end
  if not text then
    return nil, tostring(read_err or "Cannot read source")
  end
  if #text > 1048576 then
    return nil, "File exceeds 1 MiB limit"
  end
  if text:find("[%z\1-\8\11\12\14-\31\127]") then
    return nil, "Binary or control-character file cannot be displayed"
  end
  if Text.sanitize_utf8(text) ~= text then
    return nil, "Invalid UTF-8 source cannot be displayed"
  end
  local lines, truncated = {}, false
  local terminated = text:sub(-1) == "\n" and text or text .. "\n"
  for line in terminated:gmatch("(.-)\n") do
    if #lines == 10000 then
      truncated = true
      break
    end
    lines[#lines + 1] = line:gsub("\r$", "")
  end
  if #lines == 0 then
    lines[1] = ""
  end
  return lines, nil, truncated
end

local function load_source(state, path, line)
  state.file = path
  state.lines, state.error, state.truncated = read_source(path)
  state.syntax = state.lines and Highlight.highlight_file(path, state.lines) or nil
  state.line = clamp(line or 1, state.lines and #state.lines or 1)
  state.anchor, state.editor = nil, nil
  if state.error then
    maki.ui.flash(display(path) .. ": " .. state.error)
  end
end
local function flatten_tree(state)
  local collapsed = {}
  for _, row in ipairs(state.all_rows) do
    local path = row.dir
    while path do
      if state.collapsed[path] then
        collapsed[row.dir] = true
        break
      end
      path = path:match("^(.*)/[^/]+$")
    end
  end
  state.effective_collapsed = collapsed
  state.rows = Tree.flatten(state.tree, collapsed)
end

local function first_directory(row)
  -- A compressed row represents every directory in its displayed name chain.
  local suffix = row.name:match("^[^/]+(/.*)$") or ""
  return row.dir:sub(1, #row.dir - #suffix)
end
local function index_paths(state, paths)
  state.search_entries = {}
  for _, path in ipairs(paths) do
    state.search_entries[#state.search_entries + 1] = { path = path, name_lower = path:match("[^/]+$"):lower() }
  end
end

local function apply_search(state, query)
  local selected_row = state.rows and state.rows[state.file_cursor]
  local selected_path = selected_row and (selected_row.dir or state.filtered_paths[selected_row.idx])
  state.search_query, state.filtered_paths = query, {}
  local lower = query:lower()
  for _, entry in ipairs(state.search_entries) do
    if entry.name_lower:find(lower, 1, true) then
      state.filtered_paths[#state.filtered_paths + 1] = entry.path
    end
  end
  state.tree = Tree.build_tree(state.filtered_paths)
  state.all_rows = Tree.flatten(state.tree)
  flatten_tree(state)
  state.file_cursor = clamp(state.file_cursor, #state.rows)
  for index, row in ipairs(state.rows) do
    if (row.dir or state.filtered_paths[row.idx]) == selected_path then
      state.file_cursor = index
      break
    end
  end
  return state.rows[state.file_cursor]
end

M.list = files
M.load_source = load_source
M.index_paths = index_paths
M.apply_search = apply_search
M.flatten_tree = flatten_tree
M.first_directory = first_directory
return M
