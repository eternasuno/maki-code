local M = {}

function M.highlight_file(path, lines)
  if #lines == 0 or not maki or not maki.ui or not maki.ui.highlight then
    return nil
  end
  local lang = path:match("%.([%w_]+)$") or path:match("([^/]+)$") or ""
  local languages = {
    ts = "typescript",
    tsx = "tsx",
    js = "javascript",
    jsx = "jsx",
    py = "python",
    rs = "rust",
    sh = "bash",
    yml = "yaml",
    md = "markdown",
    h = "c",
    cc = "cpp",
    hpp = "cpp",
    cs = "csharp",
    rb = "ruby",
    Dockerfile = "dockerfile",
    Makefile = "make",
  }
  lang = languages[lang] or lang
  local ok, styled = pcall(maki.ui.highlight, table.concat(lines, "\n"), lang, { independent = true })
  if not ok or type(styled) ~= "table" or #styled ~= #lines then
    return nil
  end
  return styled
end

return M
