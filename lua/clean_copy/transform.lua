local M = {}
function M.merge(ranges)
  -- Outer ranges come first so a JSX container owns the replacement policy of
  -- any comment nodes it contains. Keep touching ranges with different policies
  -- separate: an HTML comment beside code must not turn into a separating space.
  table.sort(ranges, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] > b[2]) end)
  local result = {}
  for _, r in ipairs(ranges) do
    local last = result[#result]
    local no_space = not not (r.no_space or r.jsx)
    if last and (r[1] < last[2] or (r[1] == last[2] and last.no_space == no_space)) then
      if r[2] > last[2] then last.no_space = last.no_space and no_space end
      last[2] = math.max(last[2], r[2])
    else result[#result + 1] = { r[1], r[2], no_space = no_space } end
  end
  return result
end
function M.apply(snapshot, selection, ranges, opts)
  ranges = M.merge(ranges)
  local output, index, boundary_index = {}, 1, 1
  local emitted, separator = false, ''
  for row = selection.first, selection.last do
    local line, base = snapshot.lines[row], snapshot.starts[row]
    local left = math.max(base, selection.start)
    local right = math.min(base + #line, selection.finish)
    local pieces, cursor, touched, no_space_touched = {}, left, false, false
    while ranges[index] and ranges[index][2] <= left do index = index + 1 end
    local covering = ranges[index]
    if left == right and covering and covering.no_space
        and covering[1] <= left and left < covering[2] then
      touched, no_space_touched = true, true
    end
    local scan = index
    while ranges[scan] and ranges[scan][1] < right do
      local a, b = math.max(left, ranges[scan][1]), math.min(right, ranges[scan][2])
      if a < b then
        pieces[#pieces + 1] = snapshot.text:sub(cursor + 1, a)
        -- A single separating space is conservative even beside punctuation.
        pieces[#pieces + 1] = ranges[scan].no_space and '' or ' '
        cursor, touched = b, true
        no_space_touched = no_space_touched or ranges[scan].no_space
      end
      scan = scan + 1
    end
    pieces[#pieces + 1] = snapshot.text:sub(cursor + 1, right)
    local cleaned = table.concat(pieces)
    -- Only complete original lines qualify. A partial selection is never a line deletion.
    -- Markup whitespace can be rendered (for example inside <pre> or with CSS
    -- white-space rules). Its outside newlines cannot qualify for line deletion.
    local remove = opts.remove_empty_comment_lines and touched and not no_space_touched and left == base
      and right == base + #line and not cleaned:find('%S')
    if not remove then
      if emitted then output[#output + 1] = separator end
      output[#output + 1] = cleaned
      emitted, separator = true, ''
    end
    if row < selection.last then
      local newline = base + #line
      while ranges[boundary_index] and ranges[boundary_index][2] <= newline do
        boundary_index = boundary_index + 1
      end
      local r = ranges[boundary_index]
      local inside = r and r[1] <= newline and newline < r[2] and r.no_space
      -- HTML/JSX comments contribute no rendered whitespace, including their
      -- internal newlines. Across removed rows retain one outside newline when
      -- present, so removing a multiline comment cannot concatenate text that
      -- was originally separated by a newline outside the comment.
      if not inside then separator = '\n' end
    end
  end
  return table.concat(output)
end
return M
