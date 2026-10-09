local M = {}
local warnings = {
  SELECTION = true, UNSUPPORTED_LANGUAGE = true, UNSUPPORTED_EMBEDDED = true,
  PARSER_MISSING = true, SYNTAX = true, BUFFER_CHANGED = true,
}
local mt = { __tostring = function(err) return M.format(err, false) end }

function M.is(err)
  return type(err) == 'table' and getmetatable(err) == mt
end

function M.describe(value)
  local ok, result = pcall(function()
    return M.is(value) and M.format(value, true) or tostring(value)
  end)
  return ok and result or '<unprintable error>'
end

function M.new(code, stage, message, extra)
  local result = vim.tbl_extend('force', {
    ok = false, partial = false, code = code, stage = stage, message = message,
    level = warnings[code] and vim.log.levels.WARN or vim.log.levels.ERROR,
    traceback = debug.traceback('', 2),
  }, extra or {})
  if result.cause ~= nil then result.detail = M.describe(result.cause); result.cause = nil end
  return setmetatable(result, mt)
end

function M.raise(code, stage, message, extra)
  error(M.new(code, stage, message, extra), 0)
end

function M.normalize(err, stage, context)
  if M.is(err) then
    if not err.context then err.context = context end
    return err
  end
  return M.new('INTERNAL', stage or 'internal', 'unexpected failure; operation stopped', {
    context = context, cause = err, hint = 'Enable debug=true for details and report the failure.',
  })
end

-- Capture here, while the failing call is still on the stack.
function M.capture(err, stage, context)
  local result = M.normalize(err, stage, context)
  result.traceback = result.traceback or debug.traceback('', 2)
  return result
end

function M.handler(stage, context)
  return function(err) return M.capture(err, stage, context) end
end

function M.format(result, debug_enabled)
  local message = string.format('[%s/%s] %s', result.stage or 'copy', result.code or 'OK', result.message)
  if result.context then
    local values = {}
    for key, value in pairs(result.context) do values[#values + 1] = tostring(key) .. '=' .. tostring(value) end
    table.sort(values)
    if #values > 0 then message = message .. ' (' .. table.concat(values, ', ') .. ')' end
  end
  if result.hint then message = message .. '. ' .. result.hint end
  if debug_enabled then
    if result.detail then message = message .. '\nDetails: ' .. tostring(result.detail) end
    if result.traceback then message = message .. '\n' .. result.traceback end
  end
  return message
end

function M.notify(result, debug_enabled)
  local message = 'CopyClean: ' .. M.format(result, debug_enabled)
  local level = result.level or vim.log.levels.INFO
  local ok = pcall(vim.notify, message, level)
  if not ok then
    local highlight = level >= vim.log.levels.ERROR and 'ErrorMsg'
      or level == vim.log.levels.WARN and 'WarningMsg' or 'Normal'
    pcall(vim.api.nvim_echo, {{message, highlight}}, true, {})
  end
  return message
end

return M
