local M = {}

function M.fill_input(state, windows, prompt, restore)
  local closed = false
  local ok, edited, err = pcall(function()
    local guard, guard_err = maki.ui.input()
    if not guard or guard_err then
      return nil, guard_err or "No input snapshot returned"
    end
    closed = true
    local close_error
    for _, name in ipairs(windows) do
      local window = state[name]
      if window then
        local close_ok, failure = pcall(function()
          window:close()
        end)
        if close_ok then
          state[name] = nil
        elseif not close_error then
          close_error = failure
        end
      end
    end
    if close_error then
      return nil, close_error
    end
    maki.async.sleep(16)
    for attempt = 1, 5 do
      local input, input_err = maki.ui.input()
      if not input or input_err then
        return nil, input_err or "No input snapshot returned"
      end
      if input.session_id ~= guard.session_id then
        return nil, "Focused session changed"
      end
      local result, edit_err = maki.ui.input_edit({
        start = #input.text,
        stop = #input.text,
        text = (input.text ~= "" and "\n\n" or "") .. prompt,
        version = input.version,
        session_id = guard.session_id,
      })
      if result or edit_err ~= "the chat input is not on screen, so it cannot be edited" or attempt == 5 then
        return result, edit_err
      end
      maki.async.sleep(16)
    end
  end)
  if not ok or not edited or err then
    if closed then
      restore()
    end
    maki.ui.flash("Failed to fill chat input: " .. tostring(ok and (err or "Input edit rejected") or edited))
    return false
  end
  maki.ui.flash("Prompt filled into chat input — review and send manually")
  return true
end

return M
