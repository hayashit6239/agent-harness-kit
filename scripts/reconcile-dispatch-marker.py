#!/usr/bin/env python3
"""dispatch の in-flight マーカー (transient) の tick 冒頭 reconciliation 判定器。
python3 標準ライブラリのみの 1 ファイル。

`commands/harness-orchestrate.md` の「tick 冒頭 reconciliation」の判定器 (issue #26)。
`decide-orchestrator-route.py` / `evaluate-stop-condition.py` と同型の pure decision script で、
同じ設計境界を守る:「状況 (進捗の有無・現在 tick 番号) を解決するのは prose 側 /
マーカーの解釈と有界化の適用は script 側で決定論」。

背景 (issue #26 Problem #1): 実装役の `no_pr` (dispatch 後 PR 未作成) は唯一の無界再 dispatch
経路で、原因が持続的 (issue 実装不能 / subagent の決定論的クラッシュ) でも人間に一切 surface
されなかった。これを塞ぐため、dispatch のたびに in-flight マーカー (`dispatched_tick` /
`deadline_tick` / `retry_count`) を対象 step に書き、以後の tick 冒頭でこの script が
「進捗したか / 締切 (`deadline_tick`) を超過したか / リトライ上限に達したか」を決定論的に判定する。

**P1 決定 (issue #26 所有者判断・2026-07-14)**: 無状態 tick が真であり、跨 tick で参照できる
永続シグナルは on-disk のマーカー + PR の有無のみ (live セッションへの完了通知には依存しない)。
`no_pr` (完了したが PR 未作成) は独立に観測できる枝ではない — 無状態 tick では「完了して no_pr」
と「まだ処理中」を区別できないため、`no_pr` は締切超過 (timeout) と同じリトライカウンタに畳み込む
(set3 で導入した独立 `no_pr_count` は v1 で破棄)。本 script はこの P1 決定を実装する:
`no_pr` を返した dispatch も、締切超過 (hang) を返した dispatch も、同じ `retry_count` で
数える (呼び出し側は両者を区別せず `progressed=false` として本 script に渡す)。

使い方:
    stdin に判定入力 JSON を渡す:
        {
          "marker": null | {"dispatched_tick": <int>, "deadline_tick": <int>, "retry_count": <int>},
          "current_tick": <int>,   # 現在の tick 番号 (台帳 top-level の transient カウンタ由来)
          "progressed": <bool>     # この step が前進した事実が確認できたか
                                   # (例: PR が実在確認できた)。prose が解決する。
        }
    stdout に判定結果 JSON を返す:
        {"action": "eligible"|"clear"|"wait"|"redispatch"|"sink",
         "retry_count": <int, redispatch/sink(retries_exhausted) のみ>,
         "reason": <str, sink のみ>}

action の意味 (呼び出し側の適用方法は `commands/harness-orchestrate.md` 参照):
  - eligible:   marker が無い (in-flight ではない)。配車選別の対象にしてよい。
  - clear:      有効な marker があり、進捗が確認できた。marker を消去し通常の outcome 解決へ。
  - wait:       有効な marker があり、進捗なし・締切未到達。in-flight のまま静観 (選別対象外)。
  - redispatch: 有効な marker があり、締切超過 (進捗なし) だがリトライ上限未到達。
                返った retry_count で marker を更新し (dispatched_tick を今 tick に更新)、
                再 dispatch してよい。
  - sink:       (a) marker が壊れている/不整合 (fail-closed。暴走再 dispatch より安全側)、または
                (b) 締切超過でリトライ上限に到達。既存の単一 sink (need for human review) へ
                (`decide-orchestrator-route.py` の implementer/`timeout` outcome を経由する)。

marker の妥当性 (壊れている/不整合と判定する条件。1 つでも満たせば invalid):
  - dict でない
  - 3 キー (dispatched_tick / deadline_tick / retry_count) のいずれかが欠損
  - いずれかが bool を除く整数でない
  - dispatched_tick < 0 または retry_count < 0
  - deadline_tick < dispatched_tick (締切が dispatch より前という矛盾)
  - dispatched_tick > current_tick (dispatch が「未来」に起きたという矛盾)

判定順序 (issue #26 Alternatives A の reconciliation 手順どおり): (0) 妥当性検証 (fail-closed) が
最優先 — 壊れたマーカーは、たとえ progressed=true であっても sink する (妥当性が確認できない状態を
信用して前進扱いにしない)。次に (1) 進捗 (2) 締切超過 → リトライ有界化、の順で判定する。

不正入力 (dict でない / current_tick が整数でない / progressed が真偽値でない / marker が
null でも dict でもない / marker キー自体の欠損) は exit 2 + stderr (判定エラーと入力エラーを
区別する。他の decision script と同じ検証スタイル)。marker **dict の中身**が壊れている/不整合は
**入力エラーではなく判定結果 (action=sink)** として扱う (妥当性検証そのものが本 script の責務)。
判定自体は action の値によらず exit 0。

MAX_RETRIES (=N) は issue #26 の確定値 (N=2・初回 + 2 リトライ = 計 3 dispatch)。締切のオフセット
K (deadline_tick = dispatched_tick + K、v1: K=2) は marker 書込側 (prose) が計算するため、
本 script は K を持たず deadline_tick を直接比較するだけ。
"""

import json
import sys

MAX_RETRIES = 2  # issue #26 確定値: N=2 (初回 + 2 リトライ = 計 3 dispatch)


def input_error(cause):
    print(f"::error:: reconcile-dispatch-marker: {cause}", file=sys.stderr)
    sys.exit(2)


def require_int(data, key):
    if key not in data:
        input_error(f"必須キー '{key}' が無い。")
    v = data[key]
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


def marker_is_valid(marker, current_tick):
    """marker (dict であることは呼び出し前に確定) の型/整合を検査する。壊れていれば False。"""
    for key in ("dispatched_tick", "deadline_tick", "retry_count"):
        if key not in marker:
            return False
        v = marker[key]
        if isinstance(v, bool) or not isinstance(v, int):
            return False
    if marker["dispatched_tick"] < 0 or marker["retry_count"] < 0:
        return False
    if marker["deadline_tick"] < marker["dispatched_tick"]:
        return False
    if marker["dispatched_tick"] > current_tick:
        return False
    return True


def reconcile(marker, current_tick, progressed):
    if marker is None:
        return {"action": "eligible"}

    if not isinstance(marker, dict) or not marker_is_valid(marker, current_tick):
        # (0) 妥当性検証: 壊れた/不整合な marker は fail-closed (progressed の真偽より優先)
        return {"action": "sink", "reason": "invalid_marker"}

    if progressed:
        # (1) 進捗確認: marker を消去し通常の outcome 解決へ委ねる
        return {"action": "clear"}

    if current_tick > marker["deadline_tick"]:
        # (3) 締切超過 (hang / P1 決定により no_pr もここに合流する)
        new_retry = marker["retry_count"] + 1
        if new_retry > MAX_RETRIES:
            return {"action": "sink", "reason": "retries_exhausted", "retry_count": new_retry}
        return {"action": "redispatch", "retry_count": new_retry}

    # 締切未到達・進捗なし: in-flight のまま静観
    return {"action": "wait"}


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        input_error(f"stdin を JSON として読めない ({e})。")
    if not isinstance(data, dict):
        input_error("入力が判定 JSON オブジェクトでない。")

    if "marker" not in data:
        input_error("必須キー 'marker' が無い。")
    marker = data["marker"]
    if marker is not None and not isinstance(marker, dict):
        input_error(f"'marker' が null かオブジェクトでない ({marker!r})。")

    current_tick = require_int(data, "current_tick")
    progressed = require_bool(data, "progressed")

    print(json.dumps(reconcile(marker, current_tick, progressed), ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
