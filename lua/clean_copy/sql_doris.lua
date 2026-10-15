local errors = require('clean_copy.errors')
local selection = require('clean_copy.selection')
local lexer = require('clean_copy.sql_lex')
local M = {}

local function position(snapshot, offset)
  for row = #snapshot.starts, 1, -1 do
    if snapshot.starts[row] <= offset then return row, offset - snapshot.starts[row] + 1 end
  end
  return 1, 1
end

local function invalid(snapshot, token, message)
  local row, col = position(snapshot, token and token.start or #snapshot.text)
  errors.raise('SYNTAX', 'parser', message, {
    context = { language = 'sql', dialect = 'Doris', row = row, col = col },
    hint = 'Check the complete Doris clause, its quoting and delimiters before copying.',
  })
end

local function name(text)
  local quote = text:sub(1, 1)
  if quote == '`' or quote == '"' then text = text:sub(2, -2):gsub(quote .. quote, quote) end
  return text:lower()
end

local function is_identifier(token)
  return token and (token.kind == 'word' or token.kind == 'quoted'
    and (token.text:sub(1, 1) == '`' or token.text:sub(1, 1) == '"'))
end

local function is_literal(token)
  local quote = token and token.text:sub(1, 1)
  return token and (token.kind == 'number' or (token.kind == 'string' or token.kind == 'quoted')
    and (quote == "'" or quote == '"'))
end

local function reader(tokens, first, last, snapshot, metadata)
  local r = { index = first, last = last }
  function r.peek(value)
    local token = tokens[r.index]
    if r.index > last then return nil end
    if value then return token and (token.lower or token.text) == value end
    return token
  end
  function r.take(value)
    if not r.peek(value) then invalid(snapshot, r.peek(), 'invalid or incomplete Doris clause; expected ' .. value) end
    local token = tokens[r.index]
    r.index = r.index + 1
    return token
  end
  function r.role(role)
    local token = r.peek()
    if not (role == 'identifier' and is_identifier(token) or role == 'literal' and is_literal(token)) then
      invalid(snapshot, token, 'expected a complete Doris ' .. role .. ' token')
    end
    r.index = r.index + 1
    metadata.roles[#metadata.roles + 1] = {
      start = token.start, finish = token.finish, text = token.text, role = role,
    }
    return token
  end
  function r.ids()
    local result = {}
    r.take('(')
    repeat
      result[#result + 1] = r.role('identifier')
      if not r.peek(',') then break end
      r.take(',')
    until false
    r.take(')')
    return result
  end
  return r
end

local function mask(metadata, token, replacement)
  metadata.edits[#metadata.edits + 1] = {
    start = token.start, finish = token.finish, text = replacement,
  }
end

local function create(tokens, first, last, snapshot, metadata)
  local r = reader(tokens, first, last, snapshot, metadata)
  r.take('create'); r.take('table')
  if r.peek('if') then r.take('if'); r.take('not'); r.take('exists') end
  if not is_identifier(r.peek()) then return end
  r.index = r.index + 1
  while r.peek('.') do
    r.take('.')
    if not is_identifier(r.peek()) then return end
    r.index = r.index + 1
  end
  if not r.peek('(') then return end
  local opening, depth = r.peek(), 0
  repeat
    local token = r.peek()
    if not token then return end
    if token.text == '(' then depth = depth + 1
    elseif token.text == ')' then depth = depth - 1 end
    r.index = r.index + 1
  until depth == 0
  local closing = tokens[r.index - 1]
  if r.peek('engine') then
    r.take('engine'); r.take('=')
    -- Other CREATE forms belong to the general parser, not this finite adapter.
    if not r.peek('olap') then return end
    r.take('olap')
  end
  local extension = r.index
  local known = { duplicate = true, comment = true, partition = true, distributed = true, properties = true }
  local next_token = r.peek()
  if not next_token or not known[next_token.lower] then return end
  local item = { start = tokens[first].start, body_start = opening.start, body_finish = closing.finish,
    references = {}, partitions = {}, kind = 'create' }
  local function references(list)
    for _, token in ipairs(list) do item.references[#item.references + 1] = token end
    return list
  end
  if r.peek('duplicate') then r.take('duplicate'); r.take('key'); references(r.ids()) end
  if r.peek('comment') then
    r.take('comment')
    local token = r.role('literal')
    if token.kind == 'number' then invalid(snapshot, token, 'Doris COMMENT requires a quoted string') end
  end
  if r.peek('partition') then
    r.take('partition'); r.take('by'); r.take('range')
    local keys = references(r.ids())
    r.take('(')
    repeat
      r.take('partition')
      local partition = r.role('identifier')
      if item.partitions[name(partition.text)] then invalid(snapshot, partition, 'duplicate Doris partition name') end
      item.partitions[name(partition.text)] = true
      r.take('values'); r.take('[')
      for bound = 1, 2 do
        r.take('(')
        local count = 0
        repeat
          r.role('literal'); count = count + 1
          if not r.peek(',') then break end
          r.take(',')
        until false
        r.take(')')
        if count ~= #keys then invalid(snapshot, partition, 'Doris partition bound does not match the partition column count') end
        if bound == 1 then r.take(',') end
      end
      r.take(')') -- Exclusive upper bound in VALUES [(lower), (upper)).
      if not r.peek(',') then break end
      r.take(',')
    until false
    r.take(')')
  end
  if r.peek('distributed') then
    r.take('distributed'); r.take('by'); r.take('hash'); references(r.ids())
    if r.peek('buckets') then
      r.take('buckets')
      local bucket = r.role('literal')
      if bucket.kind ~= 'number' or not bucket.text:match('^%d+$') or tonumber(bucket.text) < 1 then
        invalid(snapshot, bucket, 'Doris BUCKETS requires a positive integer')
      end
    end
  end
  if r.peek('properties') then
    r.take('properties'); r.take('(')
    local properties = {}
    repeat
      local key = r.role('literal')
      if key.kind == 'number' then invalid(snapshot, key, 'Doris PROPERTIES requires quoted keys') end
      if properties[key.text] then invalid(snapshot, key, 'duplicate Doris property key') end
      properties[key.text] = true
      r.take('=')
      local value = r.role('literal')
      if value.kind == 'number' then invalid(snapshot, value, 'Doris PROPERTIES requires quoted values') end
      if not r.peek(',') then break end
      r.take(',')
    until false
    r.take(')')
  end
  if r.index <= last then invalid(snapshot, r.peek(), 'unexpected or out-of-order Doris CREATE clause') end
  for index = extension, last do mask(metadata, tokens[index]) end
  metadata.creates[#metadata.creates + 1] = item
end

local filter_fields = { tablename = true, createtime = true, finishtime = true, finishedtime = true, state = true }
local order_fields = { jobid = true, tablename = true, createtime = true, finishedtime = true,
  indexname = true, indexid = true, originindexid = true, schemaversion = true, transactionid = true,
  state = true, msg = true, progress = true, timeout = true }

local function show(tokens, first, last, snapshot, metadata)
  local r = reader(tokens, first, last, snapshot, metadata)
  local opening, alter = r.take('show'), r.take('alter')
  r.take('table'); r.take('column')
  if r.peek('from') then r.take('from'); r.role('identifier') end
  local suffix = r.index
  local function field(allowed)
    local token = r.role('identifier')
    if not allowed[name(token.text)] then invalid(snapshot, token, 'unsupported field in Doris SHOW ALTER clause') end
  end
  local expression
  local function atom(depth)
    if depth > 64 then invalid(snapshot, r.peek(), 'Doris SHOW predicate nesting is too deep') end
    if r.peek('not') then r.take('not'); atom(depth + 1)
    elseif r.peek('(') then r.take('('); expression(depth + 1); r.take(')')
    else
      field(filter_fields)
      local token = r.peek()
      local op = token and (token.lower or token.text)
      if not ({ ['='] = true, ['<'] = true, ['>'] = true, ['<='] = true,
          ['>='] = true, ['<>'] = true, ['!='] = true, like = true })[op] then
        invalid(snapshot, token, 'expected a comparison in Doris SHOW ALTER WHERE')
      end
      r.index = r.index + 1
      if (op == '<' or op == '>') and r.peek('=') or op == '<' and r.peek('>') then r.index = r.index + 1 end
      r.role('literal')
    end
  end
  expression = function(depth)
    atom(depth)
    while r.peek('and') or r.peek('or') do r.index = r.index + 1; atom(depth) end
  end
  if r.peek('where') then r.take('where'); expression(1) end
  if r.peek('order') then
    r.take('order'); r.take('by')
    repeat
      field(order_fields)
      if r.peek('asc') or r.peek('desc') then r.index = r.index + 1 end
      if not r.peek(',') then break end
      r.take(',')
    until false
  end
  if r.peek('limit') then
    r.take('limit')
    local limit = r.role('literal')
    if limit.kind ~= 'number' or not limit.text:match('^%d+$') then
      invalid(snapshot, limit, 'Doris SHOW LIMIT requires a nonnegative integer')
    end
  end
  if r.index <= last then invalid(snapshot, r.peek(), 'unexpected or out-of-order Doris SHOW ALTER clause') end
  local check = { 'SELECT 0 FROM _clean_copy_doris' }
  for index = suffix, last do check[#check + 1] = tokens[index].text end
  metadata.shows[#metadata.shows + 1] = {
    start = opening.start, alter = alter.start, equals = tokens[first + 2].start,
    value_start = tokens[last].finish - 1, finish = tokens[last].finish,
    query = table.concat(check, ' ') .. ';',
  }
  -- SET a = 0 fits the existing words even with comments between every keyword.
  -- The final marker ends at the last original token, retaining statement bounds.
  -- The original SHOW clauses are checked independently, never silently ignored.
  for index = first, last do
    local replacement = index == first and 'SET ' or index == first + 1 and 'a    '
      or index == first + 2 and '=    ' or nil
    if index == last then replacement = tokens[index].text:gsub('[^\r\n]', ' '):sub(1, -2) .. '0' end
    mask(metadata, tokens[index], replacement)
  end
end

local function native_statement(source, tokens, first, last, parse)
  if not parse then return false end
  -- Check each complete original statement independently. A different statement's
  -- dialect error must not cause us to reinterpret syntax the parser understands.
  local statement_source = source:sub(tokens[first].start + 1, tokens[last].finish) .. ';'
  local tree = parse(statement_source):parse(true)[1]
  if not tree or tree:root():has_error() then return false end
  local count = 0
  for child in tree:root():iter_children() do
    if child:named() and child:type() ~= 'comment' and child:type() ~= 'marginalia' then
      if child:type() ~= 'statement' then return false end
      count = count + 1
    end
  end
  return count == 1
end

function M.prepare(source, snapshot, lexed, parse)
  local metadata = { creates = {}, shows = {}, roles = {}, edits = {} }
  local tokens, first = lexed.tokens, 1
  for index = 1, #tokens + 1 do
    if index == #tokens + 1 or tokens[index].text == ';' then
      local last = index - 1
      if first <= last then
        local a, b = tokens[first], tokens[first + 1]
        local is_create = a.lower == 'create' and b and b.lower == 'table'
        local is_show = first + 3 <= last and a.lower == 'show' and b and b.lower == 'alter'
          and tokens[first + 2].lower == 'table' and tokens[first + 3].lower == 'column'
        if is_create and not native_statement(source, tokens, first, last, parse) then
          create(tokens, first, last, snapshot, metadata)
        elseif is_show and not native_statement(source, tokens, first, last, parse) then
          show(tokens, first, last, snapshot, metadata)
        end
      end
      first = index + 1
    end
  end
  return lexer.apply(source, metadata.edits), metadata
end

local function offsets(node, snapshot)
  local sr, sc, er, ec = node:range()
  return selection.offset(snapshot, sr, sc), selection.offset(snapshot, er, ec)
end

local function find(root, kind, first, snapshot)
  local stack = { root }
  while #stack > 0 do
    local node = table.remove(stack)
    if node:type() == kind and offsets(node, snapshot) == first then return node end
    for child in node:iter_children() do stack[#stack + 1] = child end
  end
end

local function strict_role(token, parse)
  local prefix = token.role == 'identifier' and 'SELECT 0 AS ' or 'SELECT '
  local source = prefix .. token.text .. ';'
  local tree = parse(source):parse(true)[1]
  local root = tree and tree:root()
  if not root or root:has_error() or root:named_child_count() ~= 1 then return false end
  local statement = root:named_child(0)
  local select = statement and statement:named_child(0)
  local expression = select and select:named_child(1)
  local term = expression and expression:named_child(0)
  if statement:type() ~= 'statement' or statement:named_child_count() ~= 1
      or not select or select:type() ~= 'select' or select:named_child_count() ~= 2
      or not expression or expression:type() ~= 'select_expression' or expression:named_child_count() ~= 1
      or not term or term:type() ~= 'term' then return false end
  local node
  if token.role == 'identifier' then
    node = term:field('alias')[1]
    local value = term:field('value')[1]
    if term:named_child_count() ~= 3 or not value or value:type() ~= 'literal'
        or vim.treesitter.get_node_text(value, source) ~= '0'
        or term:named_child(1):type() ~= 'keyword_as' then return false end
  else
    node = term:field('value')[1]
    if term:named_child_count() ~= 1 then return false end
  end
  if not node or node:type() ~= (token.role == 'identifier' and 'identifier' or 'literal') then return false end
  local _, _, first, _, _, finish = node:range(true)
  return first == #prefix and finish == #prefix + #token.text
    and vim.treesitter.get_node_text(node, source) == token.text
end

function M.validate(root, snapshot, metadata, parse)
  for _, token in ipairs(metadata.roles) do
    if not strict_role(token, parse) then
      invalid(snapshot, token, 'Doris ' .. token.role .. ' does not have an unambiguous SQL token boundary')
    end
  end
  for _, item in ipairs(metadata.creates) do
    local node = find(root, 'create_table', item.start, snapshot)
    local definitions
    if node then
      for child in node:iter_children() do if child:type() == 'column_definitions' then definitions = child end end
    end
    if not node or node:has_error() or not definitions then invalid(snapshot, item, 'invalid Doris CREATE table body') end
    local first, finish = offsets(definitions, snapshot)
    if first ~= item.body_start or finish ~= item.body_finish then
      invalid(snapshot, item, 'Doris CREATE column boundaries do not match the complete SQL body')
    end
    local declared = {}
    for child in definitions:iter_children() do
      if child:type() == 'column_definition' then
        local identifier = child:field('name')[1]
        if identifier then declared[name(vim.treesitter.get_node_text(identifier, snapshot.text))] = true end
      end
    end
    for _, token in ipairs(item.references) do
      if not declared[name(token.text)] then invalid(snapshot, token, 'Doris key, partition or hash column is not declared in the table') end
    end
  end
  for _, item in ipairs(metadata.shows) do
    local node = find(root, 'set_statement', item.start, snapshot)
    if not node or node:has_error() then invalid(snapshot, item, 'invalid Doris SHOW ALTER statement boundary') end
    local fields = {}
    for child in node:iter_children() do
      if child:named() and child:type() ~= 'comment' and child:type() ~= 'marginalia' then fields[#fields + 1] = child end
    end
    if #fields ~= 3 or fields[1]:type() ~= 'keyword_set' or fields[2]:type() ~= 'object_reference'
        or fields[3]:type() ~= 'literal' then invalid(snapshot, item, 'invalid Doris SHOW ALTER validation anchor') end
    local key_start, key_finish = offsets(fields[2], snapshot)
    local value_start, value_finish = offsets(fields[3], snapshot)
    local first, finish = offsets(node, snapshot)
    if key_start ~= item.alter or key_finish ~= item.alter + 1
        or value_start ~= item.value_start or value_finish ~= item.finish
        or first ~= item.start or finish ~= item.finish then
      invalid(snapshot, item, 'Doris SHOW ALTER token boundaries changed during validation')
    end
    local tree = parse(item.query):parse(true)[1]
    if not tree or tree:root():has_error() or tree:root():named_child_count() ~= 1 then
      invalid(snapshot, item, 'invalid Doris SHOW ALTER filter, ordering or limit')
    end
  end
  return true
end

return M
