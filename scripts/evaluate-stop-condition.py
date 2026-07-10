#!/usr/bin/env python3
"""停止条件 (round_flag / trend_flag / escalate) の判定器。python3 標準ライブラリのみの 1 ファイル。

/harness-review-pr 手順 5.6 の判定器。LLM の解釈で判定させず、ここで決定論的に判定する。
`reaggregate-has-blocker.py` (has_blocker 再集計) と対をなす存在で、同じ設計境界を守る:
「severity タグ付け・意味判断は LLM 側 / 集約と停止条件の判定は script 側で決定論」。

使い方:
    stdin に判定入力 JSON を渡す:
        {
          "round": <int>,              # 今回のレビュー往復回数 (1 始まり)
          "has_blocker": <bool>,       # 今回の has_blocker (reaggregate-has-blocker.py の出力)
          "blocker_count": <int>,      # 今回の blocker 件数 (= c0)
          "prev_markers": [<str>, ...] # 直近の "# PR Reviewer" コメント本文末尾マーカー行。
                                       # most-recent-first (直近が先頭)、最大 2 件。
                                       # マーカー例:
                                       #   "<!-- harness-review-pr: round=4 has_blocker=true
                                       #    blocker_count=4 escalate=false -->"
        }
    stdout に判定結果 JSON を返す:
        {"escalate": bool, "round_flag": bool, "trend_flag": bool, "reason": str}

ロジック (issue #12 の設計そのまま):
- round < 3: 停止条件の判定を行わない (round_flag=trend_flag=escalate=false 固定)。
- round_flag: round >= 5 かつ has_blocker。
- trend_flag: prev_markers から blocker_count(N-1)・blocker_count(N-2) を両方パースできた場合のみ、
  blocker_count(N) >= blocker_count(N-1) かつ blocker_count(N-1) >= blocker_count(N-2)
  (2 回連続で改善していない) で true。
  2 件揃わない / パース失敗した履歴は「欠損」扱いで trend_flag を成立させない (false)。
  WHY fail-open: 履歴不足・マーカー不正のときに escalate させる (fail-closed) と、誤 escalate で
  正常に収束中の PR を人間に押し付ける実害が出る。誤 escalate の方が実害が大きいので、
  履歴が不確かなときは escalate させない側 (fail-open) に倒す。
  (対照的に reaggregate-has-blocker.py は「blocker 見逃し」の実害が大きいので fail-closed。
   どちらに倒すかは「誤りの実害が大きい側を避ける」で一貫している。)
- escalate = (round_flag or trend_flag) かつ has_blocker
  (has_blocker == false なら flag が立っても escalate しない — blocker が無いのに停止条件を
   立てる自己矛盾を避ける)。
- reason:
  - round_flag のみ成立: "round 上限到達(round N)"
  - trend_flag のみ成立: "blocker 件数が改善していない(round N-2 → N-1 → N: c2 → c1 → c0 の推移)"
  - 両方成立: 上記 2 つを読点で連結
  - escalate == false: 空文字列

不正入力 (dict でない / 必須キー (round / has_blocker / blocker_count) 欠損 / 型不正 /
prev_markers が配列でない) は exit 2 + stderr にエラー (判定エラーと入力エラーを区別する。
reaggregate-has-blocker.py と同じ入力検証スタイル)。判定自体は escalate の真偽によらず exit 0。
"""

import json
import re
import sys

# マーカー行から blocker_count=<M> を取り出す。round_flag/trend_flag のパースはここに集約し、
# テスト対象に含める (prose に正規表現を複製しない — reaggregate-has-blocker.py と同じ方針)。
BLOCKER_COUNT_RE = re.compile(r"blocker_count=(\d+)")


def input_error(cause):
    print(f"::error:: evaluate-stop-condition: {cause}", file=sys.stderr)
    sys.exit(2)


def require_int(data, key):
    if key not in data:
        input_error(f"必須キー '{key}' が無い。")
    v = data[key]
    # bool は int の派生だが整数値として扱わない (True/False の混入を弾く)
    if isinstance(v, bool) or not isinstance(v, int):
        input_error(f"'{key}' が整数でない ({v!r})。")
    return v


def require_bool(data, key):
    if key not in data:
        input_error(f"必須キー '{key}' が無い。")
    v = data[key]
    if not isinstance(v, bool):
        input_error(f"'{key}' が真偽値でない ({v!r})。")
    return v


def parse_blocker_count(marker):
    """マーカー行 (文字列) から blocker_count を取り出す。取り出せなければ None (欠損扱い)。"""
    if not isinstance(marker, str):
        return None
    m = BLOCKER_COUNT_RE.search(marker)
    if not m:
        return None
    return int(m.group(1))


def evaluate(round_, has_blocker, blocker_count, prev_markers):
    c0 = blocker_count
    c1 = parse_blocker_count(prev_markers[0]) if len(prev_markers) >= 1 else None
    c2 = parse_blocker_count(prev_markers[1]) if len(prev_markers) >= 2 else None

    if round_ < 3:
        # round < 3 は停止条件を判定しない (バックストップにも早期検知にも届かない領域)
        round_flag = False
        trend_flag = False
    else:
        round_flag = (round_ >= 5) and has_blocker
        if c1 is not None and c2 is not None:
            trend_flag = (c0 >= c1) and (c1 >= c2)
        else:
            trend_flag = False  # fail-open: 履歴不足・パース不能は escalate させない

    escalate = (round_flag or trend_flag) and has_blocker

    if not escalate:
        reason = ""
    else:
        parts = []
        if round_flag:
            parts.append(f"round 上限到達(round {round_})")
        if trend_flag:
            parts.append(
                f"blocker 件数が改善していない(round {round_ - 2} → {round_ - 1} → {round_}: "
                f"{c2} → {c1} → {c0} の推移)")
        reason = "、".join(parts)

    return {
        "escalate": escalate,
        "round_flag": round_flag,
        "trend_flag": trend_flag,
        "reason": reason,
    }


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        input_error(f"stdin を JSON として読めない ({e})。")
    if not isinstance(data, dict):
        input_error("入力が判定 JSON オブジェクトでない。")

    round_ = require_int(data, "round")
    has_blocker = require_bool(data, "has_blocker")
    blocker_count = require_int(data, "blocker_count")

    prev_markers = data.get("prev_markers", [])
    if not isinstance(prev_markers, list):
        input_error("prev_markers が配列でない。")

    print(json.dumps(
        evaluate(round_, has_blocker, blocker_count, prev_markers),
        ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
