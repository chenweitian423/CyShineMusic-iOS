#!/usr/bin/env python3
"""把 iOS 侧新增的源文件与资源接进 Xcode 工程（幂等）。

为什么要脚本：Runner target 的资源与源码是逐个列在 project.pbxproj 里的，
新增文件必须同时改 4 处（PBXBuildFile / PBXFileReference / PBXGroup /
PBXSourcesBuildPhase 或 PBXResourcesBuildPhase），手改一次两次还行，
每次从上游 rebase 之后都要重来，不如脚本。

接入内容：
  ios/Runner/CyShineNativePlugin.swift   -> Runner target 的 Sources
  ios/Runner/Icons/                      -> Runner target 的 Resources
     用「文件夹引用」（lastKnownFileType = folder）一次引用整个目录，
     这样以后新增图标文件不用再改工程文件。

用法：python3 tool/patch_xcodeproj.py
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PBXPROJ = os.path.join(ROOT, "ios", "Runner.xcodeproj", "project.pbxproj")

# 固定 ID，避免重复执行时生成不同 ID（幂等的关键）。
ID_PLUGIN_FILE = "C7A0E0012E0000000000A001"
ID_PLUGIN_BUILD = "C7A0E0022E0000000000A002"
ID_ICONS_FILE = "C7A0E0032E0000000000A003"
ID_ICONS_BUILD = "C7A0E0042E0000000000A004"

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
ANCHOR_SOURCES = (
    "\t\t\t\t7884E8682EC3CC0700C636F2 /* SceneDelegate.swift in Sources */,\n"
)
ANCHOR_RESOURCES = "\t\t\t\t97C146FC1CF9000F007C117D /* Main.storyboard in Resources */,\n"


def fail(message: str) -> None:
    print(f"[error] {message}", file=sys.stderr)
    print("        project.pbxproj 结构与预期不符。请手动新增：", file=sys.stderr)
    print("          ios/Runner/CyShineNativePlugin.swift -> Runner target / Compile Sources",
          file=sys.stderr)
    print("          ios/Runner/Icons/ -> Runner target / Copy Bundle Resources",
          file=sys.stderr)
    sys.exit(1)


def main() -> int:
    if not os.path.exists(PBXPROJ):
        print(f"[error] 找不到 {PBXPROJ}", file=sys.stderr)
        return 1

    with open(PBXPROJ, "r", encoding="utf-8") as handle:
        text = handle.read()

    # 幂等判断必须看「完整定义」而不是裸 ID：ID 会先作为 fileRef 出现，
    # 用裸 ID 判断会导致中间的 PBXFileReference 步骤被误跳过。
    plugin_ref_marker = f"{ID_PLUGIN_FILE} /* CyShineNativePlugin.swift */ = {{isa = PBXFileReference"
    icons_ref_marker = f"{ID_ICONS_FILE} /* Icons */ = {{isa = PBXFileReference"
    if plugin_ref_marker in text and icons_ref_marker in text:
        print("[skip] 工程文件已包含所需引用，无需改动")
        return 0

    # 1) PBXBuildFile
    plugin_build_def = f"{ID_PLUGIN_BUILD} /* CyShineNativePlugin.swift in Sources */ = "
    if plugin_build_def not in text:
        if ANCHOR_BUILD_FILE not in text:
            fail("未找到 PBXBuildFile 锚点（AppDelegate.swift in Sources）")
        additions = (
            f"\t\t{ID_PLUGIN_BUILD} /* CyShineNativePlugin.swift in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {ID_PLUGIN_FILE} /* CyShineNativePlugin.swift */; }};\n"
            f"\t\t{ID_ICONS_BUILD} /* Icons in Resources */ = "
            f"{{isa = PBXBuildFile; fileRef = {ID_ICONS_FILE} /* Icons */; }};\n"
        )
        text = text.replace(ANCHOR_BUILD_FILE, ANCHOR_BUILD_FILE + additions, 1)

    # 2) PBXFileReference
    # 注意：这里必须用「完整的定义文本」做判断。第 1 步已经把 ID 作为 fileRef
    # 写进文本了，用裸 ID 判断会误认为已存在而跳过本步。
    plugin_ref_def = f"{ID_PLUGIN_FILE} /* CyShineNativePlugin.swift */ = {{isa = PBXFileReference"
    if plugin_ref_def not in text:
        if ANCHOR_FILE_REF not in text:
            fail("未找到 PBXFileReference 锚点（AppDelegate.swift）")
        additions = (
            f"\t\t{ID_PLUGIN_FILE} /* CyShineNativePlugin.swift */ = "
            "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            'path = CyShineNativePlugin.swift; sourceTree = "<group>"; };\n'
            f"\t\t{ID_ICONS_FILE} /* Icons */ = "
            '{isa = PBXFileReference; lastKnownFileType = folder; path = Icons; '
            'sourceTree = "<group>"; };\n'
        )
        text = text.replace(ANCHOR_FILE_REF, ANCHOR_FILE_REF + additions, 1)

    # 3) Runner group 的 children
    if "\t\t\t\t" + ID_PLUGIN_FILE not in text:
        if ANCHOR_GROUP_CHILD not in text:
            fail("未找到 Runner group 子项锚点（AppDelegate.swift）")
        additions = (
            f"\t\t\t\t{ID_PLUGIN_FILE} /* CyShineNativePlugin.swift */,\n"
            f"\t\t\t\t{ID_ICONS_FILE} /* Icons */,\n"
        )
        text = text.replace(ANCHOR_GROUP_CHILD, ANCHOR_GROUP_CHILD + additions, 1)

    # 4) Compile Sources
    if "\t\t\t\t" + ID_PLUGIN_BUILD not in text:
        if ANCHOR_SOURCES not in text:
            fail("未找到 Runner Sources 阶段锚点（SceneDelegate.swift in Sources）")
        text = text.replace(
            ANCHOR_SOURCES,
            ANCHOR_SOURCES
            + f"\t\t\t\t{ID_PLUGIN_BUILD} /* CyShineNativePlugin.swift in Sources */,\n",
            1,
        )

    # 5) Copy Bundle Resources
    if "\t\t\t\t" + ID_ICONS_BUILD not in text:
        if ANCHOR_RESOURCES not in text:
            fail("未找到 Runner Resources 阶段锚点（Main.storyboard in Resources）")
        text = text.replace(
            ANCHOR_RESOURCES,
            ANCHOR_RESOURCES + f"\t\t\t\t{ID_ICONS_BUILD} /* Icons in Resources */,\n",
            1,
        )

    with open(PBXPROJ, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)

    # 校验：4 个 ID 各出现次数符合预期。
    for identifier, expected in (
        (ID_PLUGIN_BUILD, 2),
        (ID_PLUGIN_FILE, 3),
        (ID_ICONS_BUILD, 2),
        (ID_ICONS_FILE, 3),
    ):
        actual = text.count(identifier)
        if actual != expected:
            print(f"[warn] {identifier} 出现 {actual} 次，预期 {expected} 次，请人工确认")
        else:
            print(f"[ok] {identifier} x{actual}")

    print("[done] project.pbxproj 已更新")
    return 0


if __name__ == "__main__":
    sys.exit(main())
