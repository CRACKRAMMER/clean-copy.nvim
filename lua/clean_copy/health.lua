local M = {}

function M.check()
  local health = vim.health
  health.start('clean-copy.nvim')
  if vim.fn.has('nvim-0.12') ~= 1 then
    health.error('Neovim 0.12+ is required', { 'Upgrade Neovim.' })
    return
  end
  health.ok('Neovim ' .. tostring(vim.version()))
  local plugin = require('clean_copy')
  local opts = plugin.get_config()
  health.info(string.format('Configuration: register=%s, clipboard=%s, legacy_command=%s, debug=%s',
    opts.register, tostring(opts.clipboard), tostring(opts.legacy_command), tostring(opts.debug)))
  local source = vim.api.nvim_get_current_buf()
  -- :checkhealth opens its report buffer before calling plugin checks.
  if vim.api.nvim_buf_get_name(source) == 'health://' or vim.bo[source].filetype == 'checkhealth' then
    local previous = vim.fn.bufnr('#')
    if previous > 0 and vim.api.nvim_buf_is_valid(previous) then source = previous end
  end
  local commands = require('clean_copy.commands')
  for _, name in ipairs({'CopyClean', 'CopyCleanParsers'}) do
    if commands.owns(name) then health.ok(':' .. name .. ' is registered')
    else health.error(':' .. name .. ' is missing or owned by another command', { 'Resolve the conflict and restart Neovim.' }) end
    if vim.api.nvim_buf_get_commands(source, {})[name] then
      health.warn('A buffer-local :' .. name .. ' shadows the plugin command', { 'Rename or remove the buffer-local command in this buffer.' })
    end
  end

  local errors = require('clean_copy.errors')
  local comments = require('clean_copy.comments')
  local ft = vim.bo[source].filetype
  local ok, language = pcall(comments.language, ft, opts)
  if not ok then
    health.warn(errors.format(errors.normalize(language, 'language'), opts.debug), { 'Set a supported filetype or language_overrides.' })
  else
    local added, available = pcall(vim.treesitter.language.add, language)
    if not added or not available then
      health.error('Missing or incompatible parser: ' .. language, { 'Install a matching parser on runtimepath; no dependency is installed automatically.' })
    else
      health.ok('Current filetype ' .. ft .. ' uses parser ' .. language)
      local names = { 'clean_copy' }
      if language == 'php' or language == 'html' or language == 'vue' then names[#names + 1] = 'clean_copy_regions' end
      for _, name in ipairs(names) do
        local queried, result = pcall(comments.load_query, language, name)
        if queried then health.ok(language .. '/' .. name .. ' query is valid')
        else health.error(errors.format(errors.normalize(result, 'query'), opts.debug)) end
      end
    end
  end
  if opts.clipboard or opts.register == '+' or opts.register == '*' then
    local checked, available = pcall(require('clean_copy.registers').available)
    if checked and available then health.ok('Clipboard provider is available (no clipboard read or write performed)')
    else health.warn('Clipboard provider unavailable', { 'Configure a provider (:help clipboard), or use a local register with clipboard=false.' }) end
  else health.ok('Clipboard forwarding is disabled; target register is local') end
  health.info('Only the current root parser/query is checked; copying also validates selected embedded languages.')
  health.info(':CopyCleanParsers checks optional installer dependencies when invoked; :checkhealth nvim-treesitter provides installer diagnostics.')
end

return M
