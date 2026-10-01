local selection = require('clean_copy.selection')
local M = {}

local function neighbor(node, previous)
  local sibling
  if previous then sibling = node:prev_sibling() else sibling = node:next_sibling() end
  while sibling and (sibling:type() == 'comment' or sibling:type() == 'marginalia') do
    if previous then sibling = sibling:prev_sibling() else sibling = sibling:next_sibling() end
  end
  return sibling
end

local function intersects(node, snapshot, sel)
  local sr, sc, er, ec = node:range()
  return selection.offset(snapshot, sr, sc) < sel.finish
    and selection.offset(snapshot, er, ec) > sel.start
end

-- DerekStride's program grammar requires separators between top-level statements,
-- but allows a final statement without one. A missing separator can be placed
-- after trailing comment extras, inside the range used to copy a single query.
function M.unselected_separator(node, snapshot, sel)
  if not node:missing() or node:type() ~= ';' then return false end
  local parent = node:parent()
  if not parent or parent:type() ~= 'program' then return false end
  local before, after = neighbor(node, true), neighbor(node, false)
  if not before or not after or before:type() ~= 'statement' or after:type() ~= 'statement'
      or before:has_error() or after:has_error() then return false end
  -- Never exempt a batch selection, separators inside blocks, or other errors.
  return intersects(before, snapshot, sel) ~= intersects(after, snapshot, sel)
end

return M
