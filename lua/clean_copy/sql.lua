local selection = require('clean_copy.selection')
local errors = require('clean_copy.errors')
local lex = require('clean_copy.sql_lex')
local M = {}

local function quoted_end(text, first, quote)
  local cursor = first + 1
  while cursor <= #text do
    local char = text:sub(cursor, cursor)
    if char == '\\' then cursor = cursor + 2
    elseif char == quote then
      if text:sub(cursor + 1, cursor + 1) == quote then cursor = cursor + 2
      else return cursor + 1, true end
    else cursor = cursor + 1 end
  end
  return #text + 1, false
end

-- BI condition templates are expressions supplied by an external renderer.
-- Replace only this finite syntax in the parser's view, preserving every byte
-- coordinate. Comment capture and copied text still use the original snapshot.
-- The shared lexer protects strings/comments, including all dollar tags
-- accepted by the installed grammar. It never supplies removal ranges.
function M.parser_view(text, scanned)
  local tokens = (scanned or lex.scan(text)).tokens
  local changes, templates, index, braces = {}, {}, 1, 0
  while index <= #tokens do
    local token = tokens[index]
    if token.kind == 'symbol' and token.text == '{' then
      local rest = text:sub(token.start + 1)
      local prefix = '^%{[ \t]*[%a_][%w_]*[ \t]+%[conditions%.[%a_][%w_]*'
      local template = braces == 0 and (rest:match(prefix .. '%(number%)%][ \t]*%}')
        or rest:match(prefix .. '%][ \t]*%}'))
      if template then
        local finish = token.start + #template
        changes[#changes + 1] = { start = token.start, finish = finish,
          text = 'TRUE' .. string.rep(' ', #template - 4) }
        templates[#templates + 1] = { start = token.start, finish = finish }
        while tokens[index + 1] and tokens[index + 1].start < finish do index = index + 1 end
      else braces = braces + 1 end
    elseif token.kind == 'symbol' and token.text == '}' then braces = math.max(0, braces - 1) end
    index = index + 1
  end
  return lex.apply(text, changes), templates
end

local function position(snapshot, offset)
  for row = #snapshot.starts, 1, -1 do
    if snapshot.starts[row] <= offset then return row - 1, offset - snapshot.starts[row] end
  end
end

local function trivia(text, cursor)
  while cursor <= #text do
    local pair = text:sub(cursor, cursor + 1)
    if text:sub(cursor, cursor):match('%s') then cursor = cursor + 1
    elseif pair == '--' then cursor = text:find('\n', cursor + 2, true) or (#text + 1)
    elseif pair == '/*' then
      local finish = text:find('*/', cursor + 2, true)
      if not finish or text:sub(cursor + 2, finish - 1):find('/*', 1, true) then return nil end
      cursor = finish + 2
    else break end
  end
  return cursor
end

local function identifier(text, cursor)
  local char, finish = text:sub(cursor, cursor)
  if char == '"' or char == '`' then
    local closed
    finish, closed = quoted_end(text, cursor, char)
    if not closed then return nil end
  else
    local name = text:sub(cursor):match('^[%a_][%w_$]*')
    if not name then return nil end
    finish = cursor + #name
  end
  return { start = cursor - 1, finish = finish - 1, text = text:sub(cursor, finish - 1) }
end

local function offsets(node, snapshot)
  local sr, sc, er, ec = node:range()
  return { selection.offset(snapshot, sr, sc), selection.offset(snapshot, er, ec) }
end

local function stack(node, source)
  local reference = node and node:type() == 'invocation' and node:named_child(0)
  return reference and reference:type() == 'object_reference' and not node:has_error()
    and vim.treesitter.get_node_text(reference, source):lower() == 'stack'
end

-- Recover only a finite identifier list after an AST-confirmed stack call.
-- Expressions, strings, nested lists and incomplete/trailing-comma lists are
-- never adapted. The final tree must still confirm the SELECT/alias context.
function M.stack_alias(node, snapshot, source)
  if not stack(node, source) then return nil end
  local call = offsets(node, snapshot)
  local cursor = trivia(source, call[2] + 1)
  if not cursor or source:sub(cursor, cursor + 1):lower() ~= 'as'
      or source:sub(cursor + 2, cursor + 2):match('[%w_$]') then return nil end
  cursor = trivia(source, cursor + 2)
  if not cursor or source:sub(cursor, cursor) ~= '(' then return nil end
  local alias = { start = cursor - 1, call = call, names = {}, erase = { { cursor - 1, cursor } } }
  cursor = trivia(source, cursor + 1)
  while cursor do
    local name = identifier(source, cursor)
    if not name then return nil end
    alias.names[#alias.names + 1] = name
    if #alias.names > 1 then alias.erase[#alias.erase + 1] = { name.start, name.finish } end
    cursor = trivia(source, name.finish + 1)
    if not cursor then return nil end
    local char = source:sub(cursor, cursor)
    if char ~= ',' and char ~= ')' then return nil end
    alias.erase[#alias.erase + 1] = { cursor - 1, cursor }
    if char == ')' then alias.finish = cursor; return alias end
    cursor = trivia(source, cursor + 1)
  end
end

function M.alias_view(source, aliases, known)
  local ranges = {}
  for _, alias in ipairs(known or aliases) do ranges[#ranges + 1] = alias end
  table.sort(ranges, function(a, b) return a.start < b.start end)
  for index = 2, #ranges do
    if ranges[index].start < ranges[index - 1].finish then
      errors.raise('SYNTAX', 'parser', 'ambiguous overlapping stack column aliases', {
        context = { language = 'sql', byte = ranges[index].start + 1 },
        hint = 'Check quoted column aliases and escaping; overlapping alias lists cannot be safely adapted.',
      })
    end
  end
  local erasures, pieces, cursor = {}, {}, 1
  for _, alias in ipairs(aliases) do
    for _, erase in ipairs(alias.erase) do erasures[#erasures + 1] = erase end
  end
  table.sort(erasures, function(a, b) return a[1] < b[1] end)
  for _, erase in ipairs(erasures) do
    if erase[1] < cursor - 1 then
      errors.raise('SYNTAX', 'parser', 'ambiguous overlapping stack alias tokens', {
        context = { language = 'sql', byte = erase[1] + 1 },
        hint = 'Check the column aliases and their quoting before copying.',
      })
    end
    pieces[#pieces + 1] = source:sub(cursor, erase[1])
    -- Preserve newlines, real comments and the first identifier. Erase quoted
    -- later identifiers as whole tokens, never exposing their comment markers.
    pieces[#pieces + 1] = source:sub(erase[1] + 1, erase[2]):gsub('[^\r\n]', ' ')
    cursor = erase[2] + 1
  end
  pieces[#pieces + 1] = source:sub(cursor)
  return table.concat(pieces)
end

function M.valid_alias_names(root, source, expected)
  -- A no-error parse alone is insufficient: a dialect's quote escaping can
  -- turn part of an apparent name into another statement or a comment. Require
  -- exactly one alias node for every complete token, with no extra structure.
  if root:has_error() or root:named_child_count() ~= 1 then return false end
  local statement = root:named_child(0)
  local select = statement:named_child(0)
  if statement:type() ~= 'statement' or statement:named_child_count() ~= 1
      or not select or select:type() ~= 'select' or select:named_child_count() ~= 2 then return false end
  local expression = select:named_child(1)
  if select:named_child(0):type() ~= 'keyword_select' or expression:type() ~= 'select_expression'
      or expression:named_child_count() ~= #expected then return false end
  for index, name in ipairs(expected) do
    local term = expression:named_child(index - 1)
    local value, alias = term:field('value')[1], term:field('alias')[1]
    if term:type() ~= 'term' or term:named_child_count() ~= 3 or not value or value:type() ~= 'literal'
        or vim.treesitter.get_node_text(value, source) ~= '0'
        or term:named_child(1):type() ~= 'keyword_as' or not alias or alias:type() ~= 'identifier' then
      return false
    end
    local _, _, first, _, _, finish = alias:range(true)
    if first ~= name.start or finish ~= name.finish
        or vim.treesitter.get_node_text(alias, source) ~= name.text then return false end
  end
  return true
end

function M.validate_aliases(root, snapshot, aliases, check_names)
  for _, alias in ipairs(aliases) do
    -- Validate every applied adaptation, even outside the selection: malformed
    -- quoting could otherwise change comment scope in a later selected region.
    local first = alias.names[1]
    local sr, sc = position(snapshot, first.start)
    local er, ec = position(snapshot, first.finish)
    local node = root:descendant_for_range(sr, sc, er, ec)
    local term = node and node:parent()
    local value = term and term:field('value')[1]
    local field = term and term:field('alias')[1]
    local parent = term and term:parent()
    local valid = node and node:type() == 'identifier' and term and term:type() == 'term'
      and field and field:id() == node:id() and parent and parent:type() == 'select_expression'
      and stack(value, snapshot.text)
      and vim.deep_equal(offsets(node, snapshot), { first.start, first.finish })
      and vim.deep_equal(offsets(value, snapshot), alias.call)
    if valid then
      local terms, expected, cursor = {}, {}, #'SELECT '
      for _, name in ipairs(alias.names) do
        terms[#terms + 1] = '0 AS ' .. name.text
        expected[#expected + 1] = { start = cursor + #'0 AS ',
          finish = cursor + #'0 AS ' + #name.text, text = name.text }
        cursor = cursor + #'0 AS ' + #name.text + #', '
      end
      valid = check_names('SELECT ' .. table.concat(terms, ', ') .. ';', expected)
    end
    if not valid then
      errors.raise('SYNTAX', 'parser', string.format('invalid or unsupported stack column aliases at %d:%d',
        sr + 1, sc + 1), {
        context = { language = 'sql', row = sr + 1, col = sc + 1, node = 'stack aliases' },
        hint = 'Use AS (identifier, ...) after a direct stack(...) expression in a SELECT list; check all alias names and SQL syntax.',
      })
    end
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
