-- Real-parser and command checks for the finite Hive lateral-array form.
vim.opt.runtimepath = { vim.fn.getcwd(), vim.fn.getcwd() .. '/.test/runtime', vim.env.VIMRUNTIME }
vim.o.swapfile, vim.o.clipboard = false, ''
local h = dofile('tests/helpers.lua')
local plugin = require('clean_copy')
assert(plugin.setup({ register = 'a', clipboard = false }))
local messages = {}
vim.notify = function(message, level) messages[#messages + 1] = { message, level } end

local function copy(source, expected)
  h.buffer(source, 'sql')
  vim.fn.setreg('a', 'lateral sentinel', 'v')
  local before, tick, undo = vim.fn.getreginfo('a'), vim.api.nvim_buf_get_changedtick(0), vim.fn.undotree()
  local count = #messages
  local ok, _, report = plugin.copy()
  h.eq(#messages, count + 1)
  h.eq(vim.api.nvim_buf_get_changedtick(0), tick)
  h.eq(vim.fn.undotree(), undo)
  h.eq(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, true), '\n'), source)
  if expected == false then
    assert(not ok, source)
    h.eq(report.code, 'SYNTAX'); h.eq(messages[#messages][2], vim.log.levels.WARN)
    h.eq(vim.fn.getreginfo('a'), before)
  else
    assert(ok, report.message)
    h.eq(vim.fn.getreg('a'), expected .. '\n')
    h.eq(vim.fn.getregtype('a'), 'V')
    h.eq(messages[#messages][2], vim.log.levels.INFO)
  end
end

for _, source in ipairs({
  "SELECT * FROM t LATERAL VIEW explode(array('all', t.x)) u AS x;",
  "SELECT * FROM t\nLATERAL VIEW explode(array('all', t.x)) u AS x\n"
    .. "LATERAL VIEW explode(array('all', t.y)) v AS y\nGROUP BY t.x;",
  "SELECT * FROM t LATERAL VIEW explode(array('all', abs(-x))) u AS x WHERE x RLIKE '^x' AND x <=> y;",
  'SELECT * FROM t LATERAL VIEW explode(array(1,2)) "table--alias" AS `中/*alias*/`;',
  'SELECT * FROM t\r\n\tLATERAL VIEW explode(array(1,2)) u AS x;',
}) do
  h.test('valid lateral-array SQL retains all original tokens: ' .. source, function()
    copy(source .. ' -- erase', source .. '  ')
  end)
end

h.test('lateral keyword and alias comments are removed without exposing quoted markers', function()
  local source = "SELECT * FROM t LATERAL /* erase */ VIEW explode(array('/* kept */', t.x))\n"
    .. '/* erase */ u /* erase */ AS /* erase */ "x--kept";'
  copy(source, source:gsub('/%* erase %*/', ' '))
end)

h.test('native joins and identifiers named lateral or array remain supported', function()
  local source = 'SELECT t.lateral, t.array FROM t CROSS JOIN fn(1) u;'
  copy(source .. ' -- erase', source .. '  ')
end)

for _, source in ipairs({
  'SELECT * FROM t LATERAL VIEW explode(array(1,,2)) u AS x;',
  'SELECT * FROM t LATERAL VIEW explode(array(1,2)) u AS x, y;',
  'SELECT * FROM t LATERAL VIEW explode(array(1,2)) u AS;',
  'SELECT * FROM t LATERAL VIEW explode(array(1,2)) u AS 2;',
  'SELECT * FROM t LATERAL VIEW explode(array(1,2)) u AS x+1;',
  'SELECT * FROM t LATERAL VIEW explode(array(1,2)) u AS x WHERE ;',
  'SELECT * FROM t LATERAL VIEW explode(array(1,2), 3) u AS x;',
  'SELECT * FROM t LATERAL VIEW OUTER explode(array(1,2)) u AS x;',
  'SELECT * FROM t LATERAL VIEW posexplode(array(1,2)) u AS pos,x;',
  'SELECT LATERAL VIEW explode(array(1,2)) u AS x;',
  'SELECT * FROM t LATERAL VIEW explode(array(1,2)) u AS (x);',
}) do
  h.test('malformed or unsupported lateral form is refused: ' .. source, function() copy(source, false) end)
end

h.finish('Hive lateral arrays')
