local Text = require("common.text")
local Comments = require("common.comments")
local TextInput = require("maki.text_input")
local Files = require("code.files")
local CodeComments = require("code.comments")
local Render = require("code.render")
local store = CodeComments.store
local files, load_source = Files.list, Files.load_source
local index_paths, flatten_tree = Files.index_paths, Files.flatten_tree
local first_directory = Files.first_directory
local current_comment, open_editor = CodeComments.current, CodeComments.open_editor
local save_editor, submit = CodeComments.save_editor, CodeComments.submit
local open_windows, close_windows, redraw = Render.open_windows, Render.close_windows, Render.redraw
local M = {}

local display = Text.display

local function clamp(n, count)
  return math.max(1, math.min(n, count))
end
local function preview_selected(state)
  local row = state.rows[state.file_cursor]
  if row and row.idx then
    local path = state.filtered_paths[row.idx]
    if path ~= state.file then
      load_source(state, path)
    end
  end
end
local function apply_search(state, query)
  local row = Files.apply_search(state, query)
  if row and row.idx then
    preview_selected(state)
  else
    state.file, state.lines, state.syntax, state.error, state.truncated = nil, nil, nil, nil, nil
    state.line, state.anchor, state.editor = 1, nil, nil
  end
end

local function refresh(state)
  local paths, err = files()
  if not paths then
    maki.ui.flash(tostring(err))
    return
  end
  local file, line = state.file, state.line
  index_paths(state, paths)
  Files.apply_search(state, state.search_query)
  if state.pane == "files" then
    local row = state.rows[state.file_cursor]
    local path = row and row.idx and state.filtered_paths[row.idx]
    if path then
      load_source(state, path, path == file and line or 1)
    else
      state.file, state.lines, state.syntax, state.error, state.truncated = nil, nil, nil, nil, nil
      state.line, state.anchor, state.editor = 1, nil, nil
    end
  elseif file then
    load_source(state, file, line)
  end
  return true
end

local function edit_file(state)
  local target = state.file
  if state.pane == "files" then
    local row = state.rows[state.file_cursor]
    target = row and row.idx and state.filtered_paths[row.idx]
    if not target then
      maki.ui.flash("Select a working-tree file to edit, not a directory")
      return
    end
  elseif not target then
    maki.ui.flash("No source file to edit")
    return
  end
  local path = maki.fs.abspath("./" .. target)
  local ok, meta, err = pcall(maki.fs.metadata, path)
  if not ok or not meta then
    maki.ui.flash("Cannot edit file: " .. tostring(err or (not ok and meta) or "File no longer exists"))
    return
  end
  if not meta.is_file then
    maki.ui.flash("Cannot edit file: Not a regular file")
    return
  end
  local editor_ok, code = pcall(maki.ui.open_editor, path)
  local refreshed = refresh(state)
  if not refreshed then
    load_source(state, target, state.file == target and state.line or 1)
  end
  if not editor_ok then
    maki.ui.flash("Editor failed: " .. tostring(code))
  elseif code == -1 then
    maki.ui.flash("Editor could not be opened; check VISUAL or EDITOR")
  elseif code ~= 0 then
    maki.ui.flash("Editor exited with code " .. tostring(code))
  end
end

local function navigate(state, delta, endpoint)
  if state.pane == "files" then
    state.file_cursor = endpoint or clamp(state.file_cursor + delta, #state.rows)
    preview_selected(state)
  elseif state.pane == "comments" then
    state.comment_cursor = endpoint or clamp(state.comment_cursor + delta, #store)
  elseif state.lines then
    state.line = endpoint or clamp(state.line + delta, #state.lines)
  end
end

local function handle_key(state, key)
  if state.search_input then
    if key == "<CR>" then
      state.search_input = nil
    elseif key == "<Esc>" or key == "<C-c>" then
      state.search_input = nil
      apply_search(state, "")
    else
      local before = state.search_input:value()
      state.search_input:handle_key(key)
      local query = state.search_input:value()
      if query ~= before then
        apply_search(state, query)
      end
    end
    return false
  end
  if state.editor then
    if key == "<CR>" then
      save_editor(state)
    elseif key == "<Esc>" or key == "<C-c>" then
      state.editor = nil
    else
      state.editor.input:handle_key(key)
    end
    return false
  end
  local count = state.pane == "files" and #state.rows
    or state.pane == "comments" and #store
    or state.lines and #state.lines
    or 1
  if key == "/" and state.pane == "files" then
    state.search_input = TextInput.new()
    state.search_input:insert_text(state.search_query)
  elseif key == "q" or key == "<C-c>" then
    return true
  elseif key == "s" then
    return submit(state, function()
      open_windows(state)
      redraw(state)
    end)
  elseif key == "e" and (state.pane == "files" or state.pane == "source") then
    edit_file(state)
  elseif key == "r" then
    refresh(state)
  elseif key == "1" or key == "2" or key == "3" then
    state.pane = ({ ["1"] = "files", ["2"] = "comments", ["3"] = "source" })[key]
    state.anchor = nil
  elseif key == "j" or key == "<Down>" then
    navigate(state, 1)
  elseif key == "k" or key == "<Up>" then
    navigate(state, -1)
  elseif key == "<PageDown>" then
    navigate(state, math.max(1, state.heights[state.pane] - 2))
  elseif key == "<PageUp>" then
    navigate(state, -math.max(1, state.heights[state.pane] - 2))
  elseif key == "g" or key == "<Home>" then
    navigate(state, 0, 1)
  elseif key == "G" or key == "<End>" then
    navigate(state, 0, math.max(1, count))
  elseif key == "<Esc>" then
    if state.pane == "files" and state.search_query ~= "" then
      apply_search(state, "")
    elseif state.anchor then
      state.anchor = nil
    elseif state.pane == "source" then
      state.pane = "files"
    else
      return true
    end
  elseif key == "h" or key == "<Left>" then
    if state.pane == "source" and key == "<Left>" then
      state.pane, state.anchor = "files", nil
    elseif state.pane == "files" then
      local row = state.rows[state.file_cursor]
      if row and row.dir then
        if not state.effective_collapsed[row.dir] then
          state.collapsed[row.dir] = true
          flatten_tree(state)
          state.file_cursor = clamp(state.file_cursor, #state.rows)
        end
      end
    end
  elseif key == "c" then
    open_editor(state)
  elseif key == "v" and state.pane == "source" and state.lines then
    state.anchor = not state.anchor and state.line or nil
  elseif key == "d" and (state.pane == "source" or state.pane == "comments") then
    local _, index = current_comment(state)
    if index then
      Comments.remove(store, index)
    end
  elseif key == "<CR>" or key == "l" or key == "<Right>" then
    if state.pane == "files" then
      local row = state.rows[state.file_cursor]
      if row and row.dir then
        if state.effective_collapsed[row.dir] then
          local path = row.dir
          while path do
            state.collapsed[path] = nil
            path = path:match("^(.*)/[^/]+$")
          end
        else
          state.collapsed[row.dir] = true
        end
        flatten_tree(state)
        state.file_cursor = clamp(state.file_cursor, #state.rows)
      elseif row and row.idx and key ~= "l" then
        preview_selected(state)
        state.pane = "source"
      end
    elseif state.pane == "comments" and key ~= "l" then
      local comment = store[state.comment_cursor]
      if comment then
        local path = Comments.path(comment)
        if Comments.kind(comment) == "dir" then
          state.pane = "files"
          apply_search(state, "")
          local ancestor = path
          while ancestor do
            state.collapsed[ancestor] = nil
            ancestor = ancestor:match("^(.*)/[^/]+$")
          end
          flatten_tree(state)
          for index, row in ipairs(state.rows) do
            if
              row.dir
              and #path >= #first_directory(row)
              and (row.dir == path or row.dir:sub(1, #path + 1) == path .. "/")
            then
              state.file_cursor = index
              break
            end
          end
        else
          load_source(state, path, comment.start_line or 1)
          state.pane = "source"
        end
      end
    end
  end
  return false
end

local function run_browser(state)
  local paths, err = files()
  if not paths then
    maki.ui.flash(tostring(err))
    return
  end
  index_paths(state, paths)
  state.pane, state.collapsed = "files", {}
  state.file_cursor, state.comment_cursor, state.line = 1, 1, 1
  state.fbuf, state.mbuf, state.sbuf = maki.ui.buf(), maki.ui.buf(), maki.ui.buf()
  apply_search(state, "")
  for index, row in ipairs(state.rows) do
    if row.idx then
      state.file_cursor = index
      break
    end
  end
  preview_selected(state)
  open_windows(state)
  redraw(state)
  local done = false
  while not done do
    local event = state.inputwin:recv()
    if not event or event.type == "close" then
      done = true
    elseif event.type == "resize" then
      local size = maki.ui.terminal_size()
      if size.cols ~= state.term.cols or size.rows ~= state.term.rows then
        open_windows(state)
      end
      redraw(state)
    elseif event.type == "paste" and state.search_input then
      local before = state.search_input:value()
      state.search_input:insert_text(display(event.text):gsub("[\r\n\t]+", " "))
      local query = state.search_input:value()
      if query ~= before then
        apply_search(state, query)
      end
      redraw(state)
    elseif event.type == "paste" and state.editor then
      state.editor.input:insert_text(event.text)
      redraw(state)
    elseif event.type == "key" then
      done = handle_key(state, event.key)
      if not done then
        redraw(state)
      end
    end
  end
end

local function open_safe()
  local state = {}
  local ok, err = pcall(run_browser, state)
  close_windows(state)
  if not ok then
    maki.ui.flash("Code browser error: " .. tostring(err))
  end
end

M.open = open_safe
return M
