local Browser = require("code.browser")
local initialized = false
local M = {}

function M.setup(opts)
  if initialized then
    return
  end
  local description = type(opts) == "string" and opts or type(opts) == "table" and opts.description
  maki.api.register_command({
    name = "/code",
    description = description
      or "Browse workspace files, add source/file/directory comments, and submit comments to Maki.",
    handler = Browser.open,
  })
  initialized = true
end

return M
