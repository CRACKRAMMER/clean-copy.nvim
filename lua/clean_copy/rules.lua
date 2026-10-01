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
    for _, directive in ipairs({ '@ts-check', '@ts-nocheck', '@ts-ignore', '@ts-expect-error' }) do
      if text:find(directive, 1, true) then return true end
    end
    if text:match('^///%s*<reference%s') or text:match('^///%s*<amd%-') then return true end
  end
  if lang == 'python' then
    if lower:match('^#%s*type:%s*ignore') or lower:match('^#%s*noqa') then return true end
    local row = node:range()
    if row < 2 and lower:match('coding[=:]%s*[%w_.-]+') then return true end
  end
  if lang == 'sql' and (text:match('^/%*[!+]') or text:match('^/%*M!')) then return true end
  for _, directive in ipairs({ 'clang-format off', 'clang-format on', 'clang-format disable',
      'clang-format enable', 'prettier-ignore', 'eslint-disable', 'eslint-enable',
      'stylelint-disable', 'stylelint-enable', 'fmt: off', 'fmt: on', 'fmt: skip',
      'isort: off', 'isort: on', 'isort: skip', 'ruff: noqa', 'yapf: disable',
      'yapf: enable', 'luacheck:', 'stylua: ignore', '@formatter:off', '@formatter:on' }) do
    if lower:find(directive, 1, true) then return true end
  end
  for _, rule in ipairs(opts.directive_rules) do
    local keep = rule(text, lang, node)
    if type(keep) ~= 'boolean' then error('directive rule must return a boolean', 0) end
    if keep then return true end
  end
  return false
end
return M
