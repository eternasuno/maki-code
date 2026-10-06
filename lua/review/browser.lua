local TextInput = require("maki.text_input")
local Tree = require("common.tree")
local Comments = require("common.comments")
local ReviewComments = require("review.comments")
local Git = require("review.git")
local Lists = require("review.render_lists")
local Render = require("review.render")
local Windows = require("review.windows")
local Files = require("review.files")
local Input = require("common.input")
local comments = ReviewComments.store
local comment_at, make_comment, line_range_label = ReviewComments.at, ReviewComments.make, ReviewComments.label
local M = {}
local function submit(state, restore)
  if #comments == 0 then
    maki.ui.flash("No review comments yet — press c on a file, directory, or diff line")
    return false
  end
  local prompt = ReviewComments.prompt()
  if not Input.fill_input(state, { "rwin", "cwin", "mwin", "fwin" }, prompt, restore) then
    return false
  end
  ReviewComments.clear()
  return true
end
local function edit_selected_file(state)
  local selected = state.frow_map[state.fcursor]
  local change = type(selected) == "number" and state.working_changes[selected]
  local selected_path = change and not change.commit and change.path
  if not selected_path then
    maki.ui.flash("Select a working-tree file to edit, not a directory")
    return
  end
  local path = Git.path(state.root, change)
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
  M.refresh(state)
  if not editor_ok then
    maki.ui.flash("Editor failed: " .. tostring(code))
  elseif code == -1 then
    maki.ui.flash("Editor could not be opened; check VISUAL or EDITOR")
  elseif code ~= 0 then
    maki.ui.flash("Editor exited with code " .. tostring(code))
  end
end

--- pane switching ----------------------------------------------------------

local PANE_KEYS = { ["1"] = "files", ["2"] = "commits", ["3"] = "comments", ["4"] = "diff" }

local function set_pane(state, pane)
  if pane == "diff" and not state.dlines then
    maki.ui.flash("No diff to focus")
    return
  end
  if state.pane == pane then
    return
  end
  state.pane = pane
  state.vstart = nil
  if pane ~= "diff" then
    state.preview_pane = pane
    Files.load_preview(state)
  end
  Render.redraw(state)
end

-- Toggles a directory row in the files / commit-files tree.
local function toggle_dir(state, dir)
  if (state.pane == "files" and state.fquery ~= "") or (state.pane == "commits" and state.cquery ~= "") then
    return
  end
  local set = state.pane == "commits" and state.ccollapsed or state.fcollapsed
  Tree.toggle_dir(set, dir)
  local key = state.pane == "commits" and "ccollapse_revision" or "fcollapse_revision"
  state[key] = state[key] + 1
  Render.redraw(state)
end

local function enter_commit(state)
  local sel = state.crow_map and state.crow_map[state.ccursor]
  local cm = type(sel) == "number" and state.commits[sel] or nil
  if not cm then
    return
  end
  local ch, err = Git.commit_changes(state.root, cm.sha)
  if not ch then
    maki.ui.flash("commit diff failed: " .. tostring(err))
    return
  end
  state.saved_ccursor = state.ccursor
  state.commit = cm
  state.commit_changes = ch
  state.ccollapsed = {}
  state.ccursor = 1
  Lists.prepare(state)
  for r = 1, #state.crow_map do
    if type(state.crow_map[r]) == "number" then
      state.ccursor = r
      break
    end
  end
  Files.load_preview(state)
  Render.redraw(state)
end

local function leave_commit(state)
  state.commit = nil
  state.commit_changes = nil
  state.ccursor = state.saved_ccursor or 1
  Lists.prepare(state)
  Files.load_preview(state)
  Render.redraw(state)
end

local function delete_selected_comment(state)
  local idx = state.mrow_map and state.mrow_map[state.mcursor]
  if not idx or not comments[idx] then
    maki.ui.flash("No comment selected")
    return
  end
  Comments.remove(comments, idx)
  maki.ui.flash("Comment deleted")
  if state.mcursor > 1 then
    state.mcursor = state.mcursor - 1
  end
  Files.load_preview(state)
  Render.redraw(state)
end

--- navigation --------------------------------------------------------------

local CURSOR_KEY = { files = "fcursor", commits = "ccursor", comments = "mcursor" }

local function active_view(state)
  if state.pane == "files" then
    return state.fcursor, state.frow_map, state.fbuf
  elseif state.pane == "commits" then
    return state.ccursor, state.crow_map, state.cbuf
  elseif state.pane == "comments" then
    return state.mcursor, state.mrow_map, state.mbuf
  end
  return state.dcursor, state.drow_map, state.rbuf
end

local function active_height(state)
  if state.pane == "files" then
    return state.fheight
  elseif state.pane == "commits" then
    return state.cheight
  elseif state.pane == "comments" then
    return state.mheight
  end
  return state.rheight
end

local function set_active_cursor(state, r)
  if state.pane == "diff" then
    local index = state.drow_map[r]
    while r > 1 and state.drow_map[r - 1] == index do
      r = r - 1
    end
    if r ~= state.dcursor then
      state.dcursor = r
      state.dline = state.drow_map[r]
      if state.vstart then
        state.vcur = state.drow_map[r]
      end
      Render.redraw(state)
    end
    return
  end
  local key = CURSOR_KEY[state.pane]
  if r ~= state[key] then
    state[key] = r
    Files.load_preview(state)
    Render.redraw(state)
  end
end

local function move(state, dir, count)
  count = count or 1
  local cursor, row_map, buf = active_view(state)
  local r = cursor
  local total = buf:len()
  for _ = 1, count do
    local nr = r + dir
    while nr >= 1 and nr <= total and (not row_map[nr] or (state.pane == "diff" and row_map[nr] == row_map[r])) do
      nr = nr + dir
    end
    if row_map[nr] then
      r = nr
    else
      break
    end
  end
  set_active_cursor(state, r)
end

local function jump(state, to_end)
  local _, row_map, buf = active_view(state)
  local best
  local from, to, step = 1, buf:len(), 1
  if to_end then
    from, to, step = buf:len(), 1, -1
  end
  for r = from, to, step do
    if row_map[r] then
      best = r
      break
    end
  end
  if best then
    set_active_cursor(state, best)
  end
end

local function apply_search(state, query)
  local committed = state.pane == "commits"
  local key = committed and "cquery" or "fquery"
  local cursor_key = committed and "ccursor" or "fcursor"
  local map = committed and state.crow_map or state.frow_map
  local selected = map[state[cursor_key]]
  state[key] = query
  Lists.prepare(state)
  map = committed and state.crow_map or state.frow_map
  state[cursor_key] = 1
  local first
  for row, value in ipairs(map) do
    if type(value) == "number" then
      first = first or row
    end
    if value == selected then
      state[cursor_key] = row
      first = row
      break
    end
  end
  state[cursor_key] = first or 1
  Files.load_preview(state)
  Render.redraw(state)
end

local function jump_comment(state)
  local record = comments[state.mrow_map[state.mcursor]]
  if not record then
    return
  end
  local path = Comments.path(record)
  local committed = record.commit ~= nil
  local changes = state.working_changes
  if committed then
    local err
    changes, err = Git.commit_changes(state.root, record.commit)
    if not changes then
      maki.ui.flash("Cannot locate comment: " .. tostring(err))
      return
    end
  end
  local kind = Comments.kind(record)
  local found
  for index, change in ipairs(changes) do
    if (kind == "dir" and change.path:sub(1, #path + 1) == path .. "/") or (kind ~= "dir" and change.path == path) then
      found = index
      break
    end
  end
  if not found then
    maki.ui.flash("Comment target is no longer in this diff")
    return
  end
  local preview = {
    root = state.root,
    working_changes = changes,
    frow_map = { found },
    fcursor = 1,
    preview_pane = "files",
    cache = state.cache,
  }
  if kind ~= "dir" then
    Files.load_preview(preview)
    if kind == "line" and (not preview.dlines or #preview.dlines == 0) then
      maki.ui.flash("Cannot locate comment: " .. tostring(preview.diff_err or "No diff lines"))
      return
    end
  end
  local anchor
  if kind == "line" then
    local side = record.anchor == "old" and "old_ln" or "new_ln"
    local target = record.anchor == "old" and record.old_start or record.new_start
    for index, line in ipairs(preview.dlines) do
      if line[side] == target and (side ~= "old_ln" or line.kind == "del") then
        anchor = index
        break
      end
    end
    if not anchor then
      maki.ui.flash("Comment line is no longer in this diff; snapshot retained")
      return
    end
  end
  local pane = committed and "commits" or "files"
  if committed then
    state.saved_ccursor = state.commit and state.saved_ccursor or state.ccursor
    state.commit = { sha = record.commit }
    state.commit_changes = changes
    state.cquery = ""
    state.ccollapsed = {}
    state.ccollapse_revision = state.ccollapse_revision + 1
  else
    state.fquery = ""
    local parent = path
    while parent do
      state.fcollapsed[parent] = nil
      parent = parent:match("^(.*)/[^/]+$")
    end
    state.fcollapse_revision = state.fcollapse_revision + 1
  end
  state.preview_pane, state.pane = pane, pane
  state.vstart = nil
  Lists.prepare(state)
  local map = committed and state.crow_map or state.frow_map
  local cursor_key = committed and "ccursor" or "fcursor"
  for row, value in ipairs(map) do
    if
      (kind == "dir" and type(value) == "table" and (value.dir == path or value.dir:sub(1, #path + 1) == path .. "/"))
      or (kind ~= "dir" and value == found)
    then
      state[cursor_key] = row
      break
    end
  end
  Files.load_preview(state)
  if kind ~= "dir" and state.dlines and #state.dlines > 0 then
    state.pane = "diff"
    state.dline = anchor or 1
  end
  Render.redraw(state)
end

--- comment editing ---------------------------------------------------------

local function open_comment_editor(state)
  if state.pane ~= "diff" then
    local record, existing_idx
    if state.pane == "comments" then
      existing_idx = state.mrow_map and state.mrow_map[state.mcursor]
      record = comments[existing_idx]
    elseif state.pane == "files" or (state.pane == "commits" and state.commit) then
      local committed = state.pane == "commits"
      local map = committed and state.crow_map or state.frow_map
      local cursor = committed and state.ccursor or state.fcursor
      local selected = map and map[cursor]
      local changes = committed and state.commit_changes or state.working_changes
      local change = type(selected) == "number" and changes[selected]
      if type(selected) == "table" and selected.dir then
        record = { target = { kind = "dir", path = selected.dir }, commit = committed and state.commit.sha or nil }
      elseif change then
        record = { target = { kind = "file", path = change.path }, commit = change.commit }
      end
    end
    if not record then
      maki.ui.flash("Select a file, directory, or comment first")
      return
    end
    local input = TextInput.new()
    if existing_idx then
      input:insert_text(record.text)
    end
    state.editor = {
      input = input,
      record = record,
      existing_idx = existing_idx,
      label = line_range_label(record),
      path_editor = true,
    }
    state.vstart = nil
    Render.redraw(state)
    return
  end
  local at = state.drow_map[state.dcursor]
  local dl = state.dlines and state.dlines[at]
  if not dl or dl.kind == "hunk" then
    maki.ui.flash("Move onto a diff line first (j/k)")
    return
  end

  local from, to
  if state.vstart then
    from = math.min(state.vstart, state.vcur)
    to = math.max(state.vstart, state.vcur)
  else
    from, to = at, at
  end

  local input = TextInput.new()
  local existing, existing_idx = comment_at(state.change, state.dlines[to])
  local record = existing or make_comment(state.change, state.dlines, from, to, "")
  if existing then
    input:insert_text(existing.text)
  end
  local label = line_range_label(record)

  state.editor = {
    input = input,
    at = at,
    existing_idx = existing_idx,
    label = label,
    record = record,
  }
  state.vstart = nil
  Render.redraw(state)
end

local function save_comment(state)
  local e = state.editor
  local text = e.input:value():match("^%s*(.-)%s*$")
  state.editor = nil
  if text == "" then
    Render.redraw(state)
    return
  end
  if e.existing_idx then
    local record = comments[e.existing_idx]
    record.text = text
    Comments.update(comments, e.existing_idx, record)
  else
    e.record.text = text
    Comments.add(comments, e.record)
  end
  Render.redraw(state)
end

local function delete_comment(state)
  local dl = state.dlines and state.dlines[state.drow_map[state.dcursor]]
  if not dl then
    return
  end
  local _, idx = comment_at(state.change, dl)
  if idx then
    Comments.remove(comments, idx)
    maki.ui.flash("Comment deleted")
    Render.redraw(state)
  else
    maki.ui.flash("No comment on this line")
  end
end

function M.create_state(root, changes, commits)
  return {
    root = root,
    working_changes = changes,
    commits = commits,
    fbuf = maki.ui.buf(),
    cbuf = maki.ui.buf(),
    mbuf = maki.ui.buf(),
    rbuf = maki.ui.buf(),
    pane = "files",
    preview_pane = "files",
    fcursor = 1,
    ccursor = 1,
    mcursor = 1,
    dcursor = 1,
    fquery = "",
    cquery = "",
    frow_map = {},
    crow_map = {},
    mrow_map = {},
    drow_map = {},
    fcollapsed = {},
    ccollapsed = {},
    fcollapse_revision = 0,
    ccollapse_revision = 0,
    cache = {},
  }
end
function M.open(state)
  local ok, err = pcall(function()
    Windows.open(state)
    Lists.prepare(state)
    for r, selected in ipairs(state.frow_map) do
      if type(selected) == "number" then
        state.fcursor = r
        break
      end
    end
    Files.load_preview(state)
    Render.redraw(state)
  end)
  if not ok then
    Windows.close(state)
    error(err)
  end
  return state
end
local function handle_event(state, ev)
  if not ev or ev.type == "close" then
    return false
  end
  if ev.type == "resize" then
    local size = maki.ui.terminal_size()
    if size.cols ~= state.term.cols or size.rows ~= state.term.rows then
      Windows.open(state)
    end
    Render.redraw(state)
    return true
  end
  if state.search_input then
    if ev.type == "paste" then
      state.search_input:insert_text(ev.text)
      apply_search(state, state.search_input:value())
    elseif ev.type == "key" then
      if ev.key == "<CR>" then
        state.search_input = nil
        Render.redraw(state)
      elseif ev.key == "<Esc>" or ev.key == "<C-c>" then
        state.search_input = nil
        apply_search(state, "")
      elseif ev.key == "<Up>" or ev.key == "<Down>" then
        move(state, ev.key == "<Up>" and -1 or 1)
      else
        state.search_input:handle_key(ev.key)
        apply_search(state, state.search_input:value())
      end
    end
    return true
  end
  if ev.type == "paste" and state.editor then
    state.editor.input:insert_text(ev.text)
    state.editor_revision = (state.editor_revision or 0) + 1
    Render.redraw(state)
    return true
  end
  if ev.type ~= "key" then
    return true
  end
  local key = ev.key

  -- Comment editor owns the keyboard while open.
  if state.editor then
    if key == "<CR>" then
      save_comment(state)
    elseif key == "<Esc>" or key == "<C-c>" then
      state.editor = nil
      Render.redraw(state)
    else
      if state.editor.input:handle_key(key) ~= TextInput.Result.IGNORED then
        state.editor_revision = (state.editor_revision or 0) + 1
        Render.redraw(state)
      end
    end
    return true
  end

  if key == "/" and (state.pane == "files" or (state.pane == "commits" and state.commit)) then
    state.search_input = TextInput.new()
    state.search_input:insert_text(state.pane == "files" and state.fquery or state.cquery)
    Render.redraw(state)
  elseif key == "r" then
    M.refresh(state)
  elseif
    key == "<Esc>"
    and (
      (state.pane == "files" and state.fquery ~= "")
      or (state.pane == "commits" and state.commit and state.cquery ~= "")
    )
  then
    apply_search(state, "")
  elseif key == "<Up>" or key == "k" then
    move(state, -1)
  elseif key == "<Down>" or key == "j" then
    move(state, 1)
  elseif key == "<PageUp>" then
    move(state, -1, math.max(active_height(state) - 2, 1))
  elseif key == "<PageDown>" then
    move(state, 1, math.max(active_height(state) - 2, 1))
  elseif key == "g" or key == "<Home>" then
    jump(state, false)
  elseif key == "G" or key == "<End>" then
    jump(state, true)
  elseif PANE_KEYS[key] then
    set_pane(state, PANE_KEYS[key])
  elseif key == "e" and state.pane == "files" then
    edit_selected_file(state)
  elseif key == "s" then
    if submit(state, function()
      Windows.open(state)
      Render.redraw(state)
    end) then
      return false
    end
    Render.redraw(state)
  elseif key == "q" or key == "<C-c>" then
    return false
  elseif state.pane ~= "diff" then -- one of the left panels
    if key == "c" then
      open_comment_editor(state)
    elseif key == "<CR>" or key == "l" or key == "<Right>" then
      if state.pane == "commits" and not state.commit then
        enter_commit(state)
      elseif state.pane == "comments" and key ~= "l" then
        jump_comment(state)
      else
        local cursor, row_map = active_view(state)
        local sel = row_map[cursor]
        if type(sel) == "table" and sel.dir then
          toggle_dir(state, sel.dir)
        elseif key ~= "l" then
          set_pane(state, "diff")
        end
      end
    elseif key == "d" and state.pane == "comments" then
      delete_selected_comment(state)
    elseif key == "h" or key == "<Left>" then
      local cursor, row_map = active_view(state)
      local sel = row_map[cursor]
      local set = state.pane == "commits" and state.ccollapsed or state.fcollapsed
      if
        (state.pane == "files" or (state.pane == "commits" and state.commit))
        and type(sel) == "table"
        and sel.dir
        and not set[sel.dir]
      then
        toggle_dir(state, sel.dir) -- collapse the directory under the cursor
      elseif state.pane == "commits" and state.commit then
        leave_commit(state)
      end
    elseif key == "<Esc>" then
      if state.pane == "commits" and state.commit then
        leave_commit(state)
      else
        return false
      end
    end
  else -- diff pane
    if key == "c" then
      open_comment_editor(state)
    elseif key == "v" then
      if state.vstart then
        state.vstart = nil
      else
        state.vstart = state.drow_map[state.dcursor]
        state.vcur = state.vstart
      end
      Render.redraw(state)
    elseif key == "d" then
      delete_comment(state)
    elseif key == "<Left>" or key == "<Esc>" then
      if state.vstart then
        state.vstart = nil
        Render.redraw(state)
      else
        set_pane(state, state.preview_pane)
      end
    end
  end

  return true
end
function M.handle_event(state, ev)
  local ok, running = pcall(handle_event, state, ev)
  if not ok or not running then
    Windows.close(state)
  end
  if not ok then
    error(running)
  end
  return running
end
M.close = Windows.close
M.redraw = Render.redraw

function M.refresh(state)
  local change, dlines, hl = state.change, state.dlines, state.hl
  local line = dlines and dlines[state.dline or state.drow_map[state.dcursor]]
  local focused = state.pane == "diff"
  local logical = state.dline
  local path = change and change.path
  local side = line and (line.kind == "del" and "old_ln" or "new_ln")
  local number = side and line[side]
  Files.refresh(state)
  if path and state.preview_pane ~= "comments" then
    local committed = state.preview_pane == "commits"
    local changes = committed and state.commit_changes or state.working_changes
    local map = committed and state.crow_map or state.frow_map
    local cursor_key = committed and "ccursor" or "fcursor"
    local found
    for row, index in ipairs(map) do
      if type(index) == "number" and changes[index].path == path then
        state[cursor_key] = row
        found = true
        break
      end
    end
    if found then
      Files.load_preview(state)
      if not state.dlines and state.diff_err and dlines then
        state.change, state.dlines, state.hl = change, dlines, hl
        state.dline = logical
        maki.ui.flash("Refresh failed; previous diff retained")
      end
      if number then
        for index, candidate in ipairs(state.dlines or {}) do
          if candidate[side] == number and (side ~= "old_ln" or candidate.kind == "del") then
            state.dline = index
            break
          end
        end
      end
    else
      if focused then
        state.pane = state.preview_pane
      end
      maki.ui.flash("File is no longer in this diff")
    end
  end
  Render.redraw(state)
end
return M
