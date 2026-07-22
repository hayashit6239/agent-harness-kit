#!/usr/bin/env python3
"""空転検知と退避 (安価 no-op tick) + 完了通知の判定器 (issue #84・Phase 3)。
python3 標準ライブラリのみの 1 ファイル。

`commands/harness-orchestrate.md` の tick 手順が持つ「選別ゼロ tick が続いたら退避する /
全 step が終端したら完了通知する」判定を、`evaluate-stop-condition.py` /
`decide-statuses-post-action.py` と同型の pure decision script へ切り出したもの。設計境界は
他の判定器と同じ:「I/O (選別 jq の実行・PushNotification・tick 報告) は prose 側 /
idle counter の更新・退避閾値判定・完了/退避 の文言分岐・notify-once・リセットは script 側で
決定論」。prose に閾値ロジック (>= N の比較) や notify-once の二重フラグ配線を複製しない。

## 判定モデル (issue #84 の round1〜round4 決定事項)

主動機 `/loop` は自身の発火間隔を tick 途中で変えられないため、退避 action は「発火間隔延長」
ではなく **「安価 no-op tick」** (idleTickCount >= N の間、tick 冒頭 reconciliation・選別 jq
再計数・discover(#78) レーンだけ実行し、freshness 報告と冗長な再通知を skip・通知は notify-once
で 1 回・早期 return)。この script は「今 tick を安価 no-op tick にするか (退避)」「通知を出すか
(notify-once)」「どの種類の通知か (退避 / 完了)」を決定論に返す。

### idle counter を +1 する 4 条件 (round1 🔴 L2/L6 の 3 条件 + round2 🔴 L6/L2 の第 4 条件)

次の 4 条件が **すべて真** の tick だけを「空転 (idle)」と数え idleTickCount を +1 する:
  1. eligible = 0                (選別 jq の配車候補が 0 件)
  2. in-flight marker 保持 step = 0 (dispatchMarker / reviewLock / issueReviewLock のいずれも無い)
  3. all-sink ではない            (未終端 step が全て need for human review sink に居る状態を除外)
  4. sink への推移的 dependsOn ブロックが無い (未終端 sink にぶら下がって進めない step を除外)

これにより idle と数えるのは **(a) 真に eligible な仕事が無い** / **(d) 全 step 終端** の 2 つ
だけになる ((d) は未終端 step が 0 なので all-sink が vacuously false・blocked も false で 4 条件を
満たす)。除外される 3 状態:
  - (b) in-flight (遅い実装役 / reviewer の dispatch 中) … 条件 2 で除外
  - (c) all-sink (全未終端 step が sink・#79/#75 の blocked 領分) … 条件 3 で除外
  - 第 4 状態 (some-sink + 推移的ブロック・#79/#75 領分) … 条件 4 で除外

### counter のリセット / 保持 / 加算 (3 分岐)

  - **リセット (idleTickCount→0・idleNotified→false で再武装)**: `eligible > 0` または
    `in-flight marker > 0` = 仕事が在る / 復帰した tick。round1 🟡 L2 のリセット条件のうち
    「eligible>0」「marker 出現」を満たす。3 つ目の「discover(#78) が新規 step を enqueue」は
    別入力を持たず、**enqueue された step (issue.status="created issue") が issue reviewer 選別で
    eligible になり `eligible > 0` へ畳まれる**ことで実現する (固定入力契約を観測可能な選別後
    状態に閉じるための受容・依存ブロックで非 eligible な稀な enqueue は blocked 側へ倒れる)。
  - **保持 (加算も減算もしない)**: 上記リセット条件が偽で、かつ all-sink または推移的ブロックが
    真 (= blocked)。blocked は idle でも仕事復帰でもないため counter を触らない (round1/round2 が
    列挙したリセット条件は blocked を含まないため、literal に保持する)。
  - **加算 (+1)**: 上記いずれでもない = 4 条件を満たす idle tick。

### 退避 (evacuate) と通知 (notify-once・2 フラグ独立・round4)

  - **evacuate**: idle tick かつ new_idle_count >= N のときだけ真 (= 今 tick を安価 no-op tick に
    する)。blocked tick では counter を保持しても evacuate は偽 (blocked は退避対象外・#79/#75 領分)。
  - **通知種別 (round3 🔴 L1/L2)**: evacuate 時、`all_terminal` が真なら完了通知 (`complete`)、
    偽なら退避通知 (`idle`)。決定 script の入力に全 step 終端 真偽を持たせ、(a) 退避 と (d) 完了 を
    決定論に区別する ((a)/(d) は eligible=0・marker=0・not all-sink・not blocked で一致し、
    all_terminal だけが分岐点)。
  - **notify-once は 2 フラグ独立 (round4 🔴 L1/L2・人間選択 option (ii))**: 退避通知は `idleNotified`、
    完了通知は `completeNotified` で各々 1 回だけ発火する。両フラグは互いに独立で、
    **idleNotified=true は完了通知を一切抑止しない (逆も同様)** — これで「退避が先発して
    idleNotified=true → その後全終端 → 完了通知が恒久 suppress される」最頻経路を構造排除する。
  - **各フラグの再武装 (reset)**:
    - `idleNotified`: 上記 counter リセット (eligible>0 / marker>0 / discover→eligible) で落とす。
    - `completeNotified`: **all-terminal が true→false へ推移した tick** で落とす。current_complete_notified
      が true (= 前に完了通知済み = 前 tick は all-terminal) かつ現 all_terminal=false を「推移」と
      みなし false へ戻す。discover 等で仕事が復帰し全終端が崩れれば、次に系が完了に至ったとき
      また完了通知を 1 回出せる。

## 固定値 (best-effort・書換禁止・issue #84 DoD)

N (idle 連続閾値) = 2。既存の dispatchMarker K=2 / N=2 と同じ校正根拠の無い best-effort 値
(`/loop` 間隔が実装役所要より十分長い前提)。単一ソースは下記 `IDLE_EVACUATION_THRESHOLD`
(prose に閾値を複製しない)。

## 使い方

    stdin に判定入力 JSON を渡す:
        {
          "eligible_count": <int>,             # 選別 jq の配車候補件数 (全カテゴリ合算)
          "inflight_marker_count": <int>,      # in-flight marker を保持する step 件数
          "all_sink": <bool>,                  # 未終端 step が全て need for human review sink か
          "blocked_behind_sink": <bool>,       # 未終端 sink に dependsOn でぶら下がる未終端 step の有無
          "all_terminal": <bool>,              # 全 step が終端か (未終端 step 件数が 0 か否か)
          "current_idle_count": <int>,         # 現 idleTickCount (キー無しは呼出側が 0 を渡す)
          "current_idle_notified": <bool>,     # 現 idleNotified (キー無しは false)
          "current_complete_notified": <bool>  # 現 completeNotified (キー無しは false)
        }
    stdout に判定結果 JSON を返す:
        {
          "new_idle_count": <int>,             # 書き戻す idleTickCount
          "evacuate": <bool>,                  # 今 tick を安価 no-op tick にするか (退避判定)
          "notify": <bool>,                    # 今 tick で PushNotification を出すか (notify-once)
          "notify_kind": <"complete"|"idle"|null>, # evacuate 時の通知種別 (evacuate=false なら null)
          "new_idle_notified": <bool>,         # 書き戻す idleNotified
          "new_complete_notified": <bool>      # 書き戻す completeNotified
        }

不正入力 (dict でない / 必須キー欠損 / 整数でない / bool でない / count が負) は exit 2 +
stderr にエラー (判定エラーと入力エラーを区別する。evaluate-stop-condition.py /
decide-statuses-post-action.py と同じ入力検証スタイル)。判定自体は evacuate/notify の真偽に
よらず exit 0。
"""

import json
import sys

# idle が連続してこの回数に達したら退避 (安価 no-op tick + notify)。prose に複製しないための
# 単一ソース (issue #84 の固定値・best-effort・書換禁止)。
IDLE_EVACUATION_THRESHOLD = 2


def input_error(cause):
    print(f"::error:: decide-idle-evacuation: {cause}", file=sys.stderr)
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


def decide(
    eligible_count,
    inflight_marker_count,
    all_sink,
    blocked_behind_sink,
    all_terminal,
    current_idle_count,
    current_idle_notified,
    current_complete_notified,
):
    work_present = eligible_count > 0 or inflight_marker_count > 0
    blocked = all_sink or blocked_behind_sink

    # --- idle counter の 3 分岐 (リセット / 保持 / 加算) ---
    if work_present:
        # 仕事が在る / 復帰した (eligible>0 / marker 出現 / discover→eligible)。counter を 0 へ
        # 落とし idleNotified を再武装する (round1 🟡 L2)。
        new_idle_count = 0
        new_idle_notified = False
        is_idle_tick = False
    elif blocked:
        # blocked (all-sink / 推移的ブロック)。idle でも復帰でもないため counter を保持する
        # (列挙されたリセット条件に blocked は含まれない・round2 🔴 L6/L2)。
        new_idle_count = current_idle_count
        new_idle_notified = current_idle_notified
        is_idle_tick = False
    else:
        # 4 条件を満たす idle tick ((a) eligible 無し / (d) 全終端)。加算する。
        new_idle_count = current_idle_count + 1
        new_idle_notified = current_idle_notified
        is_idle_tick = True

    # --- completeNotified の再武装 (idle counter 分岐から独立・round4) ---
    # all-terminal が true→false へ推移した tick で落とす。current_complete_notified=true は
    # 「前に完了通知済み = 直近の観測で all-terminal だった」を含意するため、現 all_terminal=false
    # を推移とみなせる。
    new_complete_notified = current_complete_notified
    if current_complete_notified and not all_terminal:
        new_complete_notified = False

    # --- 退避判定 + notify-once (退避=idleNotified / 完了=completeNotified の独立 2 系統) ---
    evacuate = False
    notify = False
    notify_kind = None
    if is_idle_tick and new_idle_count >= IDLE_EVACUATION_THRESHOLD:
        evacuate = True
        if all_terminal:
            notify_kind = "complete"
            if not new_complete_notified:
                notify = True
                new_complete_notified = True
        else:
            notify_kind = "idle"
            if not new_idle_notified:
                notify = True
                new_idle_notified = True

    return {
        "new_idle_count": new_idle_count,
        "evacuate": evacuate,
        "notify": notify,
        "notify_kind": notify_kind,
        "new_idle_notified": new_idle_notified,
        "new_complete_notified": new_complete_notified,
    }


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        input_error(f"stdin を JSON として読めない ({e})。")
    if not isinstance(data, dict):
        input_error("入力が判定 JSON オブジェクトでない。")

    eligible_count = require_int(data, "eligible_count")
    if eligible_count < 0:
        input_error(f"'eligible_count' が負 ({eligible_count})。")
    inflight_marker_count = require_int(data, "inflight_marker_count")
    if inflight_marker_count < 0:
        input_error(f"'inflight_marker_count' が負 ({inflight_marker_count})。")
    all_sink = require_bool(data, "all_sink")
    blocked_behind_sink = require_bool(data, "blocked_behind_sink")
    all_terminal = require_bool(data, "all_terminal")
    current_idle_count = require_int(data, "current_idle_count")
    if current_idle_count < 0:
        input_error(f"'current_idle_count' が負 ({current_idle_count})。")
    current_idle_notified = require_bool(data, "current_idle_notified")
    current_complete_notified = require_bool(data, "current_complete_notified")

    result = decide(
        eligible_count,
        inflight_marker_count,
        all_sink,
        blocked_behind_sink,
        all_terminal,
        current_idle_count,
        current_idle_notified,
        current_complete_notified,
    )
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
