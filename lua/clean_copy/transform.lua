local M = {}
function M.merge(ranges)
  table.sort(ranges, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
  local result = {}
  for _, r in ipairs(ranges) do
    local last = result[#result]
    if last and r[1] <= last[2] then
      if r[2] > last[2] then last.jsx = last.jsx and r.jsx end
      last[2] = math.max(last[2], r[2])
    else result[#result + 1] = { r[1], r[2], jsx = r.jsx } end
  end
  return result
end
function M.apply(snapshot, selection, ranges, opts)
  ranges = M.merge(ranges)
  local output, index = {}, 1
  for row = selection.first, selection.last do
    local line, base = snapshot.lines[row], snapshot.starts[row]
    local left = math.max(base, selection.start)
    local right = math.min(base + #line, selection.finish)
    local pieces, cursor, touched = {}, left, false
    while ranges[index] and ranges[index][2] <= left do index = index + 1 end
    local scan = index
    while ranges[scan] and ranges[scan][1] < right do
      local a, b = math.max(left, ranges[scan][1]), math.min(right, ranges[scan][2])
      if a < b then
        pieces[#pieces + 1] = snapshot.text:sub(cursor + 1, a)
        -- A single separating space is conservative even beside punctuation.
        pieces[#pieces + 1] = ranges[scan].jsx and '' or ' '
        cursor, touched = b, true
      end
      scan = scan + 1
    end
    pieces[#pieces + 1] = snapshot.text:sub(cursor + 1, right)
    local cleaned = table.concat(pieces)
    -- Only complete original lines qualify. A partial selection is never a line deletion.
    local remove = opts.remove_empty_comment_lines and touched and left == base
      and right == base + #line and not cleaned:find('%S')
    if not remove then output[#output + 1] = cleaned end
  end
  return table.concat(output, '\n')
end
return M
