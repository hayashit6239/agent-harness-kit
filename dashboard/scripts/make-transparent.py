#!/usr/bin/env python3
"""ロールキャラ画像 (chactor1-4.png) の背景透過ワンショット変換 (issue #97 part3・🟡3 / 🟢D)。

配置された元画像は「不透明の均一スレート背景 (RGB≈(82,86,101)) + 画像端に非接触のキャラ本体」
という構造 (issue #97 で検証済み)。この構造を利用し、

  1. 四隅の平均色を背景色として推定する
  2. **画像端から連結する背景色ピクセルのみ** を flood-fill で透過する (color-key)
     — 端から到達可能な bg だけを抜くため、キャラ内部の同系色 (chactor1 の紺装束など) は
       silhouette の内側で到達不能となり punch out されない (単純 chroma-key の破綻を回避)
  3. 透過後の不透明領域の bounding box へ crop する (均一余白を除去し 4 体の寸法差を揃えやすくする)

tolerance=24 の根拠: tol を 8→20→32 と振ると bbox は tol=20 で安定し (端の anti-alias リングを
除去しきる)、tol=32 でも bbox が動かない (= 本体へ tunneling しない) ことを実測。24 は halo 除去と
本体保護の両立点。

これは **一度きりの資産変換** であり build 依存ではない (透過済み PNG を commit 済み・issue #97
🟢D 決定)。本 script は再変換の再現性のための参照として repo に残す。元の不透明キャプチャに対して
実行する前提 (透過済みファイルに再実行しても border が bg 色を保つため概ね冪等)。

使い方: python3 dashboard/scripts/make-transparent.py dashboard/src/assets/chactor1.png ...
        (引数省略時は dashboard/src/assets/chactor{1..4}.png を対象)
"""
from __future__ import annotations

import sys
from collections import deque
from pathlib import Path

from PIL import Image

TOLERANCE = 24


def make_transparent(path: Path) -> None:
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    px = im.load()

    corners = [px[0, 0], px[w - 1, 0], px[0, h - 1], px[w - 1, h - 1]]
    bg = (
        sum(c[0] for c in corners) // 4,
        sum(c[1] for c in corners) // 4,
        sum(c[2] for c in corners) // 4,
    )

    def is_bg(p: tuple[int, int, int, int]) -> bool:
        return max(abs(p[0] - bg[0]), abs(p[1] - bg[1]), abs(p[2] - bg[2])) <= TOLERANCE

    seen = [[False] * w for _ in range(h)]
    dq: deque[tuple[int, int]] = deque()
    # 端 (4 辺) の bg 色ピクセルを種にする
    for x in range(w):
        for y in (0, h - 1):
            if not seen[y][x] and is_bg(px[x, y]):
                seen[y][x] = True
                dq.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if not seen[y][x] and is_bg(px[x, y]):
                seen[y][x] = True
                dq.append((x, y))
    # 端から連結する bg のみ透過 (4 近傍 flood-fill)
    while dq:
        x, y = dq.popleft()
        px[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and is_bg(px[nx, ny]):
                seen[ny][nx] = True
                dq.append((nx, ny))

    cropped = im.crop(im.getbbox())  # 不透明領域の bbox へ trim
    cropped.save(path)
    print(f"{path.name}: {w}x{h} -> {cropped.width}x{cropped.height} (bg={bg}, tol={TOLERANCE})")


def main() -> None:
    args = sys.argv[1:]
    if args:
        targets = [Path(a) for a in args]
    else:
        here = Path(__file__).resolve().parent.parent / "src" / "assets"
        targets = [here / f"chactor{n}.png" for n in (1, 2, 3, 4)]
    for t in targets:
        make_transparent(t)


if __name__ == "__main__":
    main()
