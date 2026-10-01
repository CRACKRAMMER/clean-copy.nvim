-- Each fixture runs against a real pinned parser, including partial selections.
return {
  { ft = 'sql', lang = 'sql', text = [[-- 中文 remove
SELECT '-- /* 中文 */', "--标识符", $$/* raw */$$, $tag$--raw$tag$, E'\\x' /* remove
中文 remove */;
SELECT /*+ INDEX(t idx) */ 1; /*!40101 SET @x=1 */ /*M! executable */]], keep = { "'-- /* 中文 */'", '"--标识符"', '$$/* raw */$$', '$tag$--raw$tag$', '/*+ INDEX', '/*!40101', '/*M!' } },
  { ft = 'c', lang = 'c', text = [[// 中文 remove
#define FLAG 1
int main(void) { char c='/'; char *s="/* 中文 */"; /* remove
中文 remove */ return FLAG; // remove
}]], keep = { '#define FLAG 1', "'/'", '"/* 中文 */"' } },
  { ft = 'cpp', lang = 'cpp', text = [[// 中文 remove
#include <string>
auto s=R"tag(/* 中文 */ // raw)tag";
char c='/'; /* remove
中文 remove */ int value=1; // remove]], keep = { '#include <string>', 'R"tag(/* 中文 */ // raw)tag"', "'/'" } },
  { ft = 'javascript', lang = 'javascript', text = [[// 中文 remove
// @ts-check
const url="https://中文.test/* */";
const regex=/\/\*foo\*\//;
const t=`/* 中文 */ ${1 /* remove */}`; /* remove
中文 remove */ const value=1; // remove]], keep = { '// @ts-check', '"https://中文.test/* */"', [=[/\/\*foo\*\//]=], '`/* 中文 */ ${1' } },
  { ft = 'typescript', lang = 'typescript', text = [[// 中文 remove
// @ts-expect-error reason
/// <reference path="./types.d.ts" />
const url: string="https://中文.test";
const regex=/\/\*foo\*\//;
const t=`/* 中文 */ ${1 /* remove */}`; /* remove
中文 remove */ const value: number=1; // remove]], keep = { '@ts-expect-error', '/// <reference', '"https://中文.test"', [=[/\/\*foo\*\//]=], '`/* 中文 */ ${1' } },
  { ft = 'rust', lang = 'rust', text = [[// 中文 remove
fn main() { let s="/* 中文 */"; let raw=r###"// raw /* */"###; let c='/';
/* remove /* nested remove */
中文 remove */ let value=1; // remove
}]], keep = { '"/* 中文 */"', 'r###"// raw /* */"###', "'/'" } },
  { ft = 'go', lang = 'go', text = [[//go:build linux
// +build linux

// 中文 remove
package main
//go:noinline
func main() { s := "/* 中文 */"; raw := `// /* raw */`; /* remove
中文 remove */ _, _ = s, raw // remove
}]], keep = { '//go:build linux', '// +build linux', '//go:noinline', '"/* 中文 */"', '`// /* raw */`' } },
  { ft = 'python', lang = 'python', text = [=[#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 中文 remove
"""docstring # /* 中文 */"""
value = "# 中文" # remove
raw = '''# /* string */'''
other = 1 # type: ignore[attr-defined]
third = 2 # noqa: E123
]=], keep = { '#!/usr/bin/env python3', '# -*- coding: utf-8 -*-', '"""docstring # /* 中文 */"""', "'''# /* string */'''", '# type: ignore', '# noqa' } },
  { ft = 'php', lang = 'php', text = [[<p title="<!-- 中文 -->">hello</p><!-- remove -->
<?php
// 中文 remove
#[Attribute]
class Example {}
$s="/* 中文 */";
$a=<<<TXT
// string
TXT;
$b=<<<'TXT'
/* string */
TXT;
/* remove
中文 remove */ $v=1; # remove
?>
<script>const s="// 中文"; // remove
</script><style>p { color: red; /* remove */ }</style>]], keep = { 'title="<!-- 中文 -->"', '#[Attribute]', '"/* 中文 */"', '// string', '/* string */', '"// 中文"' } },
  { ft = 'cs', lang = 'c_sharp', text = [[// 中文 remove
#define FLAG
class C {
string a="/* 中文 */";
string b=@"// 中文";
string c=$"/* text */ {1 /* remove */}";
string d="""// raw /* 中文 */""";
/* remove
中文 remove */ int value=1; // remove
}]], keep = { '#define FLAG', '"/* 中文 */"', '@"// 中文"', '$"/* text */', '"""// raw /* 中文 */"""' } },
  { ft = 'html', lang = 'html', text = [[<!-- 中文 remove -->
<div title="<!-- 中文 -->">文字</div><!-- remove -->
<!-- remove
中文 remove -->
<script>const url="https://中文.test"; /* remove */ const t=`// string ${1 /* remove */}`; // remove
</script><style>p { content: "/* 中文 */"; background: url("https://test"); /* remove */ }</style>]], keep = { 'title="<!-- 中文 -->"', '"https://中文.test"', '`// string ${1', '"/* 中文 */"', 'url("https://test")' } },
  { ft = 'css', lang = 'css', text = [[/* 中文 remove */
p { content: "/* 中文 */"; background: url("https://test"); /* remove
中文 remove */ color: red; } /* remove */]], keep = { '"/* 中文 */"', 'url("https://test")' } },
  { ft = 'java', lang = 'java', text = [[// 中文 remove
class C {
String s="/* 中文 */";
char c='/';
String t="""
// /* 中文 string */
""";
/* remove
中文 remove */ int value=1; // remove
}]], keep = { '"/* 中文 */"', "'/'", '// /* 中文 string */' } },
  { ft = 'vue', lang = 'vue', text = [[<!-- 中文 remove -->
<template><div title="<!-- 中文 -->">文字<!-- remove --></div></template>
<script>const s="// 中文"; /* remove */ // remove
</script>
<script setup lang="ts">const value: number=1; /* remove
中文 remove */ const t=`/* string */ ${1 /* remove */}`; // remove
</script>
<style scoped>p { content: "/* 中文 */"; /* remove */ }</style>]], keep = { 'title="<!-- 中文 -->"', '"// 中文"', 'const value: number=1', '`/* string */ ${1', '"/* 中文 */"' } },
  { ft = 'javascriptreact', lang = 'javascript', text = [[// 中文 remove
const el=<div title="/* 中文 */">// text{/* remove */}{1 /* remove */}{/* remove */ 2}</div>; /* remove
中文 remove */ const v=1; // remove]], keep = { 'title="/* 中文 */"', '// text', '{1', '2}' }, absent = { '{ }' } },
  { ft = 'typescriptreact', lang = 'tsx', text = [[// 中文 remove
const v: number=1;
const el=<div title="/* 中文 */">// text{/* remove */}{v /* remove */}{/* remove */ 2}</div>; /* remove
中文 remove */ const w=1; // remove]], keep = { 'title="/* 中文 */"', '// text', '{v', '2}' }, absent = { '{ }' } },
  { ft = 'lua', lang = 'lua', text = [====[#!/usr/bin/env lua
-- 中文 remove
local s="-- /* 中文 */"
local raw=[=[-- /* string */]=]
--[=[ remove
中文 remove ]=]
--[==[ remove ]==]
local value=1 -- remove]====], keep = { '#!/usr/bin/env lua', '"-- /* 中文 */"', '[=[-- /* string */]=]' } },
}
