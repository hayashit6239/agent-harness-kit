#!/usr/bin/env python3
"""discover→enqueue の純 enqueue/dedup 判定器 (issue #78・能力3 v1=A)。
python3 標準ライブラリのみの 1 ファイル。

`commands/harness-orchestrate.md` の「discover→enqueue フェーズ」の判定器。
`decide-orchestrator-route.py` / `reconcile-dispatch-marker.py` / `evaluate-stop-condition.py`
と同型の pure decision script で、同じ設計境界を守る:「network な発見 (ラベル付き open issue の
問い合わせ) と台帳への書込 (append) は prose / orchestrator 側 / dedup・batch 採番・step 雛形生成の
決定論的な判定は script 側」。**network 非依存・LLM 非依存**なので `tests/smoke/run-smoke.sh` の
決定論テストに乗る (issue #78 round2 🟡1 のテスト境界)。

3 層分離 (issue #78 round2 🔴2) の**中間層**を担う:
  1. network discover (orchestrator の prose・smoke 対象外): `gh issue list --label <discover-label>
     --state open --json number` で候補 issue.number を得る。
  2. 純 enqueue/dedup (本 script・smoke 対象): {候補 numbers, 現台帳の steps} → {追加 step 群 / no-op}。
  3. 台帳書込 (orchestrator・単一 writer): 本 script が返す追加 step を台帳へ append する。
本 script は発見も書込もしない (候補と現 steps を受け取り、追加すべき step 群を返すだけ)。

確定した仕様 (issue #78 の round1/round2 レビューで収束):
  - **dedup key = `issue.number` 一致** (round1 🔴2)。突合範囲 = 現台帳の**全 step** (終端
    `closed issue` / `merged pr` を含む)。**終端後の再ラベル = no-op** — 一度 enqueue した
    `issue.number` は終端済みでも再 enqueue しない。全 step を突合対象にするため、終端 step の
    `issue.number` に一致する候補は自然に no-op になる (status を見ずに number だけで閉じる)。
  - **batch 採番 = max+1, max+2, … 逐次加算** (round2 🟡2)。既存 step の最大 id (数値 string と
    見なせるもの) + 1 を起点に、dedup を通過した候補へ連番を振る。同一 tick で N 件同時 enqueue
    しても衝突しない (単一 writer 不変条件は tick 跨ぎの衝突しか防がないため、batch 内の連番は
    本 script が振る)。既存 step が無ければ起点は 1。
  - **step 雛形** (round1 🟡1・schema `step.required=[id, issue, pr]` を充足):
      {"id": "<max+1 以降の string>",
       "issue": {"number": <N>, "status": "created issue", "githubState": "open"},
       "pr": {"number": null, "status": null, "githubState": null}}
    `dependsOn` は付けない (自動 enqueue step は依存なし = 常に eligible)。`created issue` は
    ready 系でないため個別 evidence 不要 (top-level evidence を継承・本 script は evidence を書かない)。
  - **空入力 = no-op** (round1 🟡2)。候補が空なら追加 step は空。dedup で全滅した場合も空。
  - **batch 内の重複も dedup**: 同一 tick の候補リストに同じ `issue.number` が複数現れたら 1 件だけ
    enqueue する (既存 step との突合と同じ key で、走査済みの batch 内 number も突合対象に加える)。

使い方:
    stdin に判定入力 JSON を渡す:
        {
          "candidates": [<issue.number: int>, ...],   # network discover が返した候補 (順序を保つ)
          "steps": [<step object>, ...]                # 現台帳の steps 配列 (dedup / max id の突合元)
        }
    stdout に判定結果 JSON を返す:
        {"enqueue": [<追加すべき step object>, ...]}   # 空配列 = no-op

不正入力 (dict でない / candidates が list でない / 要素が bool を除く整数でない /
steps が list でない / steps 要素が dict でない) は exit 2 + stderr (判定エラーと入力エラーを
区別する。他の decision script と同じ検証スタイル)。判定自体 (enqueue の中身によらず) は exit 0。

**この script は fail-soft を担わない**: network discover (`gh issue list`) 自体の失敗
(network 断 / auth 失効 / rate limit) 時の fail-soft (報告に留め no-op で tick 続行・issue #78
round3 🟡 L6) は、その前段の orchestrator prose の責務。本 script には失敗した network の入力は
そもそも渡らない (候補が得られなければ prose が本 script を呼ばずに no-op で続行する)。空結果
(候補 0 件・クエリ成功) と、クエリ失敗 (候補が得られない) は別の失敗モードであり、前者だけが
本 script の `candidates: []` = no-op として入ってくる。
"""

import json
import sys


def input_error(cause):
    print(f"::error:: decide-enqueue-steps: {cause}", file=sys.stderr)
    sys.exit(2)


def _is_valid_int(v):
    """bool を除く整数かどうか (True/False の混入は整数として扱わない)。
    reconcile-dispatch-marker.py の同名ヘルパと同じ流儀 — JSON の true/false は Python では
    int のサブクラス bool になるため、issue.number として混入させない。"""
    return isinstance(v, int) and not isinstance(v, bool)


def _existing_numbers(steps):
    """現台帳の全 step から `issue.number` (有効な int) を集めた集合を返す (dedup key の突合元)。
    status は見ない — 終端 step も含めて number だけで突合する (round1 🔴2)。step / issue が
    欠けている・number が無い等の部分データは寛容に読み飛ばす (台帳の schema 妥当性は
    validate-plan-progress.py が別途担保する。本 script は number の突合だけに責務を絞る)。"""
    numbers = set()
    for step in steps:
        issue = step.get("issue")
        if isinstance(issue, dict) and _is_valid_int(issue.get("number")):
            numbers.add(issue["number"])
    return numbers


def _max_id(steps):
    """既存 step の id を数値 string と見なして最大値を返す (batch 採番の起点)。数値化できない
    id は max 計算から除外する (新規 id は数値なので非数値 id とは衝突しない)。数値 id が
    1 つも無ければ 0 を返す (起点 = max+1 = 1)。"""
    current_max = 0
    for step in steps:
        sid = step.get("id")
        if isinstance(sid, str):
            try:
                n = int(sid)
            except ValueError:
                continue
            if n > current_max:
                current_max = n
    return current_max


def decide_enqueue(candidates, steps):
    """候補 issue.number 群と現台帳 steps から、追加すべき step 群を返す (純関数・決定論)。"""
    existing = _existing_numbers(steps)
    next_id = _max_id(steps) + 1
    enqueue = []
    seen = set()  # batch 内で既に enqueue した number (batch 内重複の dedup)
    for number in candidates:
        if number in existing or number in seen:
            # dedup: 既存 step と一致 (終端含む)、または同一 tick batch 内で既出 = no-op
            continue
        seen.add(number)
        enqueue.append({
            "id": str(next_id),
            "issue": {"number": number, "status": "created issue", "githubState": "open"},
            "pr": {"number": None, "status": None, "githubState": None},
        })
        next_id += 1
    return {"enqueue": enqueue}


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        input_error(f"stdin を JSON として読めない ({e})。")
    if not isinstance(data, dict):
        input_error("入力が判定 JSON オブジェクトでない。")

    if "candidates" not in data:
        input_error("必須キー 'candidates' が無い。")
    candidates = data["candidates"]
    if not isinstance(candidates, list):
        input_error(f"'candidates' が配列でない ({candidates!r})。")
    for c in candidates:
        if not _is_valid_int(c):
            input_error(f"'candidates' の要素が整数 (issue.number) でない ({c!r})。")

    if "steps" not in data:
        input_error("必須キー 'steps' が無い。")
    steps = data["steps"]
    if not isinstance(steps, list):
        input_error(f"'steps' が配列でない ({steps!r})。")
    for s in steps:
        if not isinstance(s, dict):
            input_error(f"'steps' の要素がオブジェクトでない ({s!r})。")

    print(json.dumps(decide_enqueue(candidates, steps), ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
