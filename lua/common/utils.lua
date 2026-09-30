local M = {}

local function chars(s)
  local out, i = {}, 1
  while i <= #s do
    local b = s:byte(i)
    local n = b < 128 and 1 or (b >= 194 and b <= 223 and 2)
      or (b >= 224 and b <= 239 and 3) or (b >= 240 and b <= 244 and 4) or 0
    local valid = n > 0 and i + n - 1 <= #s
    for j = i + 1, i + n - 1 do
      local c = s:byte(j)
      if not c or c < 128 or c > 191 then valid = false end
    end
    local second = s:byte(i + 1)
    if n == 3 and ((b == 224 and second and second < 160)
      or (b == 237 and second and second >= 160)) then valid = false end
    if n == 4 and ((b == 240 and second and second < 144)
      or (b == 244 and second and second >= 144)) then valid = false end
    if valid then
      out[#out + 1] = s:sub(i, i + n - 1)
      i = i + n
    else
      i = i + 1
    end
  end
  return out
end

function M.sanitize_utf8(s)
  if not s or s == "" then return s end
  return table.concat(chars(s))
end

local function cell_width(c)
  local b = c:byte(1)
  local cp = b
  if #c > 1 then
    cp = b % (2 ^ (7 - #c))
    for i = 2, #c do cp = cp * 64 + c:byte(i) - 128 end
  end
  if cp < 32 or (cp >= 127 and cp < 160) or (cp >= 768 and cp <= 879)
    or (cp >= 6832 and cp <= 6911) or (cp >= 7616 and cp <= 7679)
    or (cp >= 8203 and cp <= 8207) or (cp >= 65024 and cp <= 65039)
    or (cp >= 65056 and cp <= 65071) then return 0 end
  if cp >= 4352 and (cp <= 4447 or cp == 9001 or cp == 9002
    or (cp >= 11904 and cp <= 42191 and cp ~= 12351)
    or (cp >= 44032 and cp <= 55203) or (cp >= 63744 and cp <= 64255)
    or (cp >= 65040 and cp <= 65049) or (cp >= 65072 and cp <= 65135)
    or (cp >= 65281 and cp <= 65376) or (cp >= 65504 and cp <= 65510)
    or (cp >= 127744 and cp <= 129791) or (cp >= 131072 and cp <= 262141)) then return 2 end
  return 1
end

function M.display_len(s)
  s = M.sanitize_utf8(s or "")
  if maki and maki.ui and maki.ui.display_width then
    local ok, n = pcall(maki.ui.display_width, s)
    if ok and type(n) == "number" then return n end
  end
  local n = 0
  for _, c in ipairs(chars(s)) do n = n + cell_width(c) end
  return n
end

function M.wrap(text, width)
  width = math.max(math.floor(width), 1)
  local lines = {}
  for raw in (M.sanitize_utf8(text) .. "\n"):gmatch("(.-)\n") do
    if raw == "" then lines[#lines + 1] = "" end
    while #raw > 0 do
      if M.display_len(raw) <= width then
        lines[#lines + 1] = raw
        break
      end
      local cut, cells, space = 0, 0, nil
      for _, c in ipairs(chars(raw)) do
        local next_cells = cells + M.display_len(c)
        if next_cells > width then break end
        cut, cells = cut + #c, next_cells
        if c == " " and cells >= math.max(width - 20, 1) then space = cut end
      end
      if cut == 0 then cut = #chars(raw)[1] end
      cut = space or cut
      lines[#lines + 1] = raw:sub(1, cut)
      raw = raw:sub(cut + 1):gsub("^%s+", "")
    end
  end
  return lines
end

function M.fit_path(path, max)
  path = M.sanitize_utf8(path)
  max = math.max(math.floor(max), 0)
  if M.display_len(path) <= max then return path end
  if max == 0 then return "" end
  local parts, tail, cells = chars(path), {}, M.display_len("…")
  for i = #parts, 1, -1 do
    local n = M.display_len(parts[i])
    if cells + n > max then break end
    table.insert(tail, 1, parts[i])
    cells = cells + n
  end
  return "…" .. table.concat(tail)
end

return M
