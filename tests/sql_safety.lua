-- Independent SQL adapter safety checks. Requires the isolated SQL parser in
-- .test/runtime, but no local/business fixtures, database, compiler or provider.
vim.opt.runtimepath = { vim.fn.getcwd(), vim.fn.getcwd() .. '/.test/runtime', vim.env.VIMRUNTIME }
vim.o.swapfile, vim.o.clipboard, vim.o.shada = false, '', ''
local h = dofile('tests/helpers.lua')
local plugin = require('clean_copy')
local errors = require('clean_copy.errors')
local comments = require('clean_copy.comments')
local anchor = '-- SQL safety byte-boundary anchor'
local original_parser, original_collect = vim.treesitter.get_string_parser, comments.collect
local original_notify = errors.notify
local original_provider = vim.g.clipboard
local active, report, messages, provider_calls = nil, nil, {}, 0
local outcomes = {}

vim.g.clipboard = {
  name = 'SQL safety sentinel provider', cache_enabled = 0,
  copy = {
    ['+'] = function() provider_calls = provider_calls + 1; error('unexpected clipboard write') end,
    ['*'] = function() provider_calls = provider_calls + 1; error('unexpected clipboard write') end,
  },
  paste = {
    ['+'] = function() provider_calls = provider_calls + 1; error('unexpected clipboard read') end,
    ['*'] = function() provider_calls = provider_calls + 1; error('unexpected clipboard read') end,
  },
}
vim.notify = function(message, level) messages[#messages + 1] = { message, level } end
errors.notify = function(value, debug_enabled)
  report = value
  return original_notify(value, debug_enabled)
end

-- Observe real calls without replacing the parser, query or product adapters.
-- Name-validation scratch queries have no anchor and are deliberately separate.
vim.treesitter.get_string_parser = function(source, language, ...)
  if active and language == 'sql' and source:sub(1, #anchor) == anchor then
    active.views[#active.views + 1] = source
  end
  return original_parser(source, language, ...)
end
comments.collect = function(snapshot, selection, language, options)
  local ranges = original_collect(snapshot, selection, language, options)
  if active and language == 'sql' then
    active.removals = {}
    for _, range in ipairs(ranges) do
      -- Extract from ORIGINAL source bytes, not the adapted grammar view.
      active.removals[#active.removals + 1] = snapshot.text:sub(range[1] + 1, range[2])
    end
  end
  return ranges
end

local function breaks(text)
  local result = {}
  for byte = 1, #text do
    local char = text:sub(byte, byte)
    if char == '\r' or char == '\n' then result[#result + 1] = { byte, char } end
  end
  return result
end

local function registers()
  local result = {}
  for _, register in ipairs({ 'a', 'b', '0', '"' }) do result[register] = vim.fn.getreginfo(register) end
  return result
end

local function exercise(case)
  h.buffer(anchor .. '\n' .. case.source, 'sql')
  assert(plugin.setup({ register = 'a', clipboard = false }))
  for _, register in ipairs({ 'a', 'b', '0', '"' }) do vim.fn.setreg(register, 'sentinel ' .. register, 'v') end
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
  local source = table.concat(lines, '\n')
  local state = {
    tick = vim.api.nvim_buf_get_changedtick(buf), modified = vim.bo.modified,
    undo = vim.fn.undotree(), cursor = vim.api.nvim_win_get_cursor(win), registers = registers(),
  }
  local old_calls = provider_calls
  active, report, messages = { views = {} }, nil, {}
  if case.implicit_clipboard then vim.o.clipboard = 'unnamedplus' end
  local clipboard = vim.o.clipboard
  local command = case.range and (case.range[1] + 1) .. ',' .. (case.range[2] + 1) .. 'CopyClean' or 'CopyClean'
  local executed, reason = pcall(vim.cmd, command)
  -- Suppress implicit provider access before examining local register state.
  local resulting_clipboard = vim.o.clipboard
  vim.o.clipboard = ''
  local after_registers = registers()
  h.eq(vim.api.nvim_get_current_buf(), buf)
  h.eq(vim.api.nvim_get_current_win(), win)
  h.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, true), lines)
  h.eq(vim.api.nvim_buf_get_changedtick(buf), state.tick)
  h.eq(vim.bo.modified, state.modified)
  h.eq(vim.fn.undotree(), state.undo)
  h.eq(vim.api.nvim_win_get_cursor(win), state.cursor)
  h.eq(resulting_clipboard, clipboard)
  h.eq(provider_calls, old_calls)
  assert(executed, 'unhandled command exception: ' .. tostring(reason))
  assert(report, 'missing structured CopyClean report')
  h.eq(#messages, 1)
  local modified_view = false
  for _, view in ipairs(active.views) do
    h.eq(#view, #source)
    h.eq(breaks(view), breaks(source))
    if case.preserved_view then
      assert(view:find(case.preserved_view, 1, true), 'native SQL was rewritten during dialect recovery')
    end
    if view ~= source then modified_view = true end
  end
  local outcome = { name = case.name, accepted = report.ok, code = report.code, stage = report.stage,
    message = report.message, views = #active.views, adapted = modified_view }
  outcomes[#outcomes + 1] = outcome
  if case.expected == false then
    h.eq(after_registers, state.registers)
    assert(not report.ok, 'invalid or lexically ambiguous SQL was accepted')
    h.eq(report.code, 'SYNTAX')
    h.eq(report.partial, false)
    h.eq(messages[1][2], vim.log.levels.WARN)
  else
    assert(report.ok, errors.format(report, false))
    h.eq(report.partial, false)
    h.eq(messages[1][2], vim.log.levels.INFO)
    assert(#active.views > 0, 'the real SQL parser was not observed')
    if case.adapted then assert(modified_view, 'expected a same-byte dialect parser view') end
    if case.native then h.eq(modified_view, false) end
    h.eq(vim.fn.getregtype('a'), 'V')
    h.eq(vim.fn.getreg('a'), case.expected .. '\n')
    h.eq(after_registers['0'], state.registers['0'])
    h.eq(after_registers.b, state.registers.b)
    local expected_removals = vim.deepcopy(case.removals or {})
    if not case.range then table.insert(expected_removals, anchor) end
    table.sort(expected_removals)
    table.sort(active.removals)
    h.eq(active.removals, expected_removals)
  end
  active = nil
end

local cases = {
  {
    name = 'stack alias markers, UTF-8 and original comment byte ranges', adapted = true,
    source = [[SELECT stack(1, '中文 -- keep', '/* keep */') AS (
  "name--keep", /* erase alias */
  `value/*keep*/`
); -- erase tail]],
    expected = [[SELECT stack(1, '中文 -- keep', '/* keep */') AS (
  "name--keep",]] .. '  \n' .. [[  `value/*keep*/`
);  ]],
    removals = { '/* erase alias */', '-- erase tail' },
  },
  {
    name = 'stack alias CRLF and tab positions stay byte aligned', adapted = true,
    source = "SELECT stack(1, '中', 1) AS (\r\n\ta, /* erase */\r\n\tb\r\n);",
    expected = "SELECT stack(1, '中', 1) AS (\r\n\ta,  \r\n\tb\r\n);",
    removals = { '/* erase */' },
  },
  {
    name = 'Doris properties preserve quoted markers and COMMENT clauses', adapted = true,
    source = [[CREATE TABLE safety_t (
  id BIGINT COMMENT 'column -- /* kept */'
) ENGINE=OLAP
DUPLICATE /* erase key */ KEY(id)
COMMENT 'table -- /* kept */'
DISTRIBUTED BY HASH(id) BUCKETS 1
PROPERTIES (
  "note" = "payload -- /* kept */" -- erase property
);]],
    expected = [[CREATE TABLE safety_t (
  id BIGINT COMMENT 'column -- /* kept */'
) ENGINE=OLAP
DUPLICATE   KEY(id)
COMMENT 'table -- /* kept */'
DISTRIBUTED BY HASH(id) BUCKETS 1
PROPERTIES (
  "note" = "payload -- /* kept */"]] .. '  \n' .. [[);]],
    removals = { '/* erase key */', '-- erase property' },
  },
  {
    name = 'Doris half-open range partition punctuation is preserved', adapted = true,
    source = [[CREATE TABLE safety_t (id BIGINT) ENGINE=OLAP
DUPLICATE KEY(id)
PARTITION BY RANGE(id) (
  PARTITION p1 VALUES [("1"), ("2")) /* erase partition */
)
DISTRIBUTED BY HASH(id) BUCKETS 1
PROPERTIES ("replication_num"="1");]],
    expected = [[CREATE TABLE safety_t (id BIGINT) ENGINE=OLAP
DUPLICATE KEY(id)
PARTITION BY RANGE(id) (
  PARTITION p1 VALUES [("1"), ("2"))]] .. '  \n' .. [[)
DISTRIBUTED BY HASH(id) BUCKETS 1
PROPERTIES ("replication_num"="1");]],
    removals = { '/* erase partition */' },
  },
  {
    name = 'RLIKE and null-safe equality preserve literals and operands', adapted = true,
    source = [[SELECT a FROM safety_t
WHERE a /* erase left */ <=> b
  AND c RLIKE '中--/*kept*/' /* erase right */;]],
    expected = [[SELECT a FROM safety_t
WHERE a   <=> b
  AND c RLIKE '中--/*kept*/'  ;]],
    removals = { '/* erase left */', '/* erase right */' },
  },
  {
    name = 'negative invocations retain arithmetic and nested argument tokens', adapted = true,
    source = [[SELECT -pmod(month(d)-1,3), -abs(1) /* erase */ FROM safety_t;]],
    expected = [[SELECT -pmod(month(d)-1,3), -abs(1)   FROM safety_t;]],
    removals = { '/* erase */' },
  },
  {
    name = 'BI condition, stack and expression adapters compose safely', adapted = true,
    source = [[SELECT stack(1,'中',1) AS (label, amount) FROM safety_t
WHERE {filter [conditions.day(number)]} AND v RLIKE '--/*kept*/'; -- erase]],
    expected = [[SELECT stack(1,'中',1) AS (label, amount) FROM safety_t
WHERE {filter [conditions.day(number)]} AND v RLIKE '--/*kept*/';  ]],
    removals = { '-- erase' },
  },
  {
    name = 'quoted doubled quotes, escapes and dollar strings stay untouched',
    source = [[SELECT 'it''s -- kept', E'it\'s -- /* kept */', "a""--b", 'back\\slash /* kept */', $tag$中文 -- /* kept */$tag$; -- erase]],
    expected = [[SELECT 'it''s -- kept', E'it\'s -- /* kept */', "a""--b", 'back\\slash /* kept */', $tag$中文 -- /* kept */$tag$;  ]],
    removals = { '-- erase' },
  },
  {
    name = 'RLIKE identifiers are not treated as predicate operators', native = true,
    source = [[SELECT rlike FROM safety_t; SELECT a AS rlike FROM safety_t; -- erase]],
    expected = [[SELECT rlike FROM safety_t; SELECT a AS rlike FROM safety_t;  ]],
    removals = { '-- erase' },
  },
  {
    name = 'native CREATE partition syntax remains unchanged', native = true,
    source = [[CREATE TABLE safety_native(id INT) PARTITION BY RANGE(id); -- erase]],
    expected = [[CREATE TABLE safety_native(id INT) PARTITION BY RANGE(id);  ]],
    removals = { '-- erase' },
  },
  {
    name = 'native CREATE and binary minus survive a separate RLIKE statement', adapted = true,
    source = [[CREATE TABLE safety_native(id INT) PARTITION BY RANGE(id);
SELECT t.rlike - f(x) FROM t;
SELECT * FROM safety_t WHERE x RLIKE '^a'; -- erase]],
    expected = [[CREATE TABLE safety_native(id INT) PARTITION BY RANGE(id);
SELECT t.rlike - f(x) FROM t;
SELECT * FROM safety_t WHERE x RLIKE '^a';  ]],
    preserved_view = [[CREATE TABLE safety_native(id INT) PARTITION BY RANGE(id);
SELECT t.rlike - f(x) FROM t;]],
    removals = { '-- erase' },
  },
  {
    name = 'grammar dollar tags protect template-looking string contents', native = true,
    source = [[SELECT $tag!${filter [conditions.x]} -- /* kept */$tag!$; -- erase]],
    expected = [[SELECT $tag!${filter [conditions.x]} -- /* kept */$tag!$;  ]],
    removals = { '-- erase' },
  },
  {
    name = 'native E-string with two backslashes closes at its real quote', native = true,
    source = [[SELECT E'\\'; -- erase]],
    expected = [[SELECT E'\\';  ]],
    removals = { '-- erase' },
  },
  {
    name = 'SQL optimizer and executable directives survive stack adaptation', adapted = true,
    source = [[/*!40101 SET NAMES utf8 */
SELECT /*+ BROADCAST(t) */ stack(1,'x',1) AS (a,b) FROM t; -- erase]],
    expected = [[/*!40101 SET NAMES utf8 */
SELECT /*+ BROADCAST(t) */ stack(1,'x',1) AS (a,b) FROM t;  ]],
    removals = { '-- erase' },
  },
  {
    name = 'LATERAL VIEW preserves array contents and quoted alias markers', adapted = true,
    source = [[SELECT lv.`value--keep` FROM safety_t
LATERAL /* erase view */ VIEW explode(array('中--kept', /* erase array */ '/* kept */')) lv AS `value--keep`; -- erase tail]],
    expected = [[SELECT lv.`value--keep` FROM safety_t
LATERAL   VIEW explode(array('中--kept',   '/* kept */')) lv AS `value--keep`;  ]],
    removals = { '/* erase view */', '/* erase array */', '-- erase tail' },
  },
  {
    name = 'SHOW ALTER retains original filters, literals and intervening comments', adapted = true,
    source = [[SHOW /* erase show */ ALTER TABLE COLUMN
WHERE TableName = 't--/* kept */' /* erase where */
ORDER BY CreateTime DESC LIMIT 1; -- erase tail]],
    expected = [[SHOW   ALTER TABLE COLUMN
WHERE TableName = 't--/* kept */']] .. '  \n' .. [[ORDER BY CreateTime DESC LIMIT 1;  ]],
    removals = { '/* erase show */', '/* erase where */', '-- erase tail' },
  },
  {
    name = 'an unrelated invalid statement does not replace full-buffer lexical context',
    source = [[SELECT * FROM ;
SELECT '-- string' AS value; -- erase]],
    range = { 2, 2 }, expected = [[SELECT '-- string' AS value;  ]], removals = { '-- erase' },
  },
  {
    name = 'a closed unselected hash comment does not extend its diagnostic to EOF',
    source = [[# unsupported;
SELECT 2; -- erase]],
    range = { 2, 2 }, expected = [[SELECT 2;  ]], removals = { '-- erase' },
  },
  {
    name = 'disabled clipboard preserves implicit clipboard option and never calls provider', adapted = true,
    source = [[SELECT stack(1,'x',1) AS (a,b); -- erase]],
    expected = [[SELECT stack(1,'x',1) AS (a,b);  ]], removals = { '-- erase' }, implicit_clipboard = true,
  },
}

local invalid = {
  { 'RLIKE missing right operand', 'SELECT a FROM safety_t WHERE a RLIKE ; -- erase' },
  { 'null-safe equality missing right operand', 'SELECT a FROM safety_t WHERE a <=> ; -- erase' },
  { 'malformed null-safe operator', 'SELECT a FROM safety_t WHERE a <=>= b; -- erase' },
  { 'unary invocation does not hide a missing operand', 'SELECT -abs(1) + ; -- erase' },
  { 'stack adapter does not hide another invalid SELECT', 'SELECT stack(1,1,2) AS (a,b); SELECT * FROM ; -- erase' },
  { 'Doris key list cannot contain expressions', 'CREATE TABLE safety_t(id BIGINT) ENGINE=OLAP DUPLICATE KEY(id+1); -- erase' },
  { 'Doris key list cannot omit an identifier before a comma', 'CREATE TABLE safety_t(id BIGINT) ENGINE=OLAP DUPLICATE KEY(,); -- erase' },
  { 'Doris key list cannot end with a comma', 'CREATE TABLE safety_t(id BIGINT) ENGINE=OLAP DUPLICATE KEY(id,); -- erase' },
  { 'Doris properties cannot contain statements', 'CREATE TABLE safety_t(id BIGINT) ENGINE=OLAP DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES("k"="v", SELECT * FROM;); -- erase' },
  { 'Doris properties cannot hide an unterminated quoted value', 'CREATE TABLE safety_t(id BIGINT) ENGINE=OLAP DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES("k"="unterminated); -- erase' },
  { 'Doris properties cannot hide a dangling comma', 'CREATE TABLE safety_t(id BIGINT) ENGINE=OLAP DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES("k"="v",); -- erase' },
  { 'Doris partition cannot hide an omitted upper boundary', 'CREATE TABLE safety_t(id BIGINT) ENGINE=OLAP DUPLICATE KEY(id) PARTITION BY RANGE(id) (PARTITION p1 VALUES [("1"), ())) DISTRIBUTED BY HASH(id) BUCKETS 1;' },
  { 'Doris partition cannot hide a missing close parenthesis', 'CREATE TABLE safety_t(id BIGINT) ENGINE=OLAP DUPLICATE KEY(id) PARTITION BY RANGE(id) (PARTITION p1 VALUES [("1"), ("2")) DISTRIBUTED BY HASH(id) BUCKETS 1;' },
  { 'SHOW ALTER cannot hide invalid WHERE', 'SHOW ALTER TABLE COLUMN WHERE ; -- erase' },
  { 'SHOW ALTER cannot hide a missing predicate operand', "SHOW ALTER TABLE COLUMN WHERE TableName = ; -- erase" },
  { 'LATERAL VIEW cannot hide malformed array arguments', 'SELECT * FROM safety_t LATERAL VIEW explode(array(1,,2)) lv AS value; -- erase' },
  { 'LATERAL VIEW requires a complete column alias', 'SELECT * FROM safety_t LATERAL VIEW explode(array(1)) lv AS; -- erase' },
  { 'LATERAL VIEW column alias cannot be an expression', 'SELECT * FROM safety_t LATERAL VIEW explode(array(1)) lv AS value+1; -- erase' },
  { 'LATERAL VIEW surrogate cannot become a SELECT expression', 'SELECT LATERAL VIEW explode(array(1)) lv AS value; -- erase' },
  { 'LATERAL VIEW cannot hide an additional invalid statement', 'SELECT * FROM safety_t LATERAL VIEW explode(array(1)) lv AS value; SELECT * FROM ; -- erase' },
  { 'nested block comments are conservatively refused', 'SELECT 1; /* outer /* nested */ rest */ -- erase' },
  { 'unterminated block comments are refused', 'SELECT 1; /* unterminated -- erase' },
  { 'unterminated dollar quote cannot expose comment markers', 'SELECT $tag$ -- /* unclosed ;' },
  { 'doubled quote cannot hide a missing string terminator', "SELECT 'a'' -- unterminated ;" },
}
for _, case in ipairs(invalid) do
  cases[#cases + 1] = { name = case[1], source = case[2], expected = false }
end
for _, prefix in ipairs({
  { name = 'unterminated string', source = "SELECT 'unterminated\nSELECT 2; -- erase" },
  { name = 'unterminated block comment', source = '/* unterminated\nSELECT 2; -- erase' },
  { name = 'ambiguous quoted alias', source = [[SELECT stack(2,1,2) AS (a, "x\"; SELECT 1 AS c --");
SELECT 2; -- erase]] },
}) do
  cases[#cases + 1] = { name = 'unselected ' .. prefix.name .. ' cannot alter selected comment scope',
    source = prefix.source, expected = false, range = { 2, 2 } }
end

for _, case in ipairs(cases) do h.test(case.name, function() exercise(case) end) end

vim.treesitter.get_string_parser, comments.collect, errors.notify = original_parser, original_collect, original_notify
vim.g.clipboard = original_provider
vim.fn.mkdir('.test/tmp', 'p')
vim.fn.writefile({ vim.json.encode({ passed = h.passed, failed = h.failed, cases = outcomes }) }, '.test/tmp/sql-safety.json')
h.finish('SQL adapter safety')
