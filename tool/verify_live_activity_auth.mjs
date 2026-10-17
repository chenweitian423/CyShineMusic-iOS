// 实时活动「授权死锁」回归检查。
//
// 背景（第 10 轮定位到的真 bug）：
//   iOS 17 起「实时活动」开关挂在通知授权上。通知处于 notDetermined 时，
//   `ActivityAuthorizationInfo().areActivitiesEnabled` 返回 **false**。
//   而 Dart 侧 live_activity_service.dart 的逻辑是：
//       isSupported == false  ->  不挂监听、也不调用 start
//   如果 `ensureNotificationAuthorization()` 只写在 `case "start"` 里，
//   就形成死锁：不给权限 -> 报不支持 -> 不调 start -> 永远不给权限。
//   上一版（ios-v2.0.1）就是这么写的，所以灵动岛一直不出现。
//
// 本脚本把这条约束变成硬校验，防止以后重构时又踩回去。
// 用法：node tool/verify_live_activity_auth.mjs

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const bridgePath = join(root, 'ios/Runner/CyShineLiveActivityBridge.swift');
const servicePath = join(root, 'lib/features/player/live_activity_service.dart');
const plistPath = join(root, 'ios/Runner/Info.plist');

const bridge = readFileSync(bridgePath, 'utf8');
const service = readFileSync(servicePath, 'utf8');
const plist = readFileSync(plistPath, 'utf8');

/** 取 `case "xxx":` 到下一个 `case "` 之间的片段。 */
function caseBody(source, name) {
  const start = source.indexOf(`case "${name}":`);
  if (start < 0) return null;
  const rest = source.slice(start + `case "${name}":`.length);
  const next = rest.search(/\n\s*case\s+"/);
  return next < 0 ? rest : rest.slice(0, next);
}

const failures = [];
const notes = [];

// ① ★ 核心：`ensureNotificationAuthorization()` 必须在 isSupported 分支里被调用。
//    只在 start 里调用 = 死锁（见文件头注释）。
const isSupported = caseBody(bridge, 'isSupported');
if (isSupported === null) {
  failures.push('ios/Runner/CyShineLiveActivityBridge.swift 里找不到 case "isSupported"');
} else if (!/ensureNotificationAuthorization\s*\(\s*\)/.test(isSupported)) {
  failures.push([
    'case "isSupported" 里没有调用 ensureNotificationAuthorization() —— 这会让灵动岛进入死锁：',
    'iOS 17 起通知未授权时 areActivitiesEnabled 返回 false，Dart 因此不会调用 start，',
    '而问权限的代码只在 start 里，于是永远问不到权限、灵动岛永远不出现。',
    '修法：在 isSupported 分支开头也调一次（该方法是幂等的）。',
  ].join('\n  '));
}

// ② isSupported 不能在「授权弹窗还没回答」时直接把 false 回给 Dart，
//    必须放行（result(true)），否则 Dart 依旧会放弃。
if (isSupported && /isNotificationAuthorizationPending/.test(isSupported) === false) {
  failures.push([
    'case "isSupported" 没有考虑 isNotificationAuthorizationPending ——',
    '「还没回答弹窗」必须与「用户拒绝」区分开：前者要按可用放行(result(true))，',
    '否则 Dart 拿到 false 后不再重试，授权完成后也不会恢复。',
  ].join('\n  '));
}

// ③ Dart 侧必须处理原生推来的 authorizationResolved，否则授权完成后要等
//    下一次播放状态变化才恢复（用户观感是「授权完了还是没反应」）。
if (!/authorizationResolved/.test(service)) {
  failures.push([
    'lib/features/player/live_activity_service.dart 没有处理原生回调 authorizationResolved ——',
    '通知授权刚被回答时 areActivitiesEnabled 才翻成 true，必须立刻重试并补推当前曲目。',
  ].join('\n  '));
}

// ④ _ensureAvailable 必须支持强制重查（force），否则授权回调无法突破
//    「已经判定过 false」的缓存。
if (!/_ensureAvailable\s*\(\s*\{\s*bool\s+force/.test(service)) {
  failures.push([
    'live_activity_service.dart 的 _ensureAvailable 没有 force 参数 ——',
    '授权回调需要强制重新判定一次 areActivitiesEnabled，否则会被缓存挡住。',
  ].join('\n  '));
}

// ⑤ Info.plist 两个键都要在（少一个都是静默失败）。
for (const key of ['NSSupportsLiveActivities', 'NSSupportsLiveActivitiesFrequentUpdates']) {
  if (!plist.includes(key)) {
    failures.push(`ios/Runner/Info.plist 缺少 ${key}`);
  }
}

// ⑥ 扩展侧也必须声明 NSSupportsLiveActivities（只写主 App 会「request 成功但不渲染」）。
const widgetPlistPath = join(root, 'ios/CyShineMusicWidget/Info.plist');
const widgetPlist = readFileSync(widgetPlistPath, 'utf8');
if (!widgetPlist.includes('NSSupportsLiveActivities')) {
  failures.push('ios/CyShineMusicWidget/Info.plist 缺少 NSSupportsLiveActivities（扩展侧也要写）');
}

// ⑥b ★ UIDeviceFamily —— 手工组装的 .appex 不会被 Xcode 自动补这个键，
//缺失时 iOS 可能直接不加载扩展：灵动岛与桌面小组件一起消失，且**没有任何报错**。
// 2.0.2 的产物里实测就是缺这个键（主 App 有 [1,2]，appex 完全没有）。
if (!widgetPlist.includes('UIDeviceFamily')) {
  failures.push([
    'ios/CyShineMusicWidget/Info.plist 缺少 UIDeviceFamily ——',
    '这个 .appex 是手工组装的（xcrun swiftc），Xcode 不会替它注入这个键。',
    '缺失时 iOS 可能直接不加载扩展：灵动岛不显示 + 桌面搜不到小组件，',
    '而主 App 一切正常、控制台也没有任何报错。',
  ].join('\n  '));
}

// ⑦ 主 App 与扩展必须共用同一个 ActivityAttributes 源文件，
//    否则系统匹配不到已启动的活动（类型不一致 = 灵动岛不渲染）。
if (!/CyShineActivityAttributes\.swift/.test(bridge)) {
  failures.push([
    'CyShineLiveActivityBridge.swift 没有引用 CyShineActivityAttributes ——',
    '主 App 与扩展必须编译同一份 ActivityAttributes 源码，否则活动起不来。',
  ].join('\n  '));
}

// ---- 输出 ----
console.log('实时活动授权链路检查');
console.log('  bridge :', bridgePath.replace(root + '/', ''));
console.log('  service:', servicePath.replace(root + '/', ''));
console.log('');

if (notes.length) {
  for (const n of notes) console.log('  [info]', n);
  console.log('');
}

if (failures.length) {
  console.error(`✗ ${failures.length} 项不通过：\n`);
  failures.forEach((f, i) => {
    console.error(`  ${i + 1}. ${f}\n`);
  });
  process.exit(1);
}

console.log('✓ 全部通过：授权请求在 isSupported 路径上、Dart 会响应授权结果、两个 Info.plist 键齐全。');