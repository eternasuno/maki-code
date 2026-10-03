local Text = require("common.text")
local Comments = require("common.comments")
local Layout = require("common.layout")
local Files = require("code.files")
local store = require("code.comments").store
local first_directory = Files.first_directory
local M = {}

local display = Text.display

local function clamp(n, count)
  return math.max(1, math.min(n, count))
end
local function close_windows(state)
  for _, name in ipairs({ "fwin", "mwin", "swin", "rootwin" }) do
    if state[name] then
      local ok = pcall(function()
        state[name]:close()
      end)
      if ok then
        state[name] = nil
      end
    end
  end
end

local function open_windows(state)
  close_windows(state)
  if state.fwin or state.mwin or state.swin or state.rootwin then
    error("Cannot reopen code windows: previous windows could not be closed")
  end
  state.rendered = nil
  state.inputwin = nil
  state.rootwin = Layout.open_root()
  local size = Layout.sizing(state.rootwin)
  state.rootwin:set_config({ row = size.row, col = size.col, anchor = "NW" })
  local fh = math.max(1, math.floor(size.h * 0.6))
  local mh = math.max(1, size.h - fh)
  state.panel_width, state.panel_source_width = size.lw, size.rw
  state.heights = { files = fh, comments = mh, source = size.h }
  state.swin = Layout.open_panel(state.sbuf, {
    title = Text.fit_path(" Source ", math.max(size.rw - 2, 0)),
    width = size.rw,
    height = size.h,
    row = size.row,
    col = size.col + size.lw + size.gap,
    anchor = "NW",
    focus = false,
  })
  state.mwin = Layout.open_panel(state.mbuf, {
    title = Text.fit_path(" Comments ", math.max(size.lw - 2, 0)),
    width = size.lw,
    height = mh,
    row = size.row + fh,
    col = size.col,
    anchor = "NW",
    focus = false,
  })
  state.fwin = Layout.open_panel(state.fbuf, {
    title = Text.fit_path(" Files ", math.max(size.lw - 2, 0)),
    width = size.lw,
    height = fh,
    row = size.row,
    col = size.col,
    anchor = "NW",
    focus = true,
  })
  Layout.attach_root(state.fwin, state)
  state.inputwin = state.fwin
  state.width, state.source_width = state.fwin.width, state.swin.width
  state.term = maki.ui.terminal_size()
end

local function selected(spans, width)
  return Layout.pad_spans(Layout.restyle(spans, "selected"), width, "selected")
end

local function render_files(state, counts)
  local file_lines = {}
  for index, row in ipairs(state.rows) do
    local label = string.rep("  ", row.depth)
      .. (row.dir and (state.effective_collapsed[row.dir] and "▸ " or "▾ ") or "  ")
      .. display(row.name)
    local count = row.dir and (counts.under[first_directory(row)] or 0)
      or (counts.exact[state.filtered_paths[row.idx]] or 0)
    if count > 0 then
      label = label .. " ●" .. count
    end
    local spans = { { Text.fit_path(label, state.width - 2), row.dir and "accent" or "item" } }
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
end

local function render_comments(state)
  local comment_lines = {}
  for index, comment in ipairs(store) do
    local location = Text.fit_path(display(Comments.location(comment)), math.max(1, state.width - 12))
    local preview = display(comment.text):gsub("\n", " ")
    local available = state.width - Text.display_len(location) - 3
    local label = location
    if available > 3 then
      label = label .. " " .. Text.first_line(preview, available)
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
end

local function source_maps(state, counts, version)
  local count = state.lines and #state.lines or 0
  local maps = state.source_maps
  if maps and maps.file == state.file and maps.version == version and maps.count == count then
    return maps
  end
  maps = { file = state.file, version = version, count = count, marked = {}, ending = {} }
  local delta = {}
  for _, entry in ipairs(counts.by_path[state.file] or {}) do
    local comment = entry.record
    if Comments.kind(comment) == "line" then
      local first, last = math.max(1, comment.start_line), math.min(count, comment.end_line)
      if first <= last then
        delta[first] = (delta[first] or 0) + 1
        delta[last + 1] = (delta[last + 1] or 0) - 1
      end
      local ending = math.min(count, comment.end_line)
      maps.ending[ending] = maps.ending[ending] or {}
      table.insert(maps.ending[ending], comment)
    end
  end
  local active = 0
  for line = 1, count do
    active = active + (delta[line] or 0)
    maps.marked[line] = active > 0
  end
  state.source_maps = maps
  return maps
end

local function render_source(state, maps)
  local source, cursor = {}, 1
  local function append(spans)
    source[#source + 1] = spans
  end
  local function append_editor()
    local record = state.editor.record
    append({ { "    ┌ Comment: " .. display(Comments.location(record)) .. "  Enter: save  Esc: cancel", "accent" } })
    local rendered =
      state.editor.input:render("    │ ", Text.display_len("    │ "), math.max(1, state.source_width - 8))
    local start = #source
    for _, entry in ipairs(rendered.lines) do
      append(entry)
    end
    cursor = start + rendered.cursor_row
    append({ { "    └", "accent" } })
  end
  if not state.lines then
    append({ { state.error or "Select a file on the left", "dim" } })
  else
    append({ { Text.fit_path(display(state.file), state.source_width), "accent" } })
    local base = maki.ui.theme_color("background") or "#1e1e1e"
    local range_bg = Layout.blend(base, "#58a6ff", 0.30)
    local comment_bg = Layout.blend(base, "#e3b341", 0.22)
    local first = state.anchor and math.min(state.anchor, state.line)
    local last = state.anchor and math.max(state.anchor, state.line)
    for line, text in ipairs(state.lines) do
      local marked = maps.marked[line]
      local syntax = state.syntax and state.syntax[line] or { { text, "item" } }
      if line == state.line then
        cursor = #source + 1
      end
      for part, wrapped in ipairs(Text.wrap_spans(syntax, math.max(1, state.source_width - 10))) do
        local spans = part == 1 and { { marked and "● " or "  ", "warning" }, { string.format("%5d ", line), "dim" } }
          or { { "      ↪ ", "dim" } }
        for _, span in ipairs(wrapped) do
          spans[#spans + 1] = span
        end
        if first and line >= first and line <= last then
          spans = Layout.pad_spans(Layout.with_bg(spans, range_bg), state.source_width, { bg = range_bg })
        end
        if line == state.line and state.pane == "source" and not state.editor then
          spans = selected(spans, state.source_width)
        end
        append(spans)
      end
      if
        state.editor
        and Comments.kind(state.editor.record) == "line"
        and line == math.min(state.editor.record.end_line, #state.lines)
      then
        append_editor()
      end
      for _, comment in ipairs(maps.ending[line] or {}) do
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
        for _, wrapped in ipairs(Text.wrap(display(comment.text), math.max(1, state.source_width - 8))) do
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
    if state.truncated then
      append({ { "Showing first 10000 lines (display limit)", "warning" } })
    end
  end
  if state.editor and (Comments.kind(state.editor.record) ~= "line" or not state.lines) then
    append_editor()
  end
  state.sbuf:set_lines(source)
  state.swin:set_cursor(cursor)
end

local function redraw(state)
  state.file_cursor = clamp(state.file_cursor, #state.rows)
  state.comment_cursor = clamp(state.comment_cursor, #store)
  local version = Comments.version(store)
  if state.count_version ~= version then
    state.counts = Comments.index(store)
    state.count_version = version
  end
  local previous = state.rendered or {}
  local editor = state.editor
  local editor_text = editor and editor.input:value()
  local editor_line = editor and editor.input.line
  local editor_col = editor and editor.input.col
  if
    previous.rows ~= state.rows
    or previous.file_cursor ~= state.file_cursor
    or previous.files_active ~= (state.pane == "files")
    or previous.version ~= version
    or previous.width ~= state.width
  then
    render_files(state, state.counts)
  end
  if
    previous.comment_cursor ~= state.comment_cursor
    or previous.comments_active ~= (state.pane == "comments")
    or previous.version ~= version
    or previous.width ~= state.width
  then
    render_comments(state)
  end
  if
    previous.lines ~= state.lines
    or previous.file ~= state.file
    or previous.error ~= state.error
    or previous.line ~= state.line
    or previous.anchor ~= state.anchor
    or previous.source_active ~= (state.pane == "source")
    or previous.version ~= version
    or previous.source_width ~= state.source_width
    or previous.editor ~= editor
    or previous.editor_text ~= editor_text
    or previous.editor_line ~= editor_line
    or previous.editor_col ~= editor_col
  then
    render_source(state, source_maps(state, state.counts, version))
  end
  local files_active = state.pane == "files" and not state.editor
  local comments_active = state.pane == "comments" and not state.editor
  local source_active = state.pane == "source" or state.editor ~= nil
  local files_title = " [1] Files (" .. #state.filtered_paths .. ") "
  if state.search_input or state.search_query ~= "" then
    files_title = files_title .. "/" .. display(state.search_query) .. " "
  end
  local search_col = state.search_input and state.search_input.col
  local files_hints = state.search_input
      and { { "↑↓", "select" }, { "←→", "edit" }, { "Enter", "keep" }, { "Esc", "clear" } }
    or { { "/", "search" }, { "Enter", "open" }, { "c", "comment" }, { "e", "edit" }, { "r", "refresh" } }
  if
    previous.pane ~= state.pane
    or previous.editor ~= editor
    or previous.search_input ~= state.search_input
    or previous.query ~= state.search_query
    or previous.search_col ~= search_col
    or previous.rows ~= state.rows
    or previous.width ~= state.width
  then
    local config = Layout.panel_config(state.panel_width, files_title, files_active, files_active and files_hints or {})
    config.title_cursor = false
    if state.search_input then
      local prefix = "[1] Files (" .. #state.filtered_paths .. ") /"
      config.title = prefix .. display(state.search_query)
      config.title_cursor = #prefix + #display(state.search_query:sub(1, search_col))
    end
    state.fwin:set_config(config)
  end
  if
    previous.pane ~= state.pane
    or previous.editor ~= editor
    or previous.version ~= version
    or previous.width ~= state.width
  then
    state.mwin:set_config(
      Layout.panel_config(
        state.panel_width,
        " [2] Comments (" .. #store .. ") ",
        comments_active,
        comments_active and { { "Enter", "jump" }, { "c", "edit" }, { "d", "delete" }, { "s", "submit" } } or {}
      )
    )
  end
  local source_title = " [3] Source "
  if state.file then
    source_title = " [3] Source: " .. Text.fit_path(display(state.file), math.max(0, state.source_width - 17))
  end
  if
    previous.pane ~= state.pane
    or previous.editor ~= editor
    or previous.file ~= state.file
    or previous.source_width ~= state.source_width
  then
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
  local inputwin = source_active and state.swin or (comments_active and state.mwin or state.fwin)
  if state.inputwin ~= inputwin then
    inputwin:focus()
    state.inputwin = inputwin
  end
  state.rendered = {
    rows = state.rows,
    file_cursor = state.file_cursor,
    comment_cursor = state.comment_cursor,
    files_active = state.pane == "files",
    comments_active = state.pane == "comments",
    source_active = state.pane == "source",
    pane = state.pane,
    version = version,
    width = state.width,
    source_width = state.source_width,
    lines = state.lines,
    file = state.file,
    error = state.error,
    line = state.line,
    anchor = state.anchor,
    editor = editor,
    editor_text = editor_text,
    editor_line = editor_line,
    editor_col = editor_col,
    search_input = state.search_input,
    search_col = search_col,
    query = state.search_query,
  }
end

M.open_windows = open_windows
M.close_windows = close_windows
M.redraw = redraw
return M
