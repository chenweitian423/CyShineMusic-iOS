#!/usr/bin/env python3
"""把 iOS 侧新增的源文件与资源接进 Xcode 工程（幂等）。

为什么需要脚本：Runner target 的资源与源码是逐个列在 project.pbxproj 里的，
新增文件必须同时改 4 处（PBXBuildFile / PBXFileReference / PBXGroup /
PBXSourcesBuildPhase 或 PBXResourcesBuildPhase），手改一次两次还行，
每次从上游 rebase 之后都要重来，不如脚本。

接入内容：
  1. ios/Runner/CyShineNativePlugin.swift
       -> Runner target 的 Compile Sources
  2. ios/Runner/Icons/*.png （逐个文件，不是文件夹引用）
       -> Runner target 的 Copy Bundle Resources

第 2 点为什么要逐个文件而不是「文件夹引用」：
  Folder Reference 会把文件放到 Runner.app/Icons/ 下面，而 iOS 解析
  Info.plist 的 CFBundleIconFiles 是在 **bundle 根目录**找图的
  （备用图标 icon_midnight.png / @2x / @3x），放在子目录里会找不到。
  逐个文件加入时 Xcode 会把资源平铺拷到 Runner.app/ 根目录，正好符合要求。

用法：python3 tool/patch_xcodeproj.py
"""

from __future__ import annotations

import glob
import hashlib
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ = os.path.join(ROOT, "ios", "Runner.xcodeproj", "project.pbxproj")
ICONS_DIR = os.path.join(ROOT, "ios", "Runner", "Icons")

# 固定 ID，避免重复执行时生成不同 ID（幂等的关键）。
ID_PLUGIN_FILE = "C7A0E0012E0000000000A001"
ID_PLUGIN_BUILD = "C7A0E0022E0000000000A002"

# 早期版本用的是「Icons 文件夹引用」，这两个 ID 需要迁移掉。
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
    print("          ios/Runner/CyShineNativePlugin.swift -> Compile Sources",
          file=sys.stderr)
    print("          ios/Runner/Icons/*.png -> Copy Bundle Resources", file=sys.stderr)
    sys.exit(1)


def icon_ids(path: str) -> tuple[str, str]:
    """由文件名派生稳定 ID，保证脚本幂等。"""
    name = os.path.basename(path)
    digest = hashlib.md5(name.encode("utf-8")).hexdigest()[:18].upper()
    return ("C7A0E0" + digest, "C7A0E1" + digest)


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


def main() -> int:
    if not os.path.exists(PBXPROJ):
        print(f"[error] 找不到 {PBXPROJ}", file=sys.stderr)
        return 1

    with open(PBXPROJ, "r", encoding="utf-8") as handle:
        text = handle.read()

    text = strip_legacy_folder_reference(text)

    icons = sorted(glob.glob(os.path.join(ICONS_DIR, "*.png")))
    if not icons:
        print("[warn] ios/Runner/Icons/ 下没有 PNG。备用图标不会被加入工程。")
        print("       先跑：bash tool/fetch_app_icons.sh")

    # 1) CyShineNativePlugin.swift -> PBXBuildFile
    if f"{ID_PLUGIN_BUILD} /* CyShineNativePlugin.swift in Sources */" not in text:
        if ANCHOR_BUILD_FILE not in text:
            fail("未找到 PBXBuildFile 锚点（AppDelegate.swift in Sources）")
        text = text.replace(
            ANCHOR_BUILD_FILE,
            ANCHOR_BUILD_FILE
            + f"\t\t{ID_PLUGIN_BUILD} /* CyShineNativePlugin.swift in Sources */ = "
              f"{{isa = PBXBuildFile; fileRef = {ID_PLUGIN_FILE} "
              f"/* CyShineNativePlugin.swift */; }};\n",
            1,
        )

    # 2) 图标 -> PBXBuildFile
    # 判断必须用「完整定义字符串」：裸 ID 会先作为 fileRef 出现而误判。
    icon_build_lines = []
    for path in icons:
        name = os.path.basename(path)
        file_id, build_id = icon_ids(path)
        if f"{build_id} /* {name} in Resources */ = {{isa = PBXBuildFile" in text:
            continue
        icon_build_lines.append(
            f"\t\t{build_id} /* {name} in Resources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n"
        )
    if icon_build_lines:
        if ANCHOR_BUILD_FILE not in text:
            fail("未找到 PBXBuildFile 锚点（AppDelegate.swift in Sources）")
        text = text.replace(ANCHOR_BUILD_FILE,
                            ANCHOR_BUILD_FILE + "".join(icon_build_lines), 1)

    # 3) CyShineNativePlugin.swift -> PBXFileReference
    if f"{ID_PLUGIN_FILE} /* CyShineNativePlugin.swift */ = {{isa = PBXFileReference" not in text:
        if ANCHOR_FILE_REF not in text:
            fail("未找到 PBXFileReference 锚点（AppDelegate.swift）")
        text = text.replace(
            ANCHOR_FILE_REF,
            ANCHOR_FILE_REF
            + f"\t\t{ID_PLUGIN_FILE} /* CyShineNativePlugin.swift */ = "
              "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
              'path = CyShineNativePlugin.swift; sourceTree = "<group>"; };\n',
            1,
        )

    # 4) 图标 -> PBXFileReference
    icon_ref_lines = []
    for path in icons:
        name = os.path.basename(path)
        file_id, _ = icon_ids(path)
        if f"{file_id} /* {name} */ = {{isa = PBXFileReference" in text:
            continue
        icon_ref_lines.append(
            f"\t\t{file_id} /* {name} */ = "
            '{isa = PBXFileReference; lastKnownFileType = image.png; '
            f'path = "{name}"; sourceTree = "<group>"; }};\n'
        )
    if icon_ref_lines:
        if ANCHOR_FILE_REF not in text:
            fail("未找到 PBXFileReference 锚点（AppDelegate.swift）")
        text = text.replace(ANCHOR_FILE_REF,
                            ANCHOR_FILE_REF + "".join(icon_ref_lines), 1)

    # 5) Runner group 的 children
    group_lines = []
    if f"\t\t\t\t{ID_PLUGIN_FILE} /* CyShineNativePlugin.swift */,\n" not in text:
        group_lines.append(f"\t\t\t\t{ID_PLUGIN_FILE} /* CyShineNativePlugin.swift */,\n")
    for path in icons:
        name = os.path.basename(path)
        file_id, _ = icon_ids(path)
        if f"\t\t\t\t{file_id} /* {name} */,\n" not in text:
            group_lines.append(f"\t\t\t\t{file_id} /* {name} */,\n")
    if group_lines:
        if ANCHOR_GROUP_CHILD not in text:
            fail("未找到 Runner group 子项锚点（AppDelegate.swift）")
        text = text.replace(ANCHOR_GROUP_CHILD,
                            ANCHOR_GROUP_CHILD + "".join(group_lines), 1)

    # 6) Compile Sources
    if f"\t\t\t\t{ID_PLUGIN_BUILD} /* CyShineNativePlugin.swift in Sources */,\n" not in text:
        if ANCHOR_SOURCES not in text:
            fail("未找到 Runner Sources 阶段锚点（SceneDelegate.swift in Sources）")
        text = text.replace(
            ANCHOR_SOURCES,
            ANCHOR_SOURCES
            + f"\t\t\t\t{ID_PLUGIN_BUILD} /* CyShineNativePlugin.swift in Sources */,\n",
            1,
        )

    # 7) Copy Bundle Resources
    resource_lines = []
    for path in icons:
        name = os.path.basename(path)
        _, build_id = icon_ids(path)
        if f"\t\t\t\t{build_id} /* {name} in Resources */,\n" not in text:
            resource_lines.append(f"\t\t\t\t{build_id} /* {name} in Resources */,\n")
    if resource_lines:
        if ANCHOR_RESOURCES not in text:
            fail("未找到 Runner Resources 阶段锚点（Main.storyboard in Resources）")
        text = text.replace(ANCHOR_RESOURCES,
                            ANCHOR_RESOURCES + "".join(resource_lines), 1)

    with open(PBXPROJ, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)

    # 校验每个 ID 出现次数：fileRef 3 处（定义/引用/group），build 2 处（定义/阶段）
    checks = [(ID_PLUGIN_BUILD, 2), (ID_PLUGIN_FILE, 3)]
    for path in icons:
        file_id, build_id = icon_ids(path)
        checks.append((build_id, 2))
        checks.append((file_id, 3))

    problems = 0
    for identifier, expected in checks:
        actual = text.count(identifier)
        if actual != expected:
            print(f"[warn] {identifier} 出现 {actual} 次，预期 {expected} 次")
            problems += 1

    print(f"[ok] Swift 1 个 + 图标 {len(icons)} 个 -> 引用校验"
          f"{'通过' if problems == 0 else '有问题'}")

    if LEGACY_ICONS_FILE in text or LEGACY_ICONS_BUILD in text:
        print("[warn] 仍残留旧的文件夹引用 ID，请人工检查")

    print("[done] project.pbxproj 已更新")
    return 0


if __name__ == "__main__":
    sys.exit(main())
