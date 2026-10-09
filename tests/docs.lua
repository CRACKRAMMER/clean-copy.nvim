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

h.test('native help tags resolve the new command and plugin entry point', function()
  vim.cmd.helptags('doc')
  for _, topic in ipairs({'clean-copy', 'CopyClean', 'CopyCleanParsers', 'clean-copy-parsers'}) do
    vim.cmd.help(topic)
    assert(vim.api.nvim_buf_get_name(0):match('/doc/clean%-copy%.txt$'), topic)
  end
end)

h.finish('documentation')
