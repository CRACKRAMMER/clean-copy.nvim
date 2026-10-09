-- Optional, explicit parser maintenance. Copying only uses Neovim's runtime.
local errors = require('clean_copy.errors')
local M = {}
local running, unmonitored = false, false
local levels = vim.log.levels

local function compiler_available()
  local compiler = vim.env.CC
  if compiler and compiler ~= '' then
    if vim.fn.executable(compiler) == 1 then return true end
    -- cc-rs accepts CC with a wrapper/arguments as well as an executable path.
    local program = compiler:match('^%s*"([^"]+)"') or compiler:match("^%s*'([^']+)'")
      or compiler:match('^%s*(%S+)')
    return program and vim.fn.executable(program) == 1, 'C compiler specified by CC=' .. compiler
  end
  for _, name in ipairs({'cc', 'gcc', 'clang'}) do
    if vim.fn.executable(name) == 1 then return true end
  end
  return false, 'C compiler (cc, gcc or clang)'
end

local function dependencies()
  if vim.fn.has('nvim-0.12') ~= 1 or vim.treesitter.language_version < 13 then
    return false, 'Neovim 0.12+ with Tree-sitter runtime ABI 13+ is required'
  end
  local missing = {}
  for _, name in ipairs({'tree-sitter', 'curl', 'tar'}) do
    if vim.fn.executable(name) ~= 1 then missing[#missing + 1] = name end
  end
  local ok, compiler = compiler_available()
  if not ok then missing[#missing + 1] = compiler end
  if #missing > 0 then return false, 'missing ' .. table.concat(missing, ', ') end
  return true
end

function M.run(command, options)
  local debug_enabled = options.debug
  if running then
    errors.notify(errors.new('PARSER_BUSY', 'parser-install', unmonitored
      and 'a previous parser operation could not be monitored' or 'parser maintenance is already running', {
      level = levels.WARN, hint = unmonitored and 'Restart Neovim before retrying to avoid overlapping file changes.'
        or 'Wait for completion before starting another :CopyCleanParsers command.',
    }), debug_enabled)
    return false
  end
  -- get_available() runs User TSUpdate hooks, which can re-enter this command.
  running, unmonitored = true, false
  local started = false
  local function info(message)
    errors.notify({ok = true, partial = false, code = 'OK', stage = 'parser-install',
      message = message, level = levels.INFO}, debug_enabled)
  end
  local function fail(code, stage, message, extra)
    unmonitored = extra and extra.keep_busy or false
    running = unmonitored
    if extra then extra.keep_busy = nil end
    extra = vim.tbl_extend('force', {
      partial = started,
      hint = (started and 'Some parsers or queries may already have changed; installation is not transactional. '
        or 'No parser installation was started. ')
        .. 'Check :messages and :checkhealth nvim-treesitter, then retry.',
    }, extra or {})
    errors.notify(errors.new(code, stage, message, extra), debug_enabled)
  end
  local function protect(stage, callback)
    local ok, err = xpcall(callback, errors.handler(stage))
    if not ok then
      fail('PARSER_INSTALL', stage, 'parser maintenance stopped unexpectedly', {cause = err})
    end
    return ok
  end
  local function synchronize(treesitter, selected)
    -- Unlike get_installed(), this excludes leftover query-only installations.
    local installed = treesitter.get_installed('parsers')
    local known, missing, present = {}, {}, {}
    for _, language in ipairs(installed) do known[language] = true end
    for _, language in ipairs(selected) do
      local target = known[language] and present or missing
      target[#target + 1] = language
    end
    local phases = {}
    if command.bang then
      phases[1] = {name = 'rebuild', method = 'install', languages = selected, force = true}
    else
      if #missing > 0 then
        -- Force repairs a missing binary even if its query directory exists.
        phases[#phases + 1] = {name = 'install', method = 'install', languages = missing, force = true}
      end
      if #present > 0 then
        phases[#phases + 1] = {name = 'update', method = 'update', languages = present}
      end
    end
    info((command.bang and 'rebuilding ' or 'synchronizing ') .. #selected
      .. ' configured languages and required dependencies (at most 2 concurrent jobs)')
    local function next_phase(index)
      local phase = phases[index]
      if not phase then
        running, unmonitored = false, false
        info('selected parsers and required queries are synchronized; restart Neovim to reload previously loaded parsers')
        return
      end
      local task_options = {max_jobs = 2, summary = false}
      if phase.force then task_options.force = true end
      started = true
      local task = treesitter[phase.method](phase.languages, task_options)
      local readable, await = pcall(function() return task and task.await end)
      if not readable or type(await) ~= 'function' then
        fail('DEPENDENCY', 'parser-' .. phase.name, 'nvim-treesitter returned an incompatible task', {
          keep_busy = true, cause = not readable and await or nil,
          hint = 'An operation may still be running. Check :messages, update nvim-treesitter main and restart Neovim before retrying.',
        })
        return
      end
      local subscribed, reason = pcall(await, task, function(err, success)
        vim.schedule(function()
          protect('parser-' .. phase.name, function()
            if err then
              fail('PARSER_INSTALL', 'parser-' .. phase.name, 'parser maintenance failed', {cause = err})
            elseif success ~= true then
              fail('PARSER_INSTALL', 'parser-' .. phase.name, 'one or more parser/query operations failed', {level = levels.WARN})
            else next_phase(index + 1) end
          end)
        end)
      end)
      if not subscribed then
        fail('PARSER_INSTALL', 'parser-' .. phase.name, 'could not monitor the parser task', {
          cause = reason, keep_busy = true,
          hint = 'The task may still be running. Check :messages and restart Neovim before retrying to avoid overlapping file changes.',
        })
      end
    end
    next_phase(1)
  end

  return protect('parser-preflight', function()
    local requested = #command.fargs > 0 and command.fargs or options.parser_languages
    local selected, seen, allowed = {}, {}, {}
    for _, language in ipairs(options.parser_languages) do allowed[language] = true end
    for _, language in ipairs(requested) do
      if not allowed[language] then
        fail('ARGUMENT', 'parser-arguments', "parser '" .. language .. "' is not configured", {
          context = {language = language},
          hint = 'Choose a configured parser or add its name to parser_languages in setup().',
        })
        return
      end
      if not seen[language] then selected[#selected + 1], seen[language] = language, true end
    end
    if #selected == 0 then running = false; info('no configured parsers to synchronize'); return end
    local loaded, treesitter = pcall(require, 'nvim-treesitter')
    if not loaded or type(treesitter) ~= 'table' or type(treesitter.install) ~= 'function'
      or type(treesitter.update) ~= 'function' or type(treesitter.get_available) ~= 'function'
      or type(treesitter.get_installed) ~= 'function' then
      fail('DEPENDENCY', 'parser-plugin', 'nvim-treesitter main installation API is required', {
        cause = not loaded and treesitter or nil,
        hint = 'Install nvim-treesitter on its main branch or use another parser installer; copying needs only compatible parser binaries.',
      })
      return
    end
    local known = {}
    for _, language in ipairs(treesitter.get_available()) do known[language] = true end
    for _, language in ipairs(treesitter.get_available(4)) do known[language] = nil end
    for _, language in ipairs(selected) do
      if not known[language] then
        fail('DEPENDENCY', 'parser-registry', "unsupported configured parser '" .. language .. "'", {
          context = {language = language}, hint = 'Correct parser_languages or update nvim-treesitter main.',
        })
        return
      end
    end
    local available, reason = dependencies()
    if not available then
      fail('DEPENDENCY', 'parser-dependencies', reason, {
        hint = 'Install the missing tools or correct PATH/CC, then run :CopyCleanParsers again.',
      })
      return
    end
    vim.system({'tree-sitter', '--version'}, {text = true, timeout = 5000}, function(output)
      vim.schedule(function()
        protect('parser-version', function()
          if output.code ~= 0 then
            fail('DEPENDENCY', 'parser-version', 'tree-sitter --version failed (exit ' .. output.code .. ')', {
              cause = output.stderr,
              hint = 'Check tree-sitter --version in your shell and install a working tree-sitter-cli.',
            })
            return
          end
          local version = vim.version.parse(output.stdout or '')
          if not version or version.prerelease or not vim.version.ge(version, {0, 26, 1}) then
            fail('DEPENDENCY', 'parser-version', 'stable tree-sitter-cli 0.26.1+ is required', {
              cause = output.stdout, hint = 'Install or update tree-sitter-cli, then retry :CopyCleanParsers.',
            })
            return
          end
          synchronize(treesitter, selected)
        end)
      end)
    end)
  end)
end

return M
