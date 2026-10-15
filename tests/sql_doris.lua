-- Synthetic dialect cases only; private local SQL fixtures are never imported.
vim.opt.runtimepath = { vim.fn.getcwd(), vim.fn.getcwd() .. '/.test/runtime', vim.env.VIMRUNTIME }
vim.o.swapfile, vim.o.clipboard = false, ''
local h = dofile('tests/helpers.lua')
local test, eq = h.test, h.eq
local doris = require('clean_copy.sql_doris')
local lexer = require('clean_copy.sql_lex')
local selection = require('clean_copy.selection')
local transform = require('clean_copy.transform')
local opts = require('clean_copy.config').resolve({ clipboard = false, register = 'a' })

local function snapshot(source)
  local lines = vim.split(source, '\n', { plain = true })
  local starts, offset = {}, 0
  for index, line in ipairs(lines) do starts[index], offset = offset, offset + #line + 1 end
  return { text = source, lines = lines, starts = starts }
end

local function prepare(source, inspect)
  local snap, parsers = snapshot(source), {}
  local function parse(text)
    local parser = vim.treesitter.get_string_parser(text, 'sql', { injections = { sql = '' } })
    parsers[#parsers + 1] = parser
    parser:parse(true)
    return parser
  end
  local ok, result = pcall(function()
    local original = lexer.scan(source)
    local view, metadata = doris.prepare(source, snap, original, parse)
    lexer.validate_layout(source, view)
    eq(lexer.scan(view).comments, original.comments)
    local root = parse(view):parse(true)[1]:root()
    assert(not root:has_error(), root:sexpr())
    assert(doris.validate(root, snap, metadata, parse))
    if inspect then return inspect(view, metadata, root, snap) end
    return view, metadata
  end)
  for _, parser in ipairs(parsers) do parser:destroy() end
  if not ok then error(result, 0) end
  return result
end

local ddl = [=[-- remove heading
CREATE TABLE `sample` (
  `day` BIGINT NULL COMMENT "date -- retained",
  payload VARCHAR(100) NULL COMMENT '/* retained metadata */'
) ENGINE=OLAP
DUPLICATE KEY(`day`)
COMMENT "table /* retained */"
PARTITION BY RANGE(`day`) (
  PARTITION p1 VALUES [("1"), ("2")),
  PARTITION p2 VALUES [("2"), ("3"))
)
DISTRIBUTED BY HASH(`day`) BUCKETS 1
PROPERTIES ("key"="-- /* retained value */", 'other'='it''s -- retained'); -- remove tail]=]

test('finite Doris CREATE validates body, references, values and original comment scopes', function()
  prepare(ddl, function(_, metadata, root, snap)
    eq(#metadata.creates, 1)
    assert(#metadata.roles > 10)
    local query = require('clean_copy.comments').load_query('sql', 'clean_copy')
    local removals = {}
    for _, node in query:iter_captures(root, snap.text, 0, -1) do
      local sr, sc, er, ec = node:range()
      removals[#removals + 1] = { selection.offset(snap, sr, sc), selection.offset(snap, er, ec) }
    end
    eq(#removals, 2)
    local output = transform.apply(snap, selection.lines(snap, 1, #snap.lines), removals, opts)
    assert(not output:find('remove', 1, true))
    for _, text in ipairs({ 'COMMENT "date -- retained"', "COMMENT '/* retained metadata */'",
        'COMMENT "table /* retained */"', '"key"="-- /* retained value */"', "'other'='it''s -- retained'" }) do
      assert(output:find(text, 1, true), output)
    end
  end)
end)

test('same-byte Doris view preserves comments between every keyword and UTF-8 byte columns', function()
  local source = 'CREATE TABLE t (id BIGINT) ENGINE=OLAP\n'
    .. 'DUPLICATE/* 中文 */KEY/* keep gap */(id)\n'
    .. 'DISTRIBUTED/* one */BY/* two */HASH/* three */(id) BUCKETS 2\n'
    .. 'PROPERTIES/* property comment */("k"="中文 -- literal");'
  prepare(source)
end)

test('qualified table, composite key and matching composite partition bounds validate', function()
  prepare([[CREATE TABLE db.t (a INT, b INT) DUPLICATE KEY(a,b)
PARTITION BY RANGE(a,b) (PARTITION p VALUES [("1","2"),("3","4")))
DISTRIBUTED BY HASH(a,b) BUCKETS 2 PROPERTIES('k'='v');]])
end)

test('ordinary SQL and Hive DDL are unchanged by the Doris adapter', function()
  for _, source in ipairs({ 'SELECT 1;', 'SHOW TABLES;',
      "CREATE TABLE t (value STRING COMMENT 'docs') PARTITIONED BY (day BIGINT) STORED AS PARQUET;" }) do
    local view, metadata = doris.prepare(source, snapshot(source), lexer.scan(source))
    eq(view, source)
    eq(#metadata.edits, 0)
    eq(#metadata.roles, 0)
  end
end)

test('native CREATE options and partition forms are never reinterpreted as Doris clauses', function()
  for _, source in ipairs({
    'CREATE TABLE t(id INT) PARTITION BY RANGE(id);',
    'CREATE TABLE t(id INT) PARTITION BY HASH(id);',
    'CREATE TABLE t(id INT) PARTITION BY RANGE(id) AS SELECT 1;',
    "CREATE TABLE t(id INT) COMMENT='docs';",
    "CREATE TABLE t(id INT) PROPERTIES='docs';",
    "CREATE TABLE t(id INT) DISTRIBUTED='x';",
    "CREATE TABLE t(id INT) COMMENT='-- /* literal */'; -- real comment",
  }) do
    prepare(source, function(view, metadata)
      eq(view, source)
      eq(#metadata.edits, 0)
      eq(#metadata.creates, 0)
    end)
  end
end)

test('native statements remain unchanged when a different statement needs Doris adaptation', function()
  local native = "CREATE TABLE native_table(id INT) COMMENT='docs' PARTITION BY RANGE(id);"
  local adapted = 'CREATE TABLE special_table(id INT) DUPLICATE KEY(id);'
  for _, source in ipairs({ native .. '\n' .. adapted, adapted .. '\n' .. native }) do
    prepare(source, function(view, metadata)
      assert(view:find(native, 1, true), view)
      eq(#metadata.creates, 1)
    end)
  end
end)

test('native statement probing is local even beside an unrelated syntax error', function()
  local native = 'CREATE TABLE t(id INT) PARTITION BY RANGE(id);'
  local source = native .. '\nSELECT * FROM;'
  local parsers = {}
  local function parse(text)
    local parser = vim.treesitter.get_string_parser(text, 'sql', { injections = { sql = '' } })
    parsers[#parsers + 1] = parser
    return parser
  end
  local view, metadata = doris.prepare(source, snapshot(source), lexer.scan(source), parse)
  eq(view, source)
  eq(#metadata.edits, 0)
  for _, parser in ipairs(parsers) do parser:destroy() end
end)

test('only SHOW ALTER TABLE COLUMN is considered for Doris adaptation', function()
  for _, source in ipairs({ 'SHOW TABLES;', 'SHOW ALL;', 'SHOW ALTER;',
      'SHOW ALTER TABLE;', 'SHOW ALTER TABLE ROLLUP;' }) do
    local view, metadata = doris.prepare(source, snapshot(source), lexer.scan(source), function()
      error('unrelated SHOW must not need an adapter parser')
    end)
    eq(view, source)
    eq(#metadata.edits, 0)
    eq(#metadata.shows, 0)
  end
end)

for _, source in ipairs({
  'CREATE TABLE t (id INT) DUPLICATE KEY();',
  'CREATE TABLE t (id INT) DUPLICATE KEY(id+1);',
  'CREATE TABLE t (id INT) DUPLICATE KEY(id,);',
  'CREATE TABLE t (id INT) DUPLICATE KEY(id) DUPLICATE KEY(id);',
  'CREATE TABLE t (id INT) DUPLICATE KEY(id) UNKNOWN data;',
  'CREATE TABLE t (id INT +) DUPLICATE KEY(id);',
  'CREATE TABLE t (id INT) DUPLICATE KEY(missing);',
  'CREATE TABLE t (id INT) DISTRIBUTED BY HASH(missing) BUCKETS 1;',
  'CREATE TABLE t (id INT) DISTRIBUTED BY HASH(id) BUCKETS 0;',
  'CREATE TABLE t (id INT) DISTRIBUTED BY HASH(id) BUCKETS 1.5;',
  'CREATE TABLE t (id INT) PROPERTIES("k"="v",SELECT * FROM);',
  'CREATE TABLE t (id INT) PROPERTIES("k"=call());',
  'CREATE TABLE t (id INT) PROPERTIES("k"="v",);',
  'CREATE TABLE t (id INT) PROPERTIES("k"="v","k"="x");',
  'CREATE TABLE t (id INT) PROPERTIES("k"  "v");',
  'CREATE TABLE t (id INT) PROPERTIES("k"="v") SELECT 1;',
  'CREATE TABLE t (id INT) PARTITION BY RANGE(id) (PARTITION p VALUES [("1"),("2")]);',
  'CREATE TABLE t (id INT) PARTITION BY RANGE(id) (PARTITION p VALUES [("1"),("2"));',
  'CREATE TABLE t (id INT) PARTITION BY RANGE(id) (PARTITION p VALUES [("1","2"),("3","4")));',
  'CREATE TABLE t (id INT) PARTITION BY RANGE(id) (PARTITION p VALUES [("1"),("2")),);',
}) do
  test('malformed Doris extension cannot be hidden: ' .. source, function()
    local ok, err = pcall(prepare, source)
    assert(not ok, source)
    if type(err) == 'table' then eq(err.code, 'SYNTAX') end
  end)
end

test('Doris SHOW ALTER keeps complete filters and supports inter-keyword comments', function()
  for _, source in ipairs({
    "SHOW ALTER TABLE COLUMN WHERE TableName='t' ORDER BY CreateTime DESC LIMIT 20;",
    'SHOW/* one */ALTER/* two */TABLE/* three */COLUMN;',
    "SHOW ALTER TABLE COLUMN FROM db WHERE (State='FINISHED' OR State='CANCELLED') AND CreateTime>='2026-01-01' ORDER BY JobId DESC, CreateTime LIMIT 0;",
  }) do
    prepare(source, function(_, metadata) eq(#metadata.shows, 1) end)
  end
end)

for _, source in ipairs({
  'SHOW ALTER TABLE COLUMN WHERE;',
  'SHOW ALTER TABLE COLUMN WHERE UnknownColumn=1;',
  'SHOW ALTER TABLE COLUMN WHERE TableName=;',
  "SHOW ALTER TABLE COLUMN WHERE TableName='t' UNION SELECT 1;",
  'SHOW ALTER TABLE COLUMN ORDER BY CreateTime,;',
  'SHOW ALTER TABLE COLUMN ORDER BY UnknownField;',
  'SHOW ALTER TABLE COLUMN LIMIT -1;',
  'SHOW ALTER TABLE COLUMN LIMIT 1.5;',
  'SHOW ALTER TABLE COLUMN LIMIT 1 WHERE State=1;',
}) do
  test('malformed Doris SHOW cannot be hidden: ' .. source, function()
    local ok, err = pcall(prepare, source)
    assert(not ok, source)
    if type(err) == 'table' then eq(err.code, 'SYNTAX') end
  end)
end

test('quote escape disagreements cannot inject extra statements through masked literals', function()
  for _, source in ipairs({
    [[CREATE TABLE t (id INT) PROPERTIES("k"="a\"-- not hidden
SELECT 1;");]],
    [[CREATE TABLE t (id INT) DUPLICATE KEY(`a\`-- not hidden
SELECT 1;);]],
    [[SHOW ALTER TABLE COLUMN WHERE TableName="a\"-- not hidden
SELECT 1;]],
  }) do
    local ok = pcall(prepare, source)
    assert(not ok, source)
  end
end)

h.finish('Doris SQL')
