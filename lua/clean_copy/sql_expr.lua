local errors = require('clean_copy.errors')
local lex = require('clean_copy.sql_lex')
local M = {}

local boundaries = {}
for word in ('select from as where having on and or not when then else end group order by limit offset '
    .. 'join left right full inner outer cross union intersect except values set into insert update delete '
    .. 'create alter drop table with over partition window case between in like rlike is'):gmatch('%S+') do
  boundaries[word] = true
end
local prefix_words = {}
for word in ('select where having on and or not when then else by between like rlike'):gmatch('%S+') do
  prefix_words[word] = true
end
local prefix_symbols = {}
for _, symbol in ipairs({'(', ',', '[', '=', '<', '>', '<=', '>=', '<>', '!=', '<=>',
    '+', '-', '*', '/', '%', '||', '&', '|', '^'}) do prefix_symbols[symbol] = true end

local function lower(token)
  return token and (token.lower or token.text:lower())
end

local function expression_end(token)
  if not token then return false end
  if token.kind == 'word' then return not boundaries[lower(token)] end
  return token.kind == 'number' or token.kind == 'string' or token.kind == 'quoted'
    or token.text == ')' or token.text == ']'
end

local function expression_start(token)
  if not token then return false end
  if token.kind == 'word' then return not boundaries[lower(token)] end
  return token.kind == 'number' or token.kind == 'string' or token.kind == 'quoted'
    or token.text == '(' or token.text == '-' or token.text == '+'
    or token.text == '~' or token.text == '!'
end

-- Same-width operator surrogates let the parser inspect every original operand.
-- Nothing here removes comments or changes the text eventually copied.
function M.prepare(source, _, lexed, parse)
  local tokens, edits, metadata = lexed.tokens, {}, {}
  local native_minus = {}
  if parse then
    local roots, valid = {}, true
    parse(source):for_each_tree(function(tree)
      roots[#roots + 1] = tree:root()
      if tree:root():has_error() then valid = false end
    end)
    -- Existing valid SQL needs no expression adaptation. In recovery trees,
    -- preserve every already-confirmed binary minus, including keyword-like
    -- field names such as t.rlike - f(x).
    if valid and #roots > 0 then return source, metadata end
    for _, root in ipairs(roots) do
      local pending = {root}
      while #pending > 0 do
        local node = table.remove(pending)
        if node:type() == 'binary_expression' and not node:has_error() then
          for child in node:iter_children() do
            if child:type() == '-' then
              local _, _, first, _, _, finish = child:range(true)
              if finish == first + 1 and source:sub(first + 1, finish) == '-' then native_minus[first] = true end
            end
          end
        end
        for child in node:iter_children() do pending[#pending + 1] = child end
      end
    end
  end
  for index, token in ipairs(tokens) do
    local before, after = tokens[index - 1], tokens[index + 1]
    local kind, replacement, negation
    if token.kind == 'word' and lower(token) == 'rlike' then
      local left = before
      if before and before.kind == 'word' and lower(before) == 'not' then
        left, negation = tokens[index - 2], before
      end
      if expression_end(left) and expression_start(after) then
        kind, replacement, before = 'rlike', 'LIKE ', left
      end
    elseif token.kind == 'symbol' and token.text == '<=>' then
      kind, replacement = 'nullsafe', ' = '
    elseif token.kind == 'symbol' and token.text == '-' and not native_minus[token.start] and before and after
        and (before.kind == 'word' and prefix_words[lower(before)] or prefix_symbols[before.text])
        and (after.kind == 'word' and expression_start(after) or after.kind == 'quoted' or after.text == '(') then
      kind, replacement = 'negative', '~'
    end
    if kind then
      local item = { kind = kind, start = token.start, finish = token.finish,
        left_finish = before and before.finish, right_start = after and after.start,
        right_finish = after and after.finish }
      if negation then item.not_start, item.not_finish = negation.start, negation.finish end
      if kind == 'rlike' then item.operator_start, item.operator_finish = token.start, token.start + 4
      elseif kind == 'nullsafe' then item.operator_start, item.operator_finish = token.start + 1, token.start + 2
      else item.operator_start, item.operator_finish = token.start, token.finish end
      edits[#edits + 1] = { start = token.start, finish = token.finish, text = replacement }
      metadata[#metadata + 1] = item
    end
  end
  return lex.apply(source, edits), metadata
end

local function position(snapshot, offset)
  for row = #snapshot.starts, 1, -1 do
    if snapshot.starts[row] <= offset then return row - 1, offset - snapshot.starts[row] end
  end
end

local function offsets(node)
  local _, _, first, _, _, finish = node:range(true)
  return first, finish
end

local function exact(node, first, finish)
  if not node then return false end
  local left, right = offsets(node)
  return left == first and right == finish
end

function M.validate(root, snapshot, metadata)
  for _, item in ipairs(metadata) do
    local sr, sc = position(snapshot, item.operator_start)
    local er, ec = position(snapshot, item.operator_finish)
    local operator = root:descendant_for_range(sr, sc, er, ec)
    local expression = operator and operator:parent()
    local compound
    if item.kind == 'rlike' and expression and expression:type() == 'not_like' then
      compound, expression = expression, expression:parent()
    end
    local valid = exact(operator, item.operator_start, item.operator_finish)
      and expression and not expression:has_error() and item.right_start ~= nil
      and (item.kind == 'negative' or item.left_finish ~= nil)
    if valid and item.kind == 'negative' then
      local field = expression:field('operator')[1]
      local operand = expression:field('operand')[1]
      valid = operator:type() == 'op_unary_other' and expression:type() == 'unary_expression'
        and field and field:id() == operator:id() and operand and not operand:has_error()
      if valid then
        local first, finish = offsets(operand)
        valid = first == item.right_start and finish >= item.right_finish
          and exact(expression, item.start, finish)
      end
    elseif valid then
      local left, right = expression:field('left')[1], expression:field('right')[1]
      valid = expression:type() == 'binary_expression' and left and right
        and not left:has_error() and not right:has_error()
        and operator:type() == (item.kind == 'rlike' and 'keyword_like' or '=')
      if valid then
        local first, left_finish = offsets(left)
        local right_start, finish = offsets(right)
        valid = left_finish == item.left_finish and right_start == item.right_start
          and finish >= item.right_finish and exact(expression, first, finish)
        if item.kind == 'rlike' then
          local found = false
          for _, field in ipairs(expression:field('operator')) do
            if not item.not_start and field:id() == operator:id() then found = true end
            if compound and field:id() == compound:id() and item.not_start
                and compound:named_child_count() == 2 then
              local not_node, like_node = compound:named_child(0), compound:named_child(1)
              found = not_node:type() == 'keyword_not' and like_node:id() == operator:id()
                and exact(not_node, item.not_start, item.not_finish)
                and exact(compound, item.not_start, item.operator_finish)
            end
          end
          valid = valid and found
        end
      end
    end
    if not valid then
      errors.raise('SYNTAX', 'parser', string.format('invalid SQL %s expression at %d:%d',
        item.kind, sr + 1, sc + 1), {
        context = { language = 'sql', row = sr + 1, col = sc + 1, node = item.kind },
        hint = 'Use complete operands in an expression; check SQL syntax and dialect support.',
      })
    end
  end
end

return M
