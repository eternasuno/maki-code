local Tree = require("common.tree")
local Comments = require("common.comments")
local Highlight = require("common.highlight")
local Layout = require("common.layout")
local Utils = require("common.utils")
local Shell = require("common.shell")
local TextInput = require("maki.text_input")

local store = {}
local initialized = false
local M = {}

local function display(text)
  return Utils.sanitize_utf8(text):gsub("[%z\1-\8\11\12\14-\31\127]", "?")
end

local function line_label(first, last)
  return first == last and tostring(first) or (first .. "-" .. last)
end

local function clamp(n, count)
  return math.max(1, math.min(n, count))
end

local function files()
  local root, err = Shell.run("git rev-parse --is-inside-work-tree")
  if not root or not root:match("^true") then
    return nil, "Not a Git working tree: " .. tostring(err or root or "Git unavailable")
  end
  local out, list_err = Shell.run("git ls-files -z --cached --others --exclude-standard -- .")
  if not out then
    return nil, list_err
  end
  local paths, seen = {}, {}
  for path in out:gmatch("([^%z]+)%z") do
    if not seen[path] then
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
  if Utils.sanitize_utf8(text) ~= text then
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

local function current_comment(state)
  if state.pane == "comments" then
    return store[state.comment_cursor], state.comment_cursor
  end
  for index, comment in ipairs(store) do
    if comment.file == state.file and state.line >= comment.start_line and state.line <= comment.end_line then
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
  local old, index
  if state.pane == "comments" then
    old, index = store[state.comment_cursor], state.comment_cursor
    if not old then
      return
    end
    load_source(state, old.file, old.start_line)
    state.pane = "source"
  end
  if state.pane ~= "source" or not state.lines then
    return
  end
  if not old then
    old, index = current_comment(state)
  end
  local first, last = state.line, state.line
  if state.anchor then
    first, last = math.min(state.anchor, state.line), math.max(state.anchor, state.line)
  end
  if old then
    first, last = old.start_line, old.end_line
  end
  local input = TextInput.new()
  if old then
    input:insert_text(old.text)
  end
  state.editor = {
    input = input,
    index = index,
    first = first,
    last = last,
    snippet = old and old.snippet or snapshot(state, first, last),
  }
  state.anchor = nil
end

local function save_editor(state)
  local editor = state.editor
  local text = editor.input:value():match("^%s*(.-)%s*$")
  if text ~= "" then
    local record = {
      file = state.file,
      start_line = editor.first,
      end_line = editor.last,
      text = text,
      snippet = editor.snippet,
    }
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
    "Please address the following source review comments as modification requests for the current workspace. Locate each request by file and line/range and modify the code accordingly. Read the actual current files before making changes. The snippets are context snapshots and may be stale; verify the current contents and line locations.\n",
  }
  for _, comment in ipairs(Comments.list(store)) do
    prompt[#prompt + 1] = string.format(
      "File: %s\nLines: %d-%d\nComment: %s\nContext snapshot (may be stale):\n%s\n",
      comment.file,
      comment.start_line,
      comment.end_line,
      comment.text,
      comment.snippet or ""
    )
  end
  if not Utils.fill_input(state, { "swin", "mwin", "fwin" }, table.concat(prompt, "\n"), restore) then
    return false
  end
  store = {}
  return true
end

local function close_windows(state)
  for _, name in ipairs({ "fwin", "mwin", "swin" }) do
    if state[name] then
      pcall(function()
        state[name]:close()
      end)
      state[name] = nil
    end
  end
end

local function open_windows(state)
  close_windows(state)
  local size = Layout.sizing()
  local fh = math.max(1, math.floor(size.h * 0.6))
  local mh = math.max(1, size.h - fh)
  state.panel_width, state.panel_source_width = size.lw, size.rw
  state.heights = { files = fh, comments = mh, source = size.h }
  state.swin = Layout.open_panel(state.sbuf, {
    title = Utils.fit_path(" Source ", math.max(size.rw - 2, 0)),
    border = "none",
    width = size.rw,
    height = size.h,
    row = size.row,
    col = size.col + size.lw + size.gap,
    anchor = "NW",
    focus = false,
  })
  state.mwin = Layout.open_panel(state.mbuf, {
    title = Utils.fit_path(" Comments ", math.max(size.lw - 2, 0)),
    border = "none",
    width = size.lw,
    height = mh,
    row = size.row + fh,
    col = size.col,
    anchor = "NW",
    focus = false,
  })
  state.fwin = Layout.open_panel(state.fbuf, {
    title = Utils.fit_path(" Files ", math.max(size.lw - 2, 0)),
    border = "none",
    width = size.lw,
    height = fh,
    row = size.row,
    col = size.col,
    anchor = "NW",
    focus = true,
  })
  state.width, state.source_width = state.fwin.width, state.swin.width
  state.term = maki.ui.terminal_size()
end

local function selected(spans, width)
  return Layout.pad_spans(Layout.restyle(spans, "selected"), width, "selected")
end

local function flatten_tree(state)
  local collapsed = {}
  for _, row in ipairs(Tree.flatten(state.tree)) do
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

local function redraw(state)
  flatten_tree(state)
  state.file_cursor = clamp(state.file_cursor, #state.rows)
  state.comment_cursor = clamp(state.comment_cursor, #store)
  local file_lines = {}
  for index, row in ipairs(state.rows) do
    local label = string.rep("  ", row.depth)
      .. (row.dir and (state.effective_collapsed[row.dir] and "▸ " or "▾ ") or "  ")
      .. display(row.name)
    if row.idx then
      local count = Comments.count_for_file(store, state.filtered_paths[row.idx])
      if count > 0 then
        label = label .. " ●" .. count
      end
    end
    local spans = { { Utils.fit_path(label, state.width - 2), row.dir and "accent" or "item" } }
    if state.pane == "files" and index == state.file_cursor then
      spans = selected(spans, state.width)
    end
    file_lines[#file_lines + 1] = spans
  end
  if #file_lines == 0 then
    file_lines[1] = { { "No files", "dim" } }
  end
  state.fbuf:set_lines(file_lines)
  state.fwin:set_cursor(state.file_cursor)
  local comment_lines = {}
  for index, comment in ipairs(store) do
    local location = Utils.fit_path(display(comment.file), math.max(1, state.width - 12))
      .. ":"
      .. line_label(comment.start_line, comment.end_line)
    local preview = display(comment.text):gsub("\n", " ")
    local available = state.width - Utils.display_len(location) - 3
    local label = location
    if available > 3 then
      label = label .. " " .. Utils.wrap(preview, available)[1]
    end
    local spans = { { label, "warning" } }
    if state.pane == "comments" and index == state.comment_cursor then
      spans = selected(spans, state.width)
    end
    comment_lines[#comment_lines + 1] = spans
  end
  if #comment_lines == 0 then
    comment_lines[1] = { { "No comments", "dim" } }
  end
  state.mbuf:set_lines(comment_lines)
  state.mwin:set_cursor(state.comment_cursor)
  local source, cursor = {}, 1
  local function append(spans)
    source[#source + 1] = spans
  end
  if not state.lines then
    append({ { state.error or "Select a file on the left", "dim" } })
  else
    append({ { Utils.fit_path(display(state.file), state.source_width), "accent" } })
    local base = maki.ui.theme_color("background") or "#1e1e1e"
    local range_bg = Layout.blend(base, "#58a6ff", 0.30)
    local comment_bg = Layout.blend(base, "#e3b341", 0.22)
    local first = state.anchor and math.min(state.anchor, state.line)
    local last = state.anchor and math.max(state.anchor, state.line)
    for line, text in ipairs(state.lines) do
      local marked = false
      for _, comment in ipairs(store) do
        if comment.file == state.file and line >= comment.start_line and line <= comment.end_line then
          marked = true
        end
      end
      local spans = { { marked and "● " or "  ", "warning" }, { string.format("%5d ", line), "dim" } }
      local syntax = state.syntax and state.syntax[line] or { { text, "item" } }
      for _, span in ipairs(syntax) do
        spans[#spans + 1] = { span[1], span[2] }
      end
      if first and line >= first and line <= last then
        spans = Layout.pad_spans(Layout.with_bg(spans, range_bg), state.source_width, { bg = range_bg })
      end
      if line == state.line then
        cursor = #source + 1
        if state.pane == "source" and not state.editor then
          spans = selected(spans, state.source_width)
        end
      end
      append(spans)
      if state.editor and line == math.min(state.editor.last, #state.lines) then
        append({ { "    ┌ Comment  Enter: save  Esc: cancel", "accent" } })
        local rendered =
          state.editor.input:render("    │ ", Utils.display_len("    │ "), math.max(1, state.source_width - 8))
        local start = #source
        for _, entry in ipairs(rendered.lines) do
          append(entry)
        end
        cursor = start + rendered.cursor_row
        append({ { "    └", "accent" } })
      end
      for _, comment in ipairs(store) do
        if comment.file == state.file and line == math.min(comment.end_line, #state.lines) then
          append(
            Layout.pad_spans(
              Layout.with_bg(
                { { "    ┏ ● Comment " .. comment.start_line .. "-" .. comment.end_line, "warning" } },
                comment_bg
              ),
              state.source_width,
              { bg = comment_bg }
            )
          )
          for _, wrapped in ipairs(Utils.wrap(display(comment.text), math.max(1, state.source_width - 8))) do
            append(
              Layout.pad_spans(
                Layout.with_bg({ { "    ┃ " .. wrapped, "warning" } }, comment_bg),
                state.source_width,
                { bg = comment_bg }
              )
            )
          end
        end
      end
    end
    if state.truncated then
      append({ { "Showing first 10000 lines (display limit)", "warning" } })
    end
  end
  state.sbuf:set_lines(source)
  state.swin:set_cursor(cursor)
  local files_active = state.pane == "files" and not state.editor
  local comments_active = state.pane == "comments" and not state.editor
  local source_active = state.pane == "source" or state.editor ~= nil
  local files_title = " [1] Files (" .. #state.filtered_paths .. ") "
  if state.search_input or state.search_query ~= "" then
    files_title = files_title .. "/" .. display(state.search_query) .. " "
  end
  local files_hints = state.search_input and { { "Enter", "keep" }, { "Esc", "clear" } }
    or { { "/", "search" }, { "Enter", "open" }, { "e", "edit" }, { "r", "refresh" }, { "Esc", "clear/close" } }
  state.fwin:set_config(
    Layout.panel_config(state.panel_width, files_title, files_active, files_active and files_hints or {})
  )
  state.mwin:set_config(
    Layout.panel_config(
      state.panel_width,
      " [2] Comments (" .. #store .. ") ",
      comments_active,
      comments_active and { { "Enter", "jump" }, { "d", "delete" }, { "s", "submit" } } or {}
    )
  )
  local source_title = " [3] Source "
  if state.file then
    source_title = " [3] Source: " .. Utils.fit_path(display(state.file), math.max(0, state.source_width - 17))
  end
  state.swin:set_config(
    Layout.panel_config(
      state.panel_source_width,
      source_title,
      source_active,
      state.editor and { { "Enter", "save" }, { "Esc", "cancel" } }
        or (
          source_active
            and { { "e", "edit" }, { "c", "comment" }, { "v", "select" }, { "s", "submit" }, { "Esc", "back" } }
          or {}
        )
    )
  )
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

local function index_paths(state, paths)
  state.paths, state.search_entries = paths, {}
  for _, path in ipairs(paths) do
    state.search_entries[#state.search_entries + 1] = { path = path, name_lower = path:match("[^/]+$"):lower() }
  end
end

local function apply_search(state, query, reload)
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
  flatten_tree(state)
  state.file_cursor = clamp(state.file_cursor, #state.rows)
  for index, row in ipairs(state.rows) do
    if (row.dir or state.filtered_paths[row.idx]) == selected_path then
      state.file_cursor = index
      break
    end
  end
  local row = state.rows[state.file_cursor]
  local path = row and row.idx and state.filtered_paths[row.idx]
  if path then
    if reload or path ~= state.file then
      load_source(state, path, path == state.file and state.line or 1)
    end
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
  apply_search(state, state.search_query, state.pane == "files")
  if state.pane ~= "files" and file then
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
  if not refreshed or state.pane ~= "files" then
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
        state.collapsed[row.dir] = true
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
      elseif row and row.idx and key ~= "l" then
        load_source(
          state,
          state.filtered_paths[row.idx],
          state.file == state.filtered_paths[row.idx] and state.line or 1
        )
        state.pane = "source"
      end
    elseif state.pane == "comments" and key ~= "l" then
      local comment = store[state.comment_cursor]
      if comment then
        load_source(state, comment.file, comment.start_line)
        state.pane = "source"
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
    local event = state.fwin:recv()
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

function M.setup(opts)
  if initialized then
    return
  end
  local description = type(opts) == "string" and opts or type(opts) == "table" and opts.description
  maki.api.register_command({
    name = "/code",
    description = description
      or "Browse project source files, inspect code, add line/range comments, and submit comments to Maki.",
    handler = open_safe,
  })
  initialized = true
end

return M
