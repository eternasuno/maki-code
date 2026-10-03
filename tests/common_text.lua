local Text = require("common.text")
local function chars(s)
  local out, i = {}, 1
  while i <= #s do
    local b = s:byte(i)
    local n = b < 128 and 1
      or (b >= 194 and b <= 223 and 2)
      or (b >= 224 and b <= 239 and 3)
      or (b >= 240 and b <= 244 and 4)
      or 0
    local valid = n > 0 and i + n - 1 <= #s
    for j = i + 1, i + n - 1 do
      local c = s:byte(j)
      if not c or c < 128 or c > 191 then
        valid = false
      end
    end
    local second = s:byte(i + 1)
    if n == 3 and ((b == 224 and second and second < 160) or (b == 237 and second and second >= 160)) then
      valid = false
    end
    if n == 4 and ((b == 240 and second and second < 144) or (b == 244 and second and second >= 144)) then
      valid = false
    end
    if valid then
      out[#out + 1] = s:sub(i, i + n - 1)
      i = i + n
    else
      i = i + 1
    end
  end
  return out
end

local function old_wrap(text, width)
  width = math.max(math.floor(width), 1)
  local lines = {}
  for raw in (Text.sanitize_utf8(text) .. "\n"):gmatch("(.-)\n") do
    if raw == "" then
      lines[#lines + 1] = ""
    end
    while #raw > 0 do
      if Text.display_len(raw) <= width then
        lines[#lines + 1] = raw
        break
      end
      local cut, cells, space = 0, 0, nil
      for _, c in ipairs(chars(raw)) do
        local next_cells = cells + Text.display_len(c)
        if next_cells > width then
          break
        end
        cut, cells = cut + #c, next_cells
        if c == " " and cells >= math.max(width - 20, 1) then
          space = cut
        end
      end
      if cut == 0 then
        cut = #chars(raw)[1]
      end
      cut = space or cut
      lines[#lines + 1] = raw:sub(1, cut)
      raw = raw:sub(cut + 1):gsub("^%s+", "")
    end
  end
  return lines
end

return function(test, eq)
  test("styled wrapping preserves whitespace styles and Unicode", function()
    maki = nil
    local style = { fg = "#ffffff", bold = true }
    local spans = { { "ab  ", "item" }, { "界é\txyz", style } }
    local rows = Text.wrap_spans(spans, 4)
    local pieces = {}
    for _, row in ipairs(rows) do
      local cells = 0
      for _, span in ipairs(row) do
        cells = cells + Text.display_len(span[1])
        pieces[#pieces + 1] = span[1]
        eq(span[2], #pieces == 1 and "item" or style)
      end
      assert(cells <= 4)
    end
    eq(table.concat(pieces), "ab  界é    xyz")
    eq(rows[2][1][1], "界é ")
    eq(spans[2][1], "界é\txyz")
    eq(#Text.wrap_spans({ { "", "item" } }, 4), 1)
    eq(#Text.wrap_spans({ { "abcd", "item" } }, 4), 1)
    eq(#Text.wrap_spans({ { "ab", "item" } }, 0), 2)
  end)
  test("wrap differential whitespace UTF8 widths and final remainder", function()
    maki = nil
    local cases = {
      "",
      "\n",
      "a\n\n",
      "hello world",
      "ab cd ef",
      "  a   b  ",
      "a\t  b\r c",
      "界界éé\n\nhello world",
      "😀é foo 界",
      "\255a\192 b",
      "a" .. string.rep(" ", 30) .. "b",
      string.rep("path/word ", 40),
    }
    for _, text in ipairs(cases) do
      for width = 0, 45 do
        local expected, actual = old_wrap(text, width), Text.wrap(text, width)
        eq(#actual, #expected)
        for i, line in ipairs(expected) do
          eq(actual[i], line)
        end
        eq(Text.first_line(text, width), expected[1])
      end
    end
    eq(Text.wrap("ab cd ef", 5)[2], "cd ef")
  end)
  test("wrap preserves native nonadditive remainder measurement", function()
    maki = { ui = {
      display_width = function(s)
        return #s - select(2, s:gsub("ab", ""))
      end,
    } }
    for _, text in ipairs({ "ab ab ab ab", "x ab ab", "ababab" }) do
      for width = 1, 8 do
        local expected, actual = old_wrap(text, width), Text.wrap(text, width)
        eq(#actual, #expected)
        for i, line in ipairs(expected) do
          eq(actual[i], line)
        end
        eq(Text.first_line(text, width), expected[1])
      end
    end
    maki = nil
  end)
  test("wrap measurement work and first-line short circuit", function()
    local calls, bytes = 0, 0
    maki = {
      ui = {
        display_width = function(s)
          calls, bytes = calls + 1, bytes + #s
          return #s
        end,
      },
    }
    local text = string.rep("word ", 1000)
    old_wrap(text, 40)
    local old_calls, old_bytes = calls, bytes
    calls, bytes = 0, 0
    Text.wrap(text, 40)
    local new_calls, new_bytes = calls, bytes
    assert(new_calls < old_calls)
    assert(new_bytes < old_bytes)
    calls, bytes = 0, 0
    Text.first_line(text .. "\n" .. string.rep("later", 1000), 40)
    assert(calls <= 42)
    assert(bytes <= #text + 41)
    print(
      string.format(
        "wrap benchmark 5000 bytes/40 cells: measurements %d -> %d; measured bytes %d -> %d; first_line %d calls/%d bytes",
        old_calls,
        new_calls,
        old_bytes,
        new_bytes,
        calls,
        bytes
      )
    )
    maki = nil
  end)
end
