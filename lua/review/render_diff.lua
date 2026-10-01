local Text = require("common.text")
local Layout = require("common.layout")
local Comments = require("common.comments")
local ReviewComments = require("review.comments")
local comments = ReviewComments.store
local wrap = Text.wrap
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
  local width = math.max(state.rwidth, 20)
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
  local matches = ReviewComments.matches(ch, dlines)

  for i, dl in ipairs(dlines) do
    if dl.kind == "hunk" then
      local spans = { { " " .. dl.text, "accent" } }
      lines[#lines + 1] = spans
      row_map[#lines] = i
      if active and #lines == state.dcursor and not state.editor then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      end
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

      local spans = {
        { c and COMMENT_MARK or "  ", "warning" },
        { string.format("%4d ", ln or 0), "dim" },
        { sign .. " ", base },
      }
      for _, sp in ipairs(text_spans) do
        spans[#spans + 1] = { sp[1], sp[2] }
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
      if bg then
        spans = with_bg(spans, bg)
        pad_spans(spans, width, { bg = bg })
      end

      lines[#lines + 1] = spans
      row_map[#lines] = i
      if active and #lines == state.dcursor and not state.editor then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      end

      -- Inline comment editor, right below the anchor line.
      if state.editor and state.editor.at == i then
        lines[#lines + 1] = {
          { "    ┌ ", "accent" },
          { "Comment (" .. state.editor.label .. ")", "accent" },
          { "  Enter: save  Esc: cancel", "dim" },
        }
        local r = state.editor.input:render("    │ ", 6, math.max(width - 8, 20))
        for _, l in ipairs(r.lines) do
          lines[#lines + 1] = l
          editor_row = #lines
        end
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
          for _, cl in ipairs(wrap(c.text, math.max(width - 10, 20))) do
            local cspans = { { COMMENT_BAR, bar }, { cl, txt } }
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
    for l in (raw .. "\n"):gmatch("(.-)\n") do
      local style = "item"
      if l:match("^commit ") then
        style = "accent"
      elseif l:match("^%u[%w-]*:") then
        style = "dim"
      end
      lines[#lines + 1] = { { " " .. l, style } }
    end
    lines[#lines + 1] = { { "  Enter: browse the files of this commit", "dim" } }
  end
  state.rbuf:set_lines(lines)
end

-- Right pane: full text + snippet of the comment under the cursor.
local function render_comment_detail(state)
  local width = math.max(state.rwidth, 20)
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
  for _, cl in ipairs(wrap(c.text, math.max(width - 8, 20))) do
    local spans = { { " ┃ ", bar }, { cl, txt } }
    if cbg then
      pad_spans(spans, width, { bg = cbg })
    end
    lines[#lines + 1] = spans
  end
  lines[#lines + 1] = { { "", "" } }
  for sl in ((Comments.kind(c) == "line" and c.snippet or "") .. "\n"):gmatch("(.-)\n") do
    local ch1 = sl:sub(1, 1)
    local style = "item"
    if sl:match("^@@") then
      style = "accent"
    elseif ch1 == "+" then
      style = "diff_new"
    elseif ch1 == "-" then
      style = "diff_old"
    end
    lines[#lines + 1] = { { " " .. sl, style } }
  end
  state.rbuf:set_lines(lines)
end

return { diff = render_diff, commit_info = render_commit_info, comment_detail = render_comment_detail }
