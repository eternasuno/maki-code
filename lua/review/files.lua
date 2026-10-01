local Git = require("review.git")
local Diff = require("review.diff")
local Lists = require("review.render_lists")

local M = {}

-- Loads the right-pane content for the selection in the source panel.
function M.load_preview(state)
  state.change = nil
  state.dlines = nil
  state.hl = nil
  state.diff_err = nil
  state.vstart = nil
  state.editor = nil
  state.dcursor = 1
  state.sel_commit = nil
  state.info_err = nil

  if state.preview_pane == "comments" then
    return
  end
  if state.preview_pane == "commits" and not state.commit then
    local cm = state.commits[state.crow_map and state.crow_map[state.ccursor]]
    state.sel_commit = cm
    if cm and not state.cache["info:" .. cm.sha] then
      state.cache["info:" .. cm.sha], state.info_err = Git.commit_info(state.root, cm.sha)
    end
    return
  end

  local ch
  if state.preview_pane == "commits" then
    ch = (state.commit_changes or {})[state.crow_map and state.crow_map[state.ccursor]]
  else
    ch = state.working_changes[state.frow_map and state.frow_map[state.fcursor]]
  end
  state.change = ch
  if not ch then
    return
  end
  if ch.binary then
    state.diff_err = "Binary file — nothing to show."
    return
  end

  local key = (ch.commit or "") .. ":" .. ch.path
  local cached = state.cache[key]
  if not cached then
    local raw, err = Git.raw_diff(state.root, ch)
    local dlines = raw and Diff.parse(raw)
    if not dlines then
      state.diff_err = "diff failed: " .. tostring(err)
      return
    end
    cached = { dlines = dlines, hl = Diff.highlight(ch.path, dlines) }
    state.cache[key] = cached
    if ch.untracked then
      local n = 0
      for _, dl in ipairs(dlines) do
        if dl.kind == "add" then
          n = n + 1
        end
      end
      if ch.adds ~= n then
        ch.adds = n
        state.file_counts_revision = (state.file_counts_revision or 0) + 1
      end
    end
  end
  state.dlines = cached.dlines
  state.hl = cached.hl

  -- Cursor starts on the first changed (add/del) line.
  state.dcursor = 1
  for i, dl in ipairs(cached.dlines) do
    if dl.kind == "add" or dl.kind == "del" then
      state.dcursor = i
      break
    end
  end
end

function M.refresh(state)
  state.cache = {}
  state.list_cache = nil
  local changes, err = Git.changes(state.root)
  if changes then
    state.working_changes = changes
  else
    maki.ui.flash("Refresh failed: " .. tostring(err))
  end
  local commits
  commits, err = Git.log(state.root)
  if commits then
    state.commits = commits
  else
    maki.ui.flash("Refresh failed: " .. tostring(err))
  end
  if state.commit then
    changes, err = Git.commit_changes(state.root, state.commit.sha)
    if changes then
      state.commit_changes = changes
    else
      maki.ui.flash("Refresh failed: " .. tostring(err))
    end
  end
  Lists.prepare(state)
  M.load_preview(state)
end

return M
