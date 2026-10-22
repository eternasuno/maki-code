local Text = require("common.text")
local function chars(s)
  local out = {}
  for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = c
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
  test("comment input wraps display cells and keeps cursor visible", function()
    maki = nil
    local input = {
      render = function(_, prefix, prefix_width, width)
        eq(prefix, "")
        eq(prefix_width, 0)
        eq(width, nil)

        return {
          lines = {
            { { "中文中文", "" }, { "界", "cursor" }, { " é😀", "" } },
            { { "", "" }, { " ", "cursor" } },
          },
          cursor_row = 2,
        }
      end,
    }
    local rendered = Text.render_input(input, " │ ", 9)
    local text, cursors = {}, {}
    for index, row in ipairs(rendered.lines) do
      local cells = 0
      for part, span in ipairs(row) do
        cells = cells + Text.display_len(span[1])
        if part > 1 then
          text[#text + 1] = span[1]
        end

        if span[2] == "cursor" then
          cursors[#cursors + 1] = index
        end
      end

      assert(cells <= 9)
    end

    eq(table.concat(text), "中文中文界 é😀 ")
    eq(rendered.cursor_row, cursors[#cursors])
    assert(cursors[1] > 1)
    eq(rendered.lines[1][1][1], " │ ")
    eq(rendered.lines[2][1][1], "   ")
  end)
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
  test("wrap sanitizes input once", function()
    local sanitize, calls = Text.sanitize_utf8, 0
    Text.sanitize_utf8 = function(s)
      calls = calls + 1
      return sanitize(s)
    end
    local ok, err = pcall(Text.wrap, "hello world", 4)
    Text.sanitize_utf8 = sanitize
    assert(ok, err)
    eq(calls, 1)
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
