local Text = require("common.text")
local Layout = require("common.layout")
local Comments = require("common.comments")
local ReviewComments = require("review.comments")
local comments = ReviewComments.store
local display_len, sanitize_utf8, fit_path = Text.display_len, Text.sanitize_utf8, Text.fit_path
local pad_spans, restyle = Layout.pad_spans, Layout.restyle
local COMMENT_MARK = "● "
local Tree = require("common.tree")
local comment_count = ReviewComments.count
local STATUS_STYLE = { M = "warning", A = "diff_new", D = "diff_old", R = "accent", ["?"] = "diff_new" }

-- Renders a change list as a collapsible directory tree into `buf`.
-- row_map values: number (index into `changes`) or { dir = path }.
local function render_change_list(state, buf, changes, cursor, active, empty_msg, collapsed)
  local width = math.max(state.lwidth, 20)
  local lines, row_map = {}, {}
  if #changes == 0 then
    lines[#lines + 1] = { { empty_msg, "dim" } }
  end

  local function push(spans, val)
    lines[#lines + 1] = spans
    row_map[#lines] = val
    if #lines == cursor then
      if active and not state.editor then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      else
        -- Inactive panel: keep the selection visible, without the bar.
        local marked = restyle(spans, "active")
        marked[1] = { "▎" .. spans[1][1]:sub(2), "accent" }
        lines[#lines] = marked
      end
    end
  end

  -- Total files and review comments under a directory node.
  local function dir_stats(d)
    local nfiles = #d.files
    for _, sub in ipairs(d.dorder) do
      nfiles = nfiles + dir_stats(sub)
    end
    -- A compressed row represents all directories in its name chain.
    local suffix = d.name:match("^[^/]+(/.*)$") or ""
    local path = d.path:sub(1, #d.path - #suffix)
    local commit = changes[1] and changes[1].commit
    local ncoms = ReviewComments.count_under(path, commit)
    return nfiles, ncoms
  end

  local function emit_file(f, depth)
    local ch = changes[f.idx]
    local n = comment_count(ch)
    local right
    if ch.binary then
      right = "bin"
    elseif ch.untracked then
      right = ch.adds > 0 and ("+" .. ch.adds) or "new"
    else
      right = "+" .. ch.adds .. " -" .. ch.dels
    end
    local badge = n > 0 and (COMMENT_MARK .. n .. " ") or ""
    local prefix = " " .. string.rep("  ", depth) .. ch.status .. " "
    local avail = width - display_len(prefix) - display_len(right) - display_len(badge) - 2
    local spans = {
      { prefix, STATUS_STYLE[ch.status] or "item" },
      { fit_path(f.name, math.max(avail, 8)), "item" },
    }
    pad_spans(spans, width - display_len(right) - display_len(badge) - 1)
    if badge ~= "" then
      spans[#spans + 1] = { badge, "warning" }
    end
    spans[#spans + 1] = {
      right,
      ch.untracked and "diff_new" or (ch.binary and "dim" or "accent"),
    }
    push(spans, f.idx)
  end

  local function emit_dir(d, depth)
    local isc = collapsed[d.path]
    local nfiles, ncoms = dir_stats(d)
    local right = isc and (nfiles .. " files") or ""
    local badge = ncoms > 0 and (COMMENT_MARK .. ncoms .. " ") or ""
    local prefix = " " .. string.rep("  ", depth) .. (isc and "▸ " or "▾ ")
    local avail = width - display_len(prefix) - display_len(right) - display_len(badge) - 2
    local spans = {
      { prefix, "accent" },
      { fit_path(d.name .. "/", math.max(avail, 8)), "item" },
    }
    pad_spans(spans, width - display_len(right) - display_len(badge) - 1)
    if badge ~= "" then
      spans[#spans + 1] = { badge, "warning" }
    end
    if right ~= "" then
      spans[#spans + 1] = { right, "dim" }
    end
    push(spans, { dir = d.path })
  end

  local prepared = state.list_cache[changes]
  local tree = prepared.tree
  local dirs = {}
  local function collect(node)
    for _, d in ipairs(node.dorder) do
      dirs[d.path] = d
      collect(d)
    end
  end
  collect(tree)
  for _, row in ipairs(prepared.rows) do
    if row.dir then
      emit_dir(dirs[row.dir], row.depth)
    else
      emit_file(row, row.depth)
    end
  end

  buf:set_lines(lines)
  return row_map
end

-- Renders the commit list into cbuf. Returns row_map (row -> commit idx).
local function render_commit_list(state)
  local width = math.max(state.lwidth, 20)
  local active = state.pane == "commits" and not state.editor
  local lines, row_map = {}, {}
  if #state.commits == 0 then
    lines[#lines + 1] = { { "  No commits.", "dim" } }
  end
  for i, cm in ipairs(state.commits) do
    local sha = sanitize_utf8(cm.sha or "")
    local when = sanitize_utf8(cm.when or ""):gsub(" ago$", "")
    local subject = sanitize_utf8(cm.subject or "")
    local avail = width - #sha - display_len(when) - 4
    if display_len(subject) > avail then
      subject = maki.ui.truncate_text(subject, math.max(avail - 1, 1)).head .. "…"
    end
    local spans = {
      { " " .. sha .. " ", "accent" },
      { subject, "item" },
    }
    pad_spans(spans, width - display_len(when) - 1)
    spans[#spans + 1] = { when, "dim" }
    lines[#lines + 1] = spans
    row_map[#lines] = i
    if #lines == state.ccursor then
      if active then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      else
        local marked = restyle(spans, "active")
        marked[1] = { "▎" .. sha .. " ", "accent" }
        lines[#lines] = marked
      end
    end
  end
  state.cbuf:set_lines(lines)
  return row_map
end

-- Renders all review comments into mbuf. Returns row_map (row -> comment idx).
local function render_comment_list(state)
  local width = math.max(state.lwidth, 20)
  local active = state.pane == "comments" and not state.editor
  local lines, row_map = {}, {}
  if #comments == 0 then
    lines[#lines + 1] = { { "  No comments yet.", "dim" } }
    lines[#lines + 1] = { { "  Press c on a path or diff line.", "dim" } }
  end
  for i, c in ipairs(comments) do
    local kind = Comments.kind(c)
    local loc = Comments.location(c)
    if kind ~= "line" then
      loc = (kind == "dir" and "Dir " or "File ") .. loc
    end
    if c.commit then
      loc = loc .. " @" .. c.commit
    end
    loc = fit_path(loc, math.max(width - 4, 8))
    local spans = {
      { " " .. COMMENT_MARK, "warning" },
      { loc, "item" },
    }
    local avail = width - 3 - display_len(loc) - 2
    if avail > 4 then
      local preview = c.text:gsub("%s+", " ")
      if display_len(preview) > avail then
        preview = maki.ui.truncate_text(preview, math.max(avail - 1, 1)).head .. "…"
      end
      spans[#spans + 1] = { " " .. preview, "dim" }
    end
    lines[#lines + 1] = spans
    row_map[#lines] = i
    if #lines == state.mcursor then
      if active then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      else
        local marked = restyle(spans, "active")
        marked[1] = { "▎" .. COMMENT_MARK, "warning" }
        lines[#lines] = marked
      end
    end
  end
  state.mbuf:set_lines(lines)
  return row_map
end

local M = {}
function M.prepare(state)
  state.list_cache = state.list_cache or {}
  local function changes_map(changes, collapsed, revision)
    local cached = state.list_cache[changes]
    if not cached then
      cached = { tree = Tree.build_tree(changes) }
      state.list_cache[changes] = cached
    end
    if cached.collapsed ~= collapsed or cached.revision ~= revision then
      cached.rows = Tree.flatten(cached.tree, collapsed)
      cached.map = {}
      for i, row in ipairs(cached.rows) do
        cached.map[i] = row.dir and { dir = row.dir } or row.idx
      end
      cached.collapsed, cached.revision = collapsed, revision
    end
    return cached.map
  end
  state.frow_map = changes_map(state.working_changes, state.fcollapsed, state.fcollapse_revision)
  if state.commit then
    state.crow_map = changes_map(state.commit_changes, state.ccollapsed, state.ccollapse_revision)
  else
    state.crow_map = {}
    for i in ipairs(state.commits) do
      state.crow_map[i] = i
    end
  end
  state.mrow_map = {}
  for i in ipairs(comments) do
    state.mrow_map[i] = i
  end
  for _, panel in ipairs({ { "fcursor", "frow_map" }, { "ccursor", "crow_map" }, { "mcursor", "mrow_map" } }) do
    if not state[panel[2]][state[panel[1]]] then
      state[panel[1]] = 1
    end
  end
end
M.changes = render_change_list
M.commits = render_commit_list
M.comments = render_comment_list
return M
