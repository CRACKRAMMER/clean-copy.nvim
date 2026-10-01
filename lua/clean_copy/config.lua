local M = {}
M.defaults = {
  register = '"', clipboard = true, remove_empty_comment_lines = true,
  preserve_doc_comments = false, preserve_license_comments = false,
  preserve_directives = true, directive_rules = {}, language_overrides = {}, debug = false,
}
function M.resolve(opts)
  if opts ~= nil and type(opts) ~= 'table' then error('clean-copy: options must be a table', 0) end
  local out = vim.deepcopy(M.defaults)
  for key, value in pairs(opts or {}) do
    if out[key] == nil then error('clean-copy: unknown option ' .. tostring(key), 0) end
    if type(value) ~= type(out[key]) then error('clean-copy: invalid type for ' .. key, 0) end
    out[key] = vim.deepcopy(value)
  end
  if #out.register ~= 1 or not out.register:match('^["a-z0-9+*]$') then
    error('clean-copy: register must be ", a-z, 0-9, + or * (no append registers)', 0)
  end
  for ft, lang in pairs(out.language_overrides) do
    if type(ft) ~= 'string' or type(lang) ~= 'string' or not lang:match('^[a-z_]+$') then
      error('clean-copy: language_overrides must map filetypes to parser names', 0)
    end
  end
  local rule_count = 0
  for _ in pairs(out.directive_rules) do rule_count = rule_count + 1 end
  for key, rule in pairs(out.directive_rules) do
    if type(key) ~= 'number' or key < 1 or key > rule_count or key % 1 ~= 0 or type(rule) ~= 'function' then
      error('clean-copy: directive_rules must be a list of functions', 0)
    end
  end
  return out
end
return M
