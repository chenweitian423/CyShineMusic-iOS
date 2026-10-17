// Runner 侧 Swift 的结构性检查。
//
// 本机没有 Swift 工具链，Swift 只能靠 CI 编译（一次 ~10 分钟）。
// 所以把「不编译就能发现的错」提前拦掉 —— 最典型的是：
// 给私有方法加了参数，却漏改了某个调用点，CI 报
// `Missing argument for parameter 'x'`。第 12 轮就为此白跑了一次构建。
//
// 检查三类问题：
//   1. 私有方法的调用点是否提供了全部必填形参（支持位置传参与尾随闭包）
//   2. 文件里是否混进了 U+FFFD 乱码字符
//   3. 常见易错的静态构造器用法（`DispatchTimeInterval.milliseconds` 是
//      `static func`，不是可当属性读的 `.milliseconds` 实例成员）
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

/** 已知类型 / 前缀 -> 所属模块。用到了却没 import，编译必然报
 *  "Cannot find 'X' in scope"。本机没有 Swift 工具链，只能这样提前拦。 */
const TYPE_MODULES = [
  { module: 'MediaPlayer', names: [
    'MPNowPlayingInfoCenter', 'MPMediaItemArtwork', 'MPNowPlayingInfoMediaType',
    'MPMediaItemPropertyTitle', 'MPMediaItemPropertyArtist', 'MPMediaItemPropertyAlbumTitle',
    'MPMediaItemPropertyArtwork', 'MPMediaItemPropertyPlaybackDuration',
    'MPNowPlayingInfoPropertyElapsedPlaybackTime', 'MPNowPlayingInfoPropertyPlaybackRate',
    'MPNowPlayingInfoPropertyDefaultPlaybackRate', 'MPNowPlayingInfoPropertyMediaType',
    'MPNowPlayingInfoPropertyIsLiveStream',
  ] },
  { module: 'ActivityKit', names: [
    'ActivityAuthorizationInfo', 'ActivityContent', 'ActivityAttributes', 'Activity',
  ] },
  { module: 'WidgetKit', names: ['WidgetCenter', 'WidgetBundle', 'TimelineProvider'] },
  { module: 'AVFoundation', names: ['AVAudioSession', 'AVAsset', 'AVPlayer'] },
  { module: 'UserNotifications', names: ['UNUserNotificationCenter', 'UNAuthorizationStatus'] },
];

/** 检查「用了某类型却没 import 对应模块」。 */
function checkImports(src, file) {
  const imports = new Set(
    [...src.matchAll(/^\s*import\s+([A-Za-z_]\w*)/gm)].map((m) => m[1]),
  );
  for (const { module, names } of TYPE_MODULES) {
    if (imports.has(module)) continue;
    const hit = names.find((n) => new RegExp(`(?<![\\w.])${n}\\b`).test(src));
    if (hit) {
      failures.push(
        `${file} 用了 ${hit} 但没有 import ${module}`
        + `（会报 Cannot find '${hit}' in scope）`,
      );
    }
  }
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

  // 0) 用了类型但没 import 对应模块
  checkImports(src, file);

  // 1b) 易错的静态构造器：`.milliseconds` / `.seconds` 只能被**调用**，
  //     不能当属性读（`delay.milliseconds` 会报
  //     "Enum case 'milliseconds' cannot be used as an instance member"）。
  //     这些都是 `static func`，正确写法是 `Type.milliseconds(x)`。
  for (const enumType of ['DispatchTimeInterval']) {
    const badRe = new RegExp(
      `(?<![\\w.])([A-Za-z_][\\w.]*)\\s*\\.\\s*(milliseconds|seconds|never)\\b(?!\\s*\\()`,
      'g',
    );
    let em;
    while ((em = badRe.exec(src)) !== null) {
      const receiver = em[1];
      const member = em[2];
      const line = src.slice(0, em.index).split('\n').length;
      // 接收者就是枚举类型本身时，那是合法的类型上下文调用。
      if (receiver === enumType) continue;
      // 形如 `let delay = DispatchTimeInterval.milliseconds(...)` 后再读
      // `delay.milliseconds` 才是不合法的 —— 这里已经排除了类型名。
      failures.push(
        `${file}:${line} ${receiver}.${member} 像是在把静态构造器当属性读`
        + ` —— ${enumType}.${member} 是 static func，正确写法是 ${enumType}.${member}(...)`,
      );
    }
  }

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
