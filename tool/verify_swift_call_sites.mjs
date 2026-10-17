// Runner 侧 Swift 的结构性检查。
//
// 本机没有 Swift 工具链，Swift 只能靠 CI 编译（一次 ~10 分钟）。
// 所以把「不编译就能发现的错」提前拦掉 —— 最典型的是：
// 给私有方法加了参数，却漏改了某个调用点，CI 报
// `Missing argument for parameter 'x'`。第 12 轮就为此白跑了一次构建。
//
// 检查两类问题：
//   1. 私有方法的调用点是否提供了全部必填形参（支持位置传参与尾随闭包）
//   2. 文件里是否混进了 U+FFFD 乱码字符
//
// 用法：node tool/verify_swift_call_sites.mjs

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const runnerDir = join(root, 'ios/Runner');

/** 去掉块注释、行注释与字符串字面量，避免注释里的内容被误判。 */
function stripNoise(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/\/\/[^\n]*/g, ' ')
    .replace(/"(?:[^"\\\n]|\\.)*"/g, '""');
}

/** 按顶层逗号切分（忽略括号 / 方括号 / 尖括号内的逗号）。 */
function splitTopLevel(s) {
  const out = [];
  let depth = 0;
  let cur = '';
  for (const ch of s) {
    if ('([{<'.includes(ch)) depth++;
    else if (')]}>'.includes(ch)) depth--;
    if (ch === ',' && depth === 0) {
      out.push(cur);
      cur = '';
    } else {
      cur += ch;
    }
  }
  if (cur.trim()) out.push(cur);
  return out;
}

/** 从 `(` 开始做括号配平，返回其闭合位置。 */
function matchParen(src, open) {
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '(') depth++;
    else if (src[i] === ')') {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/** 抽出一个形参的「名字」与「是否带默认值」。 */
function parseParam(seg) {
  const colon = seg.indexOf(':');
  if (colon < 0) return null;
  const name = seg.slice(0, colon).trim().split(/\s+/).pop();
  const rest = seg.slice(colon + 1);
  return { name, optional: /=/.test(rest) };
}

const failures = [];
const stats = { files: 0, privates: 0, calls: 0 };

const files = readdirSync(runnerDir).filter((f) => f.endsWith('.swift')).sort();
console.log('Runner Swift 调用点检查');
console.log(`  目录: ios/Runner（${files.length} 个 .swift）`);
console.log('');

for (const file of files) {
  const raw = readFileSync(join(runnerDir, file), 'utf8');
  if (raw.includes('\ufffd')) {
    failures.push(`${file} 含 U+FFFD 乱码字符 —— 提交前应修掉`);
  }
  const src = stripNoise(raw);
  stats.files++;

  // 1) 收集 private func 的声明（含形参与默认值信息）
  const declRe = /private\s+(?:static\s+)?func\s+([A-Za-z_]\w*)\s*\(/g;
  const privates = new Map();
  let dm;
  while ((dm = declRe.exec(src)) !== null) {
    const name = dm[1];
    const open = src.indexOf('(', dm.index + dm[0].length - 1);
    const close = matchParen(src, open);
    if (close < 0) continue;
    const params = splitTopLevel(src.slice(open + 1, close))
      .map((s) => s.trim())
      .map(parseParam)
      .filter(Boolean);
    if (!privates.has(name)) privates.set(name, params);
    declRe.lastIndex = close;
  }
  stats.privates += privates.size;

  // 2) 逐个检查调用点
  for (const [name, params] of privates) {
    const required = params.filter((p) => !p.optional).map((p) => p.name);
    if (required.length === 0) continue;

    const callRe = new RegExp(`(?<![\\w.])${name}\\s*\\(`, 'g');
    let cm;
    while ((cm = callRe.exec(src)) !== null) {
      const at = cm.index;
      // 跳过声明本身
      if (/private\s+(?:static\s+)?func\s+$/.test(src.slice(Math.max(0, at - 40), at))) {
        continue;
      }
      const open = src.indexOf('(', at);
      const close = matchParen(src, open);
      if (close < 0) continue;
      stats.calls++;

      const args = splitTopLevel(src.slice(open + 1, close))
        .map((s) => s.trim())
        .filter(Boolean);

      // 命名实参：`name: value`
      const named = new Set(
        args.filter((a) => /^[A-Za-z_]\w*\s*:/.test(a))
          .map((a) => a.split(':')[0].trim()),
      );
      // 位置实参：按顺序补齐尚未提供的形参（尾随闭包算最后一个）
      const positional = args.filter((a) => !/^[A-Za-z_]\w*\s*:/.test(a)).length;
      // 尾随闭包：右括号之后紧跟 `{`
      let k = close + 1;
      while (k < src.length && /\s/.test(src[k])) k++;
      const trailingClosure = src[k] === '{';

      const missing = [];
      let remainingPositional = positional;
      for (const p of required) {
        if (named.has(p)) continue;
        if (remainingPositional > 0) { remainingPositional--; continue; }
        missing.push(p);
      }
      // 尾随闭包顶掉最后一个未提供的形参（Swift 的标准写法）
      if (trailingClosure && missing.length === 1) missing.length = 0;

      if (missing.length > 0) {
        const line = src.slice(0, at).split('\n').length;
        failures.push(
          `${file}:${line} 调用 ${name}( 缺少参数 ${missing.join(', ')}`
          + `（声明要求 ${required.join(', ')}）`,
        );
      }
      callRe.lastIndex = close + 1;
    }
  }
}

if (failures.length) {
  console.error(`✗ ${failures.length} 项不通过：\n`);
  for (const f of [...new Set(failures)]) console.error(`  ${f}`);
  console.error('');
  process.exit(1);
}

console.log(
  `✓ 全部通过：${stats.files} 个文件、${stats.privates} 个私有方法、`
  + `${stats.calls} 个调用点的参数都与声明一致，无乱码字符。`,
);
