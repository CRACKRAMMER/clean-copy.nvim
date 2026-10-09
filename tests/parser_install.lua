-- Offline regression tests for explicit parser maintenance.
-- Run with --clean and isolated XDG directories. All install/update/process
-- operations below are mocked; this file never downloads or compiles parsers.
local root = vim.fn.getcwd()
vim.opt.runtimepath = { root, vim.env.VIMRUNTIME }
vim.o.swapfile = false
vim.o.clipboard = ''
local command_name = 'CopyCleanParsers'

local passed, failed = 0, 0
local state
local original_notify = vim.notify
local original_system = vim.system
local original_executable = vim.fn.executable
local original_schedule = vim.schedule
local original_cc = vim.env.CC

local function equal(actual, expected, label)
  assert(vim.deep_equal(actual, expected), (label or 'values differ') .. '\nexpected: '
    .. vim.inspect(expected) .. '\nactual: ' .. vim.inspect(actual))
end

local function truth(value, label)
  assert(value, label or 'expected true')
end

local function flush()
  for _ = 1, 40 do
    if #state.scheduled == 0 then return end
    local scheduled = state.scheduled
    state.scheduled = {}
    for _, callback in ipairs(scheduled) do callback() end
  end
  error('scheduled callbacks did not settle')
end

local function task()
  local t = { callbacks = {}, completed = false }
  function t:await(callback)
    if state.await_throw then
      if state.await_throw_after_subscribe then self.callbacks[#self.callbacks + 1] = callback end
      error('await subscription failed')
    end
    if self.completed then callback(self.err, self.result)
    else self.callbacks[#self.callbacks + 1] = callback end
  end
  function t:finish(err, result)
    truth(not self.completed, 'a task must complete only once')
    self.completed, self.err, self.result = true, err, result
    local callbacks = self.callbacks
    self.callbacks = {}
    for _, callback in ipairs(callbacks) do callback(err, result) end
  end
  return t
end

local function reset(options)
  options = options or {}
  vim.env.CC = nil
  for _, name in ipairs({ command_name, 'CopyClean', 'CleanCopy', 'DotfilesTSInstall' }) do
    pcall(vim.api.nvim_del_user_command, name)
  end
  for name in pairs(package.loaded) do
    if name == 'clean_copy' or name:match('^clean_copy%.') then package.loaded[name] = nil end
  end
  vim.g.loaded_clean_copy = nil
  state = {
    notifications = {}, processes = {}, scheduled = {}, operations = {},
    installed = options.installed or { 'lua' },
    available = options.available or { 'lua', 'python', 'javascript', 'typescript', 'tsx', 'c' },
    binaries = { ['tree-sitter'] = 1, curl = 1, tar = 1, cc = 1, gcc = 1, clang = 1 },
    version = 'tree-sitter 0.26.1\n', version_code = 0,
  }
  vim.schedule = function(callback) state.scheduled[#state.scheduled + 1] = callback end
  vim.notify = function(message, level, opts)
    state.notifications[#state.notifications + 1] = { message = tostring(message), level = level, opts = opts }
  end
  vim.fn.executable = function(name) return state.binaries[name] or 0 end
  vim.system = function(command, opts, callback)
    if state.process_throw then error(state.process_throw) end
    if type(opts) == 'function' then callback, opts = opts, nil end
    state.processes[#state.processes + 1] = vim.deepcopy(command)
    equal(command, { 'tree-sitter', '--version' }, 'only the CLI version probe may spawn a mocked process')
    local result = { code = state.version_code, stdout = state.version, stderr = state.version_stderr or '' }
    if callback then vim.schedule(function() callback(result) end) end
    return { wait = function() return result end }
  end
  local treesitter = {}
  function treesitter.get_available(tier)
    if state.registry_throw then error(state.registry_throw) end
    if state.registry_callback then state.registry_callback() end
    return vim.deepcopy(tier == 4 and (state.unsupported or {}) or state.available)
  end
  function treesitter.get_installed(kind)
    if state.discovery_throw then error(state.discovery_throw) end
    state.installed_kind = kind
    return vim.deepcopy(state.installed)
  end
  for _, operation in ipairs({ 'install', 'update' }) do
    treesitter[operation] = function(languages, opts)
      if state.operation_throw then error(state.operation_throw) end
      local t = task()
      state.operations[#state.operations + 1] = {
        kind = operation, languages = vim.deepcopy(languages), options = vim.deepcopy(opts), task = t,
      }
      if state.auto_complete then t:finish(nil, true) end
      if state.invalid_task then return state.invalid_return end
      return t
    end
  end
  package.loaded['nvim-treesitter'] = treesitter
  if options.foreign_command then
    vim.api.nvim_create_user_command(command_name, options.foreign_command, {})
  end
  local plugin = require('clean_copy')
  return {
    setup = function(parsers, extra)
      local opts = vim.tbl_extend('force', { parser_languages = parsers, clipboard = false }, extra or {})
      return plugin.setup(opts)
    end,
    plugin = plugin,
  }
end

local function command(arguments, bang)
  vim.cmd(command_name .. (bang and '!' or '') .. (arguments and ' ' .. arguments or ''))
  flush()
end

local function message(pattern, level)
  flush()
  for _, item in ipairs(state.notifications) do
    if item.message:lower():find(pattern:lower(), 1, true) and (not level or item.level == level) then return item end
  end
  error('missing notification ' .. pattern .. ' at level ' .. tostring(level) .. ': ' .. vim.inspect(state.notifications))
end

local function run(name, callback)
  local ok, err = xpcall(callback, debug.traceback)
  if ok then passed = passed + 1; print('PASS ' .. name)
  else failed = failed + 1; print('FAIL ' .. name .. '\n' .. err) end
end

run('setup registers commands without network or compilation', function()
  local module = reset()
  truth(vim.api.nvim_get_commands({})[command_name], 'require must register parser maintenance without setup')
  module.setup({ 'lua', 'python' })
  local commands = vim.api.nvim_get_commands({})
  truth(commands[command_name], 'new command must be registered')
  equal(commands[command_name].nargs, '*', 'accept explicit parser names')
  truth(commands[command_name].bang, 'allow force rebuilding')
  truth(not commands.DotfilesTSInstall, 'old alias must not be registered')
  equal(state.processes, {}, 'setup must not probe or install dependencies')
  equal(state.operations, {}, 'setup must not install parsers')
  equal(state.installed_kind, nil, 'setup must not inspect or create installation directories')
end)

run('plugin runtime loader registers parser maintenance without setup', function()
  reset()
  pcall(vim.api.nvim_del_user_command, command_name)
  pcall(vim.api.nvim_del_user_command, 'CopyClean')
  for name in pairs(package.loaded) do
    if name == 'clean_copy' or name:match('^clean_copy%.') then package.loaded[name] = nil end
  end
  vim.g.loaded_clean_copy = nil
  dofile('plugin/clean_copy.lua')
  truth(vim.api.nvim_get_commands({})[command_name])
  truth(vim.api.nvim_get_commands({}).CopyClean)
  equal(state.processes, {})
  equal(state.operations, {})
end)

run('lazy command placeholder forwards parser arguments after plugin loading', function()
  reset({ installed = {} })
  pcall(vim.api.nvim_del_user_command, command_name)
  pcall(vim.api.nvim_del_user_command, 'CopyClean')
  for name in pairs(package.loaded) do
    if name == 'clean_copy' or name:match('^clean_copy%.') then package.loaded[name] = nil end
  end
  vim.g.loaded_clean_copy = nil
  local loaded = 0
  vim.api.nvim_create_user_command(command_name, function(options)
    loaded = loaded + 1
    vim.api.nvim_del_user_command(command_name)
    require('clean_copy').setup({ parser_languages = { 'lua', 'python' }, clipboard = false })
    vim.cmd(command_name .. (options.bang and '!' or '') .. ' ' .. table.concat(options.fargs, ' '))
  end, { nargs = '*', bang = true })
  command('python', true)
  equal(loaded, 1)
  equal(#state.operations, 1)
  equal(state.operations[1].kind, 'install')
  equal(state.operations[1].languages, { 'python' })
  equal(state.operations[1].options.force, true)
end)

run('repeated setup retains command registration and updates configured languages', function()
  local module = reset()
  module.setup({ 'lua' })
  module.setup({ 'python' })
  command()
  equal(#state.operations, 1)
  equal(state.operations[1].kind, 'install')
  equal(state.operations[1].languages, { 'python' })
end)

run('existing unrelated command is not overwritten', function()
  local calls = 0
  local module = reset({ foreign_command = function() calls = calls + 1 end })
  module.setup({ 'lua' })
  vim.cmd(command_name)
  equal(calls, 1, 'foreign command must remain callable')
  equal(state.operations, {})
  message(command_name, vim.log.levels.ERROR)
end)

run('invalid parser names abort before executing processes or writes', function()
  local module = reset()
  module.setup({ 'lua' })
  command('lua invalid-parser')
  equal(state.operations, {})
  equal(state.processes, {})
  message('invalid-parser', vim.log.levels.ERROR)
end)

run('missing CLI gives actionable error before installing', function()
  local module = reset()
  state.binaries['tree-sitter'] = 0
  module.setup({ 'python' })
  command()
  equal(state.operations, {})
  message('tree-sitter', vim.log.levels.ERROR)
end)

run('old CLI version aborts before installation', function()
  local module = reset()
  state.version = 'tree-sitter 0.25.10\n'
  module.setup({ 'python' })
  command()
  equal(state.operations, {})
  message('0.26.1', vim.log.levels.ERROR)
end)

run('prerelease CLI is rejected even at required version', function()
  local module = reset()
  state.version = 'tree-sitter 0.26.1-beta.1\n'
  module.setup({ 'python' })
  command()
  equal(state.operations, {})
  message('stable', vim.log.levels.ERROR)
end)

run('unreadable CLI version aborts before installation', function()
  local module = reset()
  state.version = ''
  module.setup({ 'python' })
  command()
  equal(state.operations, {})
  message('version', vim.log.levels.ERROR)
end)

run('failed CLI version process aborts before installation', function()
  local module = reset()
  state.version_code, state.version_stderr = 1, 'version probe failed'
  module.setup({ 'python' })
  command()
  equal(state.operations, {})
  truth(state.notifications[#state.notifications].level == vim.log.levels.ERROR)
end)

run('missing download and compiler dependencies abort before installation', function()
  for _, missing in ipairs({ 'curl', 'tar', 'compiler' }) do
    local module = reset()
    if missing == 'compiler' then
      state.binaries.cc, state.binaries.gcc, state.binaries.clang = 0, 0, 0
    else state.binaries[missing] = 0 end
    module.setup({ 'python' })
    command()
    equal(state.operations, {}, 'no partial work when ' .. missing .. ' is unavailable')
    truth(#state.notifications > 0, 'missing dependency must produce diagnostic')
    equal(state.notifications[#state.notifications].level, vim.log.levels.ERROR)
  end
end)

run('explicit CC is honored and missing CC does not silently fall back', function()
  local module = reset()
  vim.env.CC = 'chosen-compiler'
  module.setup({ 'python' })
  command()
  equal(state.operations, {}, 'explicit nonexistent compiler cannot silently use cc')
  message('chosen-compiler', vim.log.levels.ERROR)
  state.binaries['chosen-compiler'] = 1
  command()
  equal(#state.operations, 1, 'available explicit CC permits the workflow')
end)

run('explicit parser list is deduplicated and limits compiler concurrency', function()
  local module = reset({ installed = {} })
  module.setup({ 'lua', 'python', 'c' })
  command('python python c')
  equal(#state.operations, 1)
  equal(state.operations[1].kind, 'install')
  equal(state.operations[1].languages, { 'python', 'c' })
  equal(state.operations[1].options.max_jobs, 2)
  equal(state.operations[1].options.force, true, 'repair missing or partial parser installs')
end)

run('arguments outside configured parser list are rejected', function()
  local module = reset()
  module.setup({ 'lua' })
  command('python')
  equal(state.operations, {})
  equal(state.processes, {})
  message('python', vim.log.levels.ERROR)
end)

run('unsupported registry tier is rejected before dependency checks', function()
  local module = reset()
  state.unsupported = { 'python' }
  module.setup({ 'python' })
  command()
  equal(state.processes, {})
  equal(state.operations, {})
  message('python', vim.log.levels.ERROR)
end)

run('parser registry exceptions are diagnosed without starting work', function()
  local module = reset()
  state.registry_throw = 'registry read failed'
  module.setup({ 'python' }, { debug = true })
  command()
  equal(state.processes, {})
  equal(state.operations, {})
  message('registry read failed', vim.log.levels.ERROR)
end)

run('invalid configuration preserves previous parser language list', function()
  local module = reset()
  truth(module.setup({ 'python' }) ~= false)
  equal(module.setup({ 'c', false }), false)
  equal(module.plugin.get_config().parser_languages, { 'python' })
  command()
  equal(state.operations[1].languages, { 'python' })
end)

run('in-flight CLI preflight keeps its original configuration snapshot', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' })
  vim.cmd(command_name)
  equal(state.operations, {}, 'version callback must not block command execution')
  module.setup({ 'c' })
  flush()
  equal(state.operations[1].languages, { 'python' })
  state.operations[1].task:finish(nil, true)
  flush()
  command()
  equal(state.operations[2].languages, { 'c' })
end)

run('command completion offers configured languages', function()
  local module = reset()
  module.setup({ 'lua', 'python' })
  local completion = vim.fn.getcompletion(command_name .. ' p', 'cmdline')
  equal(completion, { 'python' })
  equal(state.processes, {}, 'completion must not probe build tools')
  equal(state.operations, {}, 'completion must not start installation')
end)

run('missing parser installation completes before updating installed parsers', function()
  local module = reset()
  module.setup({ 'lua', 'python', 'c' })
  command()
  equal(state.installed_kind, 'parsers', 'query folders alone must not count as installed parsers')
  equal(#state.operations, 1)
  equal(state.operations[1].kind, 'install')
  equal(state.operations[1].languages, { 'python', 'c' })
  equal(state.operations[1].options, { force = true, max_jobs = 2, summary = false })
  state.operations[1].task:finish(nil, true)
  flush()
  equal(#state.operations, 2)
  equal(state.operations[2].kind, 'update')
  equal(state.operations[2].languages, { 'lua' })
  equal(state.operations[2].options, { max_jobs = 2, summary = false })
  state.operations[2].task:finish(nil, true)
  flush()
  equal(state.notifications[#state.notifications].level, vim.log.levels.INFO)
end)

run('failed missing parser installation skips the update phase', function()
  local module = reset()
  module.setup({ 'lua', 'python' })
  command()
  state.operations[1].task:finish(nil, false)
  flush()
  equal(#state.operations, 1, 'a failed phase must stop subsequent work')
  truth(state.notifications[#state.notifications].level ~= vim.log.levels.INFO)
end)

run('empty configured parser list does not require build dependencies', function()
  local module = reset()
  state.binaries = {}
  module.setup({})
  command()
  equal(state.operations, {})
  equal(state.processes, {})
  equal(state.notifications[#state.notifications].level, vim.log.levels.INFO)
end)

run('an up-to-date backend result completes normally', function()
  local module = reset()
  module.setup({ 'lua' })
  command()
  equal(#state.operations, 1)
  equal(state.operations[1].kind, 'update')
  state.operations[1].task:finish(nil, true)
  flush()
  equal(state.notifications[#state.notifications].level, vim.log.levels.INFO)
end)

run('bang rebuilds selected installed and missing parsers', function()
  local module = reset()
  module.setup({ 'lua', 'python' })
  command(nil, true)
  equal(#state.operations, 1)
  equal(state.operations[1].kind, 'install')
  equal(state.operations[1].languages, { 'lua', 'python' })
  equal(state.operations[1].options.force, true)
  equal(state.operations[1].options.max_jobs, 2)
end)

run('busy operation rejects overlap until task completes', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' })
  command()
  equal(#state.operations, 1)
  command()
  equal(#state.operations, 1, 'second request must not start concurrent work')
  message('running', vim.log.levels.WARN)
  state.operations[1].task:finish(nil, true)
  flush()
  command()
  equal(#state.operations, 2, 'completion must release busy lock')
end)

run('busy lock also covers pending CLI version callbacks', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' })
  vim.cmd(command_name)
  equal(state.operations, {})
  vim.cmd(command_name)
  equal(#state.processes, 1, 'pending version probe must block a duplicate probe')
  flush()
  equal(#state.operations, 1)
  message('running', vim.log.levels.WARN)
end)

run('registry User TSUpdate callbacks cannot start reentrant maintenance', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' })
  local reentered = false
  state.registry_callback = function()
    if reentered then return end
    reentered = true
    vim.cmd(command_name)
  end
  command()
  equal(#state.processes, 1, 'get_available can trigger TSUpdate autocmds before returning')
  equal(#state.operations, 1, 'nested command must not start duplicate installation')
  message('running', vim.log.levels.WARN)
end)

run('already-completed tasks finish both phases and release busy lock', function()
  local module = reset()
  state.auto_complete = true
  module.setup({ 'lua', 'python' })
  command()
  equal(#state.operations, 2)
  equal(state.operations[1].kind, 'install')
  equal(state.operations[2].kind, 'update')
  equal(state.notifications[#state.notifications].level, vim.log.levels.INFO)
  command()
  equal(#state.operations, 4, 'synchronous await completion must release the lock')
end)

run('invalid task API retains busy lock when operation state is unknown', function()
  for _, invalid in ipairs({
    { name = 'nil' },
    { name = 'empty table', value = {} },
    { name = 'number', value = 1 },
    { name = 'boolean', value = true },
    { name = 'false', value = false },
    { name = 'function', value = function() end },
    { name = 'throwing index', value = setmetatable({}, { __index = function() error('task index failed') end }) },
  }) do
    local module = reset({ installed = {} })
    module.setup({ 'python' })
    state.invalid_task, state.invalid_return = true, invalid.value
    command()
    equal(#state.operations, 1, invalid.name)
    message('incompatible task', vim.log.levels.ERROR)
    message('restart', vim.log.levels.ERROR)
    command()
    equal(#state.operations, 1, 'unmonitored ' .. invalid.name .. ' operation must prevent duplicate installs')
    message('could not be monitored', vim.log.levels.WARN)
  end
end)

run('await subscription exception retains busy lock when task cannot be monitored', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' }, { debug = true })
  state.await_throw = true
  command()
  equal(#state.operations, 1)
  message('await subscription failed', vim.log.levels.ERROR)
  command()
  equal(#state.operations, 1)
  message('restart', vim.log.levels.WARN)
end)

run('known task completion can release lock after subscription throws', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' })
  state.await_throw, state.await_throw_after_subscribe = true, true
  command()
  state.await_throw = false
  state.operations[1].task:finish(nil, true)
  flush()
  command()
  equal(#state.operations, 2, 'a known successful callback can permit another install')
  command()
  message('already running', vim.log.levels.WARN)
end)

run('update phase failure after installation cannot report complete success', function()
  for _, failure in ipairs({ 'false-result', 'async-error' }) do
    local module = reset()
    module.setup({ 'lua', 'python' }, { debug = true })
    command()
    state.operations[1].task:finish(nil, true)
    flush()
    equal(#state.operations, 2)
    local task = state.operations[2].task
    if failure == 'false-result' then task:finish(nil, false)
    else task:finish('update backend failed') end
    flush()
    local item = state.notifications[#state.notifications]
    equal(item.level, failure == 'false-result' and vim.log.levels.WARN or vim.log.levels.ERROR)
    truth(item.message:find('may already', 1, true), 'update failure must disclose installed parsers')
    command()
    equal(#state.operations, 3, 'update failure must release busy lock')
  end
end)

run('CLI spawn exception releases busy lock before retry', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' }, { debug = true })
  state.process_throw = 'process launch failed'
  command()
  equal(state.operations, {})
  message('process launch failed', vim.log.levels.ERROR)
  state.process_throw = nil
  command()
  equal(#state.operations, 1)
end)

run('missing nvim-treesitter gives actionable diagnostic without subprocesses', function()
  local module = reset()
  module.setup({ 'python' })
  package.loaded['nvim-treesitter'] = nil
  command()
  equal(state.processes, {})
  equal(state.operations, {})
  message('nvim-treesitter', vim.log.levels.ERROR)
end)

run('maintenance success and failure preserve source buffer and registers', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local untouched = "source"' })
  vim.fn.setreg('a', 'named register')
  vim.fn.setreg('0', 'yank register')
  local buf = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local registers = { vim.fn.getreginfo('a'), vim.fn.getreginfo('0'), vim.fn.getreginfo('"') }
  local clipboard = vim.o.clipboard
  command()
  state.operations[1].task:finish(nil, true)
  flush()
  command()
  state.operations[2].task:finish(nil, false)
  flush()
  equal(vim.api.nvim_get_current_buf(), buf)
  equal(vim.api.nvim_buf_get_changedtick(buf), tick)
  equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'local untouched = "source"' })
  equal({ vim.fn.getreginfo('a'), vim.fn.getreginfo('0'), vim.fn.getreginfo('"') }, registers)
  equal(vim.o.clipboard, clipboard)
end)

run('installer false result is failure and releases busy lock', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' })
  command()
  state.operations[1].task:finish(nil, false)
  flush()
  truth(state.notifications[#state.notifications].level ~= vim.log.levels.INFO, 'false cannot report success')
  command()
  equal(#state.operations, 2)
end)

run('asynchronous installer error releases busy lock and reports failure', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' }, { debug = true })
  command()
  state.operations[1].task:finish('compiler failed')
  flush()
  message('compiler failed', vim.log.levels.ERROR)
  command()
  equal(#state.operations, 2)
end)

run('normal diagnostic hides backend exception details and marks partial changes', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' })
  command()
  state.operations[1].task:finish('private backend raw details')
  flush()
  local item = state.notifications[#state.notifications]
  equal(item.level, vim.log.levels.ERROR)
  truth(not item.message:find('private backend raw details', 1, true), 'raw cause should require debug')
  truth(item.message:find('may already', 1, true), 'failure must disclose possible partial installation')
end)

run('parser discovery exceptions release busy lock before retry', function()
  local module = reset()
  module.setup({ 'python' }, { debug = true })
  state.discovery_throw = 'parser discovery failed'
  command()
  equal(state.operations, {})
  message('parser discovery failed', vim.log.levels.ERROR)
  state.discovery_throw = nil
  command()
  equal(#state.operations, 1)
end)

run('synchronous installer exception releases busy lock', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' }, { debug = true })
  state.operation_throw = 'backend unavailable'
  command()
  message('backend unavailable', vim.log.levels.ERROR)
  state.operation_throw = nil
  command()
  equal(#state.operations, 1)
end)

run('old command is not registered or removed if owned elsewhere', function()
  local module = reset({ installed = {} })
  module.setup({ 'python' })
  equal(vim.fn.exists(':DotfilesTSInstall'), 0, 'the deprecated alias must not be registered')
  local calls = 0
  vim.api.nvim_create_user_command('DotfilesTSInstall', function() calls = calls + 1 end, {})
  module.setup({ 'python' })
  vim.cmd('DotfilesTSInstall')
  equal(calls, 1, 'a foreign legacy command must not be removed')
  equal(state.operations, {})
end)

vim.notify, vim.system, vim.fn.executable, vim.schedule = original_notify, original_system, original_executable, original_schedule
vim.env.CC = original_cc
print(('Tree-sitter workflow: %d passed, %d failed'):format(passed, failed))
vim.cmd(failed == 0 and 'qa!' or 'cquit 1')
