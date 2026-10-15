local errors = require('clean_copy.errors')
local M = {}

local operators = { '<=>', '->>', '!~*', '||', '&&', '::', '>=', '<=', '<>', '!=',
  ':=', '->', '<<', '>>', '~*', '!~', '?|', '?&' }

local function letter(char)
  return char ~= '' and (char:match('[%a_]') ~= nil or char:byte() >= 128)
end

local function word_char(char)
  return letter(char) or char ~= '' and char:match('[%d$]') ~= nil
end

-- Token boundaries for the locked SQL grammar, used only to recognize finite
-- dialect syntax. Actual removable comments always come from Tree-sitter.
function M.scan(source)
  local result = { tokens = {}, comments = {}, problems = {} }
  local cursor = 1
  local function add(kind, first, finish, extra)
    local token = { kind = kind, start = first - 1, finish = finish - 1,
      text = source:sub(first, finish - 1) }
    if kind == 'word' then token.lower = token.text:lower() end
    for key, value in pairs(extra or {}) do token[key] = value end
    local destination = kind == 'comment' and result.comments or result.tokens
    destination[#destination + 1] = token
    cursor = finish
  end
  local function problem(first, message, finish)
    result.problems[#result.problems + 1] = { start = first - 1, finish = finish or #source, message = message }
  end
  while cursor <= #source do
    local first, char, pair = cursor, source:sub(cursor, cursor), source:sub(cursor, cursor + 1)
    if char:match('%s') then cursor = cursor + 1
    elseif pair == '--' or char == '#' then
      local finish = source:find('\n', cursor + 1, true) or (#source + 1)
      if char == '#' then problem(first, 'MySQL hash comments are not supported by this SQL parser', finish - 1) end
      add('comment', first, finish)
    elseif pair == '/*' then
      local depth, nested = 1, false
      cursor = cursor + 2
      while cursor <= #source and depth > 0 do
        pair = source:sub(cursor, cursor + 1)
        if pair == '/*' then depth, nested, cursor = depth + 1, true, cursor + 2
        elseif pair == '*/' then depth, cursor = depth - 1, cursor + 2
        else cursor = cursor + 1 end
      end
      if nested then problem(first, 'nested SQL block comments are not supported by this SQL parser', cursor - 1) end
      if depth > 0 then problem(first, 'unterminated SQL block comment') end
      add('comment', first, cursor, { closed = depth == 0 })
    elseif char == "'" or char == '"' or char == '`' then
      local previous = result.tokens[#result.tokens]
      local escape = char == "'" and previous and previous.kind == 'word'
        and previous.lower == 'e' and previous.finish == first - 1
      local closed = false
      cursor = cursor + 1
      while cursor <= #source do
        local next_char = source:sub(cursor, cursor)
        if escape and next_char == '\\' then
          cursor = cursor + 2
        elseif next_char == char then
          if char == "'" and source:sub(cursor + 1, cursor + 1) == char then cursor = cursor + 2
          else cursor, closed = cursor + 1, true; break end
        else cursor = cursor + 1 end
      end
      if not closed then problem(first, 'unterminated SQL quoted token') end
      add(char == "'" and 'string' or 'quoted', first, cursor, { quote = char, closed = closed })
    elseif char == '$' then
      -- The grammar's external scanner permits any non-whitespace tag. Match
      -- its boundary conservatively rather than interpreting code inside it.
      local tag = source:sub(cursor):match('^%$[^%s$]*%$')
      if tag then
        local finish = source:find(tag, cursor + #tag, true)
        if not finish then problem(first, 'unterminated SQL dollar-quoted string') end
        add('string', first, finish and finish + #tag or #source + 1, { quote = tag, closed = finish ~= nil })
      else add('symbol', first, first + 1) end
    elseif letter(char) then
      cursor = cursor + 1
      while word_char(source:sub(cursor, cursor)) do cursor = cursor + 1 end
      add('word', first, cursor)
    elseif char:match('%d') or char == '.' and source:sub(cursor + 1, cursor + 1):match('%d') then
      local rest = source:sub(cursor)
      local number = rest:match('^0[xX][%x_]+') or rest:match('^0[bB][01_]+')
        or rest:match('^0[oO][0-7_]+') or rest:match('^%d[%d_]*%.?[%d_]*[eE][+-]?[%d_]+')
        or rest:match('^%d[%d_]*%.[%d_]*') or rest:match('^%.%d[%d_]*') or rest:match('^%d[%d_]*')
      add('number', first, first + #number)
    else
      local operator
      for _, candidate in ipairs(operators) do
        if source:sub(cursor, cursor + #candidate - 1) == candidate then operator = candidate; break end
      end
      add('symbol', first, first + #(operator or char))
    end
  end
  return result
end

function M.apply(source, changes)
  local ordered, pieces, cursor = {}, {}, 1
  for _, change in ipairs(changes) do ordered[#ordered + 1] = change end
  table.sort(ordered, function(a, b) return a.start < b.start end)
  for _, change in ipairs(ordered) do
    if change.start < cursor - 1 or change.finish <= change.start or change.finish > #source then
      errors.raise('SYNTAX', 'parser', 'ambiguous or overlapping SQL dialect tokens', {
        context = { language = 'sql', byte = change.start + 1 },
        hint = 'Check the SQL syntax and quoted-token boundaries before copying.',
      })
    end
    local original = source:sub(change.start + 1, change.finish)
    local replacement = change.text or original:gsub('[^\r\n]', ' ')
    if #replacement ~= #original or replacement:gsub('[^\r\n]', ' ') ~= original:gsub('[^\r\n]', ' ') then
      errors.raise('INTERNAL', 'parser', 'SQL dialect adaptation changed source coordinates', {
        hint = 'Report this input and keep the original buffer; no registers have been written.',
      })
    end
    pieces[#pieces + 1], pieces[#pieces + 2] = source:sub(cursor, change.start), replacement
    cursor = change.finish + 1
  end
  pieces[#pieces + 1] = source:sub(cursor)
  return table.concat(pieces)
end

function M.validate_layout(original, view)
  if #original ~= #view or original:gsub('[^\r\n]', ' ') ~= view:gsub('[^\r\n]', ' ') then
    errors.raise('INTERNAL', 'parser', 'SQL dialect adaptation changed source coordinates', {
      hint = 'Report this input and keep the original buffer; no registers have been written.',
    })
  end
end

return M
