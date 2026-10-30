#!/usr/bin/env python3
"""生成 LaunchPad.app 的图标（macOS squircle + 渐变底 + 3x3 网格方块语义）。

输出：LaunchPad/Resources/AppIcon.icns
依赖：Pillow（pip3 install pillow）、系统自带 iconutil
"""
import math
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SS = 3                      # 超采样倍数，保证边缘平滑
SQUIRCLE_N = 4.6            # 超椭圆指数，接近 macOS 连续曲率圆角
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "LaunchPad", "Resources")


def squircle_polygon(size: int, n: float = SQUIRCLE_N, inset: float = 0.0):
    """超椭圆（macOS squircle）边界点：|x/a|^n + |y/a|^n = 1"""
    a = size / 2.0 - inset
    center = size / 2.0
    steps = 720
    pts = []
    for i in range(steps):
        t = (i / steps) * 2.0 * math.pi
        ct, st = math.cos(t), math.sin(t)
        # 超椭圆参数方程
        x = center + math.copysign(a * abs(ct) ** (2.0 / n), ct)
        y = center + math.copysign(a * abs(st) ** (2.0 / n), st)
        pts.append((x, y))
    return pts


def squircle_mask(size: int, n: float = SQUIRCLE_N, inset: float = 0.0) -> Image.Image:
    img = Image.new("L", (size, size), 0)
    ImageDraw.Draw(img).polygon(squircle_polygon(size, n, inset), fill=255)
    return img.filter(ImageFilter.GaussianBlur(radius=max(0.5, size / 700.0)))


def vertical_gradient(size: int, stops):
    """stops: [(pos, (r, g, b)), ...]"""
    img = Image.new("RGB", (1, size))
    px = img.load()
    for y in range(size):
        t = y / float(size - 1)
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]
            p1, c1 = stops[i + 1]
            if p0 <= t <= p1:
                k = 0 if p1 == p0 else (t - p0) / (p1 - p0)
                px[0, y] = tuple(int(round(c0[j] + (c1[j] - c0[j]) * k)) for j in range(3))
                break
    return img.resize((size, size), Image.NEAREST)


def tile_image(tile: float, radius: float, top, bottom) -> Image.Image:
    """单个网格方块：垂直渐变本体 + 1px 内白边 + 顶部柔和高光。"""
    tw = max(2, int(round(tile)))
    mask = Image.new("L", (tw, tw), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, tw - 1, tw - 1], radius=radius, fill=255)

    body = vertical_gradient(tw, [(0.0, top), (0.55, tuple(int((top[i] + bottom[i]) / 2) for i in range(3))),
                                  (1.0, bottom)]).convert("RGBA")
    body.putalpha(mask)

    # 顶部柔和高光（覆盖 22% 高度，逐渐消失）
    gloss = vertical_gradient(tw, [(0.00, (255, 255, 255)),
                                   (0.22, (255, 255, 255)),
                                   (1.00, (255, 255, 255))]).convert("RGBA")
    strip = Image.new("L", (1, tw), 0)
    for y in range(tw):
        t = y / float(max(1, tw - 1))
        strip.putpixel((0, y), int(58 * (1.0 - t / 0.22)) if t < 0.22 else 0)
    gloss_alpha = strip.resize((tw, tw), Image.NEAREST)
    gloss.putalpha(ImageChops.multiply(gloss_alpha, mask))
    body = Image.alpha_composite(body, gloss)

    # 1px 内描边，让方块边缘干净
    inset = max(1, int(round(tile * 0.010)))
    inner = Image.new("L", (tw, tw), 0)
    ImageDraw.Draw(inner).rounded_rectangle([inset, inset, tw - 1 - inset, tw - 1 - inset],
                                            radius=max(1, radius - inset), fill=255)
    ring = ImageChops.subtract(mask, inner).point(lambda v: int(v * 0.5))
    edge = Image.new("RGBA", (tw, tw), (255, 255, 255, 0))
    edge.putalpha(ring)
    body = Image.alpha_composite(body, edge)
    return body


def draw_icon(size: int) -> Image.Image:
    # ---------- 背景 ----------
    grad = vertical_gradient(size, [
        (0.00, (126, 176, 255)),
        (0.45, (74, 110, 246)),
        (0.75, (58, 74, 214)),
        (1.00, (36, 45, 150)),
    ]).convert("RGBA")

    # 底部内阴影，增加体积感
    inner = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    idr = ImageDraw.Draw(inner)
    idr.rectangle([0, int(size * 0.72), size, size], fill=(12, 18, 70, 70))
    inner = inner.filter(ImageFilter.GaussianBlur(radius=size * 0.05))
    grad = Image.alpha_composite(grad, inner)

    # 顶部玻璃高光
    sheen = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    sd.ellipse([-size * 0.35, -size * 1.05, size * 1.35, size * 0.52], fill=(255, 255, 255, 46))
    sheen = sheen.filter(ImageFilter.GaussianBlur(radius=size * 0.06))
    grad = Image.alpha_composite(grad, sheen)

    # ---------- 3x3 网格 ----------
    grid = size * 0.622
    tile = grid / 3.0 * 0.806
    gap = (grid - tile * 3) / 2.0
    origin_x = (size - grid) / 2.0
    origin_y = (size - grid) / 2.0
    radius = tile * 0.245

    white = ((255, 255, 255), (223, 230, 245))
    colors = {
        0: white,
        1: ((141, 232, 255), (44, 168, 232)),     # 青
        2: white,
        3: ((255, 212, 138), (242, 146, 44)),     # 橙
        4: white,
        5: ((186, 170, 255), (110, 88, 238)),     # 紫
        6: white,
        7: ((150, 243, 182), (56, 194, 112)),     # 绿
        8: white,
    }

    # 方块投影单独成层，统一模糊
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sdw = ImageDraw.Draw(shadow)
    for row in range(3):
        for col in range(3):
            x0 = origin_x + col * (tile + gap)
            y0 = origin_y + row * (tile + gap)
            sdw.rounded_rectangle([x0, y0 + tile * 0.10, x0 + tile, y0 + tile],
                                  radius=radius, fill=(8, 14, 60, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=size * 0.014))

    tiles = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cache = {}
    for index in range(9):
        row, col = divmod(index, 3)
        x0 = origin_x + col * (tile + gap)
        y0 = origin_y + row * (tile + gap)
        top, bottom = colors[index]
        key = (top, bottom)
        if key not in cache:
            cache[key] = tile_image(tile, radius, top, bottom)
        tiles.alpha_composite(cache[key], (int(round(x0)), int(round(y0))))

    canvas = grad
    canvas = Image.alpha_composite(canvas, shadow)
    canvas = Image.alpha_composite(canvas, tiles)

    # ---------- 形状与描边 ----------
    mask = squircle_mask(size)
    canvas.putalpha(mask)

    # 内描边：外圈环（浅色玻璃边）
    inner_mask = squircle_mask(size, inset=size * 0.008)
    ring = ImageChops.subtract(mask, inner_mask).point(lambda v: int(v * 0.42))
    edge = Image.new("RGBA", (size, size), (186, 210, 255, 0))
    edge.putalpha(ring)
    canvas = Image.alpha_composite(canvas, edge)

    return canvas


def main() -> int:
    big = draw_icon(SIZE * SS)
    icon = big.resize((SIZE, SIZE), Image.LANCZOS)

    work = os.path.join(os.path.dirname(__file__), "..", ".build", "icon")
    shutil.rmtree(work, ignore_errors=True)
    iconset = os.path.join(work, "AppIcon.iconset")
    os.makedirs(iconset)

    specs = [
        ("icon_16x16.png", 16, 1),
        ("icon_16x16@2x.png", 16, 2),
        ("icon_32x32.png", 32, 1),
        ("icon_32x32@2x.png", 32, 2),
        ("icon_128x128.png", 128, 1),
        ("icon_128x128@2x.png", 128, 2),
        ("icon_256x256.png", 256, 1),
        ("icon_256x256@2x.png", 256, 2),
        ("icon_512x512.png", 512, 1),
        ("icon_512x512@2x.png", 512, 2),
    ]
    for name, base, scale in specs:
        px = base * scale
        icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))

    out_dir = os.path.abspath(OUT_DIR)
    os.makedirs(out_dir, exist_ok=True)
    icns = os.path.join(out_dir, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)

    # 预览图便于人工检查（放在 docs/，不打包进 App）
    docs = os.path.join(os.path.dirname(__file__), "..", "docs")
    os.makedirs(docs, exist_ok=True)
    icon.save(os.path.join(docs, "icon-1024.png"))
    icon.resize((128, 128), Image.LANCZOS).save(os.path.join(docs, "icon-128.png"))
    # 清掉上一版遗留在 Resources 的预览图
    stale = os.path.join(out_dir, "AppIcon-1024.png")
    if os.path.exists(stale):
        os.remove(stale)
    print(f"icon -> {icns}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
