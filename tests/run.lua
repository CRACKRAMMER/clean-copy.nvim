vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. '/.test/runtime')
vim.o.swapfile = false
local passed, failed = 0, 0
local function eq(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error('expected ' .. vim.inspect(expected) .. '\nactual ' .. vim.inspect(actual), 0)
  end
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then passed = passed + 1; print('PASS ' .. name)
  else failed = failed + 1; print('FAIL ' .. name .. '\n' .. err) end
end
local selection = require('clean_copy.selection')
local transform = require('clean_copy.transform')
local comments = require('clean_copy.comments')
local config = require('clean_copy.config')
local function snapshot(text)
  local lines = vim.split(text, '\n', { plain = true })
  local starts, count = {}, 0
  for i, line in ipairs(lines) do starts[i], count = count, count + #line + 1 end
  return { text = text, lines = lines, starts = starts }
end
local function clean(text, lang, opts, sel)
  local snap = snapshot(text)
  opts = config.resolve(opts)
  sel = sel or selection.lines(snap, 1, #snap.lines)
  return transform.apply(snap, sel, comments.collect(snap, sel, lang, opts), opts)
end
test('pure interval merging and token separation', function()
  local snap = snapshot('foo/*中文*/bar')
  eq(transform.apply(snap, selection.lines(snap, 1, 1), { {3, 13}, {3, 8}, {5, 13} }, config.resolve()), 'foo bar')
end)
test('pure comment lines removed, original blank/whitespace lines survive', function()
  local snap = snapshot('-- hi\n\n \t\n  value -- end\n -- bye')
  eq(transform.apply(snap, selection.lines(snap, 1, 5), {{0,5},{18,24},{26,32}}, config.resolve()), '\n \t\n  value  ')
end)
for _, fixture in ipairs(dofile('tests/fixtures.lua')) do
  test('parser ' .. fixture.ft, function()
    eq(comments.language(fixture.ft, config.resolve()), fixture.lang)
    local out = clean(fixture.text, fixture.lang)
    assert(not out:find('remove', 1, true), out)
    for _, keep in ipairs(fixture.keep) do assert(out:find(keep, 1, true), 'lost: ' .. keep .. '\n' .. out) end
    for _, absent in ipairs(fixture.absent or {}) do assert(not out:find(absent, 1, true), out) end
    local snap = snapshot(fixture.text)
    local first = assert(fixture.text:find('remove', 1, true))
    local row = 1
    for i, start in ipairs(snap.starts) do if start <= first - 1 then row = i end end
    local part = { start = first - 1, finish = first + 2, first = row, last = row, regtype = 'v' }
    assert(not clean(fixture.text, fixture.lang, { remove_empty_comment_lines = false }, part):find('%S'))
  end)
end
test('comments crossing both selection boundaries', function()
  local text = 'int a; /* first\n中文 middle\nlast */ int b;'
  local snap = snapshot(text)
  local sel = {start = snap.starts[2], finish = snap.starts[3] + 4, first = 2, last = 3, regtype = 'v'}
  eq(clean(text, 'c', {remove_empty_comment_lines = false}, sel), ' \n ')
end)
test('multiline newlines and original indentation are retained when configured', function()
  eq(clean('  int a; /* x\ny */ int b;\n\n \t', 'c', {remove_empty_comment_lines = false}),
    '  int a;  \n  int b;\n\n \t')
end)
test('preserve doc and license comments', function()
  local text = '/** doc */\n/*! SPDX-License-Identifier: MIT */\nint a; // remove'
  local out = clean(text, 'c', {preserve_doc_comments = true, preserve_license_comments = true})
  assert(out:find('/** doc */', 1, true) and out:find('SPDX-License-Identifier', 1, true))
  eq(clean(text, 'c'), 'int a;  ')
  assert(clean('/// doc\n//! module\nfn main() {}', 'rust', {preserve_doc_comments = true}):find('/// doc', 1, true))
  assert(clean('--- doc\nlocal a=1', 'lua', {preserve_doc_comments = true}):find('--- doc', 1, true))
end)
test('custom directive rules and disable builtin rules', function()
  local out = clean('-- KEEP\nlocal a=1 -- remove', 'lua', {directive_rules = {
    function(text, lang) return lang == 'lua' and text == '-- KEEP' end,
  }})
  assert(out:find('-- KEEP', 1, true))
  eq(clean('#!/usr/bin/python\nx=1 # type: ignore', 'python', {preserve_directives = false}), '#!/usr/bin/python\nx=1  ')
end)
test('all documented directive families', function()
  local families = {
    {'javascript', '// @ts-check\n// @ts-nocheck\n// @ts-ignore\n// @ts-expect-error\n/// <reference types="node" />\n/// <amd-module name="x" />\n// prettier-ignore\n// eslint-disable\n// eslint-enable\nconst a=1;'},
    {'c', '// clang-format off\n// clang-format on\n// clang-format disable\n// clang-format enable\nint a;'},
    {'css', '/* stylelint-disable */\n/* stylelint-enable */\np {}'},
    {'python', '# coding=utf-8\n# fmt: off\n# fmt: on\n# fmt: skip\n# isort: off\n# isort: on\n# isort: skip\n# ruff: noqa\n# yapf: disable\n# yapf: enable\nx=1 # noqa'},
    {'lua', '-- luacheck: globals foo\n-- stylua: ignore\nlocal a=1'},
    {'java', '// @formatter:off\n// @formatter:on\nclass C {}'},
  }
  for _, f in ipairs(families) do eq(clean(f[2], f[1]), f[2]) end
end)
test('Vue all script variants and unsupported embedded languages', function()
  for _, tag in ipairs({'<script>', '<script setup>', '<script lang="ts">', '<script setup lang="ts">'}) do
    assert(not clean('<template><!-- remove --><p>中文</p></template>\n' .. tag .. 'const a=1; // remove\n</script>\n<style scoped>/* remove */p{}</style>', 'vue'):find('remove', 1, true))
  end
  for _, text in ipairs({'<template lang="pug">p hello</template>', '<style lang="scss">p{}</style>',
    '<style lang="less">p{}</style>', '<script lang="coffee">x=1</script>'}) do
    local ok, err = pcall(clean, text, 'vue')
    assert(not ok and err:find('unsupported embedded', 1, true), tostring(err))
  end
end)
test('HTML script type, quoted values and data blocks', function()
  local text = '<script type="module">const a=1; /* remove */</script>\n'
    .. '<script type="application/ld+json">{"value":"/* string */"}</script>\n'
    .. '<style type="text/css">p{content:"/* string */";/* remove */}</style>'
  local out = clean(text, 'html')
  assert(not out:find('remove', 1, true) and out:find('{"value":"/* string */"}', 1, true))
end)
test('unrelated syntax error permits selected valid code', function()
  local text = 'int a; // remove\nint b = ;'
  local snap = snapshot(text)
  eq(clean(text, 'c', nil, selection.lines(snap, 1, 1)), 'int a;  ')
  local ok, err = pcall(clean, text, 'c')
  assert(not ok and err:find('ERROR/MISSING', 1, true), tostring(err))
end)
test('PHP-only parser', function()
  eq(clean('$a="/* string */"; // remove', 'php_only'), '$a="/* string */";  ')
end)

local plugin = require('clean_copy')
local registers = require('clean_copy.registers')
local messages = {}
vim.notify = function(msg) messages[#messages + 1] = msg end
local function buffer(text, ft)
  vim.cmd('enew!')
  vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.split(text, '\n', {plain = true}))
  vim.bo.filetype = ft or 'lua'
  vim.o.selection = 'inclusive'
  vim.o.virtualedit = ''
  vim.o.clipboard = ''
end
local function keys(text)
  vim.cmd.normal({args = {vim.api.nvim_replace_termcodes(text, true, false, true)}, bang = true})
end
-- Explicit named target isolates selection checks from native unnamed-register semantics.
plugin.setup({register = 'a', clipboard = false})
test('commands whole buffer and explicit line range', function()
  buffer('-- remove\nlocal a=1 -- remove\n\n \t\nlocal b=2')
  vim.cmd.CleanCopy()
  eq(vim.fn.getreg('a'), 'local a=1  \n\n \t\nlocal b=2\n')
  eq(vim.fn.getregtype('a'), 'V')
  vim.cmd('2CleanCopy')
  eq(vim.fn.getreg('a'), 'local a=1  \n')
  vim.cmd('2,3CleanCopy')
  eq(vim.fn.getreg('a'), 'local a=1  \n\n')
end)
test('normal copy whole buffer', function()
  buffer('local a=1 -- remove')
  assert(plugin.copy())
  eq(vim.fn.getreg('a'), 'local a=1  \n')
end)
for _, seltype in ipairs({'inclusive', 'exclusive', 'old'}) do
  for _, motion in ipairs({'gg0v5l', 'gg05lv5h', 'gg0v$', 'gg0vj3l', 'gg0vjj$', 'gg0v', 'gg0v2l', 'gg0v2j0'}) do
    test('native Visual bytes ' .. seltype .. ' ' .. motion, function()
      buffer('中文\tfoo = "--string"\nbar=2\nendvalue=3')
      -- This is valid JavaScript; use syntax without undeclared bare words.
      buffer('中文\t= "//string";\nbar=2;\nendvalue=3;', 'javascript')
      vim.o.selection = seltype
      keys(motion)
      local cursor = vim.api.nvim_win_get_cursor(0)
      -- Visual '$' can be one cell beyond EOL. Normal mode clamps this by design.
      local line = vim.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], true)[1]
      if cursor[2] >= #line then cursor[2] = math.max(0, #line - 1) end
      local original = vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), {type = 'v'})
      assert(plugin.copy(), messages[#messages])
      eq(vim.fn.getreg('a'), table.concat(original, '\n'))
      eq(vim.fn.getregtype('a'), 'v')
      eq(vim.fn.mode(), 'n')
      eq(vim.api.nvim_win_get_cursor(0), cursor)
    end)
  end
end
test('Visual line range and Visual mapping', function()
  buffer('-- remove\nlocal a=1 -- remove\nlocal b=2')
  vim.keymap.set('x', '<F6>', function() plugin.copy() end)
  keys('ggVj')
  assert(plugin.copy())
  eq(vim.fn.getreg('a'), 'local a=1  \n')
  keys('ggVj')
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<F6>', true, false, true), 'xt', false)
  eq(vim.fn.mode(), 'n')
  eq(vim.fn.getreg('a'), 'local a=1  \n')
end)
test('block selection stops and retains registers', function()
  buffer('local a=1 -- remove')
  vim.fn.setreg('a', 'sentinel')
  keys('gg0<C-v>3l')
  local ok, err = plugin.copy()
  assert(not ok and err:find('block', 1, true))
  eq(vim.fn.getreg('a'), 'sentinel')
  keys('<Esc>')
end)
test('failures retain registers: unsupported language, syntax, whitespace, all comments', function()
  for _, f in ipairs({{'int a = ;', 'c'}, {'-- only comment', 'lua'}, {' \t', 'lua'}, {'anything', 'unknown'}}) do
    buffer(f[1], f[2]); vim.fn.setreg('a', 'sentinel')
    assert(not plugin.copy())
    eq(vim.fn.getreg('a'), 'sentinel')
  end
end)
test('missing root and embedded parsers stop before writes', function()
  local add = vim.treesitter.language.add
  for _, f in ipairs({{'lua','local a=1 -- remove','lua'},
    {'javascript','<script>const a=1; // remove\n</script>','html'},
    {'typescript','<script setup lang="ts">const a: number=1; // remove\n</script>','vue'},
    {'css','<style scoped>p{/* remove */}</style>','vue'},
    {'html','<p><!-- remove --></p><?php $a=1; ?>','php'}}) do
    buffer(f[2], f[3]); vim.fn.setreg('a', 'sentinel')
    vim.treesitter.language.add = function(lang, opts) if lang == f[1] then return nil, 'missing' end; return add(lang, opts) end
    local ok, err = plugin.copy()
    vim.treesitter.language.add = add
    assert(not ok and err:find(f[1], 1, true), tostring(err))
    eq(vim.fn.getreg('a'), 'sentinel')
  end
end)
test('missing unrelated embedded parser permits a different selected region', function()
  buffer('<p>hello<!-- remove --></p>\n<script>const a=1;</script>', 'html')
  local add = vim.treesitter.language.add
  vim.treesitter.language.add = function(lang, opts) if lang == 'javascript' then return nil end; return add(lang, opts) end
  vim.cmd('1CleanCopy')
  vim.treesitter.language.add = add
  eq(vim.fn.getreg('a'), '<p>hello </p>\n')
end)
test('query load failure preserves register', function()
  buffer('local a=1 -- remove')
  vim.fn.setreg('a', 'sentinel')
  local query = comments.load_query
  comments.load_query = function() error('query load failed', 0) end
  local ok, err = plugin.copy()
  comments.load_query = query
  assert(not ok and err:find('query', 1, true)); eq(vim.fn.getreg('a'), 'sentinel')
end)
test('buffer text, changedtick, modified and undo history stay unchanged', function()
  buffer('local a=1 -- remove')
  vim.bo.modified = false
  local lines, tick, undo = vim.api.nvim_buf_get_lines(0, 0, -1, true), vim.api.nvim_buf_get_changedtick(0), vim.fn.undotree()
  assert(plugin.copy())
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, true), lines)
  eq(vim.api.nvim_buf_get_changedtick(0), tick)
  eq(vim.bo.modified, false)
  eq(vim.fn.undotree(), undo)
end)
test('ordinary yank/delete and register pointer are untouched by named copy', function()
  buffer('local a=1 -- remove\nlocal b=2')
  keys('ggyy')
  eq(vim.fn.getreg('0'), 'local a=1 -- remove\n')
  local unnamed, zero = vim.fn.getreginfo('"'), vim.fn.getreginfo('0')
  assert(plugin.copy())
  eq(vim.fn.getreginfo('"'), unnamed); eq(vim.fn.getreginfo('0'), zero)
  keys('dd')
  eq(vim.fn.getreg('1'), 'local a=1 -- remove\n')
  eq(vim.fn.getreg('"'), 'local a=1 -- remove\n')
end)
test('setup repeated without autocmds or mappings; invalid configuration fails', function()
  local before = #vim.api.nvim_get_autocmds({event = 'TextYankPost'})
  plugin.setup({register = 'a', clipboard = false}); plugin.setup({register = 'a', clipboard = false})
  eq(#vim.api.nvim_get_autocmds({event = 'TextYankPost'}), before)
  assert(vim.api.nvim_get_commands({}).CleanCopy)
  for _, opts in ipairs({{clipboard = 'yes'}, {register = 'A'}, {register = 'ab'}, {debug = 1},
    {language_overrides = {cs = 1}}, {directive_rules = {'pattern'}}, {unknown = true}}) do
    assert(not pcall(plugin.setup, opts), vim.inspect(opts))
  end
end)
test('user mapping preferred, local configurable override next', function()
  vim.treesitter.language.register('lua', 'mylua')
  eq(comments.language('mylua', config.resolve()), 'lua')
  eq(comments.language('cs', config.resolve({language_overrides = {cs = 'c'}})), 'c')
end)
test('clipboard unavailable still succeeds locally', function()
  buffer('local a=1 -- remove')
  plugin.setup({register = 'a'})
  local available = registers.available
  registers.available = function() return false end
  local ok, message = plugin.copy()
  registers.available = available
  assert(ok and message:find('provider unavailable', 1, true)); eq(vim.fn.getreg('a'), 'local a=1  \n')
  plugin.setup({register = 'a', clipboard = false})
end)
test('default unnamed/0 exception and all other local registers retained', function()
  buffer('local a=1 -- remove')
  for _, reg in ipairs({'a','b','1','2','3','4','5','6','7','8','9','-'}) do vim.fn.setreg(reg, 'old-' .. reg) end
  vim.fn.setreg('"', {points_to = 'b'})
  plugin.setup({clipboard = false})
  assert(plugin.copy())
  eq(vim.fn.getreg('"'), 'local a=1  \n'); eq(vim.fn.getreg('0'), 'local a=1  \n')
  eq(vim.fn.getreginfo('"').points_to, '0')
  for _, reg in ipairs({'a','b','1','2','3','4','5','6','7','8','9','-'}) do eq(vim.fn.getreg(reg), 'old-' .. reg) end
  plugin.setup({register = 'a', clipboard = false})
end)
test('JSX whole comment container removed without introducing rendered whitespace', function()
  eq(clean('const el=<div>{/* remove */}</div>;', 'javascript'), 'const el=<div></div>;')
  eq(clean('const el=<div>{1 /* remove */}</div>;', 'tsx'), 'const el=<div>{1  }</div>;')
  eq(clean('const el=<div>{/* @ts-ignore */}</div>;', 'javascript'), 'const el=<div>{/* @ts-ignore */}</div>;')
end)
test('all-comment failure leaves Visual selection active and saved registers intact', function()
  buffer('-- remove'); vim.fn.setreg('a', 'sentinel')
  keys('ggV')
  assert(not plugin.copy()); eq(vim.fn.mode(), 'V'); eq(vim.fn.getreg('a'), 'sentinel')
  keys('<Esc>')
end)
test('directive callback failure and changed-buffer validation stop before writes', function()
  buffer('local a=1 -- remove'); vim.fn.setreg('a', 'sentinel')
  plugin.setup({register = 'a', clipboard = false, directive_rules = {function() error('bad custom rule', 0) end}})
  assert(not plugin.copy()); eq(vim.fn.getreg('a'), 'sentinel')
  plugin.setup({register = 'a', clipboard = false, directive_rules = {function()
    vim.api.nvim_buf_set_lines(0, 0, 1, true, {'local a=2'})
    return false
  end}})
  local ok, err = plugin.copy()
  assert(not ok and err:find('buffer changed', 1, true)); eq(vim.fn.getreg('a'), 'sentinel')
  plugin.setup({register = 'a', clipboard = false})
end)
test('real query syntax failure path', function()
  buffer('local a=1 -- remove'); vim.fn.setreg('a', 'sentinel')
  local readfile = vim.fn.readfile
  vim.fn.readfile = function(path, ...)
    if path:match('/lua/clean_copy%.scm$') then return {'(nonexistent_node) @clean_copy.comment'} end
    return readfile(path, ...)
  end
  local ok, err = plugin.copy()
  vim.fn.readfile = readfile
  assert(not ok and err:find('invalid clean_copy query', 1, true)); eq(vim.fn.getreg('a'), 'sentinel')
end)
test('private queries unaffected by user highlight or string injection queries', function()
  vim.treesitter.query.set('lua', 'highlights', '')
  vim.treesitter.query.set('lua', 'injections', '((string_content) @injection.content (#set! injection.language "c"))')
  eq(clean('local s="/* string */" -- remove', 'lua'), 'local s="/* string */"  ')
  vim.treesitter.query.set('lua', 'injections', nil)
  vim.treesitter.query.set('lua', 'highlights', nil)
end)
test('plugin loader does not reset prior setup configuration', function()
  plugin.setup({register = 'b', clipboard = false})
  dofile('plugin/clean_copy.lua')
  buffer('local a=1 -- remove'); vim.cmd.CleanCopy()
  eq(vim.fn.getreg('b'), 'local a=1  \n')
  plugin.setup({register = 'a', clipboard = false})
end)
test('actual Neovim filetype detection for nontrivial parser names', function()
  for _, f in ipairs({{'example.cs', 'cs'}, {'example.jsx', 'javascriptreact'}, {'example.tsx', 'typescriptreact'},
    {'example.php', 'php'}, {'example.vue', 'vue'}, {'example.sql', 'sql'}}) do
    eq(vim.filetype.match({filename = f[1]}), f[2])
  end
end)
test('SQL quote escapes, backtick identifiers and dialect-specific forms', function()
  for _, text in ipairs({[[SELECT 'it''s -- /* string */', "a""--b"; -- remove]],
    [[SELECT `--column`, '/* string */'; -- remove]],
    [[SELECT E'it\'s -- /* string */', $tag$中文 -- /* string */$tag$; /* remove */]]}) do
    local out = clean(text, 'sql')
    assert(not out:find('remove', 1, true))
    assert(out:find('--', 1, true) and out:find('/* string */', 1, true))
  end
  local ok, err = pcall(clean, 'SELECT 1; # mysql comment', 'sql')
  assert(not ok and err:find('ERROR/MISSING', 1, true), tostring(err))
end)
test('C/C++ opaque macro arguments refuse ambiguous comment markers', function()
  for _, lang in ipairs({'c', 'cpp'}) do
    eq(clean('#define X 1\nint/* remove */value;', lang), '#define X 1\nint value;')
    for _, text in ipairs({'#define X 1 // comment\nint a;', '#define S "http://example"\nint a;'}) do
      local ok, err = pcall(clean, text, lang)
      assert(not ok and err:find('preprocessor argument', 1, true), tostring(err))
    end
  end
end)
test('SQL nested block markers conservatively refused', function()
  local ok, err = pcall(clean, 'SELECT /* outer /* inner */ 1;', 'sql')
  assert(not ok and err:find('nested SQL', 1, true), tostring(err))
end)
test('Rust parser doc fields retain empty doc markers and remove ordinary four slashes', function()
  eq(clean('///\n//// remove\nfn main() {}', 'rust', {preserve_doc_comments = true}), '///\nfn main() {}')
end)
test('gv reselects exactly the previous character selection', function()
  buffer('local value=1 -- remove\nlocal other=2')
  keys('gg04lv5l')
  local original = vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), {type = 'v'})
  assert(plugin.copy()); keys('gv')
  eq(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), {type = 'v'}), original)
  keys('<Esc>')
end)
test('clipboard provider success, failure and disabled state', function()
  local copied, throw = {}, false
  local function copy(lines, kind)
    if throw then error('test provider failed') end
    copied = {vim.deepcopy(lines), kind}
  end
  vim.g.clipboard = {name = 'clean-copy-test', copy = {['+'] = copy, ['*'] = copy},
    paste = {['+'] = function() return copied end, ['*'] = function() return copied end}, cache_enabled = 0}
  assert(registers.available())
  buffer('local a=1 -- remove')
  plugin.setup({register = 'a'})
  local ok, status = plugin.copy()
  assert(ok and status:find('system clipboard + written', 1, true))
  eq(copied, {{'local a=1  ', ''}, 'V'})
  vim.o.clipboard = 'unnamedplus'
  plugin.setup({clipboard = false})
  copied = {{'sentinel'}, 'v'}
  assert(plugin.copy()); eq(copied, {{'sentinel'}, 'v'}); eq(vim.o.clipboard, 'unnamedplus')
  vim.o.clipboard = ''
  throw = true
  plugin.setup({register = 'a'})
  ok, status = plugin.copy()
  assert(ok and status:find('clipboard write failed', 1, true)); eq(vim.fn.getreg('a'), 'local a=1  \n')
  throw = false
  plugin.setup({register = '+', clipboard = false})
  assert(plugin.copy())
  eq(copied, {{'local a=1  ', ''}, 'V'})
  plugin.setup({register = 'a', clipboard = false})
end)
print(string.format('RESULT %d passed, %d failed', passed, failed))
vim.cmd(failed == 0 and 'qa!' or 'cquit 1')
