local M = {}
local Text = require("common.text")
local display_len = Text.display_len

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
    title = Text.fit_path(title:match("^%s*(.-)%s*$"), math.max(available - 2, 0)),
    footer = fitted,
    active = active,
  }
end

function M.open_panel(buf, opts)
  local width, height = math.max(opts.width, 1), math.max(opts.height, 1)
  local frame_buf = maki.ui.buf()
  local config = { title = opts.title or "", footer = opts.footer or {}, active = opts.focus == true }
  local initial_footer = config.footer
  config.footer = {}
  for i, pair in ipairs(initial_footer) do
    config.footer[i] = { pair[1], pair[2] }
  end
  local function edge(left, right, text, style)
    if width == 1 then
      return { { left, style } }
    end
    text = Text.fit_path(text, width - 2)
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
    pcall(function()
      frame:close()
    end)
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
    local changed = false
    for _, key in ipairs({ "title", "active" }) do
      if next_config[key] ~= nil and next_config[key] ~= config[key] then
        config[key] = next_config[key]
        changed = true
      end
    end
    if next_config.footer ~= nil then
      local footer = next_config.footer
      local same = #footer == #config.footer
      for i, pair in ipairs(footer) do
        local old = config.footer[i]
        if not old or old[1] ~= pair[1] or old[2] ~= pair[2] then
          same = false
        end
      end
      if not same then
        config.footer = {}
        for i, pair in ipairs(footer) do
          config.footer[i] = { pair[1], pair[2] }
        end
        changed = true
      end
    end
    if changed then
      render()
    end
  end
  local content_closed, frame_closed = false, false
  function panel:close()
    local content_err, frame_err
    if not content_closed then
      content_closed, content_err = pcall(function()
        content:close()
      end)
    end
    if not frame_closed then
      frame_closed, frame_err = pcall(function()
        frame:close()
      end)
    end
    if not content_closed or not frame_closed then
      error(not content_closed and content_err or frame_err)
    end
  end
  return panel
end

function M.open_root()
  return maki.ui.open_win(maki.ui.buf(), {
    width = "90%",
    height = "90%",
    border = "none",
    focus = false,
    zindex = 48,
  })
end

function M.attach_root(panel, state)
  local close = panel.close
  function panel:close()
    close(self)
    if state.rootwin then
      state.rootwin:close()
      state.rootwin = nil
    end
  end
end

function M.sizing(extent)
  local sz = maki.ui.terminal_size()
  local w, h = extent.width, extent.height
  local lw = math.min(math.max(28, math.min(46, math.floor(w * 0.30))), math.floor(w / 2))
  local gap = w >= 5 and 1 or 0
  local rw = w - lw - gap
  local row = math.max(math.floor((sz.rows - h) / 2) - 1, 0)
  local col = math.floor((sz.cols - w) / 2)
  return { lw = lw, rw = rw, gap = gap, h = h, row = row, col = col }
end

return M
