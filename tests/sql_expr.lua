-- Real-parser checks for finite Hive expression adaptations. No database runs.
vim.opt.runtimepath = { vim.fn.getcwd(), vim.fn.getcwd() .. '/.test/runtime', vim.env.VIMRUNTIME }
vim.o.swapfile = false
vim.o.clipboard = ''
local h = dofile('tests/helpers.lua')
local lex = require('clean_copy.sql_lex')
local expr = require('clean_copy.sql_expr')

local function snapshot(text)
  local lines, starts, count = vim.split(text, '\n', {plain = true}), {}, 0
  for index, line in ipairs(lines) do starts[index], count = count, count + #line + 1 end
  return { text = text, lines = lines, starts = starts }
end

local function inspect(text, callback)
  local snap = snapshot(text)
  local parsers = {}
  local function parse(source)
    local parser = vim.treesitter.get_string_parser(source, 'sql', {injections = {sql = ''}})
    parsers[#parsers + 1] = parser
    parser:parse(true)
    return parser
  end
  local ok, result = xpcall(function()
    local view, metadata = expr.prepare(text, snap, lex.scan(text), parse)
    lex.validate_layout(text, view)
    local root = parse(view):parse(true)[1]:root()
    expr.validate(root, snap, metadata)
    callback(root, view, metadata)
  end, function(err) return err end)
  for index = #parsers, 1, -1 do parsers[index]:destroy() end
  if not ok then error(result, 0) end
end

for _, text in ipairs({
  [[SELECT a RLIKE '^x--/*literal*/' FROM t;]],
  [[SELECT CASE WHEN path rlike '^/x/' THEN 1 ELSE 0 END FROM t;]],
  [[SELECT * FROM t WHERE a NOT RLIKE '^x';]],
  'SELECT * FROM t WHERE a /* keep coordinates */ <=> b;',
  'SELECT * FROM t WHERE a<=>b AND c<=>d;',
  'SELECT add_months(trunc(d,\'MM\'),-pmod(month(d)-1,3)) FROM t;',
  'SELECT -pmod(3,2), f(-x), f(-(a+b)) FROM t;',
  'SELECT f(-x) FROM t WHERE x RLIKE p AND a <=> b;',
  'SELECT a - -f(x) FROM t;',
}) do
  h.test('SQL expression adaptation: ' .. text, function()
    inspect(text, function(root, _, metadata)
      assert(#metadata > 0)
      assert(not root:has_error(), root:sexpr())
    end)
  end)
end

h.test('expression adapters leave identifier names, quotes and comments untouched', function()
  local text = [[SELECT rlike, t.rlike, a AS rlike, 'RLIKE <=> -f()', "rlike" FROM t;
SELECT a RLIKE;
-- RLIKE <=> -f()
/* RLIKE <=> -f() */]]
  inspect(text, function(root, view, metadata)
    h.eq(view, text)
    h.eq(metadata, {})
    assert(not root:has_error())
  end)
end)

h.test('ordinary subtraction and negative numeric literals keep the native view', function()
  local text = 'SELECT a-1, f(-1), 0-2 FROM t;'
  inspect(text, function(root, view, metadata)
    h.eq(view, text)
    h.eq(metadata, {})
    assert(not root:has_error())
  end)
end)

for _, name in ipairs({'t.rlike', 'rlike', 'select', 'where', 'like'}) do
  h.test('native subtraction with keyword-like field ' .. name .. ' remains unchanged', function()
    local text = 'SELECT ' .. name .. ' -f(x) FROM t;'
    inspect(text, function(root, view, metadata)
      h.eq(view, text)
      h.eq(metadata, {})
      assert(not root:has_error())
    end)
  end)
end

h.test('native binary subtraction stays intact beside a real unsupported expression', function()
  local text = "SELECT t.rlike -f(x), y RLIKE '^a' FROM t;"
  inspect(text, function(root, view, metadata)
    assert(view:find('t.rlike -f(x)', 1, true))
    h.eq(#metadata, 1)
    h.eq(metadata[1].kind, 'rlike')
    assert(not root:has_error())
  end)
end)

for _, text in ipairs({
  'SELECT * FROM t WHERE a RLIKE ;',
  'SELECT * FROM t WHERE a <=> ;',
  'SELECT * FROM t WHERE <=> b;',
  'SELECT -f() + ;',
  'SELECT f(,-x);',
  'SELECT * FROM t WHERE a RLIKE b AND ;',
  'SELECT * FROM t WHERE a <=> b AND ;',
  'SELECT 1 AS -alias;',
}) do
  h.test('SQL expression adapters retain syntax rejection: ' .. text, function()
    local rejected = false
    local ok, report = pcall(inspect, text, function(root)
      rejected = root:has_error()
    end)
    if not ok then assert(type(report) == 'table' and report.code == 'SYNTAX', tostring(report)) end
    assert(not ok or rejected, 'invalid source became error-free')
  end)
end

h.test('operator-looking text in PostgreSQL dollar and E strings is unchanged', function()
  local text = [[SELECT $tag$RLIKE <=> -f() -- /*literal*/$tag$, E'it\'s RLIKE <=> -f()' FROM t;]]
  inspect(text, function(root, view, metadata)
    h.eq(view, text)
    h.eq(metadata, {})
    assert(not root:has_error())
  end)
end)

h.finish('SQL expressions')
