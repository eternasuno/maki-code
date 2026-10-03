local Layout = require("common.layout")
local Text = require("common.text")

local fit_path = Text.fit_path
local M = {}

local function layout(root)
  local base = Layout.sizing(root)
  local lw, rw, h, row, col = base.lw, base.rw, base.h, base.row, base.col
  local fh = math.min(math.max(math.floor(h * 0.38), 5), math.max(h - 2, 1))
  local ch = math.min(math.max(math.floor(h * 0.34), 5), math.max(h - fh - 1, 0))
  local mh = h - fh - ch
  return {
    lw = lw,
    rw = rw,
    gap = base.gap,
    h = h,
    fh = fh,
    ch = ch,
    mh = mh,
    row = row,
    col = col,
  }
end

local function open_windows(state)
  M.close(state)
  if state.fwin or state.cwin or state.mwin or state.rwin or state.rootwin then
    error("Cannot reopen review windows: previous windows could not be closed")
  end
  state.render_signatures = {}
  state.inputwin = nil
  state.rootwin = Layout.open_root()
  local L = layout(state.rootwin)
  state.rootwin:set_config({ row = L.row, col = L.col, anchor = "NW" })
  state.rwin = Layout.open_panel(state.rbuf, {
    title = fit_path(" Diff ", math.max(L.rw - 2, 0)),
    width = L.rw,
    height = L.h,
    row = L.row,
    col = L.col + L.lw + L.gap,
    anchor = "NW",
    focus = false,
  })
  state.cwin = Layout.open_panel(state.cbuf, {
    title = fit_path(" Commits ", math.max(L.lw - 2, 0)),
    width = L.lw,
    height = L.ch,
    row = L.row + L.fh,
    col = L.col,
    anchor = "NW",
    focus = false,
  })
  state.mwin = Layout.open_panel(state.mbuf, {
    title = fit_path(" Comments ", math.max(L.lw - 2, 0)),
    width = L.lw,
    height = L.mh,
    row = L.row + L.fh + L.ch,
    col = L.col,
    anchor = "NW",
    focus = false,
  })
  state.fwin = Layout.open_panel(state.fbuf, {
    title = fit_path(" Files ", math.max(L.lw - 2, 0)),
    width = L.lw,
    height = L.fh,
    row = L.row,
    col = L.col,
    anchor = "NW",
    focus = true,
  })
  Layout.attach_root(state.fwin, state)
  state.inputwin = state.fwin
  state.panel_lwidth, state.panel_rwidth = L.lw, L.rw
  state.lwidth = state.fwin.width
  state.rwidth = state.rwin.width
  state.fheight = state.fwin.height
  state.cheight = state.cwin.height
  state.mheight = state.mwin.height
  state.rheight = state.rwin.height
  state.term = maki.ui.terminal_size()
end

function M.close(state)
  local errors = {}
  for _, name in ipairs({ "fwin", "cwin", "mwin", "rwin", "rootwin" }) do
    local window = state[name]
    if window then
      local ok, err = pcall(function()
        window:close()
      end)
      if ok then
        state[name] = nil
      else
        errors[#errors + 1] = err
      end
    end
  end
  for _, err in ipairs(errors) do
    maki.log.error("review close failed: " .. tostring(err))
  end
end

function M.open(state)
  local ok, err = pcall(open_windows, state)
  if not ok then
    M.close(state)
    error(err)
  end
end

return M
