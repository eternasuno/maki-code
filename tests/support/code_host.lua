local Host = {}
local Layout = require("common.layout")
local open_panel = Layout.open_panel
local Tree = require("common.tree")
local build_tree, flatten = Tree.build_tree, Tree.flatten
local Comments = require("common.comments")
local Utils = require("common.text")
local add_comment, update_comment = Comments.add, Comments.update

local function eq(actual, expected)
  assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end

function Host.new(paths, sources)
  local f = {
    paths = paths or { "a.lua" },
    sources = sources or {},
    queue = {},
    windows = {},
    flashes = {},
    sessions = {},
    edits = {},
    input_reads = 0,
    draft = "",
    commands = {},
    registrations = {},
    size = { cols = 120, rows = 30 },
    autocmds = 0,
  }
  Comments.add = function(comment_store, record)
    assert(record.target, "New code comments require a target")
    eq(record.file, nil)
    if record.target.kind ~= "line" then
      eq(record.start_line, nil)
      eq(record.end_line, nil)
      eq(record.snippet, nil)
    end
    return add_comment(comment_store, record)
  end
  Comments.update = function(comment_store, index, record)
    local old = comment_store[index]
    eq(record.target, old.target)
    eq(record.start_line, old.start_line)
    eq(record.end_line, old.end_line)
    eq(record.snippet, old.snippet)
    return update_comment(comment_store, index, record)
  end
  Tree.build_tree = function(paths_to_build)
    f.tree_builds = (f.tree_builds or 0) + 1
    return build_tree(paths_to_build)
  end
  Tree.flatten = function(tree, collapsed)
    f.tree_flattens = (f.tree_flattens or 0) + 1
    return flatten(tree, collapsed)
  end
  local numbered = {}
  for i = 1, 90 do
    numbered[i] = "source " .. i
  end
  f.sources["a.lua"] = f.sources["a.lua"] or table.concat(numbered, "\n")
  local function plain(lines)
    local result = {}
    for _, line in ipairs(lines or {}) do
      local spans = {}
      for _, span in ipairs(line) do
        spans[#spans + 1] = span[1]
      end
      result[#result + 1] = table.concat(spans)
    end
    return table.concat(result, "\n")
  end
  local panels = {}
  Layout.open_panel = function(buf, opts)
    local panel = open_panel(buf, opts)
    local content = f.windows[#f.windows]
    content.frame = f.windows[#f.windows - 1]
    panels[opts.title:match("^%s*(.-)%s*$")] = content
    local set_config = panel.set_config
    function panel:set_config(config)
      content.config = config
      return set_config(self, config)
    end
    return panel
  end
  function f:win(title)
    return panels[title]
  end
  function f:text(title)
    return plain(self:win(title).buf.content)
  end
  function f:at(title)
    return plain({ self:win(title).buf.content[self:win(title).cursor] })
  end
  function f:check(fn)
    self.queue[#self.queue + 1] = fn
  end
  function f:key(key)
    self.queue[#self.queue + 1] = { type = "key", key = key }
  end
  function f:paste(text)
    self.queue[#self.queue + 1] = { type = "paste", text = text }
  end
  function f:run()
    self.commands["/code"].handler()
    for _, flash in ipairs(self.flashes) do
      assert(not flash:find("Code browser error:", 1, true), flash)
    end
    eq(#self.queue, 0)
    for _, win in ipairs(self.windows) do
      assert(win.closed, "Window leaked")
    end
  end
  maki = {
    api = {
      register_command = function(spec)
        f.registrations[spec.name] = (f.registrations[spec.name] or 0) + 1
        f.commands[spec.name] = spec
      end,
      create_autocmd = function()
        f.autocmds = f.autocmds + 1
      end,
    },
    async = {
      sleep = function(ms)
        eq(ms, 16)
        f.sleeps = (f.sleeps or 0) + 1
        for _, win in ipairs(f.windows) do
          if win.closed and f.focused == win then
            f.focused = nil
          end
        end
        if f.on_sleep then
          f.on_sleep()
        end
      end,
    },
    fn = {
      jobstart = function(cmd)
        f.jobs = (f.jobs or 0) + 1
        f.last_command = cmd
        return 1
      end,
      jobwait = function()
        if f.last_command:find("--deleted", 1, true) then
          if f.deleted_error then
            return { exit_code = 1, stderr = f.deleted_error }
          end
          return { exit_code = 0, stdout = table.concat(f.deleted or {}, "\0") .. "\0" }
        end
        if f.git_error then
          return { exit_code = 1, stderr = f.git_error }
        end
        return {
          exit_code = 0,
          stdout = f.last_command:find("rev-parse", 1, true) and "true\n" or table.concat(f.paths, "\0") .. "\0",
        }
      end,
    },
    fs = {
      abspath = function(path)
        return "/project/" .. path:sub(3)
      end,
      metadata = function(path)
        if path:sub(1, 9) == "/project/" then
          path = path:sub(10)
        else
          eq(path:sub(1, 2), "./")
          path = path:sub(3)
        end
        if f.meta_error then
          error(f.meta_error)
        end
        if f.missing == path then
          return nil, "File no longer exists"
        end
        return { is_file = not f.directory, size = f.large and 1048577 or #(f.sources[path] or "") }
      end,
      read = function(path)
        f.reads = (f.reads or 0) + 1
        if f.read_error then
          error(f.read_error)
        end
        return f.sources[path:sub(3)] or ""
      end,
    },
    session = {
      prompt = function()
        error("must not auto-send")
      end,
      new = function(opts)
        f.sessions[#f.sessions + 1] = opts
        error("session.new must not be called")
      end,
    },
    ui = {
      input = function()
        f.input_reads = f.input_reads + 1
        if f.input_throw then
          error("snapshot panic")
        end
        if f.input_fail then
          return nil, "snapshot unavailable"
        end
        return { text = f.draft, cursor = 0, version = 17, session_id = f.session_id or "current-chat" }
      end,
      input_edit = function(opts)
        assert(not f.focused, "Focused overlay still covers input")
        eq(opts.start, #f.draft)
        eq(opts.stop, #f.draft)
        eq(opts.version, 17)
        eq(opts.session_id, "current-chat")
        f.edits[#f.edits + 1] = opts
        if f.notscreen and #f.edits <= f.notscreen then
          return nil, "the chat input is not on screen, so it cannot be edited"
        end
        if f.submit_throw then
          error("input panic")
        end
        if f.submit_fail then
          return nil, "input unavailable"
        end
        f.draft = f.draft .. opts.text
        return true
      end,
      action = function()
        error("must not auto-send")
      end,
      open_editor = function(path)
        f.editor_paths = f.editor_paths or {}
        f.editor_paths[#f.editor_paths + 1] = path
        if f.edit then
          f.edit(path)
        end
        if f.editor_error then
          error(f.editor_error)
        end
        return f.editor_code or 0
      end,
      terminal_size = function()
        return { cols = f.size.cols, rows = f.size.rows }
      end,
      theme_color = function()
        return "#202020"
      end,
      highlight = function()
        return nil
      end,
      flash = function(text)
        f.flashes[#f.flashes + 1] = text
      end,
      buf = function()
        return {
          content = {},
          set_calls = 0,
          set_lines = function(self, lines)
            self.set_calls = self.set_calls + 1
            for _, row in ipairs(lines) do
              for _, span in ipairs(row) do
                eq(Utils.sanitize_utf8(span[1]), span[1])
              end
            end
            self.content = lines
          end,
        }
      end,
      open_win = function(buf, opts)
        if f.open_error and #f.windows == 1 then
          error("window unavailable")
        end
        local function dimension(value, total)
          if type(value) == "string" then
            return math.max(2, math.floor(total * tonumber(value:match("^(%d+)%%$")) / 100))
          end
          return value
        end
        local win = {
          buf = buf,
          opts = opts,
          width = dimension(opts.width, f.size.cols),
          height = dimension(opts.height, f.size.rows),
        }
        function win:set_cursor(row)
          self.cursor = row
        end
        function win:set_config(config)
          self.config = config
        end
        function win:hide()
          self.hidden = true
        end
        function win:show()
          self.hidden = false
          if self.opts.focus then
            f.focused = self
          end
          f.last_shown = self
        end
        function win:close()
          self.closed = true
        end
        function win:recv()
          assert(not self.closed, "Cannot receive events on closed window")
          while true do
            local event = table.remove(f.queue, 1)
            if type(event) == "function" then
              event(f)
            else
              return event
            end
          end
        end
        if opts.focus then
          f.focused = win
        end
        f.windows[#f.windows + 1] = win
        return win
      end,
    },
  }
  package.preload["maki.text_input"] = function()
    return {
      new = function()
        return {
          lines = { "" },
          line = 1,
          col = 0,
          insert_text = function(self, text)
            local current = self.lines[self.line]
            local before, after = current:sub(1, self.col), current:sub(self.col + 1)
            local chunks = {}
            for chunk in (text .. "\n"):gmatch("(.-)\n") do
              chunks[#chunks + 1] = chunk
            end
            self.lines[self.line] = before .. chunks[1]
            for i = 2, #chunks do
              self.line = self.line + 1
              table.insert(self.lines, self.line, chunks[i])
            end
            self.col = #self.lines[self.line]
            self.lines[self.line] = self.lines[self.line] .. after
          end,
          value = function(self)
            return table.concat(self.lines, "\n")
          end,
          move_left = function(self)
            if self.col > 0 then
              repeat
                self.col = self.col - 1
                local byte = self.lines[self.line]:byte(self.col + 1)
                if byte < 128 or byte >= 192 then
                  break
                end
              until self.col == 0
            elseif self.line > 1 then
              self.line = self.line - 1
              self.col = #self.lines[self.line]
            end
          end,
          move_right = function(self)
            if self.col < #self.lines[self.line] then
              repeat
                self.col = self.col + 1
                local byte = self.lines[self.line]:byte(self.col + 1)
                if not byte or byte < 128 or byte >= 192 then
                  break
                end
              until self.col == #self.lines[self.line]
            elseif self.line < #self.lines then
              self.line, self.col = self.line + 1, 0
            end
          end,
          move_home = function(self)
            self.col = 0
          end,
          move_end = function(self)
            self.col = #self.lines[self.line]
          end,
          handle_key = function(self, key)
            local moves = {
              ["<Left>"] = "move_left",
              ["<Right>"] = "move_right",
              ["<Home>"] = "move_home",
              ["<End>"] = "move_end",
            }
            if moves[key] then
              self[moves[key]](self)
            elseif key == "<Up>" or key == "<Down>" then
              self.line = math.max(1, math.min(#self.lines, self.line + (key == "<Up>" and -1 or 1)))
              self.col = math.min(self.col, #self.lines[self.line])
              while self.col > 0 do
                local byte = self.lines[self.line]:byte(self.col + 1)
                if not byte or byte < 128 or byte >= 192 then
                  break
                end
                self.col = self.col - 1
              end
            elseif key == "<BS>" and self.col > 0 then
              local current, stop = self.lines[self.line], self.col
              self:move_left()
              self.lines[self.line] = current:sub(1, self.col) .. current:sub(stop + 1)
            elseif key == "<C-u>" then
              self.lines, self.line, self.col = { "" }, 1, 0
            elseif #key == 1 then
              self:insert_text(key)
            end
          end,
          render = function(self, prefix)
            f.rendered_input = { text = self:value(), line = self.line, col = self.col }
            local lines = {}
            for _, line in ipairs(self.lines) do
              lines[#lines + 1] = { { prefix .. line, "item" } }
            end
            return { lines = lines, cursor_row = self.line }
          end,
        }
      end,
    }
  end
  for name in pairs(package.loaded) do
    if name == "code" or name:match("^code%.") then
      package.loaded[name] = nil
    end
  end
  package.loaded["maki.text_input"] = nil
  f.module = require("code")
  f.module.setup()
  return f
end

return Host
