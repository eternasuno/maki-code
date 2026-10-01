local M = {}

function M.add(store, record)
  store[#store + 1] = record
  return #store
end

function M.update(store, index, record)
  if not store[index] then
    return nil
  end
  store[index] = record
  return record
end

function M.remove(store, index)
  if not store[index] then
    return nil
  end
  return table.remove(store, index)
end

function M.list(store)
  return store
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

function M.count_for_path(store, path, predicate)
  local count = 0
  for _, record in ipairs(store) do
    if M.path(record) == path and (not predicate or predicate(record)) then
      count = count + 1
    end
  end
  return count
end

function M.count_under_path(store, path, predicate)
  path = path:gsub("/+$", "")
  local prefix = path .. "/"
  local count = 0
  for _, record in ipairs(store) do
    local target_path = M.path(record)
    if target_path and (target_path == path or target_path:sub(1, #prefix) == prefix) then
      if not predicate or predicate(record) then
        count = count + 1
      end
    end
  end
  return count
end

function M.count_for_file(store, file)
  return M.count_for_path(store, file)
end

return M
