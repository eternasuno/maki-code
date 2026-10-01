local Comments = require("common.comments")
local Input = require("common.input")
local TextInput = require("maki.text_input")
local Files = require("code.files")
local load_source = Files.load_source
local store = {}
local M = { store = store }

local function current_comment(state)
  if state.pane == "comments" then
    return store[state.comment_cursor], state.comment_cursor
  end
  for index, comment in ipairs(store) do
    if
      Comments.kind(comment) == "line"
      and Comments.path(comment) == state.file
      and state.line >= comment.start_line
      and state.line <= comment.end_line
    then
      return comment, index
    end
  end
end

local function snapshot(state, first, last)
  local result = {}
  local from = math.max(1, first - 2)
  local to = math.min(#state.lines, last + 2, from + 79)
  for line = from, to do
    result[#result + 1] = string.format("%d: %s", line, state.lines[line])
  end
  return table.concat(result, "\n")
end

local function open_editor(state)
  local old, index, record
  if state.pane == "comments" then
    old, index = store[state.comment_cursor], state.comment_cursor
    if not old then
      return
    end
    if Comments.kind(old) ~= "dir" then
      load_source(state, Comments.path(old), old.start_line or 1)
    end
  elseif state.pane == "files" then
    local row = state.rows[state.file_cursor]
    if not row then
      return
    end
    record = { target = { kind = row.dir and "dir" or "file", path = row.dir or state.filtered_paths[row.idx] } }
  elseif state.pane == "source" and state.lines then
    old, index = current_comment(state)
    if not old then
      local first, last = state.line, state.line
      if state.anchor then
        first, last = math.min(state.anchor, state.line), math.max(state.anchor, state.line)
      end
      record = {
        target = { kind = "line", path = state.file },
        start_line = first,
        end_line = last,
        snippet = snapshot(state, first, last),
      }
    end
  else
    return
  end
  if old then
    record = {}
    for key, value in pairs(old) do
      record[key] = value
    end
  end
  local input = TextInput.new()
  input:insert_text(old and old.text or "")
  state.editor = { input = input, index = index, record = record }
  state.anchor = nil
end

local function save_editor(state)
  local editor = state.editor
  local text = editor.input:value():match("^%s*(.-)%s*$")
  if text ~= "" then
    local record = editor.record
    record.text = text
    if editor.index then
      Comments.update(store, editor.index, record)
    else
      Comments.add(store, record)
    end
  end
  state.editor = nil
end

local function submit(state, restore)
  if #store == 0 then
    maki.ui.flash("No comments to submit")
    return false
  end
  local prompt = {
    "Please address the following source, file, and directory comments as modification requests for the current workspace. Read the actual current files before making changes. Paths and snippets may be stale; verify the current contents and line locations. Requests may require renaming, moving, deleting, reorganizing, or creating related paths.\n",
  }
  for _, comment in ipairs(store) do
    local kind, path = Comments.kind(comment), Comments.path(comment)
    if kind == "line" then
      prompt[#prompt + 1] = string.format(
        "Target: source\nFile: %s\nLines: %d-%d\nComment: %s\nContext snapshot (may be stale):\n%s\n",
        path,
        comment.start_line,
        comment.end_line,
        comment.text,
        comment.snippet or ""
      )
    else
      prompt[#prompt + 1] = string.format(
        "Target: %s\nPath: %s\nComment: %s\n",
        kind == "dir" and "directory" or "file",
        Comments.location(comment),
        comment.text
      )
    end
  end
  if not Input.fill_input(state, { "swin", "mwin", "fwin" }, table.concat(prompt, "\n"), restore) then
    return false
  end
  for index = #store, 1, -1 do
    Comments.remove(store, index)
  end
  return true
end

M.current = current_comment
M.open_editor = open_editor
M.save_editor = save_editor
M.submit = submit
return M
