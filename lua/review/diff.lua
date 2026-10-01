local Highlight = require("common.highlight")
local M = {}
local function parse_diff(raw)
  local out = {}
  local old_ln, new_ln = 0, 0
  local in_hunk = false
  for line in raw:gmatch("[^\n]*\n?") do
    line = line:gsub("\n$", "")
    local os_, ns_ = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if os_ then
      old_ln, new_ln = tonumber(os_), tonumber(ns_)
      in_hunk = true
      out[#out + 1] = { kind = "hunk", text = line }
    elseif in_hunk then
      local c = line:sub(1, 1)
      if c == "+" then
        out[#out + 1] = { kind = "add", text = line:sub(2), new_ln = new_ln }
        new_ln = new_ln + 1
      elseif c == "-" then
        out[#out + 1] = { kind = "del", text = line:sub(2), old_ln = old_ln }
        old_ln = old_ln + 1
      elseif c == " " then
        out[#out + 1] = {
          kind = "ctx",
          text = line:sub(2),
          old_ln = old_ln,
          new_ln = new_ln,
        }
        old_ln = old_ln + 1
        new_ln = new_ln + 1
      end
      -- "\ No newline at end of file" and new "diff --git" headers fall through
      if line:sub(1, 10) == "diff --git" then
        in_hunk = false
      end
    end
  end
  return out
end
local function highlight_dlines(path, dlines)
  local code, idxs = {}, {}
  for i, dl in ipairs(dlines) do
    if dl.kind ~= "hunk" then
      code[#code + 1] = dl.text
      idxs[#idxs + 1] = i
    end
  end
  local styled = Highlight.highlight_file(path, code)
  if not styled then
    return nil
  end
  local hl = {}
  for j, spans in ipairs(styled) do
    hl[idxs[j]] = spans
  end
  return hl
end

M.parse = parse_diff
M.highlight = highlight_dlines
return M
