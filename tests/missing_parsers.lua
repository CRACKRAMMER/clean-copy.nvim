-- A fresh Neovim process has only the HTML/Vue/PHP parsers on its runtimepath.
vim.opt.runtimepath = {vim.fn.getcwd(), vim.fn.getcwd() .. '/.test/missing-runtime', vim.env.VIMRUNTIME}
vim.o.swapfile = false
vim.o.clipboard = ''
vim.notify = function() end
local plugin = require('clean_copy')
plugin.setup({register = 'a', clipboard = false})
local fixtures = {
  {'cs', 'class C {}', 'c_sharp'},
  {'html', '<script>const a=1; // comment\n</script>', 'javascript'},
  {'vue', '<script setup lang="ts">const a: number=1;</script>', 'typescript'},
  {'vue', '<style scoped>p { /* comment */ }</style>', 'css'},
  {'php', '<script>const a=1;</script><?php $v=1; ?>', 'javascript'},
}
for _, f in ipairs(fixtures) do
  vim.cmd('enew!')
  vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.split(f[2], '\n', {plain = true}))
  vim.bo.filetype = f[1]
  vim.fn.setreg('a', 'sentinel')
  local ok, err = plugin.copy()
  assert(not ok and err:find('parser: ' .. f[3], 1, true), tostring(err))
  assert(vim.fn.getreg('a') == 'sentinel')
  print('PASS absent real parser ' .. f[3] .. ' in ' .. f[1])
end
print('RESULT missing parsers: 5 passed, 0 failed')
vim.cmd('qa!')
