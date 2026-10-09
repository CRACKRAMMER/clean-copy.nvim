local selection = require('clean_copy.selection')
local rules = require('clean_copy.rules')
local sql = require('clean_copy.sql')
local errors = require('clean_copy.errors')
local M = {}
local root_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
local supported = { sql = true, c = true, cpp = true, typescript = true, javascript = true,
  rust = true, go = true, python = true, php = true, php_only = true, c_sharp = true,
  html = true, css = true, java = true, vue = true, tsx = true, lua = true }
local fallback = { cs = 'c_sharp', javascriptreact = 'javascript', typescriptreact = 'tsx' }

-- Keep API failures at their boundary so normal messages do not expose Lua internals.
-- Structured failures raised by nested callbacks retain their original category.
local function guard(code, stage, message, context, hint, fn)
  local ok, result = xpcall(fn, function(err)
    if errors.is(err) then return err end
    local failure = errors.new(code, stage, message, {
      context = context, hint = hint, cause = err,
    })
    failure.traceback = debug.traceback('', 2)
    return failure
  end)
  if not ok then error(result, 0) end
  return result
end

function M.language(ft, opts)
  local lang = opts.language_overrides[ft]
  if lang == nil then
    lang = guard('LANGUAGE_MAP', 'language', 'cannot resolve the filetype language',
      { filetype = ft }, 'Check Tree-sitter language mappings or set language_overrides.',
      function() return vim.treesitter.language.get_lang(ft) end)
    -- Core can return the filetype itself or nil for an unregistered alias.
    if (lang == ft or lang == nil) and fallback[ft] then lang = fallback[ft] end
  end
  if lang ~= nil and type(lang) ~= 'string' then
    errors.raise('LANGUAGE_MAP', 'language', 'language mapping returned an invalid parser name', {
      context = { filetype = ft, returned = type(lang) },
      hint = 'Register a string parser name or set language_overrides.',
    })
  end
  if not supported[lang] then
    errors.raise('UNSUPPORTED_LANGUAGE', 'language', 'unsupported language/parser: ' .. tostring(lang or ft), {
      context = { filetype = ft, language = lang },
      hint = 'Set a supported filetype or map it to a supported parser with language_overrides.',
    })
  end
  return lang
end
function M.load_query(lang, name)
  local path = root_dir .. '/queries/' .. lang .. '/' .. name .. '.scm'
  local context = { language = lang, query = name, path = path }
  local lines = guard('QUERY', 'query', 'cannot load ' .. name .. ' query for ' .. lang,
    context, 'Check that the plugin query file is readable.', function() return vim.fn.readfile(path) end)
  local query = guard('QUERY', 'query', 'invalid ' .. name .. ' query for ' .. lang,
    context, 'Use a compatible parser and restore or correct the plugin query file.',
    function() return vim.treesitter.query.parse(lang, table.concat(lines, '\n')) end)
  if not query then
    errors.raise('QUERY', 'query', 'invalid ' .. name .. ' query for ' .. lang, {
      context = context, hint = 'Use a compatible parser and restore the plugin query file.',
    })
  end
  return query
end
local function load(lang)
  local ok, available, cause = pcall(vim.treesitter.language.add, lang)
  if not ok or not available then
    errors.raise('PARSER_MISSING', 'parser', 'missing or incompatible parser: ' .. lang, {
      context = { language = lang }, cause = ok and cause or available,
      hint = 'Install a compatible ' .. lang .. ' Tree-sitter parser on runtimepath.',
    })
  end
end
local function range(node, snapshot)
  local sr, sc, er, ec = node:range()
  return { selection.offset(snapshot, sr, sc), selection.offset(snapshot, er, ec) }
end
local function overlaps(r, sel)
  if r[1] == r[2] then return r[1] >= sel.start and r[1] <= sel.finish end
  return r[1] < sel.finish and r[2] > sel.start
end
local function walk(node, callback)
  -- An explicit stack avoids overflowing Lua on deeply nested valid syntax.
  local pending = { node }
  while #pending > 0 do
    local current = table.remove(pending)
    callback(current)
    local children = {}
    for child in current:iter_children() do children[#children + 1] = child end
    for index = #children, 1, -1 do pending[#pending + 1] = children[index] end
  end
end
local function attributes(node, text)
  local attrs, start_tag = {}, nil
  for child in node:iter_children() do
    if child:type() == 'start_tag' then
      start_tag = child
      for attr in child:iter_children() do
        if attr:type() == 'attribute' then
          local name, value
          for part in attr:iter_children() do
            if part:type() == 'attribute_name' then name = vim.treesitter.get_node_text(part, text):lower() end
            if part:type() == 'attribute_value' then value = vim.treesitter.get_node_text(part, text):lower() end
            if part:type() == 'quoted_attribute_value' then
              for v in part:iter_children() do
                if v:type() == 'attribute_value' then value = vim.treesitter.get_node_text(v, text):lower() end
              end
            end
          end
          if name then attrs[name] = value or '' end
        end
      end
    end
  end
  return attrs, start_tag
end
local function embedded_language(kind, attrs)
  if kind == 'style_element' then
    if attrs.lang and attrs.lang ~= 'css' then return nil, attrs.lang end
    if attrs.type and attrs.type ~= 'text/css' then return nil, attrs.type end
    return 'css'
  end
  if attrs.lang then
    if attrs.lang == 'js' or attrs.lang == 'javascript' then return 'javascript' end
    if attrs.lang == 'ts' or attrs.lang == 'typescript' then return 'typescript' end
    return nil, attrs.lang
  end
  local typ = attrs.type
  if not typ or typ == 'module' or typ == 'text/javascript' or typ == 'application/javascript'
      or typ == 'text/ecmascript' or typ == 'application/ecmascript' then return 'javascript' end
  -- These are data blocks, not embedded code; their string contents are left intact.
  if typ == 'application/json' or typ == 'application/ld+json' or typ == 'importmap'
      or typ == 'speculationrules' then return false end
  return nil, typ
end
local function disabled_injections()
  local result = {}
  for lang in pairs(supported) do result[lang] = '' end
  return result
end

local function retain_jsx_container(node, text)
  local parent = node:parent()
  if not parent or (parent:type() ~= 'jsx_element' and parent:type() ~= 'jsx_fragment') then return true end
  local before, after = node:prev_named_sibling(), node:next_named_sibling()
  for _, neighbor in pairs({ before, after }) do
    if neighbor:type() == 'jsx_text' and vim.treesitter.get_node_text(neighbor, text):find('\n', 1, true) then
      return true
    end
  end
  -- An empty expression also separates text tokens. Removing it must not turn
  -- a literal partial reference into a new JSX character reference.
  return before and before:type() == 'jsx_text'
    and vim.treesitter.get_node_text(before, text):match('&[#%w]*$') ~= nil
end

function M.collect(snapshot, sel, lang, opts)
  load(lang)
  local injections = disabled_injections()
  local clauses, seen = { html = {}, vue = {} }, { html = {}, vue = {} }
  local parsers = {}
  local function parser(source, language, injection_opts, regions)
    local p = guard('PARSER', 'parser', 'cannot create parser for ' .. language,
      { language = language }, 'Check the parser installation and Neovim compatibility.',
      function() return vim.treesitter.get_string_parser(source, language, { injections = injection_opts }) end)
    if not p then
      errors.raise('PARSER', 'parser', 'cannot create parser for ' .. language, {
        context = { language = language }, hint = 'Check the parser installation and Neovim compatibility.',
      })
    end
    parsers[#parsers + 1] = p
    local trees = guard('PARSER', 'parser', 'parse failed for ' .. language,
      { language = language }, 'Check the parser version and report the failing input if it persists.', function()
        if regions then p:set_included_regions(regions) end
        return p:parse(true)
      end)
    if type(trees) ~= 'table' or next(trees) == nil then
      errors.raise('PARSER', 'parser', 'parse did not complete for ' .. language, {
        context = { language = language }, hint = 'Check the parser version and retry copying.',
      })
    end
    return p
  end
  local function captures(tree, language, name, callback)
    guard('QUERY', 'query', 'cannot evaluate ' .. name .. ' query for ' .. language,
      { language = language, query = name }, 'Check the plugin query and parser compatibility.', function()
        local query = M.load_query(language, name)
        for id, node in query:iter_captures(tree:root(), snapshot.text, 0, -1) do
          callback(query.captures[id], node)
        end
      end)
  end
  local function preflight(tree, language)
    if language ~= 'html' and language ~= 'vue' then return end
    captures(tree, language, 'clean_copy_regions', function(capture, node)
      local attrs, tag = attributes(node, snapshot.text)
      if capture == 'clean_copy.template' then
        if attrs.lang and attrs.lang ~= 'html' and overlaps(range(node, snapshot), sel) then
          local row, col = node:range()
          errors.raise('UNSUPPORTED_EMBEDDED', 'parser', 'unsupported embedded template language: ' .. attrs.lang, {
            context = { language = language, embedded = attrs.lang, row = row + 1, col = col + 1 },
            hint = 'Select a supported region or use an HTML template.',
          })
        end
      else
        local childlang, unsupported = embedded_language(node:type(), attrs)
        local content
        for child in node:iter_children() do if child:type() == 'raw_text' then content = child end end
        local involved = overlaps(range(content or node, snapshot), sel)
        if unsupported and involved then
          local row, col = node:range()
          errors.raise('UNSUPPORTED_EMBEDDED', 'parser', 'unsupported embedded language: ' .. unsupported, {
            context = { language = language, embedded = unsupported, row = row + 1, col = col + 1 },
            hint = 'Select a supported region; supported script/style languages are JavaScript, TypeScript and CSS.',
          })
        end
        if childlang and content and tag then
          if involved then load(childlang) end
          local ok, available = pcall(vim.treesitter.language.add, childlang)
          -- Exact start-tag predicates come from AST text, not a comment regexp.
          local tagtext = vim.treesitter.get_node_text(tag, snapshot.text)
          local key = node:type() .. '\0' .. tagtext
          if ok and available and not seen[language][key] then
            seen[language][key] = true
            clauses[language][#clauses[language] + 1] = string.format(
              '((%s (start_tag) @_tag (raw_text) @injection.content)\n'
                .. ' (#eq? @_tag %s) (#set! injection.language "%s"))',
              node:type(), vim.json.encode(tagtext), childlang)
          end
        end
      end
    end)
  end
  local function run()
    -- Parse a snapshot of the ENTIRE original buffer, never the selected fragment.
    -- Private injection queries keep user highlighting and string injections out of this operation.
    local initial
    if lang == 'html' or lang == 'vue' or lang == 'php' then
      initial = parser(snapshot.text, lang, injections)
      initial:for_each_tree(function(tree) preflight(tree, lang) end)
    end
    if lang == 'php' then
      local html_ranges = {}
      initial:for_each_tree(function(tree)
        captures(tree, 'php', 'clean_copy_regions', function(_, node)
          html_ranges[#html_ranges + 1] = { node:range(true) }
          if overlaps(range(node, snapshot), sel) then load('html') end
        end)
      end)
      if #html_ranges > 0 then
        local ok, available = pcall(vim.treesitter.language.add, 'html')
        if ok and available then
          local html = parser(snapshot.text, 'html', injections, { html_ranges })
          html:for_each_tree(function(tree) preflight(tree, 'html') end)
        end
      end
      injections.php = '((text) @injection.content (#set! injection.language "html") (#set! injection.combined))'
    end
    injections.html = table.concat(clauses.html, '\n')
    injections.vue = table.concat(clauses.vue, '\n')
    -- Child LanguageTrees parse their injection query inside Neovim. Validate the
    -- generated queries first so a query failure is not mistaken for a parser failure.
    for language, query in pairs(injections) do
      if query ~= '' then
        local message = 'invalid clean_copy injection query for ' .. language
        local context = { language = language, query = 'injections' }
        local parsed = guard('QUERY', 'query', message,
          context, 'Check parser compatibility with the plugin.',
          function() return vim.treesitter.query.parse(language, query) end)
        if not parsed then
          errors.raise('QUERY', 'query', message, {
            context = context, hint = 'Check parser compatibility with the plugin.',
          })
        end
      end
    end
    local complete = parser(snapshot.text, lang, injections)
    local removals, protected, containers, syntax_errors = {}, {}, {}, {}
    complete:for_each_tree(function(tree, ltree)
      local language = ltree:lang()
      local relevant = false
      -- A combined injection root may span holes. Captures/errors keep original buffer coordinates.
      for _, regions in pairs(ltree:included_regions()) do
        for _, r in ipairs(regions) do
          if #r == 0 or overlaps({ selection.offset(snapshot, r[1], r[2]),
            selection.offset(snapshot, r[4], r[5]) }, sel) then relevant = true end
        end
      end
      if language == lang then relevant = true end
      if not relevant then return end
      captures(tree, language, 'clean_copy', function(capture, node)
        local r = range(node, snapshot)
        if not overlaps(r, sel) then return end
        if capture == 'clean_copy.jsx' then containers[#containers + 1] = node
        elseif capture == 'clean_copy.comment' then
          local text = vim.treesitter.get_node_text(node, snapshot.text)
          if rules.keep(text, language, node, opts) then protected[#protected + 1] = r
          else
            if language == 'sql' and node:type() == 'marginalia' and text:sub(3):find('/*', 1, true) then
              local row, col = node:range()
              errors.raise('SYNTAX', 'parser', 'nested SQL block comments are not supported by this parser', {
                context = { language = language, row = row + 1, col = col + 1 },
                hint = 'Avoid selecting nested block comments with this SQL grammar.',
              })
            end
            r.no_space = language == 'html' or language == 'vue'
            if r.no_space then
              local row, col = node:range()
              r.markup = { language = language, row = row + 1, col = col + 1 }
            end
            removals[#removals + 1] = r
          end
        elseif capture == 'clean_copy.opaque' then
          -- These grammars can hide // inside a single opaque macro token.
          -- Refuse ambiguous payloads; this is detection of a limitation, not comment parsing.
          local text = vim.treesitter.get_node_text(node, snapshot.text)
          if text:find('//', 1, true) or text:find('/*', 1, true) then
            local row, col = node:range()
            errors.raise('SYNTAX', 'parser', 'cannot reliably parse comment-like text in preprocessor argument (' .. language .. ')', {
              context = { language = language, row = row + 1, col = col + 1 },
              hint = 'Exclude this macro argument from the selection; the parser treats it as opaque text.',
            })
          end
        end
      end)
      if tree:root():has_error() then
        walk(tree:root(), function(node)
          if node:type() == 'ERROR' or node:missing() then
            syntax_errors[#syntax_errors + 1] = { range = range(node, snapshot), lang = language, node = node }
          end
        end)
      end
    end)
    -- A JSX container is removable only when EVERY named child is a removable comment.
    for _, container in ipairs(containers) do
      local count, only_comments = 0, true
      local inner = {}
      for child in container:iter_children() do
        if child:named() then
          count = count + 1
          local r, found = range(child, snapshot), false
          for _, remove in ipairs(removals) do
            if remove[1] == r[1] and remove[2] == r[2] then
              found = true
              inner[#inner + 1] = remove
              break
            end
          end
          if not found then only_comments = false end
        end
      end
      if only_comments and count > 0 then
        for _, r in ipairs(inner) do r.no_space = true end
        if not retain_jsx_container(container, snapshot.text) then
          local r = range(container, snapshot)
          r.no_space = true
          removals[#removals + 1] = r
        end
      end
    end
    local filtered = {}
    for _, r in ipairs(removals) do
      local retain = false
      for _, keep in ipairs(protected) do
        if overlaps(keep, { start = r[1], finish = r[2] }) then retain = true; break end
      end
      if not retain then filtered[#filtered + 1] = r end
    end
    -- Adjacent removed markup comments can form a new character reference.
    -- Inspect only the boundaries of AST-confirmed removals, including chains.
    local markup, boundaries = {}, {}
    for _, r in ipairs(filtered) do if r.markup then markup[#markup + 1] = r end end
    table.sort(markup, function(a, b) return a[1] < b[1] end)
    for _, r in ipairs(markup) do
      local last = boundaries[#boundaries]
      if last and r[1] <= last[2] then last[2] = math.max(last[2], r[2])
      else boundaries[#boundaries + 1] = { r[1], r[2], context = r.markup } end
    end
    for _, r in ipairs(boundaries) do
      local left, right = math.max(sel.start, r[1]), math.min(sel.finish, r[2])
      if snapshot.text:sub(sel.start + 1, left):match('&[#%w]*$')
          and snapshot.text:sub(right + 1, sel.finish):match('^[#%w;]') then
        errors.raise('SYNTAX', 'parser', 'removing HTML comments would join a character reference', {
          context = r.context,
          hint = 'Preserve this boundary with directive_rules or choose a selection that does not join its text.',
        })
      end
    end
    for _, err in ipairs(syntax_errors) do
      local affected = overlaps(err.range, sel)
      for _, r in ipairs(filtered) do
        if overlaps(r, sel) and overlaps(err.range, { start = r[1], finish = r[2] }) then affected = true end
      end
      if affected and not (err.lang == 'sql' and sql.unselected_separator(err.node, snapshot, sel)) then
        local row, col = err.node:range()
        local detail = err.node:missing() and ('missing ' .. err.node:type()) or 'ERROR'
        errors.raise('SYNTAX', 'parser', string.format('syntax ERROR/MISSING in selected region (%s), %s at %d:%d',
          err.lang, detail, row + 1, col + 1), {
          context = { language = err.lang, row = row + 1, col = col + 1, node = detail },
          hint = 'Fix the selected syntax or choose an error-free region; verify the parser supports this syntax.',
        })
      end
    end
    return filtered
  end
  local ok, result = xpcall(run, function(err)
    if errors.is(err) then return err end
    local failure = errors.new('PARSER', 'parser', 'failed to inspect the syntax tree', {
      context = { language = lang }, cause = err,
      hint = 'Check parser compatibility and report the failing input if it persists.',
    })
    failure.traceback = debug.traceback('', 2)
    return failure
  end)
  local cleanup = {}
  for index = #parsers, 1, -1 do
    local cleaned, err = pcall(function() parsers[index]:destroy() end)
    if not cleaned then cleanup[#cleanup + 1] = errors.describe(err) end
  end
  if #cleanup > 0 then
    if not ok then
      result.detail = (result.detail and (result.detail .. '\n') or '')
        .. 'Parser cleanup also failed: ' .. table.concat(cleanup, '; ')
    else
      errors.raise('INTERNAL', 'cleanup', 'parser cleanup failed; no register written', {
        context = { language = lang }, cause = table.concat(cleanup, '; '),
        hint = 'Retry with a compatible parser and Neovim version.',
      })
    end
  end
  if not ok then error(result, 0) end
  return result
end
return M
