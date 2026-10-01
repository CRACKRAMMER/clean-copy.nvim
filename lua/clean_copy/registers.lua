local M = {}
function M.available()
  return vim.fn.has('clipboard') == 1
end
local function set(reg, text, kind)
  -- A list preserves a last empty line; string + linewise would consume its final NL.
  local result = vim.fn.setreg(reg, vim.split(text, '\n', {plain = true}), kind)
  if result ~= 0 then error('could not write register ' .. reg, 0) end
end
function M.write(text, kind, opts)
  local reg, system = opts.register, opts.register == '+' or opts.register == '*'
  local available = (opts.clipboard or system) and M.available()
  if system and not available then error('clipboard provider unavailable; no register written', 0) end
  -- Avoid implicit provider writes through 'clipboard'; only the explicit targets are written.
  local cb = vim.o.clipboard
  vim.cmd.set({args = {'clipboard='}, mods = {noautocmd = true}})
  local completed, result = pcall(function()
    -- Clipboard targets must not trigger a paste/OSC52 read just to take a snapshot.
    local original = not system and vim.fn.getreginfo(reg) or nil
    local unnamed = vim.fn.getreginfo('"')
    local zero = reg == '"' and vim.fn.getreginfo('0') or nil
    local ok, err = pcall(set, reg, text, kind)
    if not ok then
      if original then pcall(vim.fn.setreg, reg, original) end
      if zero then pcall(vim.fn.setreg, '0', zero) end
      if unnamed.points_to then pcall(vim.fn.setreg, '"', { points_to = unnamed.points_to }) end
      error('register write failed: ' .. tostring(err), 0)
    end
    local status = system and 'clipboard target written' or ('local register ' .. reg .. ' written')
    if opts.clipboard and reg ~= '+' then
      if available then
        local copied = pcall(set, '+', text, kind)
        status = status .. (copied and '; system clipboard + written' or '; system clipboard write failed')
      else status = status .. '; clipboard provider unavailable (system clipboard not written)' end
    elseif not opts.clipboard and not system then status = status .. '; system clipboard disabled' end
    return status
  end)
  vim.cmd.set({args = {'clipboard=' .. cb}, mods = {noautocmd = true}})
  if not completed then error(result, 0) end
  return result
end
return M
