#!/usr/bin/env python3
"""Statuses post 失敗カウンタ (`statusesPostFailCount`) の更新と global halt の判定器。
python3 標準ライブラリのみの 1 ファイル。

commands/harness-orchestrate.md「Statuses post 失敗の surface と global halt」節が持っていた
counter の増減・リセット・閾値判定を、`evaluate-stop-condition.py` と同型の pure decision script
へ切り出したもの (issue #54・#87 の decision script 抽出棚卸しから参照)。設計境界は他の判定器と同じ:
「I/O (report-ledger-status.sh の実行・PushNotification・tick 報告) は prose 側 / counter の更新と
halt の閾値判定は script 側で決定論」。prose に閾値ロジック (>= 3 の比較) を複製しない。

使い方:
    stdin に判定入力 JSON を渡す:
        {
          "current_count": <int>,    # 現在の statusesPostFailCount (キー無しは呼出側が 0 を渡す)
          "post_exit_code": <int>    # report-ledger-status.sh の終了コード (0=post 成功 / 非0=post 失敗)
        }
    stdout に判定結果 JSON を返す:
        {"new_count": <int>, "halt": <bool>, "reason": <str>}

ロジック (issue #37・欠落 5 の prose 仕様そのまま):
- post_exit_code == 0 (post 成功。STATE の値によらない): new_count = 0 にリセット・halt=false。
- post_exit_code != 0 (post 失敗): new_count = current_count + 1 に加算。
  new_count が閾値 HALT_THRESHOLD (=3) に達したら halt=true。
  **失敗時は counter をリセットしない** (halt しても new_count は加算値のまま次 tick へ引き継ぐ)。
- HALT_THRESHOLD=3 は校正根拠の無い best-effort 値。他所の K/N=2 より 1 大きいのは、単発の
  network flake で即 halt しないための余裕 (prose 仕様の根拠をそのまま移設)。
- reason: halt=true のときのみ非空 (`evaluate-stop-condition.py` の reason と同じ流儀)。
  それ以外は空文字列。

不正入力 (dict でない / 必須キー (current_count / post_exit_code) 欠損 / 整数でない /
current_count が負) は exit 2 + stderr にエラー (判定エラーと入力エラーを区別する。
evaluate-stop-condition.py / reconcile-dispatch-marker.py と同じ入力検証スタイル)。
判定自体は halt の真偽によらず exit 0。
"""

import json
import sys

# 連続失敗がこの回数に達したら global halt。prose に複製しないための単一ソース (issue #54)。
HALT_THRESHOLD = 3


def input_error(cause):
    print(f"::error:: decide-statuses-post-action: {cause}", file=sys.stderr)
    sys.exit(2)


def require_int(data, key):
    if key not in data:
        input_error(f"必須キー '{key}' が無い。")
    v = data[key]
    # bool は int の派生だが整数値として扱わない (True/False の混入を弾く)
    if isinstance(v, bool) or not isinstance(v, int):
        input_error(f"'{key}' が整数でない ({v!r})。")
    return v


def decide(current_count, post_exit_code):
    if post_exit_code == 0:
        # post 成功 -> counter リセット (STATE=failure でも post 自体は成功しているのでリセット)
        return {"new_count": 0, "halt": False, "reason": ""}
    # post 失敗 -> 加算。リセットしない (halt しても加算値のまま次 tick へ引き継ぐ)
    new_count = current_count + 1
    halt = new_count >= HALT_THRESHOLD
    reason = (
        f"Statuses post 連続失敗が閾値({HALT_THRESHOLD})に到達(global halt)"
        if halt else "")
    return {"new_count": new_count, "halt": halt, "reason": reason}


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        input_error(f"stdin を JSON として読めない ({e})。")
    if not isinstance(data, dict):
        input_error("入力が判定 JSON オブジェクトでない。")

    current_count = require_int(data, "current_count")
    if current_count < 0:
        input_error(f"'current_count' が負 ({current_count})。")
    post_exit_code = require_int(data, "post_exit_code")

    print(json.dumps(decide(current_count, post_exit_code), ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
