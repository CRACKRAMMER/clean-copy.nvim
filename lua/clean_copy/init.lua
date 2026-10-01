local config = require('clean_copy.config')
local selection = require('clean_copy.selection')
local comments = require('clean_copy.comments')
local transform = require('clean_copy.transform')
local registers = require('clean_copy.registers')
local M = {}
local options = config.resolve()
local function notify(message, level)
  vim.notify('clean-copy: ' .. message, level or vim.log.levels.INFO)
end
local function execute(line_range)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local mode = vim.fn.mode()
  local ok, result = xpcall(function()
    if vim.fn.has('nvim-0.12') ~= 1 then error('Neovim 0.12 or newer is required', 0) end
    if mode == '\22' then error('Visual block selection is not supported', 0) end
    local snapshot = selection.snapshot(buf)
    local sel = line_range and selection.lines(snapshot, line_range[1], line_range[2])
      or selection.current(snapshot)
    if sel.start >= sel.finish then error('selection is empty', 0) end
    local lang = comments.language(vim.bo[buf].filetype, options)
    local ranges = comments.collect(snapshot, sel, lang, options)
    local output = transform.apply(snapshot, sel, ranges, options)
    if not output:find('%S') then error('output is empty or whitespace; no register written', 0) end
    if vim.api.nvim_get_current_buf() ~= buf or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
      error('buffer changed during copy; no register written', 0)
    end
    return registers.write(output, sel.regtype, options)
  end, function(err)
    return options.debug and debug.traceback(tostring(err), 2) or tostring(err)
  end)
  if not ok then notify(result, vim.log.levels.WARN); return false, result end
  if mode == 'v' or mode == 'V' then
    -- Execute Escape synchronously so the next key cannot repeat an active selection.
    vim.cmd.normal({ args = { vim.api.nvim_replace_termcodes('<Esc>', true, false, true) }, bang = true })
    vim.api.nvim_win_set_cursor(0, cursor)
  end
  notify(result)
  return true, result
end
function M.copy()
  return execute()
end
function M._register_command()
  vim.api.nvim_create_user_command('CleanCopy', function(command)
    execute(command.range > 0 and { command.line1, command.line2 } or nil)
  end, { range = true, force = true, desc = 'Copy code without removable comments' })
end
function M.setup(opts)
  local resolved = config.resolve(opts)
  M._register_command()
  options = resolved
end
return M
