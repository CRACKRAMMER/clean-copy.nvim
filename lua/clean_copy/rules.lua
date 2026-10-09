local errors = require('clean_copy.errors')
local M = {}
function M.is_doc(text, lang, node)
  if lang == 'rust' then return #node:field('inner') > 0 or #node:field('outer') > 0 end
  if lang == 'c_sharp' then return text:match('^///') or text:match('^/%*%*') end
  if lang == 'lua' then return text:match('^%-%-%-') end
  return text:match('^/%*%*') or ((lang == 'c' or lang == 'cpp') and text:match('^//[/!]'))
end
function M.keep(text, lang, node, opts)
  if text:match('^#!') then return true end
  if opts.preserve_doc_comments and M.is_doc(text, lang, node) then return true end
  local lower = text:lower()
  if opts.preserve_license_comments and (lower:find('spdx%-license%-identifier:')
      or lower:find('@license', 1, true) or lower:find('@preserve', 1, true)
      or lower:find('copyright', 1, true) or text:match('^/%*!')) then return true end
  if not opts.preserve_directives then return false end
  if lang == 'go' and (text:match('^//go:') or text:match('^//%s*%+build%s')) then return true end
  if lang == 'javascript' or lang == 'typescript' or lang == 'tsx' then
    -- Bundlers use this annotation to decide whether a call can be eliminated.
    if text:match('^/%*%s*[@#]__PURE__%s*%*/$') then return true end
    for _, directive in ipairs({ '@ts-check', '@ts-nocheck', '@ts-ignore', '@ts-expect-error' }) do
      if text:find(directive, 1, true) then return true end
    end
    if text:match('^///%s*<reference%s') or text:match('^///%s*<amd%-') then return true end
  end
  if lang == 'python' then
    if lower:match('^#%s*type:') or lower:match('^#%s*noqa') then return true end
    local row = node:range()
    if row < 2 and lower:match('coding[=:]%s*[%w_.-]+') then return true end
  end
  -- Conditional comments can contain actual markup in HTML and email templates.
  if (lang == 'html' or lang == 'vue') and (lower:match('^<!%-%-%s*%[if[%s%]]')
      or lower:match('^<!%-%-%s*<!%[endif%]')) then return true end
  if lang == 'sql' and (text:match('^/%*[!+]') or text:match('^/%*M!')) then return true end
  for _, directive in ipairs({ 'clang-format off', 'clang-format on', 'clang-format disable',
      'clang-format enable', 'prettier-ignore', 'eslint-disable', 'eslint-enable',
      'stylelint-disable', 'stylelint-enable', 'fmt: off', 'fmt: on', 'fmt: skip',
      'isort: off', 'isort: on', 'isort: skip', 'ruff: noqa', 'yapf: disable',
      'yapf: enable', 'luacheck:', 'stylua: ignore', '@formatter:off', '@formatter:on' }) do
    if lower:find(directive, 1, true) then return true end
  end
  for index, rule in ipairs(opts.directive_rules) do
    local row, col = node:range()
    local context = { language = lang, rule = index, row = row + 1, col = col + 1 }
    local ok, keep = xpcall(function() return rule(text, lang, node) end, function(err)
      local failure = errors.new('DIRECTIVE', 'rules', 'directive rule failed', {
        context = context,
        hint = 'Fix directive_rules[' .. index .. '] and keep callbacks free of side effects.',
        cause = err,
      })
      failure.traceback = debug.traceback('', 2)
      return failure
    end)
    if not ok then error(keep, 0) end
    if type(keep) ~= 'boolean' then
      errors.raise('DIRECTIVE', 'rules', 'directive rule must return a boolean', {
        context = vim.tbl_extend('force', context, { returned = type(keep) }),
        hint = 'Return true to preserve the comment or false to remove it.',
      })
    end
    if keep then return true end
  end
  return false
end
return M
