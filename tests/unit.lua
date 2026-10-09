-- Parser-independent safety tests. No user runtime, configuration or provider is loaded.
vim.opt.runtimepath = { vim.fn.getcwd(), vim.env.VIMRUNTIME }
vim.o.swapfile = false
vim.o.clipboard = ''
local h = dofile('tests/helpers.lua')
local eq, test, patch = h.eq, h.test, h.patch
local config = require('clean_copy.config')
local errors = require('clean_copy.errors')
local selection = require('clean_copy.selection')
local transform = require('clean_copy.transform')
local registers = require('clean_copy.registers')
local comments = require('clean_copy.comments')
local rules = require('clean_copy.rules')
local plugin = require('clean_copy')
local messages = {}
vim.notify = function(message, level) messages[#messages + 1] = { message, level } end

local function opts(extra)
  return config.resolve(vim.tbl_extend('force', { register = 'a', clipboard = false }, extra or {}))
end

local function no_parser(fn)
  patch(comments, 'collect', function() return {} end, fn)
end

local function state()
  return { lines = vim.api.nvim_buf_get_lines(0, 0, -1, true),
    tick = vim.api.nvim_buf_get_changedtick(0), modified = vim.bo.modified,
    undo = vim.fn.undotree(), a = vim.fn.getreginfo('a'), zero = vim.fn.getreginfo('0'),
    unnamed = vim.fn.getreginfo('"'), clipboard = vim.o.clipboard }
end

test('configuration rejects invalid types, keys, registers and sparse callbacks', function()
  for _, bad in ipairs({ false, 'opts', { unknown = true }, { debug = 1 }, { legacy_command = 'yes' },
    { register = 'A' }, { register = 'ab' }, { register = '_' }, { clipboard = 'yes' },
    { language_overrides = { lua = 1 } }, { language_overrides = { lua = 'bad-name' } },
    { directive_rules = { 'pattern' } }, { directive_rules = { [2] = function() return true end } } }) do
    local ok, err = pcall(config.resolve, bad)
    assert(not ok, vim.inspect(bad))
    eq(err.code, 'CONFIG')
    assert(tostring(err):find('%S'))
  end
end)

test('configuration defaults and caller options never share mutable tables', function()
  local input = { language_overrides = { foo = 'lua' }, directive_rules = { function() return false end } }
  local first = config.resolve(input)
  first.language_overrides.foo = 'c'
  first.directive_rules[2] = function() return true end
  eq(input.language_overrides.foo, 'lua')
  eq(#input.directive_rules, 1)
  eq(config.resolve().language_overrides, {})
  eq(config.resolve().directive_rules, {})
  eq(config.resolve().legacy_command, false)
end)

test('invalid setup reports once and retains the previous valid configuration', function()
  plugin.setup({ register = 'b', clipboard = false })
  local before = #messages
  local ok, message, report = plugin.setup({ register = 'A' })
  assert(ok == false and message:find('%S'))
  eq(report.code, 'CONFIG')
  eq(#messages, before + 1)
  eq(messages[#messages][2], vim.log.levels.ERROR)
  h.buffer('local a=1')
  no_parser(function() assert(plugin.copy()) end)
  eq(vim.fn.getreg('b'), 'local a=1\n')
  plugin.setup({ register = 'a', clipboard = false })
end)

test('setup during parsing affects the next copy without changing the active targets', function()
  h.buffer('local a=1')
  plugin.setup({ register = 'a', clipboard = false })
  vim.fn.setreg('a', 'a sentinel')
  vim.fn.setreg('b', 'b sentinel')
  patch(comments, 'collect', function()
    assert(plugin.setup({ register = 'b', clipboard = false }))
    return {}
  end, function()
    local ok, _, report = plugin.copy()
    assert(ok)
    eq(report.targets.a, 'written')
  end)
  eq(vim.fn.getreg('a'), 'local a=1\n')
  eq(vim.fn.getreg('b'), 'b sentinel')
  no_parser(function()
    local ok, _, report = plugin.copy()
    assert(ok)
    eq(report.targets.b, 'written')
  end)
  eq(vim.fn.getreg('b'), 'local a=1\n')
  plugin.setup({ register = 'a', clipboard = false })
end)

test('structured errors format concise guidance and debug traceback', function()
  local report = errors.new('QUERY', 'query', 'cannot parse query',
    { context = { language = 'lua' }, hint = 'Check the query file.', detail = 'raw failure' })
  local concise = errors.format(report, false)
  assert(concise:find('cannot parse query', 1, true))
  assert(not concise:find('stack traceback', 1, true))
  report.traceback = 'stack traceback:\nunit marker'
  local verbose = errors.format(report, true)
  assert(verbose:find('unit marker', 1, true))
  assert(verbose:find('raw failure', 1, true))
end)

test('empty and invalid line selections reject before register writes', function()
  h.buffer('')
  vim.fn.setreg('a', 'sentinel')
  local before = state()
  local ok, _, report = plugin.copy()
  assert(ok == false)
  eq(report.code, 'SELECTION')
  eq(state(), before)
  local snap = selection.snapshot(0)
  for _, range in ipairs({ { 0, 1 }, { 1, 2 }, { 2, 1 }, { 1.5, 1.5 } }) do
    local valid, err = pcall(selection.lines, snap, range[1], range[2])
    assert(not valid, vim.inspect(range))
    eq(err.code, 'SELECTION')
  end
end)

test('copy arguments and unsupported Neovim versions stop before snapshots or writes', function()
  h.buffer('local a=1')
  vim.fn.setreg('a', 'sentinel')
  local original = state()
  for _, argument in ipairs({ false, 1, {}, 'range' }) do
    local ok, _, report = plugin.copy(argument)
    assert(ok == false)
    eq(report.code, 'ARGUMENT')
    eq(report.level, vim.log.levels.ERROR)
    eq(state(), original)
  end
  local ok, _, report = plugin.copy(nil)
  assert(ok == false)
  eq(report.code, 'ARGUMENT')
  local has = vim.fn.has
  patch(vim.fn, 'has', function(feature)
    if feature == 'nvim-0.12' then return 0 end
    return has(feature)
  end, function()
    ok, _, report = plugin.copy()
    assert(ok == false)
    eq(report.code, 'VERSION')
    eq(report.level, vim.log.levels.ERROR)
    eq(state(), original)
  end)
end)

test('normal and explicit range commands share the unchanged snapshot pipeline', function()
  plugin.setup({ register = 'a', clipboard = false })
  h.buffer('local a=1\n\tlocal b="中文"\nlocal c=3')
  local original = { vim.api.nvim_buf_get_lines(0, 0, -1, true), vim.api.nvim_buf_get_changedtick(0), vim.fn.undotree() }
  no_parser(function()
    vim.cmd.CopyClean()
    eq(vim.fn.getreg('a'), 'local a=1\n\tlocal b="中文"\nlocal c=3\n')
    vim.cmd('2CopyClean')
    eq(vim.fn.getreg('a'), '\tlocal b="中文"\n')
    vim.cmd('2,3CopyClean')
    eq(vim.fn.getreg('a'), '\tlocal b="中文"\nlocal c=3\n')
  end)
  eq({ vim.api.nvim_buf_get_lines(0, 0, -1, true), vim.api.nvim_buf_get_changedtick(0), vim.fn.undotree() }, original)
end)

for _, selection_type in ipairs({ 'inclusive', 'exclusive', 'old' }) do
  for _, motion in ipairs({ 'gg0v2l', 'gg02lv2h', 'gg0v$', 'gg0vj$', 'ggvj', 'gg0v' }) do
    test('parser-independent native Visual bytes ' .. selection_type .. ' ' .. motion, function()
      h.buffer('中文\tfoo\n\tbar🙂\nvalue')
      vim.o.selection = selection_type
      h.keys(motion)
      local expected = table.concat(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = 'v' }), '\n')
      local original = selection.snapshot(0)
      no_parser(function() assert(plugin.copy()) end)
      eq(vim.fn.getreg('a'), expected)
      eq(vim.fn.getregtype('a'), 'v')
      eq(vim.fn.mode(), 'n')
      eq(selection.snapshot(0), original)
      h.keys('gv')
      eq(table.concat(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = 'v' }), '\n'), expected)
      h.keys('<Esc>')
    end)
  end
end

test('unsupported block and virtual selections retain active Visual mode and registers', function()
  h.buffer('local a=1\nlocal b=2')
  vim.fn.setreg('a', 'sentinel')
  h.keys('gg0<C-v>j')
  local ok, _, report = plugin.copy()
  assert(ok == false)
  eq(report.code, 'SELECTION')
  eq(vim.fn.mode(), '\22')
  eq(vim.fn.getreg('a'), 'sentinel')
  h.keys('<Esc>')
  vim.o.virtualedit = 'all'
  h.keys('gg$v3l')
  ok, _, report = plugin.copy()
  assert(ok == false)
  eq(report.code, 'SELECTION')
  eq(vim.fn.mode(), 'v')
  eq(vim.fn.getreg('a'), 'sentinel')
  h.keys('<Esc>')
  vim.o.virtualedit = ''
end)

test('language mapping failures and unsupported filetypes are classified', function()
  h.buffer('local a=1', 'unknown-language')
  vim.fn.setreg('a', 'sentinel')
  local ok, _, report = plugin.copy()
  assert(ok == false)
  eq(report.code, 'UNSUPPORTED_LANGUAGE')
  eq(vim.fn.getreg('a'), 'sentinel')
  h.buffer('local a=1')
  patch(vim.treesitter.language, 'get_lang', function() error('mapping failed') end, function()
    ok, _, report = plugin.copy()
    assert(ok == false)
    eq(report.code, 'LANGUAGE_MAP')
    eq(vim.fn.getreg('a'), 'sentinel')
  end)
end)

test('preflight failures never mutate registers or buffer and notify exactly once', function()
  for _, code in ipairs({ 'PARSER_MISSING', 'QUERY', 'SYNTAX', 'UNSUPPORTED_EMBEDDED', 'DIRECTIVE' }) do
    h.buffer('local a=1')
    vim.fn.setreg('a', 'sentinel')
    local original, before = state(), #messages
    patch(comments, 'collect', function() errors.raise(code, 'parse', 'injected preflight failure') end, function()
      local ok, message, report = plugin.copy()
      assert(ok == false and message:find('injected preflight failure', 1, true))
      eq(report.code, code)
      eq(report.partial, false)
    end)
    eq(state(), original)
    eq(#messages, before + 1)
    assert(messages[#messages][2] ~= vim.log.levels.INFO)
    assert(not messages[#messages][1]:find('stack traceback', 1, true))
  end
end)

test('unexpected failures expose traceback only in debug mode', function()
  h.buffer('local a=1')
  patch(comments, 'collect', function() error('unexpected marker') end, function()
    plugin.setup({ register = 'a', clipboard = false, debug = false })
    local ok, message, report = plugin.copy()
    assert(ok == false)
    eq(report.code, 'INTERNAL')
    assert(not message:find('stack traceback', 1, true))
    plugin.setup({ register = 'a', clipboard = false, debug = true })
    ok, message, report = plugin.copy()
    assert(ok == false)
    assert(message:find('stack traceback', 1, true))
    assert(message:find('unexpected marker', 1, true))
    assert(report.traceback:find('stack traceback', 1, true))
  end)
  plugin.setup({ register = 'a', clipboard = false })
end)

test('buffer change during callbacks rejects writes', function()
  h.buffer('local a=1')
  vim.fn.setreg('a', 'sentinel')
  patch(comments, 'collect', function()
    vim.api.nvim_buf_set_lines(0, 0, 1, true, { 'local changed=2' })
    return {}
  end, function()
    local ok, _, report = plugin.copy()
    assert(ok == false)
    eq(report.code, 'BUFFER_CHANGED')
    eq(vim.fn.getreg('a'), 'sentinel')
  end)
end)

test('register snapshot failure occurs before any write and restores clipboard option', function()
  vim.o.clipboard = 'unnamedplus'
  local before, calls = vim.fn.getreginfo('a'), 0
  patch(vim.fn, 'setreg', function() calls = calls + 1; return 0 end, function()
    patch(vim.fn, 'getreginfo', function() error('snapshot failed') end, function()
      local report = registers.write('copied', 'v', opts())
      assert(report.ok == false and report.partial == false)
      eq(report.code, 'REGISTER')
    end)
  end)
  eq(calls, 0)
  eq(vim.fn.getreginfo('a'), before)
  eq(vim.o.clipboard, 'unnamedplus')
  vim.o.clipboard = ''
end)

test('register write failure after an effect rolls back target and unnamed pointer', function()
  vim.fn.setreg('a', 'sentinel')
  vim.fn.setreg('b', 'unnamed sentinel')
  vim.fn.setreg('"', { points_to = 'b' })
  local before = { vim.fn.getreginfo('a'), vim.fn.getreginfo('"'), vim.fn.getreginfo('0') }
  local setreg, failed = vim.fn.setreg, false
  patch(vim.fn, 'setreg', function(reg, value, kind)
    if reg == 'a' and not failed then
      failed = true
      setreg(reg, value, kind)
      error('failure after effect')
    end
    if kind == nil then return setreg(reg, value) end
    return setreg(reg, value, kind)
  end, function()
    local report = registers.write('copied', 'v', opts())
    assert(report.ok == false and report.partial == false, vim.inspect(report))
    eq(report.code, 'REGISTER')
    eq(report.targets.a, 'restored')
  end)
  eq({ vim.fn.getreginfo('a'), vim.fn.getreginfo('"'), vim.fn.getreginfo('0') }, before)
end)

test('failed rollback reports unknown actual register state', function()
  local setreg = vim.fn.setreg
  patch(vim.fn, 'setreg', function(reg, value, kind)
    if reg == 'a' then
      if type(value) ~= 'table' or not value.regcontents then setreg(reg, value, kind) end
      error('write and rollback both failed')
    end
    if kind == nil then return setreg(reg, value) end
    return setreg(reg, value, kind)
  end, function()
    local report = registers.write('copied', 'v', opts())
    assert(report.ok == false and report.partial == true)
    eq(report.code, 'REGISTER')
    eq(report.targets.a, 'unknown')
  end)
end)

test('register 0 rollback verification detects setters that silently do nothing', function()
  vim.fn.setreg('0', 'zero sentinel')
  vim.fn.setreg('b', 'unnamed sentinel')
  vim.fn.setreg('"', { points_to = 'b' })
  local setreg, attempted = vim.fn.setreg, false
  patch(vim.fn, 'setreg', function(reg, value, kind)
    if reg == '0' then
      if not attempted then
        attempted = true
        setreg(reg, value, kind)
        error('failed after register 0 effect')
      end
      return 0 -- A false-success restoration must not be called a full rollback.
    end
    if kind == nil then return setreg(reg, value) end
    return setreg(reg, value, kind)
  end, function()
    local report = registers.write('copied', 'v', opts({ register = '0' }))
    assert(report.ok == false and report.partial == true, vim.inspect(report))
    eq(report.code, 'REGISTER')
    eq(report.targets['0'], 'unknown')
  end)
  eq(vim.fn.getreg('0'), 'copied')
end)

test('unnamed write failure restores register 0 and previous unnamed pointer', function()
  vim.fn.setreg('0', 'zero sentinel')
  vim.fn.setreg('b', 'unnamed sentinel')
  vim.fn.setreg('"', { points_to = 'b' })
  local original = { vim.fn.getreginfo('0'), vim.fn.getreginfo('"'), vim.fn.getreginfo('b') }
  local setreg, attempted = vim.fn.setreg, false
  patch(vim.fn, 'setreg', function(reg, value, kind)
    if reg == '"' and not attempted then
      attempted = true
      setreg(reg, value, kind)
      error('failed after unnamed effect')
    end
    if kind == nil then return setreg(reg, value) end
    return setreg(reg, value, kind)
  end, function()
    local report = registers.write('copied', 'v', opts({ register = '"' }))
    assert(report.ok == false and report.partial == false, vim.inspect(report))
    eq(report.targets['"'], 'restored')
  end)
  eq({ vim.fn.getreginfo('0'), vim.fn.getreginfo('"'), vim.fn.getreginfo('b') }, original)
end)

test('provider availability check exceptions cannot reach a register write', function()
  local before = vim.fn.getreginfo('a')
  patch(registers, 'available', function() error('provider check failed') end, function()
    local report = registers.write('copied', 'v', opts({ clipboard = true }))
    assert(report.ok == false and report.partial == false)
    eq(report.code, 'CLIPBOARD')
    eq(report.level, vim.log.levels.ERROR)
  end)
  eq(vim.fn.getreginfo('a'), before)
end)

test('clipboard unavailable gives a partial failure only after local copy succeeds', function()
  patch(registers, 'available', function() return false end, function()
    local report = registers.write('copied', 'v', opts({ clipboard = true }))
    assert(report.ok == false and report.partial == true)
    eq(report.code, 'CLIPBOARD')
    eq(report.level, vim.log.levels.WARN)
    eq(report.targets.a, 'written')
    eq(report.targets['+'], 'unavailable')
    eq(vim.fn.getreg('a'), 'copied')
    local target = registers.write('not copied', 'v', opts({ register = '+' }))
    assert(target.ok == false and target.partial == false)
    eq(target.code, 'CLIPBOARD')
  end)
end)

test('local target precedes clipboard and a provider error cannot claim complete success', function()
  local order, setreg = {}, vim.fn.setreg
  patch(registers, 'available', function() return true end, function()
    patch(vim.fn, 'setreg', function(reg, value, kind)
      order[#order + 1] = reg
      if reg == '+' then error('provider failed after possible effect') end
      if kind == nil then return setreg(reg, value) end
      return setreg(reg, value, kind)
    end, function()
      local report = registers.write('copied', 'v', opts({ clipboard = true }))
      assert(report.ok == false and report.partial == true)
      eq(report.code, 'CLIPBOARD')
      eq(report.level, vim.log.levels.WARN)
      eq(report.targets.a, 'written')
      eq(report.targets['+'], 'unknown')
      eq(order[1], 'a')
      eq(order[2], '+')
    end)
  end)
  eq(vim.fn.getreg('a'), 'copied')
end)

test('explicit clipboard targets never read external clipboard to snapshot it', function()
  local getreginfo, setreg = vim.fn.getreginfo, vim.fn.setreg
  patch(registers, 'available', function() return true end, function()
    patch(vim.fn, 'getreginfo', function(reg)
      assert(reg ~= '+' and reg ~= '*', 'unexpected external clipboard read')
      return getreginfo(reg)
    end, function()
      patch(vim.fn, 'setreg', function(reg, value, kind)
        if reg == '+' then return 0 end
        if kind == nil then return setreg(reg, value) end
        return setreg(reg, value, kind)
      end, function()
        local report = registers.write('copied', 'v', opts({ register = '+' }))
        assert(report.ok == true)
        eq(report.targets['+'], 'written')
      end)
    end)
  end)
end)

test('clipboard option clear failure performs no register write', function()
  local set, writes = vim.cmd.set, 0
  vim.o.clipboard = 'unnamedplus'
  patch(vim.cmd, 'set', function(args)
    if args.args[1] == 'clipboard=' then error('clear failed') end
    return set(args)
  end, function()
    patch(vim.fn, 'setreg', function() writes = writes + 1; return 0 end, function()
      local report = registers.write('copied', 'v', opts())
      assert(report.ok == false and report.partial == false)
      eq(report.code, 'STATE')
    end)
  end)
  eq(writes, 0)
  eq(vim.o.clipboard, 'unnamedplus')
  vim.o.clipboard = ''
end)

test('clipboard option restore fallback recovers from command failure', function()
  local set = vim.cmd.set
  vim.o.clipboard = 'unnamedplus'
  patch(vim.cmd, 'set', function(args)
    if args.args[1] == 'clipboard=unnamedplus' then error('restore failed') end
    return set(args)
  end, function()
    local report = registers.write('copied', 'v', opts())
    assert(report.ok == true)
  end)
  eq(vim.o.clipboard, 'unnamedplus')
  eq(vim.fn.getreg('a'), 'copied')
  vim.o.clipboard = ''
end)

test('failed clipboard option restoration reports the actual partial state', function()
  local set, option = vim.cmd.set, vim.api.nvim_set_option_value
  vim.o.clipboard = 'unnamedplus'
  patch(vim.cmd, 'set', function(args)
    if args.args[1] == 'clipboard=unnamedplus' then error('restore failed') end
    return set(args)
  end, function()
    patch(vim.api, 'nvim_set_option_value', function(name, value, settings)
      if name == 'clipboard' and value == 'unnamedplus' then error('fallback failed') end
      return option(name, value, settings)
    end, function()
      local report = registers.write('copied', 'v', opts())
      assert(report.ok == false and report.partial == true)
      eq(report.code, 'STATE')
      eq(report.targets.a, 'written')
    end)
  end)
  eq(vim.o.clipboard, '')
  vim.o.clipboard = ''
end)

test('copy propagates partial clipboard status in a single WARN notification', function()
  h.buffer('local a=1')
  plugin.setup({ register = 'a', clipboard = true })
  local before = #messages
  patch(registers, 'available', function() return false end, function()
    no_parser(function()
      local ok, message, report = plugin.copy()
      assert(ok == false and report.partial == true)
      eq(report.code, 'CLIPBOARD')
      assert(message:find('clipboard', 1, true))
    end)
  end)
  eq(#messages, before + 1)
  eq(messages[#messages][2], vim.log.levels.WARN)
  eq(vim.fn.getreg('a'), 'local a=1\n')
  plugin.setup({ register = 'a', clipboard = false })
end)

test('Visual exit failure reports written registers without claiming complete success', function()
  h.buffer('local a=1')
  h.keys('ggv4l')
  local expected = table.concat(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = 'v' }), '\n')
  no_parser(function()
    patch(vim.cmd, 'normal', function() error('Visual exit failed') end, function()
      local ok, _, report = plugin.copy()
      assert(ok == false and report.partial == true)
      eq(report.code, 'STATE')
      eq(report.targets.a, 'written')
      eq(vim.fn.getreg('a'), expected)
    end)
  end)
  h.keys('<Esc>')
end)

test('provider source edits report partial writes and leave Visual state untouched', function()
  h.buffer('local value=1')
  h.keys('ggv2l')
  local source = vim.api.nvim_get_current_buf()
  plugin.setup({ register = 'a', clipboard = true })
  local setreg = vim.fn.setreg
  no_parser(function()
    patch(registers, 'available', function() return true end, function()
      patch(vim.fn, 'setreg', function(reg, value, kind)
        if reg == '+' then
          vim.api.nvim_buf_set_lines(source, 0, -1, true, { 'changed by provider' })
          return 0
        end
        if kind == nil then return setreg(reg, value) end
        return setreg(reg, value, kind)
      end, function()
        local ok, _, report = plugin.copy()
        assert(ok == false and report.partial == true)
        eq(report.code, 'BUFFER_CHANGED')
        eq(report.level, vim.log.levels.WARN)
        eq(report.targets.a, 'written')
        eq(report.targets['+'], 'written')
      end)
    end)
  end)
  eq(vim.fn.getreg('a'), 'loc')
  eq(vim.fn.mode(), 'v')
  eq(vim.api.nvim_buf_get_lines(source, 0, -1, true), { 'changed by provider' })
  h.keys('<Esc>')
  plugin.setup({ register = 'a', clipboard = false })
end)

test('provider buffer switches never restore the old cursor into the new buffer', function()
  h.buffer('local value=1\nlocal second=2')
  vim.api.nvim_win_set_cursor(0, { 2, 5 })
  local replacement = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(replacement, 0, -1, true, { 'replacement' })
  plugin.setup({ register = 'a', clipboard = true })
  local setreg = vim.fn.setreg
  no_parser(function()
    patch(registers, 'available', function() return true end, function()
      patch(vim.fn, 'setreg', function(reg, value, kind)
        if reg == '+' then
          vim.api.nvim_set_current_buf(replacement)
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          return 0
        end
        if kind == nil then return setreg(reg, value) end
        return setreg(reg, value, kind)
      end, function()
        local ok, _, report = plugin.copy()
        assert(ok == false and report.partial == true)
        eq(report.code, 'BUFFER_CHANGED')
        eq(report.targets.a, 'written')
      end)
    end)
  end)
  eq(vim.api.nvim_get_current_buf(), replacement)
  eq(vim.api.nvim_win_get_cursor(0), { 1, 0 })
  eq(vim.fn.getreg('a'), 'local value=1\nlocal second=2\n')
  plugin.setup({ register = 'a', clipboard = false })
end)

test('notification errors fall back once without losing the operation result', function()
  h.buffer('local a=1')
  local echoed = {}
  no_parser(function()
    patch(vim, 'notify', function() error('notify unavailable') end, function()
      patch(vim.api, 'nvim_echo', function(chunks) echoed[#echoed + 1] = chunks end, function()
        local ok, message, report = plugin.copy()
        assert(ok and report.ok)
        eq(#echoed, 1)
        eq(echoed[1][1][1], message)
        eq(select(2, message:gsub('CopyClean:', '')), 1)
      end)
    end)
  end)
end)

test('native health diagnostics check dependencies without changing copy state', function()
  h.buffer('local a=1')
  plugin.setup({ register = 'a', clipboard = true })
  vim.fn.setreg('a', 'sentinel')
  local original, reports = state(), {}
  local health = {}
  for _, level in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
    health[level] = function(message) reports[#reports + 1] = { level, message } end
  end
  patch(vim, 'health', health, function()
    patch(vim.treesitter.language, 'add', function() return true end, function()
      patch(comments, 'load_query', function() return {} end, function()
        patch(registers, 'available', function() return false end, function()
          require('clean_copy.health').check()
        end)
      end)
    end)
  end)
  eq(state(), original)
  assert(vim.iter(reports):any(function(item) return item[1] == 'warn' and item[2]:find('Clipboard provider', 1, true) end))
  assert(vim.iter(reports):any(function(item) return item[1] == 'ok' and item[2]:find('CopyClean', 1, true) end))
  reports = {}
  patch(vim, 'health', health, function()
    patch(vim.treesitter.language, 'add', function() return false end, function()
      require('clean_copy.health').check()
    end)
  end)
  assert(vim.iter(reports):any(function(item) return item[1] == 'error' and item[2]:find('parser', 1, true) end))
  eq(state(), original)
  local exposed = plugin.get_config()
  exposed.register = 'b'
  exposed.language_overrides.lua = 'c'
  eq(plugin.get_config().register, 'a')
  eq(plugin.get_config().language_overrides, {})
  plugin.setup({ register = 'a', clipboard = false })
end)

test('directive callbacks must return booleans and failures have an actionable category', function()
  local node = { range = function() return 0, 0, 0, 10 end, field = function() return {} end }
  for _, callback in ipairs({ function() return 'yes' end, function() error('bad callback') end }) do
    local ok, err = pcall(rules.keep, '-- ordinary', 'lua', node, opts({ directive_rules = { callback } }))
    assert(not ok)
    eq(err.code, 'DIRECTIVE')
  end
end)

test('semantically significant type, pure and conditional directives are retained', function()
  local node = { range = function() return 0, 0, 0, 10 end, field = function() return {} end }
  for _, fixture in ipairs({ { '# type: int', 'python' }, { '/*#__PURE__*/', 'javascript' },
    { '/*@__PURE__*/', 'typescript' }, { '<!--[if IE]>x<![endif]-->', 'html' } }) do
    assert(rules.keep(fixture[1], fixture[2], node, opts()), fixture[1])
  end
end)

test('transformation keeps source whitespace and separator bytes without formatting', function()
  h.buffer('foo/*中文*/bar\n\n \t\n-- note')
  local snap = selection.snapshot(0)
  eq(transform.apply(snap, selection.lines(snap, 1, 4), { { 3, 13 }, { snap.starts[4], #snap.text } }, opts()),
    'foo bar\n\n \t')
end)

h.finish('unit')
