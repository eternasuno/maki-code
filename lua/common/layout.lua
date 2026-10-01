local M = {}
local Utils = require("common.utils")
local display_len = Utils.display_len

local function hex_rgb(hex)
  local h = hex:gsub("#", "")
  return tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16)
end

function M.blend(base, top, t)
  local br, bg_, bb = hex_rgb(base)
  local tr, tg, tb = hex_rgb(top)
  return string.format(
    "#%02x%02x%02x",
    math.floor(br + (tr - br) * t + 0.5),
    math.floor(bg_ + (tg - bg_) * t + 0.5),
    math.floor(bb + (tb - bb) * t + 0.5)
  )
end

function M.spans_len(spans)
  local n = 0
  for _, sp in ipairs(spans) do
    n = n + display_len(sp[1])
  end
  return n
end

function M.pad_spans(spans, width, style)
  local n = M.spans_len(spans)
  if n < width then
    spans[#spans + 1] = { string.rep(" ", width - n), style or "" }
  end
  return spans
end

function M.restyle(spans, style)
  local out = {}
  for _, sp in ipairs(spans) do
    out[#out + 1] = { sp[1], style }
  end
  return out
end

function M.with_bg(spans, bg)
  local out = {}
  for _, sp in ipairs(spans) do
    local s = sp[2]
    local ns = { bg = bg }
    if type(s) == "table" then
      ns.fg = s.fg
      ns.bold = s.bold
      ns.italic = s.italic
      ns.underline = s.underline
    end
    out[#out + 1] = { sp[1], ns }
  end
  return out
end

function M.panel_config(width, title, active, footer)
  local available = math.max(width - 2, 0)
  local fitted = {}
  local cells = 1
  for _, pair in ipairs(footer or {}) do
    local next_cells = cells + display_len(pair[1]) + display_len(pair[2]) + 2
    if next_cells > available then
      break
    end
    fitted[#fitted + 1] = pair
    cells = next_cells
  end
  return {
    border = "none",
    title = Utils.fit_path(title:match("^%s*(.-)%s*$"), math.max(available - 2, 0)),
    footer = fitted,
    active = active,
  }
end

function M.open_panel(buf, opts)
  local width, height = math.max(opts.width, 1), math.max(opts.height, 1)
  local frame_buf = maki.ui.buf()
  local config = { title = opts.title or "", footer = opts.footer or {}, active = opts.focus == true }
  local function edge(left, right, text, style)
    if width == 1 then
      return { { left, style } }
    end
    text = Utils.fit_path(text, width - 2)
    return { { left .. text .. string.rep("─", width - 2 - display_len(text)) .. right, style } }
  end
  local function render()
    local theme = maki.ui.theme_style and maki.ui.theme_style("dim") or {}
    local fg = config.active and "#bb9af7" or (theme and theme.fg)
    if not fg or fg == "default" then
      fg = "#8b949e"
    end
    local style = { fg = fg }
    local title = config.title ~= "" and " " .. config.title:match("^%s*(.-)%s*$") .. " " or ""
    local footer = {}
    for _, pair in ipairs(config.footer) do
      footer[#footer + 1] = pair[1] .. " " .. pair[2] .. " "
    end
    local lines = { edge("┌", "┐", title, style) }
    for _ = 2, height - 1 do
      lines[#lines + 1] = { { width == 1 and "│" or "│" .. string.rep(" ", width - 2) .. "│", style } }
    end
    if height > 1 then
      lines[#lines + 1] = edge("└", "┘", #footer > 0 and " " .. table.concat(footer) or "", style)
    end
    frame_buf:set_lines(lines)
  end
  render()
  local frame = maki.ui.open_win(frame_buf, {
    width = width,
    height = height,
    row = opts.row,
    col = opts.col,
    anchor = opts.anchor,
    border = "none",
    title = "",
    footer = {},
    focus = false,
    visible = opts.height > 0,
    zindex = 49,
  })
  local inset_x, inset_y = width >= 3 and 1 or 0, height >= 3 and 1 or 0
  local ok, content = pcall(maki.ui.open_win, buf, {
    width = width - 2 * inset_x,
    height = height - 2 * inset_y,
    row = (opts.row or 0) + inset_y,
    col = (opts.col or 0) + inset_x,
    anchor = opts.anchor,
    border = "none",
    title = "",
    footer = {},
    focus = opts.focus,
    visible = opts.height > 0,
    zindex = 50,
  })
  if not ok then
    frame:close()
    error(content)
  end
  local panel = { width = content.width, height = content.height }
  function panel:recv(timeout)
    return content:recv(timeout)
  end
  function panel:set_cursor(row)
    return content:set_cursor(row)
  end
  function panel:set_config(next_config)
    for _, key in ipairs({ "title", "footer", "active" }) do
      if next_config[key] ~= nil then
        config[key] = next_config[key]
      end
    end
    render()
  end
  function panel:close()
    content:close()
    frame:close()
  end
  function panel:hide()
    content:hide()
    frame:hide()
  end
  function panel:show()
    if opts.height <= 0 then
      return
    end
    frame:show()
    content:show()
  end
  function panel:is_open()
    return content:is_open() and frame:is_open()
  end
  function panel:is_visible()
    return content:is_visible() and frame:is_visible()
  end
  return panel
end

function M.sizing()
  local sz = maki.ui.terminal_size()
  local w = math.max(2, math.floor(sz.cols * 0.94))
  local h = math.max(2, math.floor(sz.rows * 0.86))
  local lw = math.min(math.max(28, math.min(46, math.floor(w * 0.30))), math.floor(w / 2))
  local gap = w >= 5 and 1 or 0
  local rw = w - lw - gap
  local row = math.max(math.floor((sz.rows - h) / 2) - 1, 0)
  local col = math.floor((sz.cols - w) / 2)
  return { lw = lw, rw = rw, gap = gap, h = h, row = row, col = col }
end

return M
