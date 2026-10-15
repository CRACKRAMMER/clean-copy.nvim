vim.opt.runtimepath = { vim.fn.getcwd(), vim.env.VIMRUNTIME }
local h = dofile('tests/helpers.lua')
local readme = table.concat(vim.fn.readfile('README.md'), '\n')
local help = table.concat(vim.fn.readfile('doc/clean-copy.txt'), '\n')

h.test('README and native help document current commands and configuration keys', function()
  for key in pairs(require('clean_copy.config').defaults) do
    assert(readme:find(key, 1, true), 'README omits ' .. key)
    assert(help:find(key, 1, true), 'help omits ' .. key)
  end
  for _, text in ipairs({readme, help}) do
    assert(text:find(':CopyClean', 1, true))
    assert(text:find(':CopyCleanParsers', 1, true))
    assert(text:find('legacy_command', 1, true))
    assert(text:find('CleanCopy', 1, true))
    assert(text:find('make test', 1, true))
    assert(text:find('make test-unit', 1, true))
  end
end)

h.test('parser command documentation matches defaults and optional dependencies', function()
  local defaults = require('clean_copy.config').defaults.parser_languages
  assert(type(defaults) == 'table', 'parser_languages default is missing')
  for _, text in ipairs({readme, help}) do
    local block = assert(text:match('parser_languages%s*=%s*{(.-)}'), 'parser default example missing')
    local documented = {}
    for name in block:gmatch('[\'"]([%w_]+)[\'"]') do documented[#documented + 1] = name end
    h.eq(documented, defaults)
    for _, required in ipairs({':CopyCleanParsers sql lua', ':CopyCleanParsers!',
      'nvim-treesitter', '0.26.1', 'CC', 'make test-parsers', 'CLEAN_COPY_TS_PATH'}) do
      assert(text:find(required, 1, true), 'parser documentation omits ' .. required)
    end
    assert(not text:find('DotfilesTSInstall', 1, true), 'unrelated installer alias is documented')
    assert(not text:find('TSParsersSync', 1, true), 'obsolete installer name is documented')
    local normalized = text:gsub('%s+', ' ')
    assert(normalized:find('completion cannot be observed', 1, true), 'unknown completion state is omitted')
    assert(normalized:find('restart Neovim before retrying', 1, true), 'unknown completion recovery is omitted')
  end
  assert(readme:find('cmd = { "CopyClean", "CopyCleanParsers" }', 1, true), 'lazy command list is incomplete')
end)

h.test('SQL template and local fixture documentation agrees across README and help', function()
  for _, text in ipairs({readme, help}) do
    for _, required in ipairs({'{identifier [conditions.identifier]}',
      '{identifier [conditions.identifier(number)]}', 'make test-fixtures',
      'fixtures/sql/*.sql', '.test/local-fixtures/report.json',
      '.test/local-fixtures/cleaned/', 'DUPLICATE KEY', 'SHOW ALTER TABLE',
      'RLIKE', '<=>', 'INSERT OVERWRITE'}) do
      assert(text:find(required, 1, true), 'SQL documentation omits ' .. required)
    end
    local normalized = text:gsub('`', ''):gsub('%s+', ' ')
    for _, required in ipairs({'temporary parser view substitutes TRUE',
      'preserves the original template unchanged',
      'Template expansion is neither executed nor validated',
      'SQL strings and COMMENT clauses are code', 'nonzero exit status'}) do
      assert(normalized:find(required, 1, true), 'SQL documentation omits ' .. required)
    end
  end
end)

h.test('SQL stack aliases document the supported form and validation boundaries', function()
  for _, text in ipairs({readme, help}) do
    local normalized = text:gsub('`', ''):gsub('%s+', ' '):lower()
    for _, required in ipairs({'direct, unqualified stack(...) calls in a select list',
      'as (col1, col2, ...)', 'calls and alias lists may span lines and contain comments',
      'bare ascii identifiers', 'double-quoted or backtick-quoted identifiers',
      'temporary parser view keeps the first alias', 'original alias text, utf-8',
      'syntax-error checks still apply', 'other functions', 'db.stack',
      'alias expressions', 'incomplete lists', 'lateral view',
      'invalid adapted aliases anywhere in the buffer abort copying, even outside the selection',
      'ordinary unrelated syntax errors retain the selection-scoped behavior'}) do
      assert(normalized:find(required, 1, true), 'stack documentation omits ' .. required)
    end
    assert(not normalized:find('aliases remain unsupported', 1, true),
      'stack aliases are incorrectly documented as unsupported')
    assert(not normalized:find('rejected hive forms include multi-column', 1, true),
      'supported stack aliases remain in the rejection list')
  end
end)

h.test('finite SQL dialect support and rejection boundaries agree across documents', function()
  for _, text in ipairs({readme, help}) do
    local normalized = text:gsub('`', ''):gsub('%s+', ' '):lower()
    for _, required in ipairs({'hive expressions', 'rlike', 'not rlike', '<=>',
      'unary negative operands', 'lateral view explode(array(...)) table_alias as column_alias',
      'with one column alias', 'engine=olap', 'duplicate key', 'values [(lower), (upper))',
      'distributed by hash', 'buckets', 'properties', 'show alter table column',
      'order by', 'limit count', 'whole-buffer structural validation',
      'the parser view preserves byte offsets and line breaks',
      'the copied sql keeps its original tokens; only removable comments change',
      'neither a formatter nor a database validator', 'unknown doris clause forms or expressions',
      'other hive udtfs', 'lateral view outer', 'general array(...) usage', 'insert overwrite',
      'unterminated sql quotes, dollar strings', 'even without a dialect adaptation'}) do
      assert(normalized:find(required, 1, true), 'SQL dialect documentation omits ' .. required)
    end
    assert(not normalized:find('known rejected hive forms include rlike', 1, true),
      'supported Hive operators still appear in the rejection list')
    assert(not normalized:find('current sql grammar rejects doris/palo', 1, true)
      and not normalized:find('current grammar rejects doris/palo', 1, true),
      'supported Doris clauses still appear in the rejection list')
    for _, page in ipairs({'CREATE-TABLE', 'SHOW-ALTER-TABLE'}) do
      assert(text:find('https://doris.apache.org/docs/4.x/sql-manual/sql-statements/table-and-view/table/'
        .. page .. '/', 1, true), 'Doris syntax reference is missing: ' .. page)
    end
  end
end)

h.test('Doris SHOW documentation describes the finite field and limit syntax', function()
  local normalized = help:gsub('%s+', ' ')
  for _, required in ipairs({'Filter fields: TableName, CreateTime, FinishTime, FinishedTime, State',
    'JobId, TableName, CreateTime, FinishedTime', 'IndexName, IndexId, OriginIndexId, SchemaVersion',
    'TransactionId, State, Msg, Progress or Timeout', 'LIMIT requires a nonnegative integer',
    'expressions, arbitrary fields and limit offsets are not supported'}) do
    assert(normalized:find(required, 1, true), 'Doris SHOW help omits ' .. required)
  end
end)

h.test('SQL specialist suites are documented and run by the default integration path', function()
  local runner = table.concat(vim.fn.readfile('tests/run.sh'), '\n')
  for _, path in ipairs({'tests/sql_expr.lua', 'tests/sql_doris.lua',
    'tests/sql_lateral.lua', 'tests/sql_safety.lua'}) do
    assert(vim.fn.filereadable(path) == 1, 'SQL suite is missing: ' .. path)
    assert(runner:find('nvim --clean --headless -l ' .. path, 1, true), 'runner omits ' .. path)
    assert(readme:find(path, 1, true) and help:find(path, 1, true), 'documentation omits ' .. path)
  end
end)

h.test('native help tags resolve the new command and plugin entry point', function()
  vim.cmd.helptags('doc')
  for _, topic in ipairs({'clean-copy', 'CopyClean', 'CopyCleanParsers', 'clean-copy-parsers', 'clean-copy-sql'}) do
    vim.cmd.help(topic)
    assert(vim.api.nvim_buf_get_name(0):match('/doc/clean%-copy%.txt$'), topic)
  end
end)

h.finish('documentation')
