local M = {}
local versions = setmetatable({}, { __mode = "k" })

function M.version(store)
  return versions[store] or 0
end

local function changed(store)
  versions[store] = M.version(store) + 1
end

function M.add(store, record)
  store[#store + 1] = record
  changed(store)
  return #store
end

function M.update(store, index, record)
  if not store[index] then
    return nil
  end
  store[index] = record
  changed(store)
  return record
end

function M.remove(store, index)
  if not store[index] then
    return nil
  end
  changed(store)
  return table.remove(store, index)
end

function M.kind(record)
  return record.target and record.target.kind or "line"
end

function M.path(record)
  return record.target and record.target.path or record.file
end

function M.location(record)
  local path = M.path(record)
  local kind = M.kind(record)
  if kind == "dir" then
    return path:gsub("/+$", "") .. "/"
  end
  if kind == "file" then
    return path
  end
  local first = record.start_line or (record.anchor == "old" and record.old_start or record.new_start)
  local last = record.end_line or (record.anchor == "old" and record.old_end or record.new_end)
  if not first then
    return path .. ":?"
  end
  return path .. ":" .. tostring(first) .. (last and last ~= first and ("-" .. last) or "")
end

function M.index(store, predicate)
  local result = { by_path = {}, exact = {}, under = {} }
  for i, record in ipairs(store) do
    local path = M.path(record)
    if path and (not predicate or predicate(record)) then
      local entries = result.by_path[path]
      if not entries then
        entries = {}
        result.by_path[path] = entries
      end
      entries[#entries + 1] = { record = record, index = i }
      result.exact[path] = (result.exact[path] or 0) + 1
      result.under[path] = (result.under[path] or 0) + 1
      for slash in path:gmatch("()/") do
        local ancestor = path:sub(1, slash - 1)
        result.under[ancestor] = (result.under[ancestor] or 0) + 1
      end
    end
  end
  return result
end

return M
