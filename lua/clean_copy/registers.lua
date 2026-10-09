local errors = require('clean_copy.errors')
local M = {}

function M.available()
  return vim.fn.has('clipboard') == 1
end

local function set(reg, text, kind)
  -- A list preserves a last empty line; string + linewise would consume its final NL.
  local result = vim.fn.setreg(reg, vim.split(text, '\n', { plain = true }), kind)
  if result ~= 0 then error('setreg returned ' .. tostring(result), 0) end
end

local function clipboard_option(value)
  vim.cmd.set({ args = { 'clipboard=' .. value }, mods = { noautocmd = true } })
end

local function rollback(reg, original, unnamed, zero)
  local issues = {}
  local function restore(target, value)
    local ok, result = pcall(vim.fn.setreg, target, value)
    if not ok or result ~= 0 then issues[#issues + 1] = target .. ': ' .. errors.describe(result) end
  end
  restore(reg, original)
  if zero then restore('0', zero) end
  if unnamed.points_to then restore('"', { points_to = unnamed.points_to }) end
  -- A setter may return success without restoring the contents. Verify local state.
  local snapshots = { [reg] = original, ['"'] = unnamed }
  if zero then snapshots['0'] = zero end
  for target, expected in pairs(snapshots) do
    local ok, actual = pcall(vim.fn.getreginfo, target)
    if not ok or not vim.deep_equal(actual, expected) then issues[#issues + 1] = target .. ': verification failed' end
  end
  return #issues == 0, table.concat(issues, '; ')
end

function M.write(text, kind, opts)
  local targets, saved_clipboard, stage = {}, nil, 'registers'
  local ok, result = xpcall(function()
    local reg, system = opts.register, opts.register == '+' or opts.register == '*'
    stage = 'clipboard'
    local available = (opts.clipboard or system) and M.available()
    if system and not available then
      return errors.new('CLIPBOARD', stage, 'clipboard provider unavailable; no register written', {
        targets = { [reg] = 'unavailable' }, hint = 'Configure a clipboard provider (:help clipboard), or choose a local register.',
      })
    end
    stage = 'state'
    saved_clipboard = vim.o.clipboard
    -- Suppress implicit writes from unnamed/unnamedplus. Always restore in the finalizer below.
    clipboard_option('')
    stage = 'registers'
    local original, unnamed, zero
    if not system then
      -- Only snapshot local registers. External clipboard reads can block (e.g. OSC52).
      local snap_ok, snap_err = pcall(function()
        original, unnamed = vim.fn.getreginfo(reg), vim.fn.getreginfo('"')
        if reg == '"' then zero = vim.fn.getreginfo('0') end
      end)
      if not snap_ok then
        return errors.new('REGISTER', stage, 'could not snapshot local registers; no register written', {
          cause = snap_err, hint = 'Check register access and retry.', targets = targets,
        })
      end
    end
    -- Mark an attempted write as unknown until completion or verified rollback.
    targets[reg] = 'unknown'
    local wrote, write_err = pcall(set, reg, text, kind)
    if not wrote then
      if system then
        targets[reg] = 'unknown'
        return errors.new('CLIPBOARD', 'clipboard', 'clipboard target ' .. reg .. ' write failed; external clipboard may already have changed', {
          partial = true, targets = targets, cause = write_err,
          hint = 'Check the clipboard provider and retry; external writes cannot be rolled back safely.',
        })
      end
      local restored, rollback_err = rollback(reg, original, unnamed, zero)
      targets[reg] = restored and 'restored' or 'unknown'
      return errors.new('REGISTER', stage, restored
        and 'register write failed; local registers restored; clipboard not written'
        or 'register write failed; rollback incomplete; local registers may have changed', {
          partial = not restored, targets = targets, cause = errors.describe(write_err) .. '\nRollback: ' .. rollback_err,
          hint = restored and 'Retry after checking register access.' or 'Inspect the target, unnamed and 0 registers before retrying.',
        })
    end
    targets[reg] = 'written'
    local message = system and ('clipboard target ' .. reg .. ' written') or ('local register ' .. reg .. ' written')
    if opts.clipboard and reg ~= '+' then
      if not available then
        targets['+'] = 'unavailable'
        return errors.new('CLIPBOARD', 'clipboard', message .. '; clipboard provider unavailable (system clipboard not written)', {
          partial = true, targets = targets, level = vim.log.levels.WARN,
          hint = 'Configure a provider (:help clipboard), or set clipboard=false for local-only copying.',
        })
      end
      targets['+'] = 'unknown'
      local copied, clipboard_err = pcall(set, '+', text, kind)
      if not copied then
        targets['+'] = 'unknown'
        return errors.new('CLIPBOARD', 'clipboard', message .. '; system clipboard write failed (external state unknown)', {
          partial = true, targets = targets, cause = clipboard_err, level = vim.log.levels.WARN,
          hint = 'Check the clipboard provider; the target write is retained and external writes cannot be rolled back safely.',
        })
      end
      targets['+'] = 'written'
      message = message .. '; system clipboard + written'
    elseif not opts.clipboard and not system then message = message .. '; system clipboard disabled' end
    return { ok = true, partial = false, code = 'OK', stage = 'registers', message = message,
      targets = targets, level = vim.log.levels.INFO }
  end, function(err) return errors.capture(err, stage) end)
  if not ok then
    result.targets = targets
    for _, state in pairs(targets) do
      if state == 'written' or state == 'unknown' then result.partial = true end
    end
    if stage == 'state' then
      result.code, result.message = 'STATE', 'could not suppress implicit clipboard writes; no register written'
      result.hint = 'Check the clipboard option and retry.'
    elseif stage == 'clipboard' then
      result.code, result.message = 'CLIPBOARD', 'could not check clipboard provider; no register written'
      result.hint = 'Check the clipboard provider (:help clipboard).'
    end
  end
  if saved_clipboard ~= nil then
    local restored, restore_err = pcall(clipboard_option, saved_clipboard)
    if not restored or vim.o.clipboard ~= saved_clipboard then
      -- Recover even if an Ex setter failed, without invoking a clipboard provider.
      pcall(vim.cmd.lua, {
        args = { string.format('vim.api.nvim_set_option_value("clipboard", %q, {})', saved_clipboard) },
        mods = { noautocmd = true },
      })
    end
    if vim.o.clipboard ~= saved_clipboard then
      local partial = result.partial or next(targets) ~= nil
      result = errors.new('STATE', 'state', result.message .. "; 'clipboard' option could not be restored", {
        partial = partial, targets = targets, cause = errors.describe(restore_err) .. '\n' .. (result.detail or ''),
        hint = "Restore 'clipboard' manually and inspect the reported register targets before retrying.",
      })
    end
  end
  return result
end

return M
