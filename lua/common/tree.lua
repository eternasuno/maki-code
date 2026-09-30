local M = {}

function M.build_tree(changes)
  local root = { dirs = {}, dorder = {}, files = {} }
  for i, ch in ipairs(changes) do
    local parts = {}
    for s in (type(ch) == "string" and ch or ch.path):gmatch("[^/]+") do
      parts[#parts + 1] = s
    end
    local node, prefix = root, ""
    for j = 1, #parts - 1 do
      prefix = prefix == "" and parts[j] or (prefix .. "/" .. parts[j])
      local d = node.dirs[parts[j]]
      if not d then
        d = { name = parts[j], path = prefix, dirs = {}, dorder = {}, files = {} }
        node.dirs[parts[j]] = d
        node.dorder[#node.dorder + 1] = d
      end
      node = d
    end
    node.files[#node.files + 1] = { name = parts[#parts], idx = i }
  end
  local function compress(node)
    for _, d in ipairs(node.dorder) do
      while #d.dorder == 1 and #d.files == 0 do
        local child = d.dorder[1]
        d.name = d.name .. "/" .. child.name
        d.path = child.path
        d.dirs = child.dirs
        d.dorder = child.dorder
        d.files = child.files
      end
      compress(d)
    end
  end
  compress(root)
  return root
end


function M.toggle_dir(collapsed, path)
  collapsed[path] = not collapsed[path] and true or nil
  return collapsed[path]
end

function M.flatten(tree, collapsed)
  collapsed = collapsed or {}
  local rows = {}
  local function walk(node, depth)
    for _, d in ipairs(node.dorder) do
      rows[#rows + 1] = { dir = d.path, name = d.name, depth = depth }
      if not collapsed[d.path] then
        walk(d, depth + 1)
      end
    end
    for _, f in ipairs(node.files) do
      rows[#rows + 1] = { idx = f.idx, name = f.name, depth = depth }
    end
  end
  walk(tree, 0)
  return rows
end

return M
