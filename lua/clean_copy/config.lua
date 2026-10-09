local M = {}
local errors = require('clean_copy.errors')
M.defaults = {
  register = '"', clipboard = true, remove_empty_comment_lines = true,
  preserve_doc_comments = false, preserve_license_comments = false,
  preserve_directives = true, directive_rules = {}, language_overrides = {}, debug = false,
  legacy_command = false,
  parser_languages = {
    'c', 'cpp', 'javascript', 'typescript', 'tsx', 'rust', 'go', 'python', 'lua',
    'java', 'c_sharp', 'css', 'html', 'sql', 'php', 'php_only', 'vue',
  },
}
local function invalid(message, key)
  errors.raise('CONFIG', 'config', message, {
    context = key and { option = key } or nil,
    hint = 'Check require("clean_copy").setup() options; the previous configuration is retained.',
  })
end
function M.resolve(opts)
  if opts ~= nil and type(opts) ~= 'table' then invalid('options must be a table') end
  local out = vim.deepcopy(M.defaults)
  for key, value in pairs(opts or {}) do
    if out[key] == nil then invalid('unknown option ' .. tostring(key)) end
    if type(value) ~= type(out[key]) then invalid('invalid type for ' .. key, key) end
    out[key] = vim.deepcopy(value)
  end
  if #out.register ~= 1 or not out.register:match('^["a-z0-9+*]$') then
    invalid('register must be ", a-z, 0-9, + or * (no append registers)', 'register')
  end
  for ft, lang in pairs(out.language_overrides) do
    if type(ft) ~= 'string' or ft == '' or type(lang) ~= 'string' or not lang:match('^[a-z_][a-z0-9_]*$') then
      invalid('language_overrides must map nonempty filetypes to parser names', 'language_overrides')
    end
  end
  local parser_count, seen = 0, {}
  for _ in pairs(out.parser_languages) do parser_count = parser_count + 1 end
  for key, lang in pairs(out.parser_languages) do
    if type(key) ~= 'number' or key < 1 or key > parser_count or key % 1 ~= 0
      or type(lang) ~= 'string' or not lang:match('^[a-z_][a-z0-9_]*$') then
      invalid('parser_languages must be a list of parser names', 'parser_languages')
    end
    if seen[lang] then
      invalid('parser_languages must not contain duplicate names: ' .. lang, 'parser_languages')
    end
    seen[lang] = true
  end
  local rule_count = 0
  for _ in pairs(out.directive_rules) do rule_count = rule_count + 1 end
  for key, rule in pairs(out.directive_rules) do
    if type(key) ~= 'number' or key < 1 or key > rule_count or key % 1 ~= 0 or type(rule) ~= 'function' then
      invalid('directive_rules must be a list of functions', 'directive_rules')
    end
  end
  return out
end
return M
