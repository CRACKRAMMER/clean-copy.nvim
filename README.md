# clean-copy.nvim

用独立命令或 Visual 快捷键复制去掉注释的代码。**源 buffer 不变，普通 `y`、删除和剪切行为不变。**
插件不设置全局快捷键，不注册 `TextYankPost`，不使用 LSP、格式化器或通用正则注释解析。

## 要求

- Neovim **0.12+**；本次验证环境为 Linux、Neovim **0.12.5**、LuaJIT。
- 预先安装需要的 Tree-sitter parser，并使其位于 `runtimepath` 的 `parser/` 下。
- 复制时仅依赖 Neovim 内置 Lua/Tree-sitter API，不需要 Node.js、Python 或 nvim-treesitter 内部 API。
- 正常使用不会联网或安装 parser。nvim-treesitter 可作为可选的 parser 安装工具。

最低版本按本机 `:help treesitter`、`getregionpos()`、语言映射和 parser API 文档确定；未验证旧版本兼容性。
各 parser 的可复现版本在 [tests/parsers.lock.json](tests/parsers.lock.json)，升级后应重新运行测试。

## 安装与入口

本地开发，lazy.nvim 插件 spec：

```lua
{
  dir = vim.fn.expand("~/Projects/clean-copy.nvim"),
  name = "clean-copy.nvim",
  cmd = "CleanCopy",
  keys = {
    {
      "<leader>cy",
      function() require("clean_copy").copy() end,
      mode = "x",
      desc = "复制去掉注释的代码",
    },
  },
  opts = {},
}
```

lazy.nvim 的 GitHub 安装格式（私有仓库需要 GitHub Git 凭据）：

```lua
{
  "CRACKRAMMER/clean-copy.nvim",
  cmd = "CleanCopy",
  keys = {
    { "<leader>cy", function() require("clean_copy").copy() end,
      mode = "x", desc = "Clean copy" },
  },
  opts = {},
}
```

手动加载：

```lua
vim.opt.runtimepath:prepend(vim.fn.expand("~/Projects/clean-copy.nvim"))
require("clean_copy").setup({})
vim.keymap.set("x", "<leader>cy", function()
  require("clean_copy").copy()
end, { desc = "复制去掉注释的代码" })
```

插件名中的连字符变为 Lua 模块名中的下划线：`require("clean_copy")`。
`setup()` 可重复调用，每次从默认值合并该次传入配置；不会叠加命令、映射或 autocmd。
按常规插件方式加载时，不调用 `setup()` 也有默认配置和 `:CleanCopy`。

| 入口 | 处理范围 / 寄存器类型 |
| --- | --- |
| Visual 字符模式调用 `copy()` | 精确字节范围，字符类型 `v` |
| Visual 整行模式调用 `copy()` | 选中整行，整行类型 `V` |
| 普通模式调用 `copy()` | 当前整个 buffer，整行类型 `V` |
| `:CleanCopy`，无显式范围 | 当前整个 buffer |
| `:10,20CleanCopy`、`:%CleanCopy` | 显式指定的整行范围 |
| Visual 后输入 `:CleanCopy` | Vim 自动添加 `'<,'>`，因此是整行范围 |

要精确复制 Visual 字符选区，请使用上面的 Lua 快捷键，不要用自动添加行范围的冒号映射。
`copy()` 返回 `success, message`；它同时通过 `vim.notify()` 显示简短结果。
块选择不支持，提示后停止。成功后退出 Visual，保留光标和最后选区；`gv` 可重新选择。
Visual `$` 可落在行尾后一个虚拟位置，退出后按 Neovim 普通模式规则夹到该行最后一个字符。
不改变 `selection`、`virtualedit`；支持正向/反向选择、`inclusive`/`exclusive`/`old`、UTF-8 和 Tab。
无法对应真实字节的虚拟单元选择会明确拒绝。

## 默认配置

```lua
require("clean_copy").setup({
  register = '"',                    -- 单个目标寄存器
  clipboard = true,                  -- provider 可用时额外写入 +
  remove_empty_comment_lines = true,  -- 删除整行只有可移除注释和空白的行
  preserve_doc_comments = false,
  preserve_license_comments = false,
  preserve_directives = true,
  directive_rules = {},              -- { function(text, language, node) -> boolean }
  language_overrides = {},           -- { [filetype] = "parser_language" }
  debug = false,                     -- 开发时显示堆栈
})
```

未知选项和错误类型会在 `setup()` 报错。`register` 接受 `"`、`a-z`、`0-9`、`+`、`*`；
不接受大写追加寄存器或表达式等特殊寄存器。显式指定命名或数字寄存器时只改该目标。
`clipboard = false` 禁用额外的系统剪贴板写入；若目标本身是 `+`/`*`，仍会写该目标，缺少 provider 时失败。

**已确认的 Neovim 原生例外：**默认写未命名寄存器会同时更新 `0`，并把未命名寄存器指向 `0`。
这两个位置不具备彼此独立的存储；其他命名、数字和小删除寄存器保持不变。
需要保留原未命名/`0` 状态时可以设置 `register = "a"`，但如果未命名原本指向 `a`，它自然也会看到 `a` 的新值。
额外写 `+` 不改未命名寄存器的本地指向。插件临时屏蔽隐式的 `'clipboard'` 转发，并恢复选项，避免双重写入。

复制前完成全部解析、转换、非空校验和 changedtick 校验。parser 缺失、query 失败、语法错误、
不支持的选区或空白输出都不会覆盖寄存器。provider 不可用时本地目标仍成功，并提示系统剪贴板未写入。
provider 抛错时报告本地已写入、系统写入失败。成功消息表示 Neovim 的 provider 接受了写入；
外部剪贴板进程异步失败仍由 Neovim/provider 报告，插件不能保证外部服务持久保存数据。

## 输出与保留规则

- 不修改源文件、buffer 内容、changedtick、修改状态或撤销历史。
- 保留非注释字符、缩进、字符串内容、代码大小写和原始行顺序，不自动格式化，不全局 trim。
- 普通注释片段保守地替换为一个空格，保留跨行注释中的换行，避免 `int/*...*/value` 拼成 `intvalue`。
- 默认删除**完整原始行**上只有可移除注释和空白、处理后变空的行。原本无注释的空行/空白行保留。
  部分选区不删除未完整选中的行；包含真实代码或保留指令的行也不删除。
- `remove_empty_comment_lines = false` 保留注释行产生的空白及换行。行尾空格不会被盲目裁剪。
- Python docstring 和其他三引号字符串始终按字符串保留，第一版无删除 docstring 功能。
- Shebang 始终保留，不受 `preserve_directives` 影响。
- C/C++、C# 的预处理指令按代码保留；遇到 parser 无法可靠解释的宏参数则停止。
- JSX/TSX 中 `{/* comment */}` 的容器只有在所有命名子节点均为可移除注释时整体移除，
  不引入 JSX 文本空格；包含真实表达式或保留指令的容器保持大括号。

默认移除普通注释与文档注释。`preserve_doc_comments = true` 覆盖 Java/C 系文档块、
C/C++ Doxygen `///`/`//!`、C# XML `///`、Rust `///`/`//!`/`/**`/`/*!` 和 Lua `---`。
`preserve_license_comments = true` 保留包含 SPDX-License-Identifier、copyright、`@license`、
`@preserve` 的注释以及 `/*!` 注释；这是有限的标记识别，不是许可证内容鉴定。

`preserve_directives = true` 已验证的规则如下，只匹配已确认的注释节点内容：

| 类别 | 保留的标记 |
| --- | --- |
| Go | `//go:` 全部指令（含 build/noinline）、旧式 `// +build` |
| JS/TS/JSX/TSX | `@ts-check`、`@ts-nocheck`、`@ts-ignore`、`@ts-expect-error`、三斜线 `<reference ...>` / `<amd-...>` |
| Python | `# type: ignore`、`# noqa`、前两行的 `coding:` / `coding=` 编码声明 |
| 格式化/检查 | `clang-format off/on/disable/enable`、`prettier-ignore`、`eslint-disable/enable`、`stylelint-disable/enable` |
| Python 工具 | `fmt: off/on/skip`、`isort: off/on/skip`、`ruff: noqa`、`yapf: disable/enable` |
| Lua/Java 工具 | `luacheck:`、`stylua: ignore`、`@formatter:off/on` |
| SQL | `/*! ... */`、`/*M! ... */`、`/*+ ... */`（内部 SQL 不继续解析） |

关闭 `preserve_directives` 会允许删除以上工具/SQL 注释。不承诺识别所有工具指令。
用户扩展，例如保留团队标记：

```lua
require("clean_copy").setup({
  directive_rules = {
    function(text, language, node)
      return text:find("TEAM_KEEP", 1, true) ~= nil
    end,
  },
})
```

回调必须返回布尔值，并保持无副作用；仅在 `preserve_directives = true` 时调用。
回调错误会停止复制。扩展规则只决定已识别注释是否保留，不用于查找或删除注释。

## 语言、filetype 与 parser 支持矩阵

下表各行均通过真实 parser 测试；“通过”指列出的用例与范围，并非对语言全部语法的完整证明。
每种文件类型均测试了整行/行尾注释、该语言支持的多行注释、字符串中的符号、Unicode 和部分选区。
语言名称同时是 `parser/<language>.so` 的名称，Windows 对应平台动态库后缀。

| 语言 | Neovim filetype | Tree-sitter language / parser | 验证范围与限制 |
| --- | --- | --- | --- |
| SQL | `sql` | `sql` | DerekStride grammar；`--`、`/* */`、引号/美元字符串、quoted identifiers；方言范围见下文 |
| C | `c` | `c` | `//`、`/* */`、字符串/字符、预处理指令；不透明宏参数限制见下文 |
| C++ | `cpp` | `cpp` | C 类注释、字符、raw string、预处理；同样限制宏参数 |
| TypeScript | `typescript` | `typescript` | 普通/文档注释、URL、regex、模板字符串及其中表达式、类型指令 |
| JavaScript | `javascript` | `javascript` | 同上，含 regex 与模板表达式内注释 |
| Rust | `rust` | `rust` | 行/块/文档注释、嵌套块注释、字符串/raw string/字符 |
| Go | `go` | `go` | 行/块注释、字符串/raw string、build constraint 与 `//go:` |
| Python | `python` | `python` | `#`、字符串/三引号/docstring、编码/type-ignore；没有多行注释语法 |
| PHP | `php` | `php` | `//`、`#`、`/* */`、heredoc/nowdoc/attribute、HTML 与其中 JS/CSS |
| PHP 纯代码（可覆盖） | 用户自行映射 | `php_only` | 不含 HTML 的 PHP 代码，用真实 parser 单独验证 |
| C# | `cs` | `c_sharp` | 行/块/XML 注释、普通/verbatim/插值/raw string、预处理指令 |
| HTML | `html` | `html` | `<!-- -->`、属性值保护、script JS、style CSS |
| CSS | `css` | `css` | `/* */`、字符串、URL；CSS 无 `//` 注释语法 |
| Java | `java` | `java` | 行/块/文档、字符串/字符、text block |
| Vue | `vue` | `vue` | SFC template HTML 注释；script/setup/ts/setup-ts；style/scoped CSS |
| React JSX | `javascriptreact` | `javascript` | JS 注释、纯注释容器/真实表达式、JSX 文本与属性 |
| React TSX | `typescriptreact` | `tsx` | TS 注释及上述 JSX 容器/文本/属性规则 |
| Lua | `lua` | `lua` | 单行、不同等号层级的长注释、普通/长字符串 |

先查询 `vim.treesitter.language.get_lang(filetype)`，尊重用户通过 `language.register()` 设置的映射。
只有核心返回 filetype 本身时，才为 `cs`、`javascriptreact`、`typescriptreact` 提供上述已验证的缺省映射。
`language_overrides = { cs = "c_sharp", javascriptreact = "javascript" }` 的显式配置优先。
不根据扩展名猜 parser。若用户把 `php` 映射为 `php_only`，则不会获得 PHP+HTML 混合支持；
混合文件可用 `language_overrides = { php = "php" }` 明确选择正确 parser。

### 混合文件

HTML 需 `html`，script 需 `javascript`，style 需 `css`。PHP 混合文件需 `php` + `html`，
HTML 中有脚本或样式再需要 `javascript`/`css`。Vue 需 `vue`，JS script 需 `javascript`，
TS script 需 `typescript`，CSS style 需 `css`；Vue parser 自身识别 template 的 HTML 注释。

使用插件私有的 AST 区域 query 和 injection query 遍历完整 language tree。
PHP 的 HTML 区域采用 combined injection，支持再嵌入 JS/CSS。
按 start-tag 的真实属性决定语言；`setup`/`scoped` 不改变语法。支持 `<script>`、`type="module"`、
常见 JS MIME type，以及 `lang="js"`/`lang="ts"`；style 支持缺省 CSS / `lang="css"` / `type="text/css"`。
`application/json`、`application/ld+json`、importmap、speculationrules 是数据块，保持原样。

涉及所选嵌入代码且缺少对应 parser 时，停止全部复制并点明 parser，保留旧寄存器。
无关区域缺少 parser 不会阻止复制已支持的选择。涉及未知 script/style 类型、SCSS、Less、
其他 Vue template 语言会明确拒绝；不宣称部分处理已完整成功。
第一版不处理 Vue 模板插值/指令属性中的代码注释、HTML 事件/style 属性、用户定义的 tagged-template 注入。
普通字符串不会被二次解析。

### SQL 方言范围

使用 [DerekStride/tree-sitter-sql](https://github.com/DerekStride/tree-sitter-sql) 的 general/permissive grammar，
并非名为 sql 的任何 parser 都保证兼容。锁定 gh-pages revision 为
`86e3d03837d282544439620eb74d224586074b8b`，真实节点 `comment` 是 `--`，`marginalia` 是 `/* */`。

实际验证的是 PostgreSQL 兼容 SELECT 片段：单引号与重复引号转义、双引号标识符、
`E'...'`、`$$...$$` 和 `$tag$...$tag$`；以及 MySQL 兼容片段的反引号标识符、
MySQL `/*!...*/`、MariaDB `/*M!...*/` 和 optimizer hint `/*+...*/` 的**原样保留**。
执行性注释内部仅作不透明文本保留，不代表 parser 能解析其中全部方言语法。
这些是 parser 测试，没有连接数据库执行。

不承诺完整 PostgreSQL/MySQL/MariaDB/SQLite/SQL Server/Oracle 支持。
MySQL `#` 注释不支持，测试中会出现 ERROR 并拒绝；嵌套 SQL 块注释不属于该 grammar 的承诺范围；在已识别块中发现嵌套标记时保守拒绝。
SQL Server 方括号标识符、Oracle q-quote 等特殊语法未验证，不能标为完整支持。

### 已知 parser 边界

C/C++ parser 会把部分宏定义的值识别为不透明 `preproc_arg`，可能将 `//` 吞在该节点里，
也可能把宏字符串中的 `/*` 识别为异常注释。若所选宏参数含 `//` 或 `/*`，插件保守拒绝，
包括宏字符串中的 URL。这只检测不可可靠处理的区域，不用这些符号执行注释删除。
不含这些标记的普通预处理指令保留；有 ERROR 的宏同样按错误策略停止。
PHP/HTML 跨区域组合和新语法也可能触发 parser 局限，不能以“代码看起来合法”绕过校验。

## 保守错误策略与实现

读取整个原始 buffer 的不可变快照，用 `vim.treesitter.get_string_parser()` 解析**完整快照**，
包括不在选区中的上下文；不会只解析选中的字符串，也不会改动高亮使用的 buffer parser。
使用插件自己的 `queries/<language>/clean_copy.scm`，不是用户 highlights 的 `@comment`。
私有 injections 屏蔽普通字符串和任意用户高亮注入，嵌入依赖经 AST 预检查后才处理。
合并重叠注释区间，再按 Tree-sitter 字节坐标与选区求交集。

若 ERROR/MISSING 范围与选区相交，或与相交的待移除注释范围相交，默认停止。
零长度 MISSING 落在选区边界时也保守停止。其他位置的语法错误不会无条件阻止复制。
没有正则降级删除；输出为空或只有空白也不写入寄存器。
目标是可靠移除已支持的注释，不证明所有语言或外部工具环境下程序行为完全等价。

## 前后对比

原始 Python：

```python
# 说明，整行删除

def answer():
    """可被读取的 docstring，保留。"""
    value = 42  # 普通注释
    return value  # type: ignore
```

复制结果（行尾空格保留；最前面的原始空行仍在）：

```python

def answer():
    """可被读取的 docstring，保留。"""
    value = 42
    return value  # type: ignore
```

JSX `const el = <div>{/* 说明 */}{value /* 说明 */}</div>;`
复制为 `const el = <div>{value  }</div>;`，包含真实表达式的容器保留。

## 自动化测试

独立 XDG 目录和 headless Neovim，不操作正在运行的用户会话。第一次显式预装测试 parser：

```sh
# 开发安装工具需要 Python 3.12+、curl、C 编译器和网络；复制插件不需要这些运行时。
make test-parsers
make test
```

`test-parsers` 从锁定公开仓库下载生成好的 C 源码，不需要 tree-sitter CLI/Node.js。
只写入忽略的 `.test/`，不安装到个人 Neovim。
如自行预装，把上述 17 个 parser（含 `php_only`）放到 `.test/runtime/parser/` 后直接 `make test`。
已安装的二进制会复用；要重建时删除 `.test/runtime/parser/`。

验证结果（2026-10-01）：**79 项主测试 + 5 项独立进程真实缺失 parser 测试全部通过**。
主测试包括纯区间/文本逻辑、17 种文件类型的真实 parser、选区/命令/寄存器集成。
覆盖 UTF-8/Tab/反向选区/selection、跨界注释、token 分离、空行规则、配置、指令、语法错误、
query 失败、重复 setup、普通 y/delete、buffer 状态与 undo、可控的剪贴板 provider 成功/失败。
系统桌面剪贴板服务未实机端到端验证；自动化使用独立模拟 provider，避免覆盖个人系统剪贴板。
未完成/未承诺范围：旧 Neovim、其他 parser 版本与操作系统、块选择、Vue 非 HTML 模板、
SCSS/Less、所有 SQL 方言、所有工具指令及上述 parser 局限。

帮助文档：`:help clean-copy`（插件管理器生成 helptags 后可用）。

## 此机器的 dotfiles 集成

仓库保持独立，dotfiles 只负责加载和个人键位。本机已接入现有 lazy.nvim 配置和 Visual 快捷键。
本机已把 GitHub 插件 spec 加到
`~/.dotfiles/nvim/.config/nvim/lua/plugins/plugins-setup.lua` 的 `local plugins` 表，键位在 `lua/core/keymaps.lua` 中设置为 `<leader>cy`。
现有 `~/.config/nvim` 是该路径的符号链接。

已在 `lua/plugins/treesitter.lua` 的 parser 列表补齐 `sql`、`go`、`php`、`php_only`、
`c_sharp`、`java`、`vue`；现有 c/cpp/css/html/javascript/lua/python/rust/tsx/typescript 已列入安装清单，
但本次检查时个人 parser 目录为空。随后**显式**执行 `:DotfilesTSInstall`。
额外的 FileType 高亮清单可补 `sql`、`go`、`php`、`cs`、`java`、`vue`、`javascriptreact`；
这是可选高亮配置，clean-copy 本身不依赖该 autocmd。

远程仓库：[CRACKRAMMER/clean-copy.nvim](https://github.com/CRACKRAMMER/clean-copy.nvim)。
本项目采用独立 Git 仓库，默认分支为 `main`；没有创建发行版。
