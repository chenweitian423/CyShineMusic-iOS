#!/usr/bin/env node
/*
 * 用 Node + node:vm 验证 music_source_preload.js 的协议与执行顺序。
 *
 * 为什么需要它：iOS（JavaScriptCore）与 Android（QuickJS）跑的是同一份
 * preload.js。iOS 侧踩过一个极难定位的坑 —— 把「执行音源脚本」放在了
 * 「music_source_setup(metadata)」之前，而 globalThis.lx 恰恰是 setup 里才创建的，
 * 于是脚本一上来就 lx 未定义；叠加 JSCore 的 exceptionHandler 吞掉异常，
 * 最终只表现为「音源初始化超时」。这个 harness 把该顺序要求变成可执行断言。
 *
 * 用法：
 *   node tool/verify_preload_protocol.mjs              # 跑全部内置场景
 *   node tool/verify_preload_protocol.mjs <file.js>    # 额外跑一个真实音源脚本
 *
 * 退出码 0 = 全部通过。
 */

import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const PRELOAD_PATH = resolve(
  ROOT,
  'packages/music_source_runtime/ios/Resources/music_source_preload.js',
)
const PRELOAD = readFileSync(PRELOAD_PATH, 'utf8')

let failCount = 0
function check(label, condition, detail = '') {
  const ok = Boolean(condition)
  if (!ok) failCount++
  console.log(`    ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? ` — ${detail}` : ''}`)
}

// --------------------------------------------------------------- 沙箱构造

/**
 * 造一个隔离的 JS 环境，装上 8 个 native 函数。
 * 返回的操作对象等价于 iOS/Android 侧的原生桥。
 */
function makeBridge() {
  const actions = []
  const timers = []

  const sandbox = {
    console: {
      log: (...a) => actions.push({ action: 'log', level: 'log', text: a.join(' ') }),
      info: (...a) => actions.push({ action: 'log', level: 'info', text: a.join(' ') }),
      warn: (...a) => actions.push({ action: 'log', level: 'warn', text: a.join(' ') }),
      error: (...a) => actions.push({ action: 'log', level: 'error', text: a.join(' ') }),
      debug: (...a) => actions.push({ action: 'log', level: 'debug', text: a.join(' ') }),
    },
    __music_source_native_call__: (action, json) => {
      actions.push({ action, json })
    },
    __music_source_md5__: value => {
      if (typeof value !== 'string') throw new Error('md5 expects string')
      return 'd41d8cd98f00b204e9800998ecf8427e'
    },
    __music_source_bytes_to_b64__: jsonBytes => {
      const bytes = JSON.parse(jsonBytes)
      if (!Array.isArray(bytes)) throw new Error('bytesToBase64 expects a JSON array')
      return Buffer.from(bytes).toString('base64')
    },
    __music_source_b64_to_bytes__: value => JSON.stringify([...Buffer.from(value, 'base64')]),
    __music_source_aes_encrypt__: (data, key, iv, transformation) => {
      for (const [name, v] of [['data', data], ['key', key], ['iv', iv], ['transformation', transformation]]) {
        if (typeof v !== 'string') throw new Error(`aesEncrypt ${name} expects string`)
      }
      return Buffer.from('stub').toString('base64')
    },
    __music_source_rsa_encrypt__: (data, key, padding) => {
      if (typeof padding !== 'string') throw new Error('rsaEncrypt padding expects string')
      return Buffer.from('stub').toString('base64')
    },
    __music_source_set_timeout__: (id, delayMs) => {
      if (typeof id !== 'number' || typeof delayMs !== 'number') {
        throw new Error(`set_timeout expects (number, number), got (${typeof id}, ${typeof delayMs})`)
      }
      timers.push({ id, delayMs })
    },
    __music_source_clear_timeout__: id => {
      if (typeof id !== 'number') throw new Error('clear_timeout expects number')
    },
  }

  const context = vm.createContext(sandbox)
  return {
    actions,
    timers,
    sandbox,
    context,
    call: (code, filename = 'inline.js') => vm.runInContext(code, context, { filename }),
    /** 等价于原生侧把 action 派发回 JS。 */
    deliver: (action, data) =>
      vm.runInContext(
        `__music_source_handle__(${JSON.stringify(action)}, ${JSON.stringify(
          typeof data === 'string' ? data : JSON.stringify(data ?? {}),
        )})`,
        context,
      ),
    drain: () => new Promise(r => setImmediate(r)),
  }
}

const METADATA_BASE = {
  id: 'probe',
  name: '协议探针',
  description: 'verify preload contract',
  author: 'tool',
  homepage: 'https://example.invalid',
  version: '1.0.0',
  sourceKey: 'probe@1.0.0',
}

// 刻意用 lx.currentScriptInfo.rawScript —— 相当多的真实音源靠它做版本识别。
function sourceScript() {
  return `
lx.on('request', async ({ source, action, info }) => {
  if (action !== 'musicUrl') throw new Error('unsupported action: ' + action)
  const stamp = String(lx.currentScriptInfo.rawScript || '').length
  if (stamp === 0) throw new Error('currentScriptInfo.rawScript is empty')
  return { url: 'https://example.invalid/' + source + '/' + info.type + '.flac', fileName: 'demo.flac' }
})
lx.send('inited', {
  sources: {
    kw: { name: '酷我', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k', 'flac'] },
    tx: { name: 'QQ', type: 'music', actions: ['musicUrl'], qualitys: ['128k', 'flac'] },
  },
})
`
}

// ------------------------------------------------------------------ 场景 1

function scenarioCorrectOrder() {
  console.log('\n[场景 A] 正确顺序：preload -> setup -> 音源脚本（与 Android createRuntime 一致）')
  const bridge = makeBridge()

  console.log('  1) native 全局函数')
  for (const name of [
    '__music_source_native_call__', '__music_source_md5__', '__music_source_bytes_to_b64__',
    '__music_source_b64_to_bytes__', '__music_source_aes_encrypt__', '__music_source_rsa_encrypt__',
    '__music_source_set_timeout__', '__music_source_clear_timeout__',
  ]) {
    check(`globalThis.${name} 已定义`, typeof bridge.context[name] === 'function')
  }

  console.log('  2) evaluate(preload.js)')
  bridge.call(PRELOAD, 'music_source_preload.js')
  check('music_source_setup 已暴露', typeof bridge.context.music_source_setup === 'function')
  check('此刻 lx 还不存在（正是它必须在脚本之前的原因）', bridge.context.lx === undefined)

  console.log('  3) music_source_setup(metadata)')
  const script = sourceScript()
  bridge.context.music_source_setup(JSON.stringify({ ...METADATA_BASE, rawScript: script }))
  check('setup 自删 music_source_setup', bridge.context.music_source_setup === undefined)
  check('lx 已创建', typeof bridge.context.lx === 'object')
  check('lx.version 存在', typeof bridge.context.lx.version === 'string', bridge.context.lx.version)
  check('lx.env = mobile', bridge.context.lx.env === 'mobile')
  check('lx.currentScriptInfo.rawScript 可用',
    (bridge.context.lx.currentScriptInfo?.rawScript ?? '').length > 0,
    `${bridge.context.lx.currentScriptInfo?.rawScript?.length ?? 0} 字节`)
  check('8 个 native 函数已被 delete',
    bridge.context.__music_source_native_call__ === undefined)

  console.log('  4) evaluate(音源脚本)')
  bridge.call(script, 'source.js')
  check('__music_source_handle__ 已暴露', typeof bridge.context.__music_source_handle__ === 'function')

  const init = bridge.actions.find(a => a.action === 'init')
  check('脚本上报了 init', Boolean(init))
  if (init) {
    const payload = JSON.parse(init.json)
    check('init.status = true', payload.status === true, payload.error ?? '')
    const codes = Object.keys(payload.info?.sources ?? {})
    check('sources 已归一化', codes.length > 0, codes.join(','))
    for (const code of codes) {
      const entry = payload.info.sources[code]
      check(`${code}.actions 含 musicUrl`, entry.actions?.includes('musicUrl'))
      check(`${code}.qualitys 非空`, (entry.qualitys ?? []).length > 0, (entry.qualitys ?? []).join('/'))
    }
  }

  console.log('  5) resolve 往返（含 httpResponse 回灌）')
  bridge.actions.length = 0
  bridge.deliver('resolve', {
    requestId: 'r1', source: 'kw', quality: 'flac',
    musicInfo: { songmid: '123', name: 'demo', singer: 'demo' },
  })
  const httpReq = bridge.actions.find(a => a.action === 'httpRequest')
  if (httpReq) {
    const payload = JSON.parse(httpReq.json)
    check('httpRequest 带 requestId 与 url',
      typeof payload.requestId === 'string' && typeof payload.url === 'string', payload.url)
    bridge.deliver('httpResponse', {
      requestId: payload.requestId,
      response: { statusCode: 200, statusMessage: 'OK', headers: {}, body: '{}', ok: true },
    })
  } else {
    console.log('    SKIP  最小音源不发起 httpRequest')
  }
  return bridge.drain().then(() => {
    const resolved = bridge.actions.find(a => a.action === 'resolveResult')
    check('脚本回报了 resolveResult', Boolean(resolved))
    if (resolved) {
      const payload = JSON.parse(resolved.json)
      check('resolveResult.status = true', payload.status === true, payload.error ?? '')
      check('url 是 http(s)', /^https?:\/\//i.test(payload.url ?? ''), payload.url)
    }
  })
}

// ------------------------------------------------------------------ 场景 2

function scenarioWrongOrder() {
  console.log('\n[场景 B] 错误顺序：preload -> 音源脚本 -> setup（我第一版写错的顺序）')
  const bridge = makeBridge()
  bridge.call(PRELOAD, 'music_source_preload.js')
  const script = sourceScript()

  let scriptError = null
  try {
    bridge.call(script, 'source.js')
  } catch (error) {
    scriptError = error
  }

  check('脚本执行时抛错（因为 lx 还不存在）', scriptError !== null,
    scriptError ? String(scriptError.message).split('\n')[0] : '没有抛错')
  check('因此没有上报 init（原生侧只能等到超时）',
    !bridge.actions.some(a => a.action === 'init'))

  // 补一次 setup —— 说明「顺序错了还会继续悄悄往下走」，
  // 这正是为什么 JSCore 侧一旦吞掉异常就只剩一句「初始化超时」。
  bridge.context.music_source_setup(JSON.stringify({ ...METADATA_BASE, rawScript: script }))
  check('事后补 setup 能建出 lx，但脚本已经不在了',
    typeof bridge.context.lx === 'object' &&
    !bridge.actions.some(a => a.action === 'init'))
}

// ------------------------------------------------------------------ 场景 3

function scenarioRealScript(scriptPath) {
  console.log(`\n[场景 C] 真实音源脚本：${scriptPath}`)
  const script = readFileSync(scriptPath, 'utf8')
  const bridge = makeBridge()
  bridge.call(PRELOAD, 'music_source_preload.js')
  bridge.context.music_source_setup(JSON.stringify({ ...METADATA_BASE, rawScript: script }))

  let thrown = null
  try {
    bridge.call(script, scriptPath)
  } catch (error) {
    thrown = error
  }
  check('脚本执行未抛异常', thrown === null,
    thrown ? String(thrown.message).split('\n')[0] : '')

  const init = bridge.actions.find(a => a.action === 'init')
  const httpReqs = bridge.actions.filter(a => a.action === 'httpRequest')
  check('脚本上报了 init，或先发起了 httpRequest（两者都算正常开局）',
    Boolean(init) || httpReqs.length > 0,
    init ? '已 init' : `待 http 响应：${httpReqs.length} 个请求`)

  if (init) {
    const payload = JSON.parse(init.json)
    check('init.status = true', payload.status === true, payload.error ?? '')
    if (payload.info?.sources) {
      check('sources 归一化后非空', Object.keys(payload.info.sources).length > 0,
        Object.keys(payload.info.sources).join(','))
    }
  }
}

// -------------------------------------------------------------------- main

const realScript = process.argv[2]
console.log(`preload: packages/music_source_runtime/ios/Resources/music_source_preload.js (${PRELOAD.length} 字节)`)

await scenarioCorrectOrder()
scenarioWrongOrder()
if (realScript) scenarioRealScript(realScript)

console.log('')
if (failCount === 0) {
  console.log('协议与执行顺序验证通过。')
  console.log('=> iOS 侧若仍报「超时」，请到 app 内「日志」页看 JS 异常记录，那里会写明原因。')
  process.exit(0)
}
console.log(`验证失败：${failCount} 项不通过。`)
process.exit(1)
