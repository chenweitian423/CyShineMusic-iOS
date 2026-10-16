#!/usr/bin/env python3
"""把 iOS 侧新增的源文件与资源接进 Flutter 的 Xcode 工程（幂等）。

为什么需要脚本：Runner target 的源码与资源是逐个列在 project.pbxproj 里的，
新增文件必须同时改 4 处（PBXBuildFile / PBXFileReference / PBXGroup /
PBXSourcesBuildPhase 或 PBXResourcesBuildPhase），手改一两次还行，
每次从上游 rebase 之后都要重来，不如脚本。

这个脚本负责四件事：

1. 把 Runner 侧新增的 Swift 源文件加进 Compile Sources
   （含从 widgets 目录共享过来的 CyShineActivityAttributes.swift）。
2. 把 ios/Runner/Icons/*.png 逐个加进 Copy Bundle Resources。
   ⚠️ 必须是**单个文件**而不是文件夹引用：文件夹引用会保持 Icons/ 子目录结构，
   而 iOS 解析 Info.plist 的 CFBundleIconFiles 是在 bundle 根目录找图的。
3. 把 IPHONEOS_DEPLOYMENT_TARGET 提到 16.2 —— 实时活动（ActivityKit）的最低要求。
   注意：`Activity.request/update/end` 与 `ActivityContent` 是 **16.2** 才有的，
   16.1 只有 `Activity.activities` 与 `ActivityAuthorizationInfo`（踩过：按 16.1
   写会得到一串 "is only available in iOS 16.2 or newer"）。
   Widget Extension 也按同一版本编译（见 tool/build_widget_extension.sh 的 MIN_IOS）。
4. 所有步骤幂等，可重复执行。

用法：python3 tool/patch_xcodeproj.py
"""

from __future__ import annotations

import glob
import hashlib
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ = os.path.join(ROOT, "ios", "Runner.xcodeproj", "project.pbxproj")
ICONS_DIR = os.path.join(ROOT, "ios", "Runner", "Icons")

# Runner target 需要编译的、由本移植新增的 Swift 文件。
# (文件名, 相对 Runner group 的路径)
# Runner group 的 path 是 "Runner"，所以同目录文件直接写文件名，
# 跨目录要写 "../<目录>/<文件>"。
RUNNER_SOURCES = [
    ("CyShineNativePlugin.swift", "CyShineNativePlugin.swift"),
    # 原生 → Dart 的日志桥：把原生失败（实时活动 / 备用图标…）回灌到
    # App 内的「日志」页，否则 Release 包上只能看到 NSLog（用户看不到）。
    ("CyShineNativeLog.swift", "CyShineNativeLog.swift"),
    ("CyShineLiveActivityBridge.swift", "CyShineLiveActivityBridge.swift"),
    # 与 Widget Extension 共享的属性定义：两边必须编译同一份源码，
    # 否则 ActivityAttributes 类型不匹配，系统匹配不到已启动的活动。
    ("CyShineActivityAttributes.swift",
     "../CyShineMusicWidget/CyShineActivityAttributes.swift"),
]

DEPLOYMENT_TARGET = "16.2"

# 资产目录里的备用图标集名。必须与
#   · tool/fetch_app_icons.py 的 ALTERNATES 第 4 列
#   · ios/Runner/CyShineNativePlugin.swift 的 alternateCandidates 首项
# 逐字一致，否则 iOS 找不到图标。
ALTERNATE_APPICON_NAMES = [
    "AppIconMidnight",
    "AppIconSky",
    "AppIconLavender",
    "AppIconMint",
    "AppIconPeach",
]

# 早期版本用的是「Icons 文件夹引用」，需要迁移掉。
LEGACY_ICONS_FILE = "C7A0E0032E0000000000A003"
LEGACY_ICONS_BUILD = "C7A0E0042E0000000000A004"

ANCHOR_BUILD_FILE = (
    "\t\t74858FAF1ED2DC5600515810 /* AppDelegate.swift in Sources */ = "
    "{isa = PBXBuildFile; fileRef = 74858FAE1ED2DC5600515810 /* AppDelegate.swift */; };\n"
)
ANCHOR_FILE_REF = (
    "\t\t74858FAE1ED2DC5600515810 /* AppDelegate.swift */ = "
    '{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; '
    'path = AppDelegate.swift; sourceTree = "<group>"; };\n'
)
ANCHOR_GROUP_CHILD = "\t\t\t\t74858FAE1ED2DC5600515810 /* AppDelegate.swift */,\n"
ANCHOR_SOURCES = "\t\t\t\t7884E8682EC3CC0700C636F2 /* SceneDelegate.swift in Sources */,\n"
ANCHOR_RESOURCES = "\t\t\t\t97C146FC1CF9000F007C117D /* Main.storyboard in Resources */,\n"


def fail(message: str) -> None:
    print(f"[error] {message}", file=sys.stderr)
    print("        project.pbxproj 结构与预期不符。请手动新增：", file=sys.stderr)
    for name, _ in RUNNER_SOURCES:
        print(f"          {name} -> Runner target / Compile Sources", file=sys.stderr)
    print("          ios/Runner/Icons/*.png -> Runner target / Copy Bundle Resources",
          file=sys.stderr)
    sys.exit(1)


def stable_ids(key: str) -> tuple[str, str]:
    """由稳定键派生文件与构建 ID，保证脚本幂等。"""
    digest = hashlib.md5(key.encode("utf-8")).hexdigest()[:18].upper()
    return ("C7A0F0" + digest, "C7A0F1" + digest)


def strip_legacy_folder_reference(text: str) -> str:
    """移除早期版本的 Icons 文件夹引用，避免图标被拷两份。"""
    if LEGACY_ICONS_FILE not in text:
        return text
    lines = text.splitlines(keepends=True)
    kept = [line for line in lines
            if LEGACY_ICONS_FILE not in line and LEGACY_ICONS_BUILD not in line]
    if len(kept) != len(lines):
        print(f"[migrate] 移除 Icons 文件夹引用（{len(lines) - len(kept)} 行）")
    return "".join(kept)


def strip_managed_entries(text: str, names: list[str]) -> str:
    """清掉这些文件在 pbxproj 里的**所有**旧条目，然后由调用方重建。

    为什么不能只比对 ID：历史上有过手工加的条目（ID 是手敲的 C7A0E0…），
    脚本按文件名派生出的稳定 ID（C7A0F0…）跟它们不一样 —— 只比对 ID 的话
    会再插一份，结果是

      * 同一个 .swift 出现在 Compile Sources 里两次 → 链接期 duplicate symbol；
      * 同一张图标出现在 Copy Bundle Resources 里两次 →
        "Multiple commands produce '.../Runner.app/icon_xxx.png'"。

    所以这里按「文件名」而不是「ID」做清除：凡是提到 /* <文件名> */、
    /* <文件名> in Sources */、/* <文件名> in Resources */ 的行一律删掉，
    后面统一用稳定 ID 重建。这样无论旧条目的 ID 是什么都能收敛，
    重复执行也不会叠加。
    """
    tokens: list[str] = []
    for name in names:
        tokens.append(f"/* {name} */")
        tokens.append(f"/* {name} in Sources */")
        tokens.append(f"/* {name} in Resources */")

    lines = text.splitlines(keepends=True)
    kept = [line for line in lines if not any(token in line for token in tokens)]
    removed = len(lines) - len(kept)
    if removed:
        print(f"[dedupe] 清除 {removed} 行旧条目（{'、'.join(names)}）")
    return "".join(kept)


def raise_deployment_target(text: str) -> str:
    pattern = re.compile(r"IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;")
    changed = 0

    def bump(match: re.Match) -> str:
        nonlocal changed
        current = re.search(r"[0-9.]+", match.group(0))
        value = current.group(0) if current else ""
        try:
            if float(value) >= float(DEPLOYMENT_TARGET):
                return match.group(0)
        except ValueError:
            pass
        changed += 1
        return f"IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};"

    text = pattern.sub(bump, text)
    print(f"[ok] 部署目标对齐到 iOS {DEPLOYMENT_TARGET}（改了 {changed} 处）")
    return text


def ensure_asset_catalog_settings(text: str) -> str:
    """打开「把资产目录里所有 AppIcon 都编进去」+ 声明备用图标集。

    为什么必须用构建设置而不是手写 Info.plist：
      iOS 切备用图标时，系统只认 Info.plist 的 CFBundleAlternateIcons。
      手工往 Info.plist 塞这个键在较新的 Xcode / iOS 上会静默失效
      （setAlternateIconName 直接报错，或 supportsAlternateIcons 返回 false）。
      Xcode 官方路径是：图标放进资产目录（Assets.xcassets/AppIcon<Name>.appiconset），
      用 ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES 声明，
      Xcode 在打包时自动生成 CFBundleIcons / CFBundleAlternateIcons。

      · INCLUDE_ALL_APPICON_ASSETS：actool 默认只编主图标，
        不打开这个开关备用图标集会被整个丢掉（Assets.car 里根本没有）。
      · ALTERNATE_APPICON_NAMES：名字必须与 AppIcon<Name>.appiconset 目录名
        逐字一致，也要与 ios/Runner/CyShineNativePlugin.swift 的
        alternateCandidates 一致。
    """
    settings = [
        "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES;",
        f'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "{" ".join(ALTERNATE_APPICON_NAMES)}";',
    ]

    added = 0
    for setting in settings:
        key = setting.split(" = ")[0]
        if f"{key} =" in text:
            continue
        # 挂在每个 XCBuildConfiguration 的 buildSettings 开头，
        # 与已有设置保持同样的缩进层级。
        text, count = re.subn(
            r"(\n\t\t\tbuildSettings = \{\n)",
            lambda m, s=setting: m.group(1) + "\t\t\t\t" + s + "\n",
            text,
        )
        added += count
        print(f"[ok] 注入 {key}（{count} 个构建配置）")

    if added == 0 and all(f"{s.split(' = ')[0]} =" in text for s in settings):
        print("[ok] 图标构建设置已就位")
    return text


def main() -> int:
    if not os.path.exists(PBXPROJ):
        print(f"[error] 找不到 {PBXPROJ}", file=sys.stderr)
        return 1

    with open(PBXPROJ, "r", encoding="utf-8") as handle:
        text = handle.read()

    text = strip_legacy_folder_reference(text)
    text = raise_deployment_target(text)
    text = ensure_asset_catalog_settings(text)

    icons = sorted(glob.glob(os.path.join(ICONS_DIR, "*.png")))
    if not icons:
        print("[warn] ios/Runner/Icons/ 下没有 PNG。备用图标不会被加入工程。")
        print("       先跑：bash tool/fetch_app_icons.sh")

    # 先清掉这些文件在 pbxproj 里的所有旧条目（不管 ID 是什么），
    # 再用稳定 ID 重建 —— 这是幂等的关键。
    text = strip_managed_entries(
        text,
        [name for name, _ in RUNNER_SOURCES] + [os.path.basename(p) for p in icons],
    )

    # ---------------------------------------------------------------- 源文件

    build_lines, ref_lines, group_lines, sources_only, resources_only = [], [], [], [], []
    for name, relative in RUNNER_SOURCES:
        file_id, build_id = stable_ids(f"src:{name}")
        build_lines.append(
            f"\t\t{build_id} /* {name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n"
        )
        ref_lines.append(
            f"\t\t{file_id} /* {name} */ = "
            "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f'path = "{relative}"; sourceTree = "<group>"; }};\n'
        )
        group_lines.append(f"\t\t\t\t{file_id} /* {name} */,\n")
        sources_only.append(f"\t\t\t\t{build_id} /* {name} in Sources */,\n")

    # ---------------------------------------------------------------- 图标

    for path in icons:
        name = os.path.basename(path)
        file_id, build_id = stable_ids(f"icon:{name}")
        build_lines.append(
            f"\t\t{build_id} /* {name} in Resources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n"
        )
        # path 必须带 Icons/ 前缀：sourceTree = "<group>" 是相对 Runner group 的。
        # 写成裸文件名会解析成 ios/Runner/<name>.png 而实际在 ios/Runner/Icons/，
        # 构建时报 "Build input file cannot be found"。
        # 这不会影响图标落到 bundle 根目录 —— Xcode 对普通文件引用是平铺拷贝的。
        ref_lines.append(
            f"\t\t{file_id} /* {name} */ = "
            "{isa = PBXFileReference; lastKnownFileType = image.png; "
            f'path = "Icons/{name}"; sourceTree = "<group>"; }};\n'
        )
        group_lines.append(f"\t\t\t\t{file_id} /* {name} */,\n")
        resources_only.append(f"\t\t\t\t{build_id} /* {name} in Resources */,\n")

    # ---------------------------------------------------------------- 写回

    if build_lines:
        if ANCHOR_BUILD_FILE not in text:
            fail("未找到 PBXBuildFile 锚点（AppDelegate.swift in Sources）")
        text = text.replace(ANCHOR_BUILD_FILE,
                            ANCHOR_BUILD_FILE + "".join(build_lines), 1)

    if ref_lines:
        if ANCHOR_FILE_REF not in text:
            fail("未找到 PBXFileReference 锚点（AppDelegate.swift）")
        text = text.replace(ANCHOR_FILE_REF,
                            ANCHOR_FILE_REF + "".join(ref_lines), 1)

    if group_lines:
        if ANCHOR_GROUP_CHILD not in text:
            fail("未找到 Runner group 子项锚点（AppDelegate.swift）")
        text = text.replace(ANCHOR_GROUP_CHILD,
                            ANCHOR_GROUP_CHILD + "".join(group_lines), 1)

    if sources_only:
        if ANCHOR_SOURCES not in text:
            fail("未找到 Runner Sources 阶段锚点（SceneDelegate.swift in Sources）")
        text = text.replace(ANCHOR_SOURCES,
                            ANCHOR_SOURCES + "".join(sources_only), 1)

    if resources_only:
        if ANCHOR_RESOURCES not in text:
            fail("未找到 Runner Resources 阶段锚点（Main.storyboard in Resources）")
        text = text.replace(ANCHOR_RESOURCES,
                            ANCHOR_RESOURCES + "".join(resources_only), 1)

    with open(PBXPROJ, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)

    # ---------------------------------------------------------------- 校验
    problems = 0
    for name, _ in RUNNER_SOURCES:
        file_id, build_id = stable_ids(f"src:{name}")
        if text.count(build_id) != 2:
            print(f"[warn] {name} 的构建引用数量异常（{text.count(build_id)}）")
            problems += 1
        if text.count(file_id) != 3:
            print(f"[warn] {name} 的文件引用数量异常（{text.count(file_id)}）")
            problems += 1
    for path in icons:
        name = os.path.basename(path)
        file_id, build_id = stable_ids(f"icon:{name}")
        if text.count(build_id) != 2 or text.count(file_id) != 3:
            print(f"[warn] 图标 {name} 的引用数量异常"
                  f"（build {text.count(build_id)} / file {text.count(file_id)}）")
            problems += 1

    # 重复条目是「静默杀手」：Xcode 会报 duplicate symbol 或
    # Multiple commands produce，排查起来很费时间。这里显式扫一遍构建阶段。
    for name, _ in RUNNER_SOURCES:
        phase = text.count(f"/* {name} in Sources */,")
        if phase != 1:
            print(f"[warn] {name} 在 Compile Sources 里出现了 {phase} 次（应为 1）")
            problems += 1
    for path in icons:
        name = os.path.basename(path)
        phase = text.count(f"/* {name} in Resources */,")
        if phase != 1:
            print(f"[warn] {name} 在 Copy Bundle Resources 里出现了 {phase} 次（应为 1）")
            problems += 1

    print(f"[ok] Swift 源文件 {len(RUNNER_SOURCES)} 个 + 图标 {len(icons)} 个 -> "
          f"引用校验{'通过' if problems == 0 else '有问题'}")
    if problems:
        return 1

    if LEGACY_ICONS_FILE in text or LEGACY_ICONS_BUILD in text:
        print("[warn] 仍残留旧的文件夹引用 ID，请人工检查")

    print("[done] project.pbxproj 已更新")
    return 0


if __name__ == "__main__":
    sys.exit(main())
