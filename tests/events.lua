vim.opt.runtimepath = { vim.fn.getcwd(), vim.env.VIMRUNTIME }
vim.o.swapfile = false
vim.notify = function() end
local h = dofile('tests/helpers.lua')
local registers = require('clean_copy.registers')
local config = require('clean_copy.config')
local events = 0
vim.api.nvim_create_autocmd('OptionSet', { pattern = 'clipboard', callback = function() events = events + 1 end })

h.test('clipboard suppression and restore fallback do not fire user OptionSet hooks', function()
  vim.o.clipboard = 'unnamedplus'
  assert(events > 0, 'the test must execute after startup when OptionSet is active')
  events = 0
  local set = vim.cmd.set
  h.patch(vim.cmd, 'set', function(args)
    if args.args[1] == 'clipboard=unnamedplus' then error('restore command failed') end
    return set(args)
  end, function()
    local report = registers.write('copied', 'v', config.resolve({ register = 'a', clipboard = false }))
    assert(report.ok)
  end)
  h.eq(vim.o.clipboard, 'unnamedplus')
  h.eq(events, 0)
  h.eq(vim.fn.getreg('a'), 'copied')
end)

h.finish('option events')
