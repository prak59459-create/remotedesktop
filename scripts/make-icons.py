#!/usr/bin/env python3
"""アプリのアイコンを描く (iPad の AppIcon / アプリ内のロゴ / Windows の .ico)。
   使い方: python3 scripts/make-icons.py   (Pillow が必要)
   画像は手描きではなくこのスクリプトで作るので、色や形を変えたいときはここを直して作り直す。"""
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
S = 4096  # 大きく描いて縮小する (縁をなめらかに)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def gradient(size, c1, c2, c3):
    """左上 c1 → 中央 c2 → 右下 c3 の斜めグラデーション"""
    w, h = size
    small = Image.new("RGB", (256, 256))
    px = small.load()
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510
            px[x, y] = lerp(c1, c2, t * 2) if t < 0.5 else lerp(c2, c3, (t - 0.5) * 2)
    return small.resize((w, h), Image.BICUBIC)


def draw_icon(size=S, rounded=False):
    bg = gradient((size, size), (88, 60, 255), (56, 112, 255), (20, 210, 245)).convert("RGBA")
    d = ImageDraw.Draw(bg)
    u = size / 1024

    # 背景の光 (左上をふわっと明るく)
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-260 * u, -300 * u, 620 * u, 520 * u], fill=(255, 255, 255, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(120 * u))
    bg = Image.alpha_composite(bg, glow)

    # モニターの影
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([210 * u, 262 * u, 814 * u, 694 * u], radius=70 * u, fill=(10, 20, 80, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(40 * u))
    bg = Image.alpha_composite(bg, shadow)
    d = ImageDraw.Draw(bg)

    # モニター (白い枠 + 画面)
    d.rounded_rectangle([200 * u, 230 * u, 824 * u, 666 * u], radius=70 * u, fill=(255, 255, 255, 255))
    screen = gradient((int(560 * u), int(372 * u)), (24, 30, 72), (34, 60, 140), (16, 150, 210)).convert("RGBA")
    mask = Image.new("L", screen.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, screen.size[0], screen.size[1]], radius=36 * u, fill=255)
    bg.paste(screen, (int(232 * u), int(262 * u)), mask)
    d = ImageDraw.Draw(bg)

    # 画面の中のウィンドウ風の帯
    d.rounded_rectangle([280 * u, 310 * u, 560 * u, 336 * u], radius=13 * u, fill=(255, 255, 255, 70))
    d.rounded_rectangle([280 * u, 360 * u, 470 * u, 380 * u], radius=10 * u, fill=(255, 255, 255, 45))
    d.rounded_rectangle([280 * u, 400 * u, 510 * u, 420 * u], radius=10 * u, fill=(255, 255, 255, 45))

    # スタンド
    d.rounded_rectangle([470 * u, 666 * u, 554 * u, 742 * u], radius=10 * u, fill=(255, 255, 255, 235))
    d.rounded_rectangle([370 * u, 734 * u, 654 * u, 784 * u], radius=25 * u, fill=(255, 255, 255, 255))

    # カーソル (画面の右下へ、少しはみ出す)
    cx, cy = 600 * u, 430 * u
    arrow = [(0, 0), (0, 250), (62, 196), (108, 296), (150, 276), (106, 180), (186, 180)]
    pts = [(cx + x * u, cy + y * u) for x, y in arrow]
    cs = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(cs).polygon([(x + 10 * u, y + 16 * u) for x, y in pts], fill=(0, 10, 60, 140))
    cs = cs.filter(ImageFilter.GaussianBlur(14 * u))
    bg = Image.alpha_composite(bg, cs)
    d = ImageDraw.Draw(bg)
    d.polygon(pts, fill=(255, 255, 255, 255))
    inner = [(cx + x * u, cy + y * u) for x, y in [(22, 52), (22, 196), (66, 156), (114, 258), (128, 252), (82, 156), (140, 156)]]
    d.polygon(inner, fill=(255, 196, 64, 255))

    # 接続を表す弧 (右上)
    for i, r in enumerate([70, 120]):
        box = [820 * u - r * u, 190 * u - r * u, 820 * u + r * u, 190 * u + r * u]
        d.arc(box, start=200, end=290, fill=(255, 255, 255, 230 - i * 60), width=int(26 * u))
    d.ellipse([805 * u, 175 * u, 835 * u, 205 * u], fill=(255, 255, 255, 255))

    if rounded:
        m = Image.new("L", (size, size), 0)
        ImageDraw.Draw(m).rounded_rectangle([0, 0, size, size], radius=size * 0.2237, fill=255)
        bg.putalpha(m)
    return bg


def save(img, path, px):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((px, px), Image.LANCZOS).save(path)
    print("wrote", os.path.relpath(path, ROOT))


if __name__ == "__main__":
    full = draw_icon()
    ipad = os.path.join(ROOT, "ipad", "RemoteDesktop.swiftpm", "Assets.xcassets")
    # iPad のアプリアイコン (角は iPadOS が丸める。透明は使えないので RGB)
    save(full.convert("RGB"), os.path.join(ipad, "AppIcon.appiconset", "AppIcon.png"), 1024)
    # アプリ内で表示するロゴ (角を丸めたもの)
    save(draw_icon(rounded=True), os.path.join(ipad, "Logo.imageset", "Logo.png"), 512)
    # プレビュー用
    save(draw_icon(rounded=True), os.path.join(ROOT, "docs", "images", "icon.png"), 256)
    # Windows の .ico (複数サイズ入り)
    ico = draw_icon(rounded=True)
    path = os.path.join(ROOT, "Sources", "RDHostApp", "Resources", "AppIcon.ico")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    ico.resize((256, 256), Image.LANCZOS).save(path, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("wrote", os.path.relpath(path, ROOT))
