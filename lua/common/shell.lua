local M = {}

function M.quote(str)
  return "'" .. str:gsub("'", "'\\''") .. "'"
end

function M.run(cmd, opts)
  opts = opts or {}
  local ok, id, err = pcall(maki.fn.jobstart, cmd, { cwd = opts.cwd, env = opts.env })
  if not ok then return nil, tostring(id) end
  if not id then return nil, err or "failed to start job" end
  local waited, res, wait_err = pcall(maki.fn.jobwait, id, opts.timeout or 15000)
  if not waited or not res then
    pcall(maki.fn.jobstop, id)
    return nil, not waited and tostring(res) or wait_err or ("timed out: " .. tostring(cmd))
  end
  if res.error then return nil, tostring(res.error) end
  if res.truncated then return nil, "job output truncated" end
  local accepted = false
  for _, code in ipairs(opts.ok_exit_codes or { 0 }) do
    if res.exit_code == code then accepted = true end
  end
  if not accepted then
    local message = (res.stderr or ""):match("^%s*(.-)%s*$")
    return nil, message ~= "" and message or ("exit " .. tostring(res.exit_code))
  end
  return res.stdout or ""
end

return M
