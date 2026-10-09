local M = { passed = 0, failed = 0 }

function M.eq(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error('expected ' .. vim.inspect(expected) .. '\nactual ' .. vim.inspect(actual), 0)
  end
end

function M.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    M.passed = M.passed + 1
    print('PASS ' .. name)
  else
    M.failed = M.failed + 1
    print('FAIL ' .. name .. '\n' .. tostring(err))
  end
end

-- Always restore injected failures, even if the assertion itself fails.
function M.patch(target, name, replacement, fn)
  local original = target[name]
  target[name] = replacement
  local ok, err = xpcall(fn, debug.traceback)
  target[name] = original
  if not ok then error(err, 0) end
end

function M.buffer(text, ft)
  vim.cmd('enew!')
  vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.split(text, '\n', { plain = true }))
  vim.bo.filetype = ft or 'lua'
  vim.o.selection = 'inclusive'
  vim.o.virtualedit = ''
  vim.o.clipboard = ''
end

function M.keys(text)
  vim.cmd.normal({ args = { vim.api.nvim_replace_termcodes(text, true, false, true) }, bang = true })
end

function M.finish(name)
  print(string.format('RESULT %s: %d passed, %d failed', name, M.passed, M.failed))
  vim.cmd(M.failed == 0 and 'qa!' or 'cquit 1')
end

return M
