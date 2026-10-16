#!/usr/bin/env python3
"""从 assets/app_icons/*.png 生成 iOS 备用图标。

为什么需要这个：
  iOS 的备用图标（setAlternateIconName）必须在 Info.plist 的
  CFBundleIcons / CFBundleAlternateIcons 里声明，并且图标文件要以
  <name>.png / <name>@2x.png / <name>@3x.png 的形式打进 App bundle。
  Android 端只需要一份 256x256 的 PNG 就够了，iOS 需要多档尺寸。

输出：
  ios/Runner/Icons/icon_<variant>.png      60x60   (@1x)
  ios/Runner/Icons/icon_<variant>@2x.png   120x120 (@2x)
  ios/Runner/Icons/icon_<variant>@3x.png   180x180 (@3x)

只用标准库（zlib + struct）做 PNG 解码/编码与双线性缩放，
不依赖 Pillow，保证在 macOS / Linux / Windows 上都能跑。
"""

from __future__ import annotations

import glob
import os
import struct
import sys
import zlib

VARIANTS = ["midnight", "sky", "lavender", "mint", "peach"]
TARGETS = [("", 60), ("@2x", 120), ("@3x", 180)]

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOURCE_DIR = os.path.join(ROOT, "assets", "app_icons")
OUTPUT_DIR = os.path.join(ROOT, "ios", "Runner", "Icons")


def read_png(path: str) -> tuple[int, int, list[list[tuple[int, int, int, int]]]]:
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

    # 反 PNG 行过滤。
    pixels: list[tuple[int, int, int, int]] = []
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

        for x in range(width):
            base = x * channels
            if channels == 4:
                pixels.append((line[base], line[base + 1], line[base + 2], line[base + 3]))
            else:
                pixels.append((line[base], line[base + 1], line[base + 2], 255))
        previous = line

    return width, height, [pixels[y * width : (y + 1) * width] for y in range(height)]


def write_png(path: str, rows: list[list[tuple[int, int, int, int]]]) -> None:
    height = len(rows)
    width = len(rows[0])

    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter type 0
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", header))
        handle.write(chunk(b"IDAT", compressed))
        handle.write(chunk(b"IEND", b""))


def resize(rows: list[list[tuple[int, int, int, int]]], size: int):
    src_h = len(rows)
    src_w = len(rows[0])
    scale_x = src_w / size
    scale_y = src_h / size
    out: list[list[tuple[int, int, int, int]]] = []

    for y in range(size):
        # 采样点用中心对齐，避免整体偏移半个像素。
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


def main() -> int:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    generated = 0

    for variant in VARIANTS:
        source = os.path.join(SOURCE_DIR, f"{variant}.png")
        if not os.path.exists(source):
            print(f"[skip] 缺少源图 {source}", file=sys.stderr)
            continue
        _, _, rows = read_png(source)
        for suffix, size in TARGETS:
            target = os.path.join(OUTPUT_DIR, f"icon_{variant}{suffix}.png")
            write_png(target, resize(rows, size))
            generated += 1
            print(f"[ok] ios/Runner/Icons/icon_{variant}{suffix}.png ({size}x{size})")

    print()
    if generated == 0:
        print("[error] 没有生成任何图标。Info.plist 里声明了 icon_* 备用图标，"
              "缺文件会导致 setAlternateIconName 失败。", file=sys.stderr)
        return 1

    print(f"[done] 共生成 {generated} 个文件 -> ios/Runner/Icons/")
    print("       这些文件需要加入 Xcode 的 Runner target -> Copy Bundle Resources。")
    print("       CI（flutter build ios）会通过 project.pbxproj 里的引用自动打包。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
