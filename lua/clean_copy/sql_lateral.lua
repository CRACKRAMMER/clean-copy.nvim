local lex = require('clean_copy.sql_lex')
local sql = require('clean_copy.sql')
local errors = require('clean_copy.errors')
local M = {}

local function word(token, name)
  return token and token.kind == 'word' and token.lower == name
end
local function name(token)
  return token and (token.kind == 'word' or token.kind == 'quoted')
end
local function symbol(token, value)
  return token and token.kind == 'symbol' and token.text == value
end
local function close(tokens, first)
  local depth = 0
  for index = first, #tokens do
    if symbol(tokens[index], '(') then depth = depth + 1 end
    if symbol(tokens[index], ')') then
      depth = depth - 1
      if depth == 0 then return index end
    end
    if symbol(tokens[index], ';') then return nil end
  end
end
local boundary = { lateral = true, where = true, group = true, having = true, window = true,
  order = true, limit = true, union = true, intersect = true, except = true,
  join = true, inner = true, left = true, right = true, full = true, cross = true }

function M.prepare(source, snapshot, scanned, parse)
  local tokens, changes, metadata = scanned.tokens, {}, {}
  if parse then
    local native, seen = true, false
    parse(source):for_each_tree(function(tree)
      seen = true
      if tree:root():has_error() then native = false end
    end)
    if seen and native then return source, metadata end
  end
  for index, token in ipairs(tokens) do
    if word(token, 'lateral') and word(tokens[index + 1], 'view')
        and word(tokens[index + 2], 'explode') and symbol(tokens[index + 3], '(')
        and word(tokens[index + 4], 'array') and symbol(tokens[index + 5], '(') then
      local array_end = close(tokens, index + 5)
      if array_end and symbol(tokens[array_end + 1], ')') and name(tokens[array_end + 2])
          and word(tokens[array_end + 3], 'as') and name(tokens[array_end + 4]) then
        local after = tokens[array_end + 5]
        if not after or symbol(after, ')') or symbol(after, ';') or boundary[after.lower] then
          local item = { lateral = token, view = tokens[index + 1], explode = tokens[index + 2],
            array = tokens[index + 4], array_end = tokens[array_end], call_end = tokens[array_end + 1],
            table_alias = tokens[array_end + 2], as = tokens[array_end + 3], column_alias = tokens[array_end + 4] }
          metadata[#metadata + 1] = item
          changes[#changes + 1] = { start = token.start, finish = token.finish, text = 'CROSS  ' }
          changes[#changes + 1] = { start = item.view.start, finish = item.view.finish, text = 'JOIN' }
          changes[#changes + 1] = { start = item.array.start, finish = item.array.finish, text = 'ary  ' }
          changes[#changes + 1] = { start = item.as.start, finish = item.as.finish }
          changes[#changes + 1] = { start = item.column_alias.start, finish = item.column_alias.finish }
        end
      end
    end
  end
  return lex.apply(source, changes), metadata
end

local function position(snapshot, offset)
  for row = #snapshot.starts, 1, -1 do
    if snapshot.starts[row] <= offset then return row - 1, offset - snapshot.starts[row] end
  end
end
local function exact(node, first, finish)
  if not node then return false end
  local _, _, a, _, _, b = node:range(true)
  return a == first and b == finish
end
local function at(root, snapshot, first, finish)
  local sr, sc = position(snapshot, first)
  local er, ec = position(snapshot, finish)
  return root:descendant_for_range(sr, sc, er, ec)
end
local function significant(node)
  local children = {}
  if node then
    for child in node:iter_children() do
      if child:named() and child:type() ~= 'comment' and child:type() ~= 'marginalia' then
        children[#children + 1] = child
      end
    end
  end
  return children
end

function M.validate(root, snapshot, metadata, parse)
  for _, item in ipairs(metadata) do
    local invocation = at(root, snapshot, item.explode.start, item.call_end.finish)
    local relation = invocation and invocation:parent()
    local join = relation and relation:parent()
    local from = join and join:parent()
    local alias = relation and relation:field('alias')[1]
    local parameters = invocation and invocation:field('parameter') or {}
    local array = parameters[1] and parameters[1]:field('value')[1]
    local array_name = array and array:named_child(0)
    local relations, joins = significant(relation), significant(join)
    local valid = invocation and invocation:type() == 'invocation' and not invocation:has_error()
      and exact(invocation, item.explode.start, item.call_end.finish)
      and relation and relation:type() == 'relation' and #relations == 2
      and exact(alias, item.table_alias.start, item.table_alias.finish)
      and join and join:type() == 'cross_join' and #joins == 3
      and exact(joins[1], item.lateral.start, item.lateral.start + #'CROSS')
      and exact(joins[2], item.view.start, item.view.finish)
      and from and from:type() == 'from' and #parameters == 1
      and array and array:type() == 'invocation' and not array:has_error()
      and exact(array, item.array.start, item.array_end.finish)
      and exact(array_name, item.array.start, item.array.start + #'ary')
    if valid then
      local names = { item.table_alias, item.column_alias }
      local terms, expected, cursor = {}, {}, #'SELECT '
      for _, token in ipairs(names) do
        terms[#terms + 1] = '0 AS ' .. token.text
        expected[#expected + 1] = { start = cursor + #'0 AS ', finish = cursor + #'0 AS ' + #token.text,
          text = token.text }
        cursor = cursor + #'0 AS ' + #token.text + #', '
      end
      local source = 'SELECT ' .. table.concat(terms, ', ') .. ';'
      parse(source):for_each_tree(function(tree)
        if not sql.valid_alias_names(tree:root(), source, expected) then valid = false end
      end)
    end
    if not valid then
      local row, col = position(snapshot, item.lateral.start)
      errors.raise('SYNTAX', 'parser', string.format('invalid or unsupported LATERAL VIEW at %d:%d', row + 1, col + 1), {
        context = { language = 'sql', row = row + 1, col = col + 1 },
        hint = 'Use LATERAL VIEW explode(array(...)) table_alias AS column_alias in a FROM clause; check its expressions and aliases.',
      })
    end
  end
end

return M
