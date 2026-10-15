-- Opt-in integration checks for untracked, local SQL files. Business text and
-- copied results are written only under the ignored .test/local-fixtures directory.
local root = vim.fn.getcwd()
vim.opt.runtimepath = { root, root .. '/.test/runtime', vim.env.VIMRUNTIME }
vim.o.swapfile, vim.o.clipboard = false, ''
local fixture_dir = vim.env.CLEAN_COPY_FIXTURES_DIR or (root .. '/fixtures/sql')
local destination = root .. '/.test/local-fixtures'
vim.fn.delete(destination .. '/cleaned', 'rf')
vim.fn.mkdir(destination .. '/cleaned', 'p')

local plugin = require('clean_copy')
assert(plugin.setup({ register = 'a', clipboard = false }))
local errors = require('clean_copy.errors')
local original_notify, notifications, active_report = errors.notify, {}, nil
errors.notify = function(report, debug_enabled)
  active_report = report
  return original_notify(report, debug_enabled)
end
vim.notify = function(message, level)
  notifications[#notifications + 1] = { message = message, level = level }
end

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message)
end

local function saved_registers()
  local result = {}
  for _, register in ipairs({ 'a', 'b', '0', '"' }) do result[register] = vim.fn.getreginfo(register) end
  return result
end

-- This lexical check is independent of the plugin's AST query/removal ranges.
-- It compares every non-comment token verbatim, including quoted identifiers,
-- string contents and COMMENT clauses. It also rejects residual ordinary comments.
local function directive(text)
  if text:match('^/%*[!+]') or text:match('^/%*M!') then return true end
  local lower = text:lower()
  for _, marker in ipairs({
    'clang-format off', 'clang-format on', 'clang-format disable', 'clang-format enable',
    'prettier-ignore', 'eslint-disable', 'eslint-enable', 'stylelint-disable', 'stylelint-enable',
    'fmt: off', 'fmt: on', 'fmt: skip', 'isort: off', 'isort: on', 'isort: skip',
    'ruff: noqa', 'yapf: disable', 'yapf: enable', 'luacheck:', 'stylua: ignore',
    '@formatter:off', '@formatter:on',
  }) do
    if lower:find(marker, 1, true) then return true end
  end
  return false
end

local function lex(text)
  local tokens, directives, ordinary, cursor = {}, {}, {}, 1
  local function comment(first, last)
    local value = text:sub(first, last)
    local target = directive(value) and directives or ordinary
    target[#target + 1] = value
    cursor = last + 1
  end
  while cursor <= #text do
    local char, pair = text:sub(cursor, cursor), text:sub(cursor, cursor + 1)
    if char:match('%s') then cursor = cursor + 1
    elseif pair == '--' then
      local finish = text:find('\n', cursor + 2, true)
      comment(cursor, finish and finish - 1 or #text)
    elseif pair == '/*' then
      local first, depth, scan = cursor, 1, cursor + 2
      while depth > 0 and scan <= #text do
        local part = text:sub(scan, scan + 1)
        if part == '/*' then depth, scan = depth + 1, scan + 2
        elseif part == '*/' then depth, scan = depth - 1, scan + 2
        else scan = scan + 1 end
      end
      assert(depth == 0, 'unterminated block comment in lexical verification')
      comment(first, scan - 1)
    elseif char == "'" or char == '"' or char == '`' then
      local first, quote, closed = cursor, char, false
      cursor = cursor + 1
      while cursor <= #text do
        local next_char = text:sub(cursor, cursor)
        if next_char == '\\' then cursor = cursor + 2
        elseif next_char == quote then
          if text:sub(cursor + 1, cursor + 1) == quote then cursor = cursor + 2
          else cursor, closed = cursor + 1, true; break end
        else cursor = cursor + 1 end
      end
      assert(closed, 'unterminated quoted token in lexical verification')
      tokens[#tokens + 1] = text:sub(first, cursor - 1)
    else
      local remainder = text:sub(cursor)
      local tag = remainder:match('^%$[%a_][%w_]*%$') or remainder:match('^%$%$')
      local token
      if tag then
        local finish = text:find(tag, cursor + #tag, true)
        assert(finish, 'unterminated dollar-quoted token in lexical verification')
        token = text:sub(cursor, finish + #tag - 1)
      elseif char:match('%d') then
        token = remainder:match('^0[xX]%x+') or remainder:match('^%d+%.%d*[eE][+-]?%d+')
          or remainder:match('^%d+[eE][+-]?%d+') or remainder:match('^%d+%.%d*')
          or remainder:match('^%d+')
      elseif char:match('[%a_$]') then token = remainder:match('^[%w_$]+')
      else
        for _, operator in ipairs({ '->>', '!~*', '||', '&&', '::', '>=', '<=', '<>', '!=',
          ':=', '->', '<<', '>>', '~*', '!~', '?|', '?&' }) do
          if remainder:sub(1, #operator) == operator then token = operator; break end
        end
        token = token or char
      end
      tokens[#tokens + 1], cursor = token, cursor + #token
    end
  end
  return { tokens = tokens, directives = directives, ordinary = ordinary }
end

local function context(lines, first, last)
  local result = {}
  for row = math.max(1, first - 1), math.min(#lines, last + 1, first + 2) do
    result[#result + 1] = { row = row, text = vim.fn.strcharpart(lines[row], 0, 160) }
  end
  return result
end

-- This is a separate grammar probe, not CopyClean's validated syntax tree. Keep
-- its errors for parser compatibility investigation without duplicating the
-- plugin's iterative stack alias adapter or treating them as copy failures.
local function raw_syntax_diagnostics(text, lines)
  local parser, diagnostics = nil, {
    count = 0, nodes = {}, parse_view = 'original-source', stack_alias_adapter = false, dialect_adapters = false,
    authoritative = false,
    description = 'Raw SQL grammar probe; excludes stack, Hive and Doris adapters. See report for the actual CopyClean result.',
  }
  local ok, reason = pcall(function()
    local parse_text = text
    local sql = require('clean_copy.sql')
    if type(sql.parser_view) == 'function' then
      local templates
      parse_text, templates = sql.parser_view(text)
      diagnostics.parse_view = 'bi-condition-templates-only'
      diagnostics.template_count = type(templates) == 'table' and #templates or tonumber(templates) or 0
    end
    parser = vim.treesitter.get_string_parser(parse_text, 'sql', { injections = { sql = '' } })
    local trees = parser:parse(true)
    for _, tree in ipairs(trees) do
      local pending = { tree:root() }
      while #pending > 0 do
        local node = table.remove(pending)
        if node:type() == 'ERROR' or node:missing() then
          diagnostics.count = diagnostics.count + 1
          if #diagnostics.nodes < 100 then
            local sr, sc, er, ec = node:range()
            local parent = node:parent()
            diagnostics.nodes[#diagnostics.nodes + 1] = {
              type = node:type(), missing = node:missing(), parent = parent and parent:type() or nil,
              range = { sr + 1, sc + 1, er + 1, ec + 1 }, context = context(lines, sr + 1, er + 1),
              sample = vim.fn.strcharpart(vim.treesitter.get_node_text(node, text), 0, 160),
            }
          end
        end
        for child in node:iter_children() do pending[#pending + 1] = child end
      end
    end
  end)
  if parser then pcall(parser.destroy, parser) end
  if not ok then diagnostics.reason = errors.describe(reason) end
  return diagnostics
end

local function public_report(report)
  if not report then return nil end
  return {
    ok = report.ok, partial = report.partial, code = report.code, stage = report.stage,
    message = report.message, level = report.level, hint = report.hint,
    context = report.context, targets = report.targets, detail = report.detail,
  }
end

local report = { files = 0, passed = 0, failed = 0, cases = {}, fixture_dir = fixture_dir }
local paths = vim.fn.glob(fixture_dir .. '/*.sql', false, true)
table.sort(paths)
if #paths == 0 then
  report.failed = 1
  report.preflight = { code = 'FIXTURES_MISSING', stage = 'fixtures',
    message = 'No local SQL fixtures found; provide fixtures/sql/*.sql or set CLEAN_COPY_FIXTURES_DIR.' }
  print('FAIL fixtures [fixtures/FIXTURES_MISSING] ' .. report.preflight.message)
end

for _, path in ipairs(paths) do
  local name = vim.fn.fnamemodify(path, ':t')
  local entry = { path = path, name = name }
  report.files = report.files + 1
  local ok, reason = xpcall(function()
    local original_file = vim.fn.readfile(path, 'b')
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.bo.filetype = 'sql'
    local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    local original_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
    local source = table.concat(original_lines, '\n')
    local tick, modified = vim.api.nvim_buf_get_changedtick(buf), vim.bo[buf].modified
    local undo, cursor = vim.fn.undotree(), vim.api.nvim_win_get_cursor(win)
    local clipboard = vim.o.clipboard
    for _, register in ipairs({ 'a', 'b', '0', '"' }) do
      vim.fn.setreg(register, { 'fixture sentinel ' .. register }, 'v')
    end
    local registers = saved_registers()
    notifications, active_report = {}, nil
    local executed, command_reason = pcall(vim.cmd.CopyClean)
    entry.report, entry.notifications = public_report(active_report), notifications
    entry.raw_syntax = raw_syntax_diagnostics(source, original_lines)
    equal(vim.api.nvim_get_current_buf(), buf, 'current buffer changed')
    equal(vim.api.nvim_get_current_win(), win, 'current window changed')
    equal(vim.api.nvim_buf_get_lines(buf, 0, -1, true), original_lines, 'source buffer content changed')
    equal(vim.api.nvim_buf_get_changedtick(buf), tick, 'source buffer changedtick changed')
    equal(vim.bo[buf].modified, modified, 'source buffer modified flag changed')
    equal(vim.fn.undotree(), undo, 'source buffer undo history changed')
    equal(vim.api.nvim_win_get_cursor(win), cursor, 'cursor changed')
    equal(vim.o.clipboard, clipboard, 'clipboard option changed')
    equal(vim.fn.readfile(path, 'b'), original_file, 'original fixture file changed')
    if not executed or not active_report or not active_report.ok then
      equal(saved_registers(), registers, 'failed CopyClean changed local registers')
      entry.state_protected = true
    end
    assert(executed, 'CopyClean command raised an unhandled error: ' .. errors.describe(command_reason))
    assert(active_report, 'CopyClean did not produce a structured diagnostic')
    equal(#notifications, 1, 'copy emitted duplicate diagnostics')
    if not active_report.ok then
      assert(not active_report.partial, 'failed copy unexpectedly reported partial writes')
      assert(active_report.level == vim.log.levels.WARN or active_report.level == vim.log.levels.ERROR,
        'failed copy did not report WARN or ERROR')
      equal(notifications[1].level, active_report.level, 'failure notification severity differs from its report')
      if active_report.code == 'SYNTAX' then
        equal(active_report.level, vim.log.levels.WARN, 'syntax refusal must report WARN')
      end
      error(active_report.message, 0)
    end
    assert(not active_report.partial, 'copy reported partial success')
    equal(active_report.code, 'OK', 'copy did not report OK')
    equal(notifications[1].level, vim.log.levels.INFO, 'successful copy did not emit INFO')
    equal(vim.fn.getregtype('a'), 'V', 'whole-buffer copy was not linewise')
    equal(vim.fn.getreginfo('0'), registers['0'], 'named target copy changed the yank register')
    equal(vim.fn.getreginfo('b'), registers.b, 'copy changed an unrelated named register')
    local copied = vim.fn.getreg('a')
    assert(copied:find('%S'), 'copied result is empty')
    local before, after = lex(source), lex(copied)
    if not vim.deep_equal(before.tokens, after.tokens) then
      for index = 1, math.max(#before.tokens, #after.tokens) do
        if before.tokens[index] ~= after.tokens[index] then
          entry.token_mismatch = { index = index, expected = before.tokens[index], actual = after.tokens[index] }
          error('code token stream changed at token ' .. index, 0)
        end
      end
    end
    equal(after.directives, before.directives, 'necessary SQL/tool directives changed')
    equal(#after.ordinary, 0, 'ordinary SQL comments remain in copied result')
    entry.state_protected, entry.token_count = true, #before.tokens
    entry.removed_comments, entry.kept_directives = #before.ordinary, #before.directives
    entry.cleaned = destination .. '/cleaned/' .. name
    vim.fn.writefile(vim.split(copied, '\n', { plain = true }), entry.cleaned, 'b')
  end, function(err) return errors.describe(err) end)
  entry.passed = ok
  if ok then report.passed = report.passed + 1; print('PASS ' .. name)
  else
    report.failed, entry.reason = report.failed + 1, reason
    local diagnostic = entry.report and not entry.report.ok and entry.report or { code = 'TEST', stage = 'verification' }
    print('FAIL ' .. name .. ' [' .. diagnostic.stage .. '/' .. diagnostic.code .. '] ' .. reason:match('^[^\n]*'))
  end
  report.cases[#report.cases + 1] = entry
end

local report_path = destination .. '/report.json'
vim.fn.writefile({ vim.json.encode(report) }, report_path)
print(('RESULT local SQL fixtures: %d passed, %d failed (%d files)'):format(report.passed, report.failed, report.files))
io.stdout:write('REPORT ' .. report_path .. '\n')
errors.notify = original_notify
vim.cmd(report.failed == 0 and 'qa!' or 'cquit 1')
