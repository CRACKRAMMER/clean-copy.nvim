local config = require('clean_copy.config')
local selection = require('clean_copy.selection')
local comments = require('clean_copy.comments')
local transform = require('clean_copy.transform')
local registers = require('clean_copy.registers')
local errors = require('clean_copy.errors')
local commands = require('clean_copy.commands')
local M = {}
local options = config.resolve()
local legacy_warned = false

local function has_partial_write(report)
  if report.partial then return true end
  for _, state in pairs(report.targets or {}) do
    if state == 'written' or state == 'unknown' then return true end
  end
  return false
end

local function finish(report, legacy, debug_enabled)
  if legacy and not legacy_warned then
    legacy_warned = true
    report.message = ':CleanCopy is deprecated; use :CopyClean. ' .. report.message
    report.level = math.max(report.level or vim.log.levels.INFO, vim.log.levels.WARN)
  end
  local message = errors.notify(report, debug_enabled)
  return report.ok, message, report
end

local function execute(line_range, legacy, invalid_args)
  local stage, context = 'arguments', {}
  -- setup() replaces the options table; an in-flight copy keeps one configuration.
  local active_options = options
  local write_result
  local ok, report = xpcall(function()
    if invalid_args then
      errors.raise('ARGUMENT', stage, 'copy() does not accept arguments', {
        hint = 'Use copy() for the current selection or :[range]CopyClean for a line range.',
      })
    end
    stage = 'version'
    if vim.fn.has('nvim-0.12') ~= 1 then
      errors.raise('VERSION', stage, 'Neovim 0.12 or newer is required', { hint = 'Upgrade Neovim.' })
    end
    local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    context = { buffer = buf, filetype = vim.bo[buf].filetype }
    local cursor = vim.api.nvim_win_get_cursor(win)
    local tick, mode = vim.api.nvim_buf_get_changedtick(buf), vim.fn.mode()
    local function unchanged()
      return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf
        and vim.api.nvim_get_current_win() == win and vim.api.nvim_buf_get_changedtick(buf) == tick
    end
    stage = 'selection'
    if mode == '\22' then
      errors.raise('SELECTION', stage, 'Visual block selection is not supported', {
        hint = 'Use characterwise or linewise Visual mode.',
      })
    end
    local snapshot = selection.snapshot(buf)
    local sel = line_range and selection.lines(snapshot, line_range[1], line_range[2])
      or selection.current(snapshot)
    if sel.start >= sel.finish then
      errors.raise('SELECTION', stage, 'selection is empty; no register written', { hint = 'Select some code.' })
    end
    stage = 'language'
    local lang = comments.language(context.filetype, active_options)
    context.language = lang
    stage = 'parser'
    local ranges = comments.collect(snapshot, sel, lang, active_options)
    stage = 'transform'
    local output = transform.apply(snapshot, sel, ranges, active_options)
    if not output:find('%S') then
      errors.raise('SELECTION', stage, 'output is empty or whitespace; no register written', {
        hint = 'Include code or enable a relevant comment preservation option.',
      })
    end
    stage = 'validation'
    if not unchanged() then
      errors.raise('BUFFER_CHANGED', stage, 'buffer changed during copy; no register written', {
        hint = 'Keep directive_rules free of side effects and retry on a stable buffer.',
      })
    end
    stage = 'registers'
    write_result = registers.write(output, sel.regtype, active_options)
    if not unchanged() then
      return errors.new('BUFFER_CHANGED', stage, 'buffer/window changed during register write; ' .. write_result.message, {
        partial = has_partial_write(write_result), targets = write_result.targets, context = context,
        cause = not write_result.ok and write_result or nil,
        hint = 'Inspect the source and reported targets; keep clipboard providers free of side effects.',
      })
    end
    if not write_result.ok then return write_result end
    if mode == 'v' or mode == 'V' then
      stage = 'visual'
      -- Synchronous Escape records the selection for gv before restoring the cursor.
      vim.cmd.normal({ args = { vim.api.nvim_replace_termcodes('<Esc>', true, false, true) }, bang = true,
        mods = { noautocmd = true } })
      vim.api.nvim_win_set_cursor(win, cursor)
    end
    return write_result
  end, function(err) return errors.capture(err, stage, context) end)
  if not ok and write_result then
    local visual = stage == 'visual'
    report = errors.new('STATE', stage, visual and 'registers written; could not restore Visual state'
      or ('could not validate editor state after register write; ' .. write_result.message), {
      partial = has_partial_write(write_result), targets = write_result.targets, cause = report,
      traceback = report.traceback, context = context,
      hint = visual and 'Press Escape and check the cursor/selection before continuing.'
        or 'Inspect the buffer and reported targets before retrying.',
    })
  end
  return finish(report, legacy, active_options.debug)
end

function M.copy(...)
  return execute(nil, false, select('#', ...) > 0)
end

local function callback(legacy)
  return function(command)
    return execute(command.range > 0 and { command.line1, command.line2 } or nil, legacy)
  end
end

function M._register_command()
  local ok, report, notify = commands.register('CopyClean', callback(false))
  if not ok and notify then errors.notify(report, options.debug) end
  local registered, parser_report, parser_notify = commands.register('CopyCleanParsers', function(command)
    return require('clean_copy.parsers').run(command, vim.deepcopy(options))
  end, {
    range = false, bang = true, nargs = '*', desc = 'Install or update parsers for clean-copy',
    complete = function(lead)
      return vim.tbl_filter(function(language) return language:sub(1, #lead) == lead end, options.parser_languages)
    end,
  })
  if not registered and parser_notify then errors.notify(parser_report, options.debug) end
  return ok, report
end

function M.setup(opts)
  local ok, result = xpcall(function()
    local resolved = config.resolve(opts)
    if resolved.legacy_command then
      local registered, report = commands.register('CleanCopy', callback(true))
      if not registered then error(report, 0) end
    else commands.remove('CleanCopy') end
    options = resolved
    return { ok = true, partial = false, code = 'OK', stage = 'config', message = 'configuration updated' }
  end, errors.handler('config'))
  if not ok then
    local message = errors.notify(result, options.debug or (type(opts) == 'table' and opts.debug == true))
    return false, message, result
  end
  return true, result.message, result
end

-- Used by :checkhealth without resetting options or exposing mutable state.
function M.get_config()
  return vim.deepcopy(options)
end

-- require(), plugin loading and lazy.nvim all reach the same idempotent registrar.
M._register_command()
return M
