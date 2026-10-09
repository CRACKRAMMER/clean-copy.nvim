-- Each scenario runs in a fresh process: module and plugin guards cannot hide bugs.
vim.opt.runtimepath = { vim.fn.getcwd(), vim.env.VIMRUNTIME }
vim.o.swapfile = false
vim.o.clipboard = ''
local h = dofile('tests/helpers.lua')
local messages = {}
vim.notify = function(message, level) messages[#messages + 1] = { message, level } end
local scenario = assert(vim.env.CLEAN_COPY_TEST_SCENARIO)

local function commands()
  return vim.api.nvim_get_commands({ builtin = false })
end

if scenario == 'require' then
  h.test('require automatically registers CopyClean without setup', function()
    local plugin = require('clean_copy')
    assert(commands().CopyClean)
    assert(not commands().CleanCopy)
    local original = commands().CopyClean
    assert(plugin.setup({ register = 'a', clipboard = false }) ~= false)
    assert(plugin.setup({ register = 'b', clipboard = false }) ~= false)
    h.eq(commands().CopyClean, original)
    dofile('plugin/clean_copy.lua')
    h.eq(commands().CopyClean, original)
    h.eq(#messages, 0)
  end)
elseif scenario == 'plugin' then
  h.test('plugin loader automatically registers CopyClean without setup', function()
    dofile('plugin/clean_copy.lua')
    assert(commands().CopyClean)
    assert(not commands().CleanCopy)
    local command = commands().CopyClean
    dofile('plugin/clean_copy.lua')
    h.eq(commands().CopyClean, command)
    h.eq(#messages, 0)
  end)
  h.test('CopyClean executes default configuration without any setup call', function()
    h.buffer('local default=1')
    h.patch(require('clean_copy.comments'), 'collect', function() return {} end, function()
      h.patch(require('clean_copy.registers'), 'available', function() return false end, function()
        vim.cmd.CopyClean()
      end)
    end)
    h.eq(vim.fn.getreg('"'), 'local default=1\n')
    h.eq(vim.fn.getreg('0'), 'local default=1\n')
    h.eq(messages[#messages][2], vim.log.levels.WARN)
    assert(messages[#messages][1]:find('provider unavailable', 1, true))
  end)
elseif scenario == 'conflict' then
  h.test('external command conflict never overwrites user command', function()
    local called = 0
    vim.api.nvim_create_user_command('CopyClean', function() called = called + 1 end,
      { desc = 'user-owned command' })
    local command = commands().CopyClean
    local plugin = require('clean_copy')
    h.eq(commands().CopyClean, command)
    assert(#messages > 0)
    assert(messages[1][1]:find('CopyClean', 1, true))
    h.eq(messages[1][2], vim.log.levels.ERROR)
    plugin.setup({ register = 'a', clipboard = false })
    plugin._register_command()
    dofile('plugin/clean_copy.lua')
    h.eq(commands().CopyClean, command)
    h.eq(#messages, 1)
    vim.cmd.CopyClean()
    h.eq(called, 1)
  end)
elseif scenario == 'lazy' then
  h.test('lazy command placeholder removes itself before plugin registration', function()
    local loaded = 0
    vim.api.nvim_create_user_command('CopyClean', function(command)
      loaded = loaded + 1
      vim.api.nvim_del_user_command('CopyClean')
      local plugin = require('clean_copy')
      assert(plugin.setup({ register = 'a', clipboard = false }) ~= false)
      -- lazy.nvim forwards the original command after loading and setup.
      vim.cmd((command.range > 0 and command.line1 .. ',' .. command.line2 or '') .. 'CopyClean')
    end, { range = true, desc = 'lazy-loading placeholder' })
    h.buffer('local a=1\nlocal b=2')
    -- Stub only parsing; registration, command forwarding and register writes stay real.
    local comments = require('clean_copy.comments')
    h.patch(comments, 'collect', function() return {} end, function()
      vim.cmd('2CopyClean')
    end)
    h.eq(loaded, 1)
    h.eq(vim.fn.getreg('a'), 'local b=2\n')
    assert(commands().CopyClean.desc ~= 'lazy-loading placeholder')
  end)
elseif scenario == 'legacy' then
  h.test('legacy alias is explicit, warns once, and can be disabled', function()
    local plugin = require('clean_copy')
    assert(not commands().CleanCopy)
    assert(plugin.setup({ legacy_command = true, register = 'a', clipboard = false }) ~= false)
    assert(commands().CleanCopy)
    h.buffer('local a=1')
    h.patch(require('clean_copy.comments'), 'collect', function() return {} end, function()
      local before = #messages
      vim.cmd.CleanCopy()
      h.eq(#messages, before + 1)
      assert(messages[#messages][1]:find('deprecated', 1, true))
      h.eq(messages[#messages][2], vim.log.levels.WARN)
      vim.cmd.CleanCopy()
      h.eq(#messages, before + 2)
      assert(not messages[#messages][1]:find('deprecated', 1, true))
      h.eq(messages[#messages][2], vim.log.levels.INFO)
    end)
    assert(plugin.setup({ legacy_command = false, register = 'a', clipboard = false }) ~= false)
    assert(not commands().CleanCopy)
    assert(commands().CopyClean)
  end)
elseif scenario == 'lazy-visual' then
  h.test('lazy command loading preserves active Visual mode with Cmd mappings', function()
    local loaded = 0
    vim.api.nvim_create_user_command('CopyClean', function()
      loaded = loaded + 1
      vim.api.nvim_del_user_command('CopyClean')
      require('clean_copy').setup({ register = 'a', clipboard = false })
      vim.cmd({ cmd = 'CopyClean' })
    end, {range = true})
    vim.keymap.set('x', '<F7>', '<Cmd>CopyClean<CR>')
    h.buffer('local text = "中文\tfoo"')
    h.keys('gg0f"lv3l')
    local expected = vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), {type = 'v'})
    h.patch(require('clean_copy.comments'), 'collect', function() return {} end, function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<F7>', true, false, true), 'xt', false)
    end)
    h.eq(loaded, 1)
    h.eq(vim.fn.getreg('a'), table.concat(expected, '\n'))
    h.eq(vim.fn.getregtype('a'), 'v')
    h.eq(vim.fn.mode(), 'n')
    h.keys('gv')
    h.eq(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), {type = 'v'}), expected)
    h.keys('<Esc>')
  end)
elseif scenario == 'legacy-conflict' then
  h.test('legacy opt-in retains an existing foreign CleanCopy command', function()
    vim.api.nvim_create_user_command('CleanCopy', function() end, { desc = 'foreign legacy name' })
    local original = commands().CleanCopy
    local plugin = require('clean_copy')
    local ok, _, report = plugin.setup({ legacy_command = true })
    assert(ok == false)
    h.eq(report.code, 'COMMAND_CONFLICT')
    h.eq(commands().CleanCopy, original)
    plugin.setup({ legacy_command = false })
    h.eq(commands().CleanCopy, original)
  end)
elseif scenario == 'ownership' then
  h.test('commands with identical descriptions remain owned by their actual callbacks', function()
    local plugin = require('clean_copy')
    plugin.setup({ legacy_command = true, register = 'a', clipboard = false })
    local description = commands().CleanCopy.desc
    vim.api.nvim_create_user_command('CleanCopy', function() end, { desc = description, force = true })
    local alias = commands().CleanCopy
    plugin.setup({ legacy_command = false, register = 'a', clipboard = false })
    h.eq(commands().CleanCopy, alias)
    local called = 0
    vim.api.nvim_create_user_command('CopyClean', function() called = called + 1 end,
      { desc = commands().CopyClean.desc, force = true })
    local main = commands().CopyClean
    local ok, report = plugin._register_command()
    assert(ok == false)
    h.eq(report.code, 'COMMAND_CONFLICT')
    h.eq(commands().CopyClean, main)
    vim.cmd.CopyClean()
    h.eq(called, 1)
  end)
else
  error('unknown lifecycle scenario: ' .. scenario)
end

h.finish('lifecycle ' .. scenario)
