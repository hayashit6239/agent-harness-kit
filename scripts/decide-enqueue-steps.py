#!/usr/bin/env python3
"""discover→enqueue の純 enqueue/dedup 判定器 (issue #78・能力3 v1=A / issue #107 で epic 除外拡張)。
python3 標準ライブラリのみの 1 ファイル。

`commands/harness-orchestrate.md` の「discover→enqueue フェーズ」の判定器。
`decide-orchestrator-route.py` / `reconcile-dispatch-marker.py` / `evaluate-stop-condition.py`
と同型の pure decision script で、同じ設計境界を守る:「network な発見 (ラベル付き open issue の
問い合わせ) と台帳への書込 (append) は prose / orchestrator 側 / dedup・batch 採番・step 雛形生成・
epic 除外の決定論的な判定は script 側」。**network 非依存・LLM 非依存**なので
`tests/smoke/run-smoke.sh` の決定論テストに乗る (issue #78 round2 🟡1 のテスト境界)。

3 層分離 (issue #78 round2 🔴2) の**中間層**を担う:
  1. network discover (orchestrator の prose・smoke 対象外): `gh issue list --label <discover-label>
     --state open --json number,labels,title` で候補 issue と epic 判定材料を得る。
  2. 純 enqueue/dedup/epic 除外 (本 script・smoke 対象): {候補, 現台帳の steps} → {追加 step 群 / no-op}。
  3. 台帳書込 (orchestrator・単一 writer): 本 script が返す追加 step を台帳へ append する。
本 script は発見も書込もしない (候補と現 steps を受け取り、追加すべき step 群を返すだけ)。

確定した仕様 (issue #78 の round1/round2 レビューで収束・issue #107 で epic 除外を追加):
  - **epic 除外 fail-safe (issue #107・D1)**: `isEpic: true` の候補は enqueue 対象から**決定論的に
    落とす** (dedup / 採番の前段で drop する。id 番号を消費しない)。epic は最下層の実装単位ではなく
    PR で close できないため、誤って `discover` ラベルが付いても台帳 step 化しない
    (`rules/issue-tree.md` §1-§2 の層意味論の唯一の機械的裏打ち)。epic 判定 (epic ラベル /
    `epic:` prefix) 自体は network 側 (orchestrator prose) が行い `isEpic` として渡す — 本 script は
    渡された `isEpic` を信頼して drop するだけ (判定材料の取得は prose の責務・smoke 対象外)。
  - **dedup key = `issue.number` 一致** (round1 🔴2)。突合範囲 = 現台帳の**全 step** (終端
    `closed issue` / `merged pr` を含む)。**終端後の再ラベル = no-op** — 一度 enqueue した
    `issue.number` は終端済みでも再 enqueue しない。全 step を突合対象にするため、終端 step の
    `issue.number` に一致する候補は自然に no-op になる (status を見ずに number だけで閉じる)。
  - **batch 採番 = max+1, max+2, … 逐次加算** (round2 🟡2)。既存 step の id を **英字 prefix +
    数値部** に分解し、最大の数値部 + 1 を起点に dedup を通過した候補へ連番を振る。同一 tick で
    N 件同時 enqueue しても衝突しない (単一 writer 不変条件は tick 跨ぎの衝突しか防がないため、
    batch 内の連番は本 script が振る)。既存 step が無ければ起点は 1。
  - **新規 id は既存台帳の形式に追随する** (issue #78 round1 🔴)。この repo の実台帳は `P1`..`P21`
    のような **`P<n>` 形式** を採るため、`P<n>` 台帳へ enqueue すると新 id は `P<max+1>` になる
    (旧実装は `int(sid)` で `P<n>` を全除外し起点を 1 に落とす = id 名前空間の分断だった)。純数値
    台帳なら従来どおり `<max+1>`。採番スキーム (prefix と最大数値) は `_id_scheme` を参照。
  - **step 雛形** (round1 🟡1・schema `step.required=[id, issue, pr]` を充足):
      {"id": "<既存形式の max+1 以降の string。例: P<n> 台帳なら P22>",
       "issue": {"number": <N>, "status": "created issue", "githubState": "open"},
       "pr": {"number": null, "status": null, "githubState": null}}
    `dependsOn` は付けない (自動 enqueue step は依存なし = 常に eligible)。`created issue` は
    ready 系でないため個別 evidence 不要 (top-level evidence を継承・本 script は evidence を書かない)。
  - **空入力 = no-op** (round1 🟡2)。候補が空なら追加 step は空。dedup / epic 除外で全滅した場合も空。
  - **batch 内の重複も dedup**: 同一 tick の候補リストに同じ `issue.number` が複数現れたら 1 件だけ
    enqueue する (既存 step との突合と同じ key で、走査済みの batch 内 number も突合対象に加える)。

**入力契約 (candidates 要素・issue #107 で拡張・#111 が後方拡張する共有契約)**:
  `candidates` 要素は次の 2 形を受理する (後方互換 + 前方拡張):
    - **裸の int** (`78`): `{number: 78, isEpic: false}` の短縮形として扱う (issue #78 の元契約・
      後方互換)。epic 判定材料が無い = 除外しない。
    - **dict** (`{"number": 78, "isEpic": true, ...}`): `number` (bool を除く int) を必須、`isEpic`
      (bool・省略時 false) を任意に持つ。**その他のキーは無視して読み飛ばす** — これは #111 が同じ
      `decide-enqueue-steps.py` の入力契約へ `dependsOn` (`Depends-on: #N` マーカーの parse 結果) を
      **破壊的変更なしに追加**できるようにするための前方拡張点である (issue #107 round2 🟡1 で
      #107 先行 → #111 追随の着地順を確定)。#111 は dict に `dependsOn` キーを足し、本 script の
      未知キー無視によって #107 実装を壊さずに載る。
  裸の int と dict は同一 `candidates` 配列に混在してよい (要素ごとに正規化する)。

使い方:
    stdin に判定入力 JSON を渡す:
        {
          "candidates": [<int | {"number": <int>, "isEpic": <bool>, ...}>, ...],  # network discover の候補 (順序を保つ)
          "steps": [<step object>, ...]                # 現台帳の steps 配列 (dedup / max id の突合元)
        }
    stdout に判定結果 JSON を返す:
        {"enqueue": [<追加すべき step object>, ...]}   # 空配列 = no-op

不正入力 (dict でない / candidates が list でない / 要素が int でも dict でもない / dict 要素に
有効な `number` が無い / `isEpic` が bool でない / steps が list でない / steps 要素が dict でない)
は exit 2 + stderr (判定エラーと入力エラーを区別する。他の decision script と同じ検証スタイル)。
判定自体 (enqueue の中身によらず) は exit 0。

**この script は fail-soft を担わない**: network discover (`gh issue list`) 自体の失敗
(network 断 / auth 失効 / rate limit) 時の fail-soft (報告に留め no-op で tick 続行・issue #78
round3 🟡 L6) は、その前段の orchestrator prose の責務。本 script には失敗した network の入力は
そもそも渡らない (候補が得られなければ prose が本 script を呼ばずに no-op で続行する)。空結果
(候補 0 件・クエリ成功) と、クエリ失敗 (候補が得られない) は別の失敗モードであり、前者だけが
本 script の `candidates: []` = no-op として入ってくる。
"""

import json
import re
import sys


def input_error(cause):
    print(f"::error:: decide-enqueue-steps: {cause}", file=sys.stderr)
    sys.exit(2)


def _is_valid_int(v):
    """bool を除く整数かどうか (True/False の混入は整数として扱わない)。
    reconcile-dispatch-marker.py の同名ヘルパと同じ流儀 — JSON の true/false は Python では
    int のサブクラス bool になるため、issue.number として混入させない。"""
    return isinstance(v, int) and not isinstance(v, bool)


def _normalize_candidate(c):
    """候補要素を `(number, is_epic)` に正規化する (issue #107 で拡張・#111 が追随する共有契約)。

    受理する 2 形 (後方互換 + 前方拡張):
      - **裸の int** (`78`): `(78, False)`。epic 判定材料が無い = 除外しない (#78 元契約)。
      - **dict** (`{"number": 78, "isEpic": true, ...}`): `number` (bool を除く int) 必須・
        `isEpic` (bool・省略時 False) 任意。**その他のキーは無視して読み飛ばす** — #111 が
        `dependsOn` を破壊的変更なしに足せる前方拡張点 (issue #107 round2 🟡1)。
    それ以外 (str / bool / list / None / number の無い dict / isEpic 非 bool) は input_error で
    exit 2 (判定エラーと入力エラーの区別・他の decision script と同じ流儀)。"""
    if _is_valid_int(c):
        return c, False
    if isinstance(c, dict):
        number = c.get("number")
        if not _is_valid_int(number):
            input_error(
                f"'candidates' の dict 要素に有効な整数 'number' が無い ({c!r})。")
        is_epic = c.get("isEpic", False)
        if not isinstance(is_epic, bool):
            input_error(
                f"'candidates' の dict 要素の 'isEpic' が真偽値でない ({c!r})。")
        return number, is_epic
    input_error(
        f"'candidates' の要素が整数でも {{number, isEpic}} dict でもない ({c!r})。")


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


# id を (英字 prefix, 数値部) に分解する regex。`P21` -> ("P", 21) / `21` -> ("", 21)。
# 数値部を持たない id (`seed` 等) や規約外の形 (`P1x` 等) はマッチせず max 計算から除外する。
_ID_RE = re.compile(r"^([A-Za-z]*)([0-9]+)$")


def _parse_id(sid):
    """id string を (prefix, numeric) に分解する。数値部を抽出できなければ None。
    `P21` -> ("P", 21) / `3` -> ("", 3) / `seed` -> None / `P1x` -> None。"""
    if not isinstance(sid, str):
        return None
    m = _ID_RE.match(sid.strip())
    if m is None:
        return None
    return m.group(1), int(m.group(2))


def _id_scheme(steps):
    """既存 step の id から採番スキーム (prefix, 最大数値) を導く (batch 採番の起点)。

    この repo の実台帳は `P1`..`P21` のような **`P<n>` 形式** を採る (schema `step.id` は
    パターン制約なしの string なので実際の規約は台帳側が握る)。旧実装は `int(sid)` で純数値
    string しか解析できず、`P<n>` id を全除外して起点を 1 に落としていた (id 名前空間の分断・
    issue #78 round1 🔴)。ここでは id の **英字 prefix と数値部を regex で分離**し:
      - 最大の数値部を持つ id の prefix を新規 id の prefix として採用する
        (uniform な `P<n>` 台帳なら常に `P`、純数値台帳なら空文字 = 後方互換で `<max+1>`)。
      - 数値部を抽出できない id (`seed` 等) は max 計算から除外する (寛容に読み飛ばす)。
    prefix と数値混在の台帳では「最大数値を持つ id の prefix」を採るのが決定論的な tie-break。
    数値部を持つ id が 1 つも無ければ ("", 0) を返す (起点 = ""+1 = "1"・従来どおり)。
    """
    best_prefix = ""
    best_num = 0
    found = False
    for step in steps:
        parsed = _parse_id(step.get("id"))
        if parsed is None:
            continue
        prefix, num = parsed
        if not found or num > best_num:
            best_prefix, best_num, found = prefix, num, True
    return best_prefix, best_num


def decide_enqueue(normalized, steps):
    """正規化済み候補 `[(number, is_epic), ...]` と現台帳 steps から、追加すべき step 群を返す
    (純関数・決定論)。epic 除外 (issue #107) → dedup → batch 採番の順で決定論的に畳む。"""
    existing = _existing_numbers(steps)
    prefix, current_max = _id_scheme(steps)
    next_num = current_max + 1
    enqueue = []
    seen = set()  # batch 内で既に enqueue した number (batch 内重複の dedup)
    for number, is_epic in normalized:
        if is_epic:
            # epic 除外 fail-safe (issue #107・D1): dedup / 採番の前段で落とす (id 番号を消費しない)。
            # epic は最下層の実装単位でなく PR で close できないため台帳 step 化しない。
            continue
        if number in existing or number in seen:
            # dedup: 既存 step と一致 (終端含む)、または同一 tick batch 内で既出 = no-op
            continue
        seen.add(number)
        enqueue.append({
            # 既存 id と同じ形式で採番する (`P<n>` 台帳なら `P<max+1>`、純数値台帳なら `<max+1>`)。
            "id": f"{prefix}{next_num}",
            "issue": {"number": number, "status": "created issue", "githubState": "open"},
            "pr": {"number": None, "status": None, "githubState": None},
        })
        next_num += 1
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
    normalized = [_normalize_candidate(c) for c in candidates]

    if "steps" not in data:
        input_error("必須キー 'steps' が無い。")
    steps = data["steps"]
    if not isinstance(steps, list):
        input_error(f"'steps' が配列でない ({steps!r})。")
    for s in steps:
        if not isinstance(s, dict):
            input_error(f"'steps' の要素がオブジェクトでない ({s!r})。")

    print(json.dumps(decide_enqueue(normalized, steps), ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
