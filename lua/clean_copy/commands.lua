local errors = require('clean_copy.errors')
local M = {}
local owned, conflicts = {}, {}

local function same(a, b)
  return a and b and a.callback == b.callback and a.definition == b.definition and a.script_id == b.script_id
end

function M.owns(name)
  return same(owned[name], vim.api.nvim_get_commands({})[name]) or false
end

function M.register(name, callback, opts)
  local current = vim.api.nvim_get_commands({})[name]
  if current then
    if same(owned[name], current) then return true end
    local repeated = same(conflicts[name], current)
    conflicts[name] = current
    return false, errors.new('COMMAND_CONFLICT', 'commands', ':' .. name .. ' is already defined', {
      context = { command = name },
      hint = 'Rename or remove the conflicting command, then restart Neovim; the existing command was kept.',
    }), not repeated
  end
  local command_options = vim.tbl_extend('force', {
    range = true, force = false, desc = 'Copy code without removable comments',
  }, opts or {})
  -- Each command has its own shape, but none may replace a foreign command.
  command_options.force = false
  local ok, err = pcall(vim.api.nvim_create_user_command, name, callback, command_options)
  if not ok then
    return false, errors.new('COMMAND_CONFLICT', 'commands', 'could not register :' .. name, {
      cause = err, hint = 'Check for a conflicting command and restart Neovim.',
    }), true
  end
  owned[name] = vim.api.nvim_get_commands({})[name]
  conflicts[name] = nil
  return true
end

function M.remove(name)
  -- A command replaced by the user belongs to the user, even if we created it first.
  if M.owns(name) then vim.api.nvim_del_user_command(name) end
  owned[name], conflicts[name] = nil, nil
end

return M
