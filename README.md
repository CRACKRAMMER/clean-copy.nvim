# clean-copy.nvim

## Project Overview

Copy code without removable comments using Neovim's Tree-sitter parsers. The source buffer stays unchanged; strings, required directives, and native register behavior are preserved within the supported parser and language boundaries.

Use `:CopyClean` for a buffer or line range, or a Lua Visual mapping for an exact character selection. The plugin installs no default mappings and does not intercept ordinary yank, delete, or cut operations.

## Features

- Character selections, line selections, explicit line ranges, and whole buffers.
- Full-buffer parsing preserves context when copying a fragment.
- Private comment queries keep deletion independent of highlighting queries.
- Retention of shebangs and recognized compiler/tool directives; optional retention of documentation and license comments.
- Configurable target register and optional system clipboard write, with explicit partial-failure reports.
- An explicit parser synchronization command with dependency checks, asynchronous jobs, and bounded concurrency.
- No buffer edits, formatting, parser installation, or network access during copying.

## Requirements

- Neovim **0.12 or newer**. Older versions are not supported.
- Compatible Tree-sitter parsers installed under `parser/` on `runtimepath`.
- A Neovim clipboard provider when writing `+` or `*`.

Copying uses Neovim's built-in Lua and Tree-sitter APIs. `nvim-treesitter` is optional and is required only for the parser installation command. That command also needs a stable `tree-sitter` CLI **0.26.1+**, `curl`, `tar`, and a C compiler; it respects `CC`. These tools are checked only when installation is explicitly requested.

The intended test parser revisions are recorded in [tests/parsers.lock.json](tests/parsers.lock.json); other versions require verification. The interactive installer follows nvim-treesitter's grammar definitions rather than this test lock file.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "CRACKRAMMER/clean-copy.nvim",
  main = "clean_copy",
  cmd = { "CopyClean", "CopyCleanParsers" },
  keys = {
    {
      "<leader>cy",
      function() require("clean_copy").copy() end,
      mode = "x",
      desc = "Copy without comments",
    },
  },
  opts = {},
}
```

The module name is `clean_copy`. Both commands are registered when the plugin loads or the module is required; calling `setup()` is optional. `opts = {}` uses the defaults. Install compatible parsers before copying.

To use `:CopyCleanParsers`, include the optional main-branch nvim-treesitter dependency:

```lua
{
  "CRACKRAMMER/clean-copy.nvim",
  main = "clean_copy",
  cmd = { "CopyClean", "CopyCleanParsers" },
  dependencies = {
    { "nvim-treesitter/nvim-treesitter", branch = "main" },
  },
  opts = {},
}
```

The default setup does not install parsers, and the example adds no automatic `:TSUpdate` build hook. Users who already manage parsers can omit this dependency and continue using `:CopyClean`.

## Quick Start

```vim
:CopyClean
:10,20CopyClean
:%CopyClean
```

For a plugin installed on `runtimepath`, this minimal configuration creates an exact Visual-selection mapping:

```lua
vim.keymap.set("x", "<leader>cy", function()
  require("clean_copy").copy()
end, { desc = "Copy without comments" })
```

To copy only to a named register without using the system clipboard:

```lua
require("clean_copy").setup({ register = "a", clipboard = false })
```

Read the installed help with `:help clean-copy` after your plugin manager generates helptags.

## Commands

| Entry point | Scope | Register type |
| --- | --- | --- |
| `:CopyClean` without a range or active Visual selection | Entire current buffer | Linewise (`V`) |
| `:10,20CopyClean`, `:%CopyClean` | Explicit whole-line range | Linewise (`V`) |
| `copy()` in Normal mode | Entire current buffer | Linewise (`V`) |
| `copy()` in Visual character mode | Exact selected characters | Characterwise (`v`) |
| `copy()` in Visual line mode | Selected whole lines | Linewise (`V`) |
| Visual mapping using `<Cmd>CopyClean<CR>` | Active character/line selection, like `copy()` | Characterwise/linewise |
| Visual `:` followed by `CopyClean` | Vim's automatic `'<,'>` whole-line range | Linewise (`V`) |

Use the Lua mapping above, or a Visual `<Cmd>CopyClean<CR>` mapping, to preserve a character selection. A mapping that enters `:` supplies a whole-line range. A programmatic command with no range also follows an active Visual selection. Block selections and virtual cells that cannot reliably map to bytes are rejected. UTF-8, Tabs, reverse selections, and `'selection'` modes are supported.

After a fully successful Lua/`<Cmd>` copy from Visual mode, the plugin exits Visual and retains the cursor and last selection for `gv`. Neovim clamps virtual end-of-line positions in Normal mode. Failures detected before this exit leave the active selection untouched, unless a callback has changed editor state. Visual `:` enters Ex before execution; a command failure does not re-enter Visual. A failure during Visual-state restoration may occur after the mode has already changed and is reported explicitly.

`require("clean_copy").copy()` returns `success, message, report` and also notifies once. `success` is `true` only when all requested writes complete. A local write followed by an unavailable or failing clipboard returns `false` with a WARN report describing what was written. Check the report before retrying.

### Parser synchronization

```vim
:CopyCleanParsers             " Install missing parsers and update existing ones
:CopyCleanParsers sql lua     " Synchronize only these configured languages
:CopyCleanParsers!            " Force rebuild every configured parser
:CopyCleanParsers! sql        " Force rebuild only SQL
```

Arguments must belong to `parser_languages`; completion lists those names. Without arguments, the command uses the whole configured list. The backend may also install required parser/query dependencies. Missing binaries are installed even when query files remain, and installed parsers are updated to the backend's configured revisions. `!` forces rebuilding all selected parsers.

The command validates arguments, backend grammar availability, and toolchain dependencies before installing anything. It runs the CLI version probe and installation asynchronously, with at most two concurrent operations. A second invocation while work is pending reports that the installer is busy. Loading the plugin, calling `setup()`, and copying never trigger installation.

Installation is not transactional: an upstream failure can occur after some parsers have completed. Read the final notification and `:messages`, then run `:checkhealth nvim-treesitter` and retry the affected languages after fixing the cause.

After parser updates, restart Neovim to reload grammars already loaded in that process.

If installation starts but completion cannot be observed because the backend API fails, subsequent installer calls remain blocked: inspect `:messages` and restart Neovim before retrying. Ordinary completed job failures release the busy state so they can be retried.

Both commands register idempotently without overwriting other commands. Resolve reported conflicts and restart Neovim.

## Configuration

```lua
require("clean_copy").setup({
  register = '"',
  clipboard = true,
  remove_empty_comment_lines = true,
  preserve_doc_comments = false,
  preserve_license_comments = false,
  preserve_directives = true,
  directive_rules = {},
  language_overrides = {},
  parser_languages = {
    "c", "cpp", "javascript", "typescript", "tsx", "rust", "go", "python",
    "lua", "java", "c_sharp", "css", "html", "sql", "php", "php_only", "vue",
  },
  legacy_command = false,
  debug = false,
})
```

| Option | Behavior |
| --- | --- |
| `register` | One of `"`, `a-z`, `0-9`, `+`, or `*`. Uppercase append and other special registers are rejected. |
| `clipboard` | Additionally write to `+`. A `+`/`*` target still requires a provider when this is `false`. |
| `remove_empty_comment_lines` | Remove complete original lines containing only removable code comments and whitespace. Preserve pre-existing blank lines, partially selected lines, and whitespace outside markup comments/JSX containers. |
| `preserve_doc_comments` | Retain recognized C-family, Rust, and Lua documentation comments. Python docstrings are always retained as strings. |
| `preserve_license_comments` | Retain SPDX, copyright, `@license`, `@preserve`, and `/*!` markers; this is marker recognition, not license analysis. |
| `preserve_directives` | Retain recognized tool/compiler comments and run custom retention rules. Shebangs are always retained. |
| `directive_rules` | List of pure `(text, language, TSNode) -> boolean` callbacks for selected recognized comments. Exceptions and non-boolean results stop copying. |
| `language_overrides` | Map Neovim filetypes to supported parser names. Takes precedence over Neovim's registered language mapping. |
| `parser_languages` | Unique list of parser names allowed by `CopyCleanParsers`; defaults to the 17 tested grammars above. `{}` makes the no-argument command a no-op while keeping it registered. Other valid backend grammars can be listed without extending supported copying languages. |
| `legacy_command` | Enable the optional `CleanCopy` alias; disabled by default. Its first invocation warns once. Disabling it removes only the plugin's alias. |
| `debug` | Include detailed causes, context, and stack traces in diagnostics. |

Each `setup()` starts from defaults and applies the supplied options. A copy uses the configuration active when it starts; later updates apply to subsequent copies. Repeated calls do not accumulate mappings, autocmds, or commands. Invalid options return `false, message, report`, notify at ERROR level, and leave the previous valid configuration active.

Custom retention example:

```lua
require("clean_copy").setup({
  directive_rules = {
    function(text)
      return text:find("TEAM_KEEP", 1, true) ~= nil
    end,
  },
})
```

Rules decide whether to retain an already identified comment overlapping the selection; they do not search for comments. Callbacks must not modify buffers or editor state.

The default unnamed-register write also updates register `0` and points the unnamed register to `0`, matching Neovim behavior. A named or numbered target preserves the unnamed pointer; if the unnamed register already points to that target, it naturally reflects the new contents. Extra clipboard writes preserve the local pointer. Implicit `'clipboard'` forwarding is temporarily suppressed, then restored, to avoid duplicate provider writes.

Ordinary code-comment fragments become a separating space to avoid merging tokens. Non-comment text, indentation, and original blank lines remain intact; trailing whitespace is not trimmed. Set `remove_empty_comment_lines = false` to retain code-comment-derived empty lines. HTML/Vue markup comments and comments inside pure comment JSX/TSX containers are removed without replacement spaces or their internal newlines. Whitespace outside those ranges stays intact, including comment-only lines inside `<pre>`. Pure JSX child containers are removed as a whole only when safe; attribute expressions and containers beside multiline/entity text retain their braces to preserve JSX parsing and text boundaries. This is comment removal, not formatting.

With `preserve_directives = true`, the tested marker families include:

| Family | Retained comments |
| --- | --- |
| Go | `//go:` and old `// +build` constraints |
| JS/TS/JSX/TSX | `@ts-check`, `@ts-nocheck`, `@ts-ignore`, `@ts-expect-error`, triple-slash `reference`/`amd` directives, `#__PURE__`/`@__PURE__` optimization markers |
| Python | `# type:` annotations, `noqa`, encoding declarations on the first two lines |
| HTML/Vue | Conditional comment markers such as `<!--[if ...]>` and `<![endif]-->` |
| Formatters and linters | clang-format controls, prettier-ignore, eslint/stylelint controls, fmt/isort controls, ruff: noqa, yapf controls, luacheck:, stylua: ignore, @formatter:off/on |
| SQL | MySQL `/*! */`, MariaDB `/*M! */`, optimizer `/*+ */` comments, retained as opaque text |

Disabling this option permits removal of these comments. The rules do not cover every external tool directive. C/C++ and C# preprocessor directives are retained as code, subject to parser limitations.

## Supported Languages

The suite contains real-parser fixtures for the rows below. Coverage describes exercised syntax, not complete language or dialect compatibility. Parser revisions and platform availability matter.

| Filetype | Parser | Tested scope |
| --- | --- | --- |
| `c` | `c` | Line/block comments, strings/chars, preprocessor directives |
| `cpp` | `cpp` | C-style comments, chars/raw strings, preprocessor directives |
| `javascript` | `javascript` | Comments, regex, strings, template expressions, directives |
| `typescript` | `typescript` | JavaScript cases, types and directives |
| `javascriptreact` | `javascript` | JSX comment containers, expressions, text and attributes |
| `typescriptreact` | `tsx` | TypeScript and JSX cases |
| `rust` | `rust` | Nested block/doc comments, strings/raw strings/chars |
| `go` | `go` | Comments, strings/raw strings, build and `//go:` directives |
| `python` | `python` | `#` comments, strings/docstrings, encoding and type directives |
| `lua` | `lua` | Line and long comments, strings/long strings |
| `java` | `java` | Comments/doc blocks, strings/chars/text blocks |
| `cs` | `c_sharp` | Comments/XML docs, verbatim/interpolated/raw strings, preprocessor directives |
| `css` | `css` | Block comments, strings and URLs; CSS has no `//` comments |
| `html` | `html` | HTML comments, attribute values, JS script and CSS style regions |
| `php` | `php` | Comments, heredoc/nowdoc, attributes, HTML and nested JS/CSS |
| Explicit override | `php_only` | Pure PHP; not suitable for PHP+HTML files |
| `vue` | `vue` | HTML template comments, JS/TS script/setup, CSS style/scoped |
| `sql` | `sql` | Selected PostgreSQL/MySQL-compatible syntax; see limitations below |

The plugin respects `vim.treesitter.language.register()`. Fallback mappings for unregistered `cs`, `javascriptreact`, and `typescriptreact` are shown above. It does not guess parsers from filenames. Use `language_overrides` when a filetype needs an explicit supported parser, for example `{ php = "php" }` for mixed PHP.

HTML requires `html` plus parsers for selected JS/CSS regions. Mixed PHP additionally requires `php`; Vue requires `vue` and selected `javascript`, `typescript`, or `css` parsers. Missing parsers or unsupported syntax in a selected embedded region stop the entire copy. Unrelated unavailable embedded parsers need not block a different selection.

Script handling supports JavaScript/module MIME types and `lang="js"`/`lang="ts"`; style handling supports CSS. JSON, LD-JSON, importmap, and speculationrules data blocks remain unchanged. Unknown script/style types, SCSS/Less, and non-HTML Vue templates are rejected when relevant.

## Examples

C input:

```c
// Remove this line.
int/* Keep tokens separate. */answer = 42;
const char *text = "/* Keep this string. */";
```

Copied result:

```c
int answer = 42;
const char *text = "/* Keep this string. */";
```

JSX input and copied result:

```jsx
const element = <div>{/* Remove this comment. */}{value}</div>;
```

```jsx
const element = <div>{value}</div>;
```

SQL input and copied result with default directive preservation:

```sql
-- Remove this line.
SELECT /*+ INDEX(users user_id_idx) */ id FROM users;
```

```sql
SELECT /*+ INDEX(users user_id_idx) */ id FROM users;
```

## Error Handling / Troubleshooting

Use `:checkhealth clean_copy` to inspect the Neovim version, current filetype/root parser/query, clipboard provider, configuration, and command availability. It does not write registers or modify the buffer. Enable `debug = true` for detailed diagnostics. Notifications identify the stage, reason, relevant context, and a suggested action. Full success uses INFO. Unsupported selections/languages, missing parsers, relevant syntax errors, changed buffers, and optional clipboard failures use WARN. Configuration, arguments, command conflicts, queries, target writes, and unexpected failures use ERROR. Parser installer dependency errors and exceptions use ERROR; busy state and an incomplete upstream result use WARN.

| Problem | Action |
| --- | --- |
| Invalid configuration or Lua arguments | Check option names/types and the documented API. Previous valid configuration remains active. |
| Command conflict | Rename/remove the conflicting global or buffer-local definition, then restart Neovim; the plugin does not force an overwrite. |
| Empty, block, or unsupported virtual selection | Select actual characters or whole lines; output containing only whitespace is not copied. |
| Unsupported language or bad mapping | Set the correct filetype or a supported `language_overrides` mapping. |
| Missing/incompatible root or embedded parser | Install a compatible parser separately and check `runtimepath`. |
| Parser installation dependency or argument failure | Check `parser_languages`, install the optional main-branch backend and required tools, then explicitly retry `CopyCleanParsers`. |
| Parser installer busy or failed | Wait for the tracked operation; inspect `:messages` and `:checkhealth nvim-treesitter`. If completion is unknown, restart Neovim before retrying. Some selected parsers may have completed. |
| Query load/parse failure | Verify plugin files and parser compatibility; restore matching queries/parsers. |
| Relevant syntax ERROR/MISSING | Fix the reported source position or select an unrelated valid region. |
| Buffer changed while copying | Remove side effects from callbacks and retry against a stable buffer. |
| Register or clipboard failure | Read the report's actual write/rollback state; fix the provider or choose a local target. |

Parsing, query evaluation, transformation, nonempty-output validation, and buffer-change validation all finish before writes begin. Failures in these stages preserve registers. The source buffer is never edited by the plugin.

The target is written before the optional `+` clipboard copy. A subsequent clipboard failure leaves the successful local write in place and reports partial failure. Local register failures attempt restoration; restoration failures and uncertain external clipboard state are reported explicitly. Clipboard and option restoration cannot be guaranteed when Neovim or the provider itself fails. A provider accepting a write does not guarantee that an external clipboard process later succeeds.

The returned `report` contains `code`, `stage`, `message`, `level`, and applicable `context`, `hint`, `detail`, and `traceback` fields. Write reports include `ok`, `partial`, and `targets`, mapping register names to `written`, `failed`, `unavailable`, `unknown`, or `restored`. Do not interpret `false` as proof that no write occurred.

## Known Limitations

- No blockwise copying, arbitrary string injections, HTML event/style attribute parsing, or Vue expression/directive-attribute comment removal.
- No formatting or regular-expression fallback. Relevant Tree-sitter ERROR/MISSING nodes stop copying, including zero-width missing nodes at a selection boundary.
- C/C++ opaque macro arguments containing `//` or `/*` are conservatively rejected, including URL-like macro strings.
- HTML/Vue comment removal that could join a character entity is rejected. Preserve an involved comment with `directive_rules` or select a different region. JSX containers retain braces when removal could alter text/entity boundaries.
- SQL uses the intended locked [DerekStride/tree-sitter-sql](https://github.com/DerekStride/tree-sitter-sql) grammar. Tests cover selected SELECT syntax, quoted identifiers, doubled quotes, PostgreSQL E/dollar strings, MySQL backticks, and special-comment retention; they do not execute queries against databases. MySQL `#` comments and nested SQL block comments are unsupported. Complete SQL dialect coverage, SQL Server bracket identifiers, and Oracle q-quotes are unverified.
- A narrow SQL exception permits selecting one error-free top-level statement when the parser inserts a missing batch semicolon between it and another statement. Selecting both statements or a missing separator inside a block still fails. No semicolon is inserted and no fragment is reparsed.
- Directive recognition is finite. Correct deletion with supported syntax is not a proof of equivalent behavior under every compiler or external tool.
- Older Neovim versions, other parser revisions/platforms, and desktop clipboard services need separate verification.

## Development & Testing

Run the existing suite with parsers already prepared in the project's isolated environment:

```sh
make test
```

For a focused run:

```sh
make test-unit         # No parser binaries required
make test-integration  # Requires project test parsers
```

`make test` runs both groups. Integration tests first check the project runtime and fail with an actionable list if parsers are missing; dependencies are never installed automatically and valid assertions are not skipped.

`make test` and `make test-unit` also require Python 3.12+ for standard-library installer tests. Installer tests mock downloads and compilation; `CopyCleanParsers` tests mock the backend and CLI, exercising validation, repair, asynchronous execution, busy state, and failures offline. Tests run headless Neovim with isolated XDG directories and parsers under ignored `.test/runtime/parser/`. They cover transformations, real parsers, command loading/conflicts, selections, register protection, configuration, diagnostics, documentation, and missing-parser processes. Clipboard tests use a private provider and do not touch the desktop clipboard or personal Neovim configuration.

To also check the actual upstream asynchronous Task API using an existing nvim-treesitter checkout:

```sh
env CLEAN_COPY_TS_PATH=/path/to/nvim-treesitter make test-unit
```

These additional checks load the backend's Task implementation while mocking installer and process operations. They do not download dependencies or install parsers.

To explicitly download and build the locked test parsers, use:

```sh
make test-parsers
make test
```

`test-parsers` prepares the isolated local development environment and does not use `CopyCleanParsers`, nvim-treesitter, or the Tree-sitter CLI. It requires Python 3.12+, curl, a C compiler, and network access, and writes only under `.test/`. Existing parser binaries are reused. After intentionally changing the lock file, remove the affected binaries from `.test/runtime/parser/` before rebuilding them. Fresh builds use temporary source/output paths and publish a parser only after compilation succeeds.

## License

The repository currently has no `LICENSE` file. No open-source license has been declared.
