local Git = require("review.git")
local Browser = require("review.browser")
local M = {}
local initialized = false
local last_signature
local function open_review()
  local state
  local ok, err = pcall(function()
    local root, failure = Git.root()
    if not root then
      maki.ui.flash(tostring(failure))
      return
    end
    local changes
    changes, failure = Git.changes(root)
    if not changes then
      maki.ui.flash(tostring(failure))
      return
    end
    local commits
    commits, failure = Git.log(root)
    if not commits then
      maki.ui.flash(tostring(failure))
      return
    end
    state = Browser.create_state(root, changes, commits)
    Browser.open(state)
    local running = true
    while running do
      running = Browser.handle_event(state, state.inputwin:recv())
    end
  end)
  if state then
    Browser.close(state)
  end
  if not ok then
    maki.log.error("review crashed: " .. tostring(err))
    maki.ui.flash("review error: " .. tostring(err))
  end
end
function M.setup()
  if initialized then
    return
  end
  maki.api.register_command({
    name = "/review",
    description = "Review changes vs HEAD, comment on diff lines, send fixes to maki",
    handler = open_review,
  })
  maki.api.create_autocmd("TurnEnd", {
    callback = function()
      maki.async.run(function()
        local root = Git.root()
        if not root then
          return
        end
        local changes = Git.changes(root)
        if not changes then
          return
        end
        local paths = { root }
        for _, change in ipairs(changes) do
          paths[#paths + 1] = change.path
        end
        local signature = table.concat(paths, "\0")
        if #changes > 0 and signature ~= last_signature then
          maki.ui.flash(#changes .. " file(s) changed — /review to inspect & comment")
        end
        last_signature = signature
      end)
    end,
  })
  initialized = true
end
return M
