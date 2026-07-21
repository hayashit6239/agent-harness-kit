#!/usr/bin/env python3
"""オフィス俯瞰画像 (office.png) の焼き込みキャラ矩形をワンショットで木床パターンへ塗り潰す (issue #104)。

author 提供の元 `office.png` (488×339) は、右下に 4 ロールキャラのスプライト + 「待機中」バッジ +
名前チップ + 市松ブロックが *モックアップの合成跡* として焼き込まれている。このまま背景に使うと、
アプリが描画するライブのキャラと二重表示になる (issue #104 DoD③ と矛盾)。

キャラ同士・市松が重なり単純 chroma-key ではスプライトを分離できないため、スプライト個別抜きではなく
**焼き込み矩形を周囲と同じ木床パターンで一括塗り潰す** ことで 4 キャラ + バッジ + チップ + 市松を
一度に除去する (issue #104 round1 決定 (d))。

## 塗り潰し仕様 (元画像を pixel 実測して確定・issue #104 round2 🟡 の位相要件を反映)

- **床パターン**: 縦板 stripe。周期 42px・継ぎ目 2px。板面 = `#a9793f` (CSS `--px-floor`)・
  継ぎ目 = `#8c6132` (CSS `--px-floor-dark`)。実測で床は各列 (x) ごとに色一定 (縦方向にフラット)。
- **位相は画像のグローバル x 基準**で再生成する (矩形ローカル原点だと左境界に縦継ぎ目の段差が残り、
  この issue の閉ループは目視主体なので気づかず PR に乗りうる — round2 🟡)。実測した継ぎ目位置は
  **x ≡ 9,10 (mod 42)** (= x=9,10, 51,52, …, 261,262, 303,304, …)。
- **塗り潰し矩形 (inclusive)**: x ∈ [248, 476], y ∈ [172, 329]。
  焼き込みブロックの実測 bbox は (265,180)–(475,328) で、この矩形はそれを全部覆う (左は名前チップ/
  市松の張り出し x≈265 の手前 248 から、上は「待機中」バッジ上端 y≈180 の手前 172 から)。
  - **右 476 / 下 329 で止める根拠 (round2 の x487/y338 を実測で微修正)**: 画像の 4 辺には
    暗いベゼル枠 (`#17110b` = CSS `--stage-bezel`) が回っており、x ≥ 477 と y ≥ 330 はこの枠である
    (焼き込みブロックではない)。枠を床で塗るとベゼルに切り欠きが出るため、床内側 (x≤476・y≤329) で
    止めて枠を保全する。枠帯 (x477–487 / y330–338) に市松の白やスプライトの残り (明色) は無いことを
    実測で確認済み (残存焼き込み無し)。レビュー室 (緑・下端 y≈161) や左の観葉植物 (x≈15) は矩形外。

これは #97 `make-transparent.py` と同系の **一度きりのアセット変換であり build 依存ではない**。
塗り潰し済み PNG を commit 済みで、本 script は再変換の再現性のための参照として repo に残す
(元の焼き込みキャプチャに対して実行する前提。塗り潰し済みファイルへ再実行しても床を床で塗るだけで冪等)。

使い方: python3 dashboard/scripts/clean-office-bg.py [dashboard/src/assets/office.png]
        (引数省略時は dashboard/src/assets/office.png を対象)
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

# 木床パターン (元画像を実測。CSS --px-floor / --px-floor-dark に桁一致)
BOARD = (169, 121, 63, 255)  # #a9793f 板面
SEAM = (140, 97, 50, 255)  # #8c6132 継ぎ目
SEAM_PHASE = (9, 10)  # 継ぎ目は x ≡ 9,10 (mod 42)・グローバル x 基準
PERIOD = 42

# 焼き込み矩形 (inclusive)。床内側で止めてベゼル枠 (x>=477 / y>=330) を保全する
FILL_X0, FILL_X1 = 248, 476
FILL_Y0, FILL_Y1 = 172, 329


def floor_color(x: int) -> tuple[int, int, int, int]:
    """グローバル x 位相の木床色。継ぎ目なら SEAM・それ以外は BOARD。"""
    return SEAM if (x % PERIOD) in SEAM_PHASE else BOARD


def clean(path: Path) -> None:
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    px = im.load()
    x1 = min(FILL_X1, w - 1)
    y1 = min(FILL_Y1, h - 1)
    n = 0
    for y in range(FILL_Y0, y1 + 1):
        for x in range(FILL_X0, x1 + 1):
            px[x, y] = floor_color(x)
            n += 1
    im.save(path)
    print(
        f"{path.name}: {w}x{h} filled rect x[{FILL_X0},{x1}] y[{FILL_Y0},{y1}] "
        f"({n} px) with global-phase wood floor"
    )


def main() -> None:
    args = sys.argv[1:]
    if args:
        targets = [Path(a) for a in args]
    else:
        here = Path(__file__).resolve().parent.parent / "src" / "assets"
        targets = [here / "office.png"]
    for t in targets:
        clean(t)


if __name__ == "__main__":
    main()
