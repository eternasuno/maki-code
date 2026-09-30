local M = {}
local display_len = require("common.utils").display_len

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

function M.sizing()
  local sz = maki.ui.terminal_size()
  local w = math.max(2, math.floor(sz.cols * 0.94))
  local h = math.max(2, math.floor(sz.rows * 0.86))
  local lw = math.min(math.max(28, math.min(46, math.floor(w * 0.30))), math.floor(w / 2))
  local rw = w - lw
  local row = math.max(math.floor((sz.rows - h) / 2) - 1, 0)
  local col = math.floor((sz.cols - w) / 2)
  return { lw = lw, rw = rw, h = h, row = row, col = col }
end

return M
