local selection = require('clean_copy.selection')
local errors = require('clean_copy.errors')
local M = {}

local function quoted_end(text, first, quote)
  local cursor = first + 1
  while cursor <= #text do
    local char = text:sub(cursor, cursor)
    if char == '\\' then cursor = cursor + 2
    elseif char == quote then
      if text:sub(cursor + 1, cursor + 1) == quote then cursor = cursor + 2
      else return cursor + 1 end
    else cursor = cursor + 1 end
  end
  return #text + 1
end

-- BI condition templates are expressions supplied by an external renderer.
-- Replace only this finite syntax in the parser's view, preserving every byte
-- coordinate. Comment capture and copied text still use the original snapshot.
-- This scanner only protects lexical boundaries; it never removes comments.
function M.parser_view(text)
  local pieces, templates, cursor, first, braces = {}, {}, 1, 1, 0
  while cursor <= #text do
    local char, pair = text:sub(cursor, cursor), text:sub(cursor, cursor + 1)
    if char == "'" or char == '"' or char == '`' then
      cursor = quoted_end(text, cursor, char)
    elseif pair == '--' or char == '#' then
      cursor = text:find('\n', cursor + 1, true) or (#text + 1)
    elseif pair == '/*' then
      local depth = 1
      cursor = cursor + 2
      while cursor <= #text and depth > 0 do
        pair = text:sub(cursor, cursor + 1)
        if pair == '/*' then depth, cursor = depth + 1, cursor + 2
        elseif pair == '*/' then depth, cursor = depth - 1, cursor + 2
        else cursor = cursor + 1 end
      end
    elseif char == '$' then
      local rest = text:sub(cursor)
      local tag = rest:match('^%$[%a_][%w_]*%$') or rest:match('^%$%$')
      local finish = tag and text:find(tag, cursor + #tag, true)
      cursor = tag and (finish and finish + #tag or #text + 1) or cursor + 1
    elseif char == '{' then
      local rest = text:sub(cursor)
      local prefix = '^%{[ \t]*[%a_][%w_]*[ \t]+%[conditions%.[%a_][%w_]*'
      local template = braces == 0 and (rest:match(prefix .. '%(number%)%][ \t]*%}')
        or rest:match(prefix .. '%][ \t]*%}'))
      if template then
        pieces[#pieces + 1] = text:sub(first, cursor - 1)
        pieces[#pieces + 1] = 'TRUE' .. string.rep(' ', #template - 4)
        templates[#templates + 1] = { start = cursor - 1, finish = cursor - 1 + #template }
        cursor, first = cursor + #template, cursor + #template
      else braces, cursor = braces + 1, cursor + 1 end
    elseif char == '}' then braces, cursor = math.max(0, braces - 1), cursor + 1
    else cursor = cursor + 1 end
  end
  if #templates == 0 then return text, templates end
  pieces[#pieces + 1] = text:sub(first)
  return table.concat(pieces), templates
end

local function position(snapshot, offset)
  for row = #snapshot.starts, 1, -1 do
    if snapshot.starts[row] <= offset then return row - 1, offset - snapshot.starts[row] end
  end
end

local function predicate(node)
  while node do
    local parent = node:parent()
    if not parent then return false end
    local kind = parent:type()
    if kind == 'where' or kind == 'join' then
      local expression = parent:field('predicate')[1]
      return expression ~= nil and expression:id() == node:id()
    elseif kind == 'having' then
      local expression = parent:named_child(parent:named_child_count() - 1)
      return expression ~= nil and expression:id() == node:id()
    elseif kind == 'binary_expression' or kind == 'unary_expression' then
      local operator = parent:field('operator')[1]
      local name = operator and operator:type()
      if not (kind == 'binary_expression' and (name == 'keyword_and' or name == 'keyword_or')
          or kind == 'unary_expression' and name == 'keyword_not') then return false end
    elseif kind ~= 'parenthesized_expression' then return false end
    node = parent
  end
  return false
end

function M.validate_templates(root, snapshot, templates, sel)
  for _, template in ipairs(templates) do
    if template.start < sel.finish and template.finish > sel.start then
      local row, col = position(snapshot, template.start)
      local node = root:descendant_for_range(row, col, row, col + 4)
      if node and node:type() == 'keyword_true' then node = node:parent() end
      local valid = node and node:type() == 'literal'
      if valid then
        local sr, sc, er, ec = node:range()
        valid = sr == row and sc == col and er == row and ec == col + 4 and predicate(node)
      end
      if not valid then
        errors.raise('SYNTAX', 'parser', string.format('SQL condition template is not a boolean predicate at %d:%d',
          row + 1, col + 1), {
          context = { language = 'sql', row = row + 1, col = col + 1, node = 'condition template' },
          hint = 'Use condition templates only in WHERE, HAVING or JOIN ON, joined with AND/OR/NOT or parentheses.',
        })
      end
    end
  end
end

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
