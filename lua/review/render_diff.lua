local Text = require("common.text")
local Layout = require("common.layout")
local Comments = require("common.comments")
local ReviewComments = require("review.comments")
local comments = ReviewComments.store
local wrap_spans = Text.wrap_spans
local pad_spans, restyle, with_bg = Layout.pad_spans, Layout.restyle, Layout.with_bg
local COMMENT_MARK = "● "
local COMMENT_BAR = "    ┃ "
local ADD_TINT = { "#3fb950", 0.18 }
local DEL_TINT = { "#f85149", 0.18 }
local SEL_TINT = { "#58a6ff", 0.30 }
local COM_TINT = { "#e3b341", 0.22 }

local blend = Layout.blend
local tints -- { add, del, sel } computed lazily from the theme background
local function get_tints()
  if tints then
    return tints
  end
  local bg = maki.ui.theme_color("background")
  if not bg then
    tints = {}
    return tints
  end
  tints = {
    add = blend(bg, ADD_TINT[1], ADD_TINT[2]),
    del = blend(bg, DEL_TINT[1], DEL_TINT[2]),
    sel = blend(bg, SEL_TINT[1], SEL_TINT[2]),
    com = blend(bg, COM_TINT[1], COM_TINT[2]),
  }
  return tints
end

local covers = ReviewComments.covers
local line_range_label = ReviewComments.label
local function render_diff(state)
  local width = math.max(state.rwidth, 1)
  local lines, row_map = {}, {}
  local ch = state.change
  local tint = get_tints()

  if not ch then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = { { "  Select a file on the left.", "dim" } }
    state.rbuf:set_lines(lines)
    return row_map, nil
  end

  local dlines = state.dlines
  if not dlines then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = { { "  " .. (state.diff_err or "No diff to show."), "dim" } }
    state.rbuf:set_lines(lines)
    return row_map, nil
  end

  local vfrom, vto
  if state.vstart then
    vfrom = math.min(state.vstart, state.vcur)
    vto = math.max(state.vstart, state.vcur)
  end

  local editor_row = nil
  local active = state.pane == "diff"
  local selected_line = state.dline or (state.drow_map and state.drow_map[state.dcursor]) or state.dcursor
  local cursor_row = nil
  local function append_wrapped(spans, index, bg, content_width)
    local wrapped = wrap_spans(spans, content_width)
    for row, wrapped_spans in ipairs(wrapped) do
      local continuation = row > 1
      local out = {}
      if continuation then
        out[#out + 1] = { "↪", "dim" }
      else
        out[#out + 1] = { " ", "" }
      end
      for _, span in ipairs(wrapped_spans) do
        out[#out + 1] = span
      end
      out[#out + 1] = { "  ", "" }
      if bg then
        out = with_bg(out, bg)
      end
      lines[#lines + 1] = pad_spans(out, width, bg and { bg = bg } or "")
      row_map[#lines] = index
      if index == selected_line then
        cursor_row = cursor_row or #lines
        if active and not state.editor then
          lines[#lines] = pad_spans(restyle(lines[#lines], "selected"), width, "selected")
        end
      end
    end
  end
  local matches = ReviewComments.matches(ch, dlines)

  for i, dl in ipairs(dlines) do
    if dl.kind == "hunk" then
      append_wrapped({ { dl.text, "accent" } }, i, nil, math.max(width - 3, 1))
    else
      local selected = vfrom and i >= vfrom and i <= vto
      local match = matches[i]
      local c = match and match.record
      local ln = dl.kind == "del" and dl.old_ln or dl.new_ln
      local sign = dl.kind == "add" and "+" or dl.kind == "del" and "-" or " "
      local base = dl.kind == "add" and "diff_new" or dl.kind == "del" and "diff_old" or "item"

      -- Code text: syntax-highlighted spans when available.
      local text_spans
      if state.hl and state.hl[i] and #state.hl[i] > 0 then
        text_spans = state.hl[i]
      else
        text_spans = { { dl.text, base } }
      end

      -- Full-row background tint by line kind / selection.
      local bg = nil
      if selected then
        bg = tint.sel
      elseif dl.kind == "add" then
        bg = tint.add
      elseif dl.kind == "del" then
        bg = tint.del
      end
      local code_spans = {}
      for _, span in ipairs(text_spans) do
        code_spans[#code_spans + 1] = { span[1], span[2] }
      end
      local gutter_spans = {
        { c and COMMENT_MARK or "  ", "warning" },
        { string.format("%4d ", ln or 0), "dim" },
        { sign .. " ", base },
      }
      local content_width = math.max(width - 11, 1)
      local wrapped = wrap_spans(code_spans, content_width)
      for row, wrapped_spans in ipairs(wrapped) do
        local out = {}
        if row == 1 then
          for _, span in ipairs(gutter_spans) do
            out[#out + 1] = span
          end
        else
          out[#out + 1] = { "    ↪    ", "dim" }
        end
        for _, span in ipairs(wrapped_spans) do
          out[#out + 1] = span
        end
        out[#out + 1] = { "  ", "" }
        if bg then
          out = with_bg(out, bg)
        end
        lines[#lines + 1] = pad_spans(out, width, bg and { bg = bg } or "")
        row_map[#lines] = i
        if i == selected_line then
          cursor_row = cursor_row or #lines
          if active and not state.editor then
            lines[#lines] = pad_spans(restyle(lines[#lines], "selected"), width, "selected")
          end
        end
      end

      -- Inline comment editor, right below the anchor line.
      if state.editor and state.editor.at == i then
        lines[#lines + 1] = {
          { "    ┌ ", "accent" },
          { "Comment (" .. state.editor.label .. ")", "accent" },
          { "  Enter: save  Esc: cancel", "dim" },
        }
        local start = #lines
        local r = state.editor.input:render("    │ ", 6, math.max(width - 8, 1))
        for _, l in ipairs(r.lines) do
          lines[#lines + 1] = l
        end
        editor_row = start + r.cursor_row
        lines[#lines + 1] = { { "    └", "accent" } }
      end

      -- Show the comment right below the last diff line it covers, in a
      -- full-width tinted block so it stands out from the code.
      if c then
        local nxt = dlines[i + 1]
        if not (nxt and nxt.kind ~= "hunk" and covers(c, nxt)) then
          local cbg = tint.com
          local bar = { fg = COM_TINT[1], bg = cbg, bold = true }
          local txt = cbg and { bg = cbg, bold = true } or "warning"
          local hdr = { { "    ┏ ", bar }, { "● Comment", bar } }
          if cbg then
            pad_spans(hdr, width, { bg = cbg })
          end
          lines[#lines + 1] = hdr
          for _, cspans in ipairs(wrap_spans({ { COMMENT_BAR, bar }, { c.text, txt } }, math.max(width, 1))) do
            if cbg then
              pad_spans(cspans, width, { bg = cbg })
            end
            lines[#lines + 1] = cspans
          end
        end
      end
    end
  end

  state.rbuf:set_lines(lines)
  state.dcursor = cursor_row or 1
  return row_map, editor_row
end

-- Right pane: summary of the commit under the cursor (commit list view).
local function render_commit_info(state)
  local lines = {}
  local cm = state.sel_commit
  if not cm then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = { { "  Select a commit on the left.", "dim" } }
  else
    local raw = state.cache["info:" .. cm.sha] or ("Commit info failed: " .. tostring(state.info_err))
    lines[#lines + 1] = { { "", "" } }
    for l in (Text.sanitize_utf8(raw) .. "\n"):gmatch("(.-)\n") do
      local style = "item"
      if l:match("^commit ") then
        style = "accent"
      elseif l:match("^%u[%w-]*:") then
        style = "dim"
      end
      for _, spans in ipairs(wrap_spans({ { " " .. l, style } }, math.max((state.rwidth or 1), 1))) do
        lines[#lines + 1] = spans
      end
    end
    lines[#lines + 1] = { { "  Enter: browse the files of this commit", "dim" } }
  end
  state.rbuf:set_lines(lines)
end

-- Right pane: full text + snippet of the comment under the cursor.
local function render_comment_detail(state)
  local width = math.max(state.rwidth, 1)
  local tint = get_tints()
  local lines = {}
  local c = comments[state.mrow_map and state.mrow_map[state.mcursor]]
  if not c then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = { { "  No comment selected.", "dim" } }
    state.rbuf:set_lines(lines)
    return
  end
  local where = line_range_label(c)
  if c.commit then
    where = where .. "  ·  commit " .. c.commit
  end
  lines[#lines + 1] = { { "", "" } }
  lines[#lines + 1] = { { " " .. Comments.path(c), "accent" } }
  lines[#lines + 1] = { { " " .. where, "dim" } }
  lines[#lines + 1] = { { "", "" } }
  local cbg = tint.com
  local bar = { fg = COM_TINT[1], bg = cbg, bold = true }
  local txt = cbg and { bg = cbg, bold = true } or "warning"
  for _, spans in ipairs(wrap_spans({ { " ┃ ", bar }, { c.text, txt } }, math.max(width, 1))) do
    if cbg then
      pad_spans(spans, width, { bg = cbg })
    end
    lines[#lines + 1] = spans
  end
  lines[#lines + 1] = { { "", "" } }
  local snippet = Text.sanitize_utf8(Comments.kind(c) == "line" and c.snippet or "")
  for sl in (snippet .. "\n"):gmatch("(.-)\n") do
    local ch1 = sl:sub(1, 1)
    local style = "item"
    if sl:match("^@@") then
      style = "accent"
    elseif ch1 == "+" then
      style = "diff_new"
    elseif ch1 == "-" then
      style = "diff_old"
    end
    for _, spans in ipairs(wrap_spans({ { " " .. sl, style } }, width)) do
      lines[#lines + 1] = spans
    end
  end
  state.rbuf:set_lines(lines)
end

return { diff = render_diff, commit_info = render_commit_info, comment_detail = render_comment_detail }
