vim.opt.runtimepath = { vim.fn.getcwd(), vim.fn.getcwd() .. '/.test/runtime', vim.env.VIMRUNTIME }
local lock = vim.json.decode(table.concat(vim.fn.readfile('tests/parsers.lock.json'), '\n'))
local missing, incompatible = {}, {}
for _, lang in ipairs(vim.tbl_keys(lock)) do
  local path = vim.fn.getcwd() .. '/.test/runtime/parser/' .. lang .. '.so'
  if vim.fn.filereadable(path) ~= 1 then
    missing[#missing + 1] = lang
  else
    local ok, available = pcall(vim.treesitter.language.add, lang, { path = path })
    if not ok or not available then incompatible[#incompatible + 1] = lang end
  end
end
table.sort(missing)
table.sort(incompatible)
if #missing > 0 then print('Missing project test parsers: ' .. table.concat(missing, ', ')) end
if #incompatible > 0 then print('Incompatible project test parsers: ' .. table.concat(incompatible, ', ')) end
if #missing > 0 or #incompatible > 0 then
  print('Integration tests require parser binaries in .test/runtime/parser. Unit tests run with make test-unit.')
  print('No dependencies are installed automatically; provision the isolated test runtime explicitly.')
  vim.cmd('cquit 1')
end
print('PASS isolated integration parser preflight (' .. #vim.tbl_keys(lock) .. ' parsers)')
vim.cmd('qa!')
