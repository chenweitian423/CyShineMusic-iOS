#!/usr/bin/env python3
"""从 assets/app_icons/classic.png 生成 iOS 所需的全部图标。

为什么要这个脚本：
  · iOS 主图标（AppIcon.appiconset）需要 15 个不同尺寸的 PNG，尺寸需求写在
    Contents.json 里；
  · iOS 备用图标（setAlternateIconName）必须在 Info.plist 的
    CFBundleAlternateIcons 里声明，且每个都要 <name>.png / @2x / @3x 三档；
  · 备用图标还必须被拷到 Runner.app/ **根目录**（不能放子目录），
    这部分由 tool/patch_xcodeproj.py 负责接进工程。

  Android 侧原本只要 256x256 一份，所以这里全部由 classic.png 派生。

只依赖标准库（zlib + struct + colorsys）：CI 的 macOS runner 上的 python3
没有 Pillow，脚本必须能在裸环境下跑。

输出：
  ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png          主图标（15 个）
  ios/Runner/Assets.xcassets/AppIcon<Name>.appiconset/*.png    备用图标（5 套）
  ios/Runner/Icons/icon_<variant>[@2x|@3x].png                 备用图标散装副本（兜底）

关于备用图标的两套产物：
  iOS 切换备用图标有两条互斥的寻址路径 —— 资产目录（Assets.car）与
  bundle 根目录的散装 PNG。历史上散装 + 手工 CFBundleAlternateIcons 是主流做法，
  但在较新的 Xcode / iOS 上手工声明图标键会**静默失效**
  （setAlternateIconName 报错，或 supportsAlternateIcons 返回 false）。
  现在以资产目录为主（Xcode 官方路径，构建设置写在 tool/patch_xcodeproj.py），
  散装副本保留作兜底：万一某个 Xcode 版本不吃
  ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES，把 Info.plist 里的
  CFBundleIcons 手工块加回去即可，PNG 已经在包里、不用重新生成。
  原生侧（CyShineAppIconChannel）按候选名逐个尝试，两套名字都能命中。
"""

from __future__ import annotations

import colorsys
import json
import os
import struct
import sys
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOURCE_DIR = os.path.join(ROOT, "assets", "app_icons")
MAIN_SOURCE = os.path.join(SOURCE_DIR, "classic.png")
APPICON_DIR = os.path.join(ROOT, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
ASSETS_DIR = os.path.join(ROOT, "ios", "Runner", "Assets.xcassets")
ALT_ICON_DIR = os.path.join(ROOT, "ios", "Runner", "Icons")

# 备用图标：从主图标做色相迁移派生，保证 6 套图标是同一个视觉家族。
# 值 = (目标色相 0-255, 饱和度系数, 亮度系数)。
# 白色音符饱和度接近 0，任何系数下都不会被改色 —— 这正是想要的效果。
#
# 第 4 个元素是资产目录里的图标集名（AppIcon<Name>.appiconset）。
# 必须与 tool/patch_xcodeproj.py 的 ALTERNATE_APPICON_NAMES、
# 以及 ios/Runner/CyShineNativePlugin.swift 的 alternateCandidates 一致。
ALTERNATES = [
    # 午夜蓝：深色海军蓝
    ("midnight", 148, 0.95, 0.72, "AppIconMidnight"),
    # 晴空蓝：明亮的天空蓝
    ("sky", 136, 0.90, 1.06, "AppIconSky"),
    # 雾紫：柔和的紫
    ("lavender", 186, 0.85, 0.98, "AppIconLavender"),
    # 薄荷青：低饱和 + 提亮，与主图标的鲜亮绿拉开区分
    ("mint", 108, 0.70, 1.10, "AppIconMint"),
    # 暖桃粉：偏橙的暖桃色
    ("peach", 12, 0.85, 1.05, "AppIconPeach"),
]
ALT_SIZES = [("", 60), ("@2x", 120), ("@3x", 180)]

# 饱和度高于这个阈值才认为「是彩色」，才参与色相迁移。
SATURATION_THRESHOLD = 40


# ---------------------------------------------------------------- PNG 读写

def read_png(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} 不是 PNG")

    offset = 8
    width = height = 0
    bit_depth = color_type = 0
    idat = bytearray()

    while offset < len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        offset += 12 + length

        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if interlace != 0:
                raise ValueError(f"{path} 使用了隔行扫描，不支持")
        elif chunk_type == b"IDAT":
            idat += payload
        elif chunk_type == b"IEND":
            break

    if bit_depth != 8:
        raise ValueError(f"{path} 位深 {bit_depth} 不支持（只支持 8）")
    if color_type not in (2, 6):
        raise ValueError(f"{path} 颜色类型 {color_type} 不支持（只支持 RGB/RGBA）")

    channels = 4 if color_type == 6 else 3
    raw = zlib.decompress(bytes(idat))
    stride = width * channels

    rows = []
    previous = bytearray(stride)
    position = 0
    for _ in range(height):
        filter_type = raw[position]
        position += 1
        line = bytearray(raw[position : position + stride])
        position += stride
        if filter_type == 1:
            for index in range(channels, stride):
                line[index] = (line[index] + line[index - channels]) & 0xFF
        elif filter_type == 2:
            for index in range(stride):
                line[index] = (line[index] + previous[index]) & 0xFF
        elif filter_type == 3:
            for index in range(stride):
                left = line[index - channels] if index >= channels else 0
                line[index] = (line[index] + ((left + previous[index]) >> 1)) & 0xFF
        elif filter_type == 4:
            for index in range(stride):
                left = line[index - channels] if index >= channels else 0
                up = previous[index]
                up_left = previous[index - channels] if index >= channels else 0
                estimate = left + up - up_left
                pa, pb, pc = abs(estimate - left), abs(estimate - up), abs(estimate - up_left)
                if pa <= pb and pa <= pc:
                    predictor = left
                elif pb <= pc:
                    predictor = up
                else:
                    predictor = up_left
                line[index] = (line[index] + predictor) & 0xFF
        elif filter_type != 0:
            raise ValueError(f"{path} 未知行过滤类型 {filter_type}")

        row = []
        for x in range(width):
            base = x * channels
            if channels == 4:
                row.append((line[base], line[base + 1], line[base + 2], line[base + 3]))
            else:
                row.append((line[base], line[base + 1], line[base + 2], 255))
        rows.append(row)
        previous = line

    return width, height, rows


def write_png(path, rows, with_alpha=False):
    """写 PNG。默认不带 alpha 通道（color type 2）。

    iOS 的 app icon 不应该带 alpha —— App Store Connect 会因此拒绝上传，
    Xcode 的 actool 也会告警。我们的图标全部是不透明的，所以直接写 RGB。
    """
    height = len(rows)
    width = len(rows[0])
    channels = 4 if with_alpha else 3

    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter type 0
        for r, g, b, a in row:
            raw += bytes((r, g, b, a)) if with_alpha else bytes((r, g, b))
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(tag, payload):
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    os.makedirs(os.path.dirname(path), exist_ok=True)
    color_type = 6 if with_alpha else 2
    header = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", header))
        handle.write(chunk(b"IDAT", compressed))
        handle.write(chunk(b"IEND", b""))


def resize(rows, size):
    src_h = len(rows)
    src_w = len(rows[0])
    if src_w == size and src_h == size:
        return rows  # 尺寸相同就直接复用，省掉百万次循环
    scale_x = src_w / size
    scale_y = src_h / size
    out = []
    for y in range(size):
        sy = (y + 0.5) * scale_y - 0.5
        y0 = max(0, min(src_h - 1, int(sy)))
        y1 = min(src_h - 1, y0 + 1)
        fy = max(0.0, min(1.0, sy - y0))
        row = []
        for x in range(size):
            sx = (x + 0.5) * scale_x - 0.5
            x0 = max(0, min(src_w - 1, int(sx)))
            x1 = min(src_w - 1, x0 + 1)
            fx = max(0.0, min(1.0, sx - x0))

            channels = []
            for channel in range(4):
                top = rows[y0][x0][channel] * (1 - fx) + rows[y0][x1][channel] * fx
                bottom = rows[y1][x0][channel] * (1 - fx) + rows[y1][x1][channel] * fx
                channels.append(round(top * (1 - fy) + bottom * fy))
            row.append((channels[0], channels[1], channels[2], channels[3]))
        out.append(row)
    return out


def recolor(rows, target_hue, saturation_scale, value_scale):
    """把彩色像素的色相整体迁到 target_hue（0-255），并按系数调整饱和度与亮度。

    白色音符的饱和度接近 0，所以不会被改色 —— 这正是想要的效果：
    背景与装饰点换成新色系，音符保持纯白。
    """
    out = []
    for row in rows:
        new_row = []
        for r, g, b, a in row:
            h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
            if s * 255 > SATURATION_THRESHOLD:
                s = min(1.0, s * saturation_scale)
                v = min(1.0, v * value_scale)
                r2, g2, b2 = colorsys.hsv_to_rgb(target_hue / 255.0, s, v)
                new_row.append((round(r2 * 255), round(g2 * 255), round(b2 * 255), a))
            else:
                new_row.append((r, g, b, a))
        out.append(new_row)
    return out


# ------------------------------------------------------------------- 主流程

def write_app_icon_set(main_rows):
    contents_path = os.path.join(APPICON_DIR, "Contents.json")
    if not os.path.exists(contents_path):
        print(f"[error] 找不到 {contents_path}", file=sys.stderr)
        return 0

    with open(contents_path, "r", encoding="utf-8") as handle:
        contents = json.load(handle)

    cache = {}
    written = 0
    for image in contents.get("images", []):
        filename = image.get("filename")
        if not filename:
            continue  # 有些条目只占位、没有实际文件
        size = float(image["size"].split("x")[0])
        scale = float(image["scale"].rstrip("x"))
        pixels = int(round(size * scale))
        if pixels not in cache:
            cache[pixels] = resize(main_rows, pixels)
        write_png(os.path.join(APPICON_DIR, filename), cache[pixels])
        written += 1
    return written


def read_main_image_specs():
    """主图标集的 image 列表，用于派生备用图标集的 Contents.json。

    去掉 ios-marketing（1024x1024）：备用图标不需要它，
    带上反而可能被 actool 判为非法条目。
    """
    contents_path = os.path.join(APPICON_DIR, "Contents.json")
    if not os.path.exists(contents_path):
        return None
    with open(contents_path, "r", encoding="utf-8") as handle:
        contents = json.load(handle)
    return [image for image in contents.get("images", [])
            if image.get("idiom") != "ios-marketing"]


def write_alternate_icon_sets(recolored_by_variant, specs):
    """把备用图标写成资产目录里的 AppIcon<Name>.appiconset。

    Xcode 通过 ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES 把这些图标集
    编进 Assets.car，并自动生成 Info.plist 的 CFBundleAlternateIcons。
    """
    set_name_of = {code: set_name for code, _, _, _, set_name in ALTERNATES}
    written = 0
    for code, recolored in recolored_by_variant.items():
        directory = os.path.join(ASSETS_DIR, f"{set_name_of[code]}.appiconset")
        os.makedirs(directory, exist_ok=True)
        cache: dict[int, list] = {}
        for image in specs:
            filename = image.get("filename")
            if not filename:
                continue
            pixels = int(round(float(image["size"].split("x")[0])
                               * float(image["scale"].rstrip("x"))))
            if pixels not in cache:
                cache[pixels] = resize(recolored, pixels)
            write_png(os.path.join(directory, filename), cache[pixels])
            written += 1
        with open(os.path.join(directory, "Contents.json"), "w", encoding="utf-8") as handle:
            json.dump({"images": specs, "info": {"version": 1, "author": "xcode"}},
                      handle, ensure_ascii=False, indent=2)
            handle.write("\n")
    return written


def write_loose_alternate_icons(recolored_by_variant):
    """散装兜底副本：Runner/Icons/icon_<variant>[@2x|@3x].png。

    资产目录路径失灵时可以把手写的 CFBundleAlternateIcons 加回 Info.plist
    （图标已在包里），不用重新生成。默认不参与构建也不影响安装。
    """
    written = 0
    for code, recolored in recolored_by_variant.items():
        for suffix, size in ALT_SIZES:
            write_png(
                os.path.join(ALT_ICON_DIR, f"icon_{code}{suffix}.png"),
                resize(recolored, size),
            )
            written += 1
    return written


def main():
    if not os.path.exists(MAIN_SOURCE):
        print(f"[error] 找不到主图标源文件 {MAIN_SOURCE}", file=sys.stderr)
        return 1

    width, height, main_rows = read_png(MAIN_SOURCE)
    if width != height:
        print(f"[error] 主图标必须是正方形，当前 {width}x{height}", file=sys.stderr)
        return 1
    print(f"[source] assets/app_icons/classic.png {width}x{height}")

    app_count = write_app_icon_set(main_rows)
    if app_count:
        print(f"[ok] 主图标 {app_count} 个 -> ios/Runner/Assets.xcassets/AppIcon.appiconset/")
    else:
        print("[warn] 没有写入任何主图标，请检查 AppIcon.appiconset/Contents.json")

    # 色相迁移在 256x256 上做（空间不变），再放大到各档尺寸，省时间。
    base = resize(main_rows, 256)
    recolored_by_variant = {}
    for variant, hue, saturation_scale, value_scale, set_name in ALTERNATES:
        recolored_by_variant[variant] = recolor(
            base, hue, saturation_scale, value_scale)
        print(f"        {set_name}  hue={hue} sat={saturation_scale} brightness={value_scale}")

    specs = read_main_image_specs()
    if not specs:
        print("[warn] 读不到 AppIcon.appiconset/Contents.json，跳过备用图标集")
    else:
        set_count = write_alternate_icon_sets(recolored_by_variant, specs)
        print(f"[ok] 备用图标 {set_count} 个 -> ios/Runner/Assets.xcassets/AppIcon*.appiconset/")

    loose_count = write_loose_alternate_icons(recolored_by_variant)
    print(f"[ok] 备用图标兜底副本 {loose_count} 个 -> ios/Runner/Icons/（默认不进包）")

    print()
    print("[done] 图标集由 asset catalog 处理；备用图标的启用靠 tool/patch_xcodeproj.py")
    print("       写入的 ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES 构建设置。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
