local M = {}

function M.add(store, record)
  store[#store + 1] = record
  return #store
end

function M.update(store, index, record)
  if not store[index] then return nil end
  store[index] = record
  return record
end

function M.remove(store, index)
  if not store[index] then return nil end
  return table.remove(store, index)
end

function M.list(store)
  return store
end

function M.count_for_file(store, file)
  local count = 0
  for _, record in ipairs(store) do
    if record.file == file then count = count + 1 end
  end
  return count
end

return M
