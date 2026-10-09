-- Optional offline smoke test against nvim-treesitter's real public Task API.
-- CLEAN_COPY_TS_PATH must point to an existing main-branch checkout. No parser,
-- installer, network operation, compiler, or clipboard provider is loaded.
vim.opt.runtimepath = { vim.fn.getcwd(), vim.env.VIMRUNTIME }
vim.o.swapfile, vim.o.clipboard = false, ''
local source = assert(vim.env.CLEAN_COPY_TS_PATH, 'set CLEAN_COPY_TS_PATH to a nvim-treesitter checkout')
local async = assert(loadfile(source .. '/lua/nvim-treesitter/async.lua'))()
local h = dofile('tests/helpers.lua')
local messages, operations = {}, {}
local behavior, deferred = {}, true
vim.notify = function(message, level) messages[#messages + 1] = { message, level } end
vim.fn.executable = function() return 1 end
vim.env.CC = nil
vim.system = function(command, _, callback)
  h.eq(command, { 'tree-sitter', '--version' })
  vim.schedule(function() callback({ code = 0, stdout = 'tree-sitter 0.26.1\n', stderr = '' }) end)
  return {}
end
local treesitter = {
  get_available = function(tier) return tier == 4 and {} or { 'lua', 'python' } end,
  get_installed = function(kind) h.eq(kind, 'parsers'); return { 'lua' } end,
}
for _, method in ipairs({ 'install', 'update' }) do
  treesitter[method] = function(languages, options)
    operations[#operations + 1] = { method, vim.deepcopy(languages), vim.deepcopy(options) }
    local outcome = behavior[method]
    return async.async(function()
      if deferred then async.schedule() end
      if outcome == 'error' then error('real upstream task failure') end
      return outcome ~= 'false'
    end)()
  end
end
package.loaded['nvim-treesitter'] = treesitter
require('clean_copy').setup({ parser_languages = { 'lua', 'python' }, clipboard = false, debug = true })

local function complete()
  assert(vim.wait(1000, function()
    local last = messages[#messages]
    return last and (last[1]:find('are synchronized', 1, true)
      or last[1]:find('may already', 1, true))
  end, 5), 'real Task completion timed out')
end
local function execute()
  messages, operations = {}, {}
  vim.cmd.CopyCleanParsers()
  complete()
end

h.test('real deferred tasks install then update and release busy lock', function()
  execute()
  h.eq(#operations, 2)
  h.eq(operations[1][1], 'install')
  h.eq(operations[2][1], 'update')
  h.eq(messages[#messages][2], vim.log.levels.INFO)
  execute()
  h.eq(#operations, 2)
end)

h.test('real already-completed tasks invoke await callbacks correctly', function()
  deferred = false
  execute()
  h.eq(#operations, 2)
  h.eq(messages[#messages][2], vim.log.levels.INFO)
end)

h.test('real Task false result reports partial failure and permits retry', function()
  deferred, behavior = true, { update = 'false' }
  execute()
  h.eq(#operations, 2)
  h.eq(messages[#messages][2], vim.log.levels.WARN)
  behavior = {}
  execute()
  h.eq(messages[#messages][2], vim.log.levels.INFO)
end)

h.test('real Task error reports failure and permits retry', function()
  behavior = { update = 'error' }
  execute()
  h.eq(messages[#messages][2], vim.log.levels.ERROR)
  assert(messages[#messages][1]:find('real upstream task failure', 1, true))
  behavior = {}
  execute()
  h.eq(messages[#messages][2], vim.log.levels.INFO)
end)

h.finish('real parser Tasks')
