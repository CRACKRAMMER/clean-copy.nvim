local selection = require('clean_copy.selection')
local rules = require('clean_copy.rules')
local sql = require('clean_copy.sql')
local M = {}
local root_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
local supported = { sql = true, c = true, cpp = true, typescript = true, javascript = true,
  rust = true, go = true, python = true, php = true, php_only = true, c_sharp = true,
  html = true, css = true, java = true, vue = true, tsx = true, lua = true }
local fallback = { cs = 'c_sharp', javascriptreact = 'javascript', typescriptreact = 'tsx' }
function M.language(ft, opts)
  local lang = opts.language_overrides[ft] or vim.treesitter.language.get_lang(ft)
  -- Core defaults to the filetype when nothing has been registered.
  if lang == ft and fallback[ft] then lang = fallback[ft] end
  if not supported[lang] then error('unsupported language/parser: ' .. tostring(lang or ft), 0) end
  return lang
end
function M.load_query(lang, name)
  local path = root_dir .. '/queries/' .. lang .. '/' .. name .. '.scm'
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then error('cannot load ' .. name .. ' query for ' .. lang, 0) end
  local parsed, query = pcall(vim.treesitter.query.parse, lang, table.concat(lines, '\n'))
  if not parsed then error('invalid ' .. name .. ' query for ' .. lang, 0) end
  return query
end
local function load(lang)
  local ok, available = pcall(vim.treesitter.language.add, lang)
  if not ok or not available then error('missing or incompatible parser: ' .. lang, 0) end
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
  callback(node)
  for child in node:iter_children() do walk(child, callback) end
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

function M.collect(snapshot, sel, lang, opts)
  load(lang)
  local injections = disabled_injections()
  local clauses, seen = { html = {}, vue = {} }, { html = {}, vue = {} }
  local parsers = {}
  local function parser(source, language, injection_opts)
    local p = vim.treesitter.get_string_parser(source, language, { injections = injection_opts })
    parsers[#parsers + 1] = p
    if not p:parse(true) then error('parse did not complete for ' .. language, 0) end
    return p
  end
  local function preflight(tree, language)
    if language ~= 'html' and language ~= 'vue' then return end
    local query = M.load_query(language, 'clean_copy_regions')
    for id, node in query:iter_captures(tree:root(), snapshot.text, 0, -1) do
      local attrs, tag = attributes(node, snapshot.text)
      if query.captures[id] == 'clean_copy.template' then
        if attrs.lang and attrs.lang ~= 'html' and overlaps(range(node, snapshot), sel) then
          error('unsupported embedded template language: ' .. attrs.lang, 0)
        end
      else
        local childlang, unsupported = embedded_language(node:type(), attrs)
        local content
        for child in node:iter_children() do if child:type() == 'raw_text' then content = child end end
        local involved = overlaps(range(content or node, snapshot), sel)
        if unsupported and involved then error('unsupported embedded language: ' .. unsupported, 0) end
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
    end
  end
  local function run()
    -- Parse a snapshot of the ENTIRE original buffer, never the selected fragment.
    -- Private injection queries keep user highlighting and string injections out of this operation.
    local initial = parser(snapshot.text, lang, injections)
    initial:for_each_tree(function(tree) preflight(tree, lang) end)
    if lang == 'php' then
      local html_ranges = {}
      local query = M.load_query('php', 'clean_copy_regions')
      initial:for_each_tree(function(tree)
        for _, node in query:iter_captures(tree:root(), snapshot.text, 0, -1) do
          html_ranges[#html_ranges + 1] = { node:range(true) }
          if overlaps(range(node, snapshot), sel) then load('html') end
        end
      end)
      if #html_ranges > 0 then
        local ok, available = pcall(vim.treesitter.language.add, 'html')
        if ok and available then
          local html = vim.treesitter.get_string_parser(snapshot.text, 'html', { injections = injections })
          parsers[#parsers + 1] = html
          html:set_included_regions({ html_ranges })
          html:parse(true)
          html:for_each_tree(function(tree) preflight(tree, 'html') end)
        end
      end
      injections.php = '((text) @injection.content (#set! injection.language "html") (#set! injection.combined))'
    end
    injections.html = table.concat(clauses.html, '\n')
    injections.vue = table.concat(clauses.vue, '\n')
    local complete = parser(snapshot.text, lang, injections)
    local removals, protected, containers, errors = {}, {}, {}, {}
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
      local query = M.load_query(language, 'clean_copy')
      for id, node in query:iter_captures(tree:root(), snapshot.text, 0, -1) do
        local r = range(node, snapshot)
        if query.captures[id] == 'clean_copy.jsx' then containers[#containers + 1] = node
        elseif query.captures[id] == 'clean_copy.comment' then
          local text = vim.treesitter.get_node_text(node, snapshot.text)
          if rules.keep(text, language, node, opts) then protected[#protected + 1] = r
          else
            if language == 'sql' and node:type() == 'marginalia' and text:sub(3):find('/*', 1, true)
                and overlaps(r, sel) then
              error('nested SQL block comments are not supported by this parser', 0)
            end
            removals[#removals + 1] = r
          end
        elseif query.captures[id] == 'clean_copy.opaque' and overlaps(r, sel) then
          -- These grammars can hide // inside a single opaque macro token.
          -- Refuse ambiguous payloads; this is detection of a limitation, not comment parsing.
          local text = vim.treesitter.get_node_text(node, snapshot.text)
          if text:find('//', 1, true) or text:find('/*', 1, true) then
            error('cannot reliably parse comment-like text in preprocessor argument (' .. language .. ')', 0)
          end
        end
      end
      if tree:root():has_error() then
        walk(tree:root(), function(node)
          if node:type() == 'ERROR' or node:missing() then
            errors[#errors + 1] = { range = range(node, snapshot), lang = language, node = node }
          end
        end)
      end
    end)
    -- A JSX container is removable only when EVERY named child is a removable comment.
    for _, container in ipairs(containers) do
      local count, only_comments = 0, true
      for child in container:iter_children() do
        if child:named() then
          count = count + 1
          local r, found = range(child, snapshot), false
          for _, remove in ipairs(removals) do
            if remove[1] == r[1] and remove[2] == r[2] then found = true; break end
          end
          if not found then only_comments = false end
        end
      end
      if only_comments and count > 0 then
        local r = range(container, snapshot)
        r.jsx = true
        removals[#removals + 1] = r
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
    for _, err in ipairs(errors) do
      local affected = overlaps(err.range, sel)
      for _, r in ipairs(filtered) do
        if overlaps(r, sel) and overlaps(err.range, { start = r[1], finish = r[2] }) then affected = true end
      end
      if affected and not (err.lang == 'sql' and sql.unselected_separator(err.node, snapshot, sel)) then
        local row, col = err.node:range()
        local detail = err.node:missing() and ('missing ' .. err.node:type()) or 'ERROR'
        error(string.format('syntax ERROR/MISSING in selected region (%s), %s at %d:%d',
          err.lang, detail, row + 1, col + 1), 0)
      end
    end
    return filtered
  end
  local ok, result = pcall(run)
  for _, p in ipairs(parsers) do p:destroy() end
  if not ok then error(result, 0) end
  return result
end
return M
