local Comments = require("common.comments")
local ReviewComments = require("review.comments")
local Lists = require("review.render_lists")
local Right = require("review.render_diff")
local Layout = require("common.layout")
local Text = require("common.text")

local comments = ReviewComments.store
local fit_path, display_len = Text.fit_path, Text.display_len
local M = {}
local NO_CHANGES = "  Working tree clean."

function M.redraw(state)
  Lists.prepare(state)
  state.render_signatures = state.render_signatures or {}
  local function changed(panel, signature)
    local old = state.render_signatures[panel]
    if old and #old == #signature then
      local same = true
      for i, value in ipairs(signature) do
        if old[i] ~= value then
          same = false
          break
        end
      end
      if same then
        return false
      end
    end
    state.render_signatures[panel] = signature
    return true
  end
  local version = Comments.version(comments)
  if
    changed("files", {
      state.working_changes,
      state.file_counts_revision or 0,
      state.fcollapse_revision,
      state.fcursor,
      state.pane == "files",
      state.editor ~= nil,
      state.lwidth,
      version,
      state.fquery or "",
    })
  then
    Lists.changes(
      state,
      state.fbuf,
      state.working_changes,
      state.fcursor,
      state.pane == "files",
      NO_CHANGES,
      state.fcollapsed
    )
  end
  if
    changed("commits", {
      state.commit_changes or state.commits,
      state.ccollapse_revision,
      state.ccursor,
      state.pane == "commits",
      state.editor ~= nil,
      state.lwidth,
      version,
      state.cquery or "",
    })
  then
    if state.commit then
      Lists.changes(
        state,
        state.cbuf,
        state.commit_changes,
        state.ccursor,
        state.pane == "commits",
        "  No files in commit.",
        state.ccollapsed
      )
    else
      Lists.commits(state)
    end
  end
  if changed("comments", { version, state.mcursor, state.pane == "comments", state.editor ~= nil, state.lwidth }) then
    Lists.comments(state)
  end
  -- Right pane: driven by the panel that last had focus (state.preview_pane).
  if
    changed("right", {
      state.preview_pane,
      state.change or false,
      state.dlines or false,
      state.diff_err or false,
      state.sel_commit or false,
      state.info_err or false,
      state.mcursor,
      state.dline or state.dcursor,
      state.vstart or false,
      state.vcur or false,
      state.pane == "diff",
      state.editor or false,
      state.editor and state.editor.input:value() or false,
      state.editor_revision or 0,
      state.rwidth,
      version,
    })
  then
    local drow_map, editor_row = {}, nil
    if state.editor and state.editor.path_editor then
      local lines = {
        { { " " .. state.editor.label .. ": " .. Comments.location(state.editor.record), "accent" } },
        { { " Enter: save  Esc: cancel", "dim" } },
      }
      local rendered = state.editor.input:render(" │ ", 3, math.max(state.rwidth - 6, 1))
      local start = #lines
      for _, line in ipairs(rendered.lines) do
        lines[#lines + 1] = line
      end
      editor_row = start + rendered.cursor_row
      state.rbuf:set_lines(lines)
    elseif state.preview_pane == "commits" and not state.commit then
      Right.commit_info(state)
    elseif state.preview_pane == "comments" then
      Right.comment_detail(state)
    else
      drow_map, editor_row = Right.diff(state)
    end
    state.drow_map = drow_map
    state.editor_row = editor_row
  end
  local drow_map, editor_row = state.drow_map, state.editor_row

  if state.change and not (state.editor and state.editor.path_editor) and not state.drow_map[state.dcursor] then
    for r = state.dcursor, 1, -1 do
      if drow_map[r] then
        state.dcursor = r
        break
      end
    end
    if not drow_map[state.dcursor] then
      state.dcursor = 1
    end
  end

  local diff_active = state.pane == "diff" or state.editor ~= nil

  local function panel_cfg(win, title, active, footer)
    local pane = win == state.fwin and "files" or win == state.cwin and "commits" or "comments"
    local query = pane == "files" and state.fquery or pane == "commits" and state.commit and state.cquery
    if query and query ~= "" then
      title = title .. "/" .. Text.display(query) .. " "
    end
    local hints = not state.editor and active and footer or {}
    if state.search_input and active then
      hints = { { "↑↓", "select" }, { "Enter", "keep" }, { "Esc", "clear" } }
    end
    local config = Layout.panel_config(state.panel_lwidth, title, active, hints)
    if state.search_input and active then
      local prefix = title:match("^(.-)/") or title
      local text = state.search_input:value()
      config.title = prefix .. "/" .. Text.display(text)
      config.title_cursor = #prefix
        + 1
        + #Text.display(text:sub(1, state.search_input.col or state.search_input.cursor or #text))
    end
    win:set_config(config)
  end

  panel_cfg(state.fwin, " [1] Files (" .. #state.working_changes .. ") ", state.pane == "files" and not state.editor, {
    { "/", "search" },
    { "Enter", "diff" },
    { "e", "edit" },
    { "c", "comment" },
    { "s", "submit " .. #comments },
    { "Esc", "close" },
  })

  local ctitle, cfooter
  if state.commit then
    ctitle = " [2] Commits: " .. state.commit.sha .. " (" .. #(state.commit_changes or {}) .. ") "
    cfooter = { { "/", "search" }, { "Enter", "diff" }, { "c", "comment" }, { "Esc", "back" } }
  else
    ctitle = " [2] Commits "
    cfooter = { { "Enter", "open" }, { "Esc", "close" } }
  end
  panel_cfg(state.cwin, ctitle, state.pane == "commits" and not state.editor, cfooter)

  panel_cfg(state.mwin, " [3] Comments (" .. #comments .. ") ", state.pane == "comments" and not state.editor, {
    { "Enter", "jump" },
    { "c", "edit" },
    { "d", "delete" },
    { "s", "submit " .. #comments },
  })

  local rtitle = " [4] Diff "
  if state.preview_pane == "commits" and not state.commit then
    rtitle = state.sel_commit and (" [4] Commit " .. state.sel_commit.sha .. " ") or " [4] Commit "
  elseif state.preview_pane == "comments" then
    rtitle = " [4] Comment "
  elseif state.change then
    rtitle = " [4] Diff: "
      .. fit_path(
        state.change.path,
        math.max(
          state.panel_rwidth - 18 - display_len(tostring(state.change.adds)) - display_len(tostring(state.change.dels)),
          0
        )
      )
      .. "  +"
      .. state.change.adds
      .. " -"
      .. state.change.dels
      .. " "
  end
  state.rwin:set_config(
    Layout.panel_config(
      state.panel_rwidth,
      rtitle,
      diff_active,
      state.editor and { { "Enter", "save" }, { "Esc", "cancel" } }
        or (
          diff_active
            and {
              { "c", "comment" },
              { "v", state.vstart and "cancel select" or "select" },
              { "d", "delete" },
              { "s", "submit " .. #comments },
              { "Esc", "back" },
            }
          or {}
        )
    )
  )

  state.fwin:set_cursor(state.fcursor)
  state.cwin:set_cursor(state.ccursor)
  state.mwin:set_cursor(state.mcursor)
  state.rwin:set_cursor(editor_row or state.dcursor)
  local inputwin = diff_active and state.rwin
    or ({ files = state.fwin, commits = state.cwin, comments = state.mwin })[state.pane]
  if state.inputwin ~= inputwin then
    inputwin:focus()
    state.inputwin = inputwin
  end
end

return M
