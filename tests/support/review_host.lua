local Host = {}
local Text = require("common.text")
local Tree = require("common.tree")
local build, flatten = Tree.build_tree, Tree.flatten

function Host.new()
  local h = {
    windows = {},
    flashes = {},
    errors = {},
    commands = {},
    autocmds = {},
    jobs = {},
    queue = {},
    edits = {},
    root = "/project root",
    paths = { "a.lua", "src/deep/b.lua", "src/deep/c.lua" },
    draft = "",
    session = "chat",
    size = { cols = 120, rows = 30 },
    counts = {},
  }
  function h:count(name)
    self.counts[name] = (self.counts[name] or 0) + 1
  end
  Tree.build_tree = function(changes)
    h:count("build")
    return build(changes)
  end
  Tree.flatten = function(tree, collapsed)
    h:count("flatten")
    return flatten(tree, collapsed)
  end
  function h:response(cmd)
    if self.git_throw then
      error("Git panic")
    end
    if self.git_fail and cmd:find(self.git_fail, 1, true) then
      return { exit_code = 1, stderr = "Git unavailable" }
    end
    local raw
    if cmd:find("rev-parse", 1, true) then
      raw = self.root .. "\n"
    elseif cmd:find("--name-status", 1, true) then
      local records = {}
      for _, path in ipairs(self.paths) do
        records[#records + 1] = "M\0" .. path .. "\0"
      end
      raw = table.concat(records)
    elseif cmd:find("--numstat", 1, true) then
      local records = {}
      for _, path in ipairs(self.paths) do
        records[#records + 1] = "2\t1\t" .. path .. "\0"
      end
      raw = table.concat(records)
    elseif cmd:find("ls-files", 1, true) then
      raw = self.untracked and self.untracked .. "\0" or ""
    elseif cmd:find(" log ", 1, true) then
      raw = "abc\0first commit\0one day ago\0def\0second commit\0two days ago\0"
    elseif cmd:find("--stat", 1, true) then
      raw = "commit abc\nAuthor: Test\n\nsummary\n"
    else
      self:count("diff")
      raw = self.raw or "diff --git a/a.lua b/a.lua\n@@ -7,2 +7,3 @@\n-old\n+new\n+extra\n context\n"
    end
    return { exit_code = cmd:find("--no-index", 1, true) and 1 or 0, stdout = raw }
  end
  maki = {
    api = {
      register_command = function(spec)
        h:count("register")
        h.commands[spec.name] = spec
      end,
      create_autocmd = function(event, spec)
        h:count("autocmd")
        h.autocmds[event] = spec.callback
      end,
    },
    log = {
      error = function(text)
        h.errors[#h.errors + 1] = text
      end,
    },
    async = {
      run = function(fn)
        fn()
      end,
      sleep = function(ms)
        assert(ms == 16)
        h:count("sleep")
        if h.focused and h.focused.closed then
          h.focused = nil
        end
        if h.on_sleep then
          h.on_sleep()
        end
      end,
    },
    fn = {
      jobstart = function(cmd)
        h.jobs[#h.jobs + 1] = cmd
        h.last_cmd = cmd
        return #h.jobs
      end,
      jobwait = function()
        return h:response(h.last_cmd)
      end,
    },
    fs = {
      metadata = function(path)
        h.edit_path = path
        if h.meta_throw then
          error("metadata panic")
        end
        if h.missing then
          return nil, "missing"
        end
        return { is_file = not h.directory }
      end,
    },
    session = {
      new = function()
        error("must not create session")
      end,
      prompt = function()
        error("must not send")
      end,
    },
    ui = {
      flash = function(text)
        h.flashes[#h.flashes + 1] = text
      end,
      terminal_size = function()
        return { cols = h.size.cols, rows = h.size.rows }
      end,
      theme_color = function()
        return "#202020"
      end,
      theme_style = function()
        return { fg = "#888888" }
      end,
      truncate_text = function(text, width)
        local head = ""
        for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
          if Text.display_len(head .. char) > width then
            break
          end
          head = head .. char
        end
        return { head = head }
      end,
      highlight = function()
        h:count("highlight")
        return nil
      end,
      open_editor = function(path)
        h.editor_path = path
        h:count("editor")
        if h.on_editor then
          h.on_editor()
        end
        if h.editor_throw then
          error("editor panic")
        end
        return h.editor_code or 0
      end,
      input = function()
        h:count("input")
        if h.input_throw then
          error("snapshot panic")
        end
        if h.input_fail or h.input_fail_at == h.counts.input then
          return nil, "snapshot unavailable"
        end
        return { text = h.draft, cursor = 0, version = 17, session_id = h.session }
      end,
      input_edit = function(opts)
        assert(not h.focused, "queued focus not released")
        assert(opts.start == #h.draft and opts.stop == #h.draft and opts.version == 17 and opts.session_id == "chat")
        h.edits[#h.edits + 1] = opts
        if h.visibility_fail and #h.edits <= h.visibility_fail then
          return nil, "the chat input is not on screen, so it cannot be edited"
        end
        if h.input_edit_throw then
          error("edit panic")
        end
        if h.input_edit_fail then
          return nil, "edit unavailable"
        end
        h.draft = h.draft .. opts.text
        return true
      end,
      buf = function()
        local b = { content = {}, set_calls = 0 }
        function b:set_lines(lines)
          self.set_calls = self.set_calls + 1
          if h.render_throw and h.render_throw(self, lines) then
            error("render panic")
          end
          for _, row in ipairs(lines) do
            for _, span in ipairs(row) do
              assert(Text.sanitize_utf8(span[1]) == span[1], "invalid UTF8")
            end
          end
          self.content = lines
        end
        function b:len()
          return #self.content
        end
        return b
      end,
      open_win = function(buf, opts)
        h:count("open")
        if h.open_fail_at == h.counts.open then
          error("open panic")
        end
        local function dimension(value, total)
          if type(value) == "string" then
            return math.max(2, math.floor(total * tonumber(value:match("^(%d+)%%$")) / 100))
          end
          return value
        end
        local w = {
          buf = buf,
          opts = opts,
          width = dimension(opts.width, h.size.cols),
          height = dimension(opts.height, h.size.rows),
        }
        function w:set_cursor(row)
          self.cursor = row
        end
        function w:set_config(config)
          self.config = config
        end
        function w:close()
          self.closed = true
          h:count("close")
          if h.close_throw then
            error("close panic")
          end
        end
        function w:recv()
          if h.recv_throw then
            error("recv panic")
          end
          while true do
            local ev = table.remove(h.queue, 1)
            if type(ev) ~= "function" then
              return ev
            end
            ev(h)
          end
        end
        h.windows[#h.windows + 1] = w
        if opts.focus then
          h.focused = w
        end
        return w
      end,
    },
  }
  package.preload["maki.text_input"] = function()
    return {
      Result = { IGNORED = "ignored" },
      new = function()
        local input = { text = "", cursor = 0 }
        function input:value()
          return self.text
        end
        function input:insert_text(text)
          self.text = self.text:sub(1, self.cursor) .. text .. self.text:sub(self.cursor + 1)
          self.cursor = self.cursor + #text
        end
        function input:handle_key(key)
          if key == "<C-u>" then
            self.text, self.cursor = "", 0
          elseif key == "<Left>" then
            self.cursor = math.max(self.cursor - 1, 0)
          elseif key == "<Right>" then
            self.cursor = math.min(self.cursor + 1, #self.text)
          elseif key == "<BS>" and self.cursor > 0 then
            self.text = self.text:sub(1, self.cursor - 1) .. self.text:sub(self.cursor + 1)
            self.cursor = self.cursor - 1
          elseif #key == 1 then
            self:insert_text(key)
          else
            return "ignored"
          end
          return "changed"
        end
        function input:render(prefix)
          return { lines = { { { prefix .. self.text, "item" } } }, cursor_row = 1 }
        end
        return input
      end,
    }
  end
  for name in pairs(package.loaded) do
    if name == "review" or name:match("^review%.") or name == "maki.text_input" then
      package.loaded[name] = nil
    end
  end
  h.browser = require("review.browser")
  h.comments = require("review.comments")
  h.git = require("review.git")
  h.module = require("review")
  function h:open()
    self.state =
      self.browser.create_state(self.root, assert(self.git.changes(self.root)), assert(self.git.log(self.root)))
    self.browser.open(self.state)
    return self.state
  end
  function h:key(key)
    return self.browser.handle_event(self.state, { type = "key", key = key })
  end
  function h:paste(text)
    return self.browser.handle_event(self.state, { type = "paste", text = text })
  end
  function h:closed()
    for _, w in ipairs(self.windows) do
      assert(w.closed, "window leaked")
    end
  end
  function h:text(buf)
    local out = {}
    for _, row in ipairs(buf.content) do
      local spans = {}
      for _, span in ipairs(row) do
        spans[#spans + 1] = span[1]
      end
      out[#out + 1] = table.concat(spans)
    end
    return table.concat(out, "\n")
  end
  return h
end
return Host
