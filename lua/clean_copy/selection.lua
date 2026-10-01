local M = {}
function M.snapshot(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
  local starts, offset = {}, 0
  for i, line in ipairs(lines) do starts[i], offset = offset, offset + #line + 1 end
  return { lines = lines, starts = starts, text = table.concat(lines, '\n') }
end
function M.offset(snapshot, row, col)
  if row >= #snapshot.lines then return #snapshot.text end
  return snapshot.starts[row + 1] + math.min(col, #snapshot.lines[row + 1])
end
local function after_char(line, col)
  if col >= #line then return #line end
  -- Exclusive getregionpos() can end on the LAST byte of a UTF-8 character.
  while col > 0 and line:byte(col + 1) >= 128 and line:byte(col + 1) < 192 do col = col - 1 end
  local byte = line:byte(col + 1)
  local length = byte < 128 and 1 or byte < 224 and 2 or byte < 240 and 3 or 4
  return math.min(#line, col + length)
end
function M.lines(snapshot, first, last)
  if first < 1 or last > #snapshot.lines or first > last then error('invalid line range', 0) end
  return { start = snapshot.starts[first], finish = M.offset(snapshot, last - 1, #snapshot.lines[last]),
    regtype = 'V', first = first, last = last }
end
function M.current(snapshot)
  local mode = vim.fn.mode()
  if mode == '\22' then error('Visual block selection is not supported', 0) end
  if mode ~= 'v' and mode ~= 'V' then return M.lines(snapshot, 1, #snapshot.lines) end
  local regions = vim.fn.getregionpos(vim.fn.getpos('v'), vim.fn.getpos('.'),
    { type = mode, exclusive = vim.o.selection == 'exclusive', eol = true })
  if #regions == 0 then error('could not resolve Visual selection', 0) end
  local a, b = regions[1][1], regions[#regions][2]
  if mode == 'V' then return M.lines(snapshot, a[2], b[2]) end
  -- Reject virtual cells rather than guess which bytes a partial Tab represents.
  if a[4] ~= 0 or b[4] ~= 0 then error('selection inside virtual cells is not supported', 0) end
  local row, col = b[2] - 1, math.max(0, b[3] - 1)
  return { start = M.offset(snapshot, a[2] - 1, math.max(0, a[3] - 1)),
    finish = M.offset(snapshot, row, after_char(snapshot.lines[row + 1], col)),
    regtype = 'v', first = a[2], last = b[2], visual = true }
end
return M
