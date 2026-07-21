#!/usr/bin/env python3
"""恒久衝突ペアの代表選出述語(issue #55)の決定論判定器。python3 標準ライブラリのみの 1 ファイル。

`commands/harness-orchestrate.md`「ファイル衝突検知」節の**代表選出述語**(issue #55・round3 で
規則 X/Y を一本化)を prose から抽出した pure decision script。`detect-dispatch-collision.py` /
`decide-orchestrator-route.py` 等と同型で、同じ設計境界を守る:
「状況(各候補が live wait 占有者か / dispatch 対象候補か / 対象ファイル不明か)を kind トークンへ
解決するのは LLM(orchestrator prose)側 / 代表選出規則の適用は script 側で決定論」。

Why 切り出し(issue #87): `detect-dispatch-collision.py` は pure Union-Find grouping のみを担い、
その下流の「1 group から dispatch は高々 1 件・占有者が居る group からは 0 件・step id 昇順 tie-break・
fail-closed 単独候補は常に持ち越し」という**代表選出の判断結果そのもの**は散文側にあり
machine-enforce されていなかった(`commands/harness-orchestrate.md`「既知の制限・拡張ポイント」節
『恒久衝突ペアの代表選出・占有者除外(issue #55)も machine-enforce されていない』が「将来 #87 の
decision script 抽出パターンが定まれば script 抽出候補とする」と予告していた領域)。#55 のデッドロック
(恒久的に同一ファイルを編集する 2 ready issue が毎 tick 同一 group に入り両方が永久に持ち越される)は
まさにこの検証不能領域で起きた事故であり、規則を本 script へ集約し smoke で全分岐を閉じることで
代表選出の回帰検知が効くようになる。

**挙動不変の operational 定義(issue #87・#37 前例に倣う)**: 抽出元 prose に baseline test が無いため
通常 refactor の before/after 等価性検証は原理的に成立しない。代わりに smoke ケースが抽出元 prose の
意図した規則を符号化し、人間が prose(「ファイル衝突検知」節「代表選出述語」)↔ script(本 DECISION
規則)の一致を目視確認する。機械的な before/after 等価性検証は不可能という限界を正直に受容する。
抽出後も kind トークンの解決 seam(占有者判定は台帳 state = dispatchMarker/pr.number/締切 を要する)は
prose 側に un-verified で残る(🟡4)— 本 script の価値は「代表選出規則の回帰検知が効く」ことであって
「seam が消える」ことではない。

使い方:
    stdin に判定入力 JSON を渡す:
        {"groups": [["<id>", ...], ...],   # detect-dispatch-collision.py の出力そのまま
         "safe":   ["<id>", ...],           # 同上
         "candidates": {                    # groups ∪ safe の全 id の kind(prose が解決)
             "<id>": {"kind": "<new_eligible|redispatch|wait_occupant>"}, ...}}
      kind トークン(prose が「入力母集団」節の 3 種を解決してから渡す):
        - new_eligible:  選別(jq)が返した新規 eligible 実装役対象(dispatch 対象候補)
        - redispatch:    reconciliation action==redispatch の再試行候補(dispatch 対象候補)
        - wait_occupant: reconciliation action==wait の live 占有者(inject 専用・dispatch 対象外。
                         「1 件目が in-flight の間、同一ファイルを触る 2 件目を出さない」を成立させる
                         ためだけに衝突判定へ注入された候補)
    stdout に判定結果 JSON を返す:
        {"dispatch":      ["<id>", ...],   # 今 tick に dispatch する(各衝突 group から高々 1 件)
         "carry_over":    ["<id>", ...],   # marker 非書換で次 tick へ持ち越す dispatch 対象候補
         "injected_only": ["<id>", ...]}   # wait 占有者(dispatch も carry_over もしない・inject 専用)

代表選出規則(`commands/harness-orchestrate.md`「代表選出述語」を符号化):
  - `safe`(単独連結成分・非空 files)の各候補:
      dispatch 対象候補(new_eligible / redispatch)→ dispatch。
      wait 占有者 → injected_only(inject 専用で dispatch しない)。
  - `groups` の各 group:
      * size==1(fail-closed 単独候補・対象ファイル抽出 0 件で files=[])→ **占有者の有無・代表選出に
        よらず常に持ち越す**(#55 以前の fail-closed 挙動を保存)。dispatch 対象候補なら carry_over・
        wait 占有者なら injected_only。**代表選出の母集団に含めない**(代表 1 件 dispatch しない)。
      * size>=2(恒久衝突組):
          - live wait 占有者を 1 人でも含む → **今 tick は何も dispatch しない**(dispatch 対象候補を
            全て carry_over・占有者を injected_only)。
          - 占有者ゼロ → dispatch 対象候補から **step id 昇順(完全順序)で最小の 1 件だけ dispatch**、
            残りの dispatch 対象候補は carry_over。

不変条件(script が保証・smoke で検証):
  - dispatch / carry_over / injected_only は互いに素で、和集合は入力の全 id 集合に一致する
    (`detect-dispatch-collision.py` の「全 id はちょうど 1 箇所」不変条件を下流で維持)。
  - 1 つの衝突 group(size>=2)から dispatch されるのは高々 1 件。live wait 占有者を含む group からは 0 件。
  - wait 占有者は常に injected_only(dispatch されない)。
  - fail-closed 単独候補(size==1 group)の dispatch 対象候補は常に carry_over(dispatch されない)。

不正入力(dict でない / groups・safe・candidates の型不正 / groups∪safe の id と candidates のキーが
不一致(kind 未解決の id を無言で dispatch しない fail-closed)/ id の重複 / kind が enum 外)は
exit 2 + stderr(判定エラーと入力エラーを区別する。他の decision script と同じ検証スタイル)。
判定自体は dispatch の有無によらず exit 0。
"""

import json
import sys

# dispatch 対象候補の kind(new_eligible ∪ redispatch)。wait_occupant は inject 専用で dispatch 対象外。
DISPATCH_KINDS = ("new_eligible", "redispatch")
# 妥当な kind の全集合(kind の唯一の正)。新 kind を足すときはここと smoke の網羅を一括更新する。
VALID_KINDS = DISPATCH_KINDS + ("wait_occupant",)


def input_error(cause):
    print(f"::error:: select-dispatch-representatives: {cause}", file=sys.stderr)
    sys.exit(2)


def parse_input(data):
    if not isinstance(data, dict):
        input_error("入力が判定 JSON オブジェクトでない。")
    for key in ("groups", "safe", "candidates"):
        if key not in data:
            input_error(f"必須キー '{key}' が無い。")

    groups = data["groups"]
    if not isinstance(groups, list):
        input_error(f"'groups' が配列でない ({groups!r})。")
    for i, g in enumerate(groups):
        if not isinstance(g, list):
            input_error(f"groups[{i}] が配列でない ({g!r})。")
        if not g:
            input_error(f"groups[{i}] が空配列(size 0 の group は不正)。")
        for j, cid in enumerate(g):
            if not isinstance(cid, str):
                input_error(f"groups[{i}][{j}] が文字列でない ({cid!r})。")

    safe = data["safe"]
    if not isinstance(safe, list):
        input_error(f"'safe' が配列でない ({safe!r})。")
    for i, cid in enumerate(safe):
        if not isinstance(cid, str):
            input_error(f"safe[{i}] が文字列でない ({cid!r})。")

    candidates = data["candidates"]
    if not isinstance(candidates, dict):
        input_error(f"'candidates' がオブジェクトでない ({candidates!r})。")

    # id の重複検査(groups ∪ safe の全 id はちょうど 1 箇所に現れる。detect-dispatch-collision.py の
    # 出力不変条件を下流で fail-closed 再検証する)。
    all_ids = []
    for g in groups:
        all_ids.extend(g)
    all_ids.extend(safe)
    seen = set()
    for cid in all_ids:
        if cid in seen:
            input_error(f"id が groups ∪ safe で重複している ({cid!r})。")
        seen.add(cid)

    # groups ∪ safe の id 集合と candidates のキー集合が一致することを要求する(fail-closed)。
    # 一致しないと「kind を解決し忘れた id を無言で dispatch する / candidates にある余分な id」を
    # 見逃す。他の decision script の必須キー検証と同じ fail-closed 思想。
    cand_keys = set(candidates)
    if seen != cand_keys:
        missing = seen - cand_keys
        extra = cand_keys - seen
        input_error(
            "groups ∪ safe の id 集合と candidates のキー集合が一致しない "
            f"(candidates に無い id={sorted(missing)} / groups∪safe に無い id={sorted(extra)})。")

    kinds = {}
    for cid in seen:
        entry = candidates[cid]
        if not isinstance(entry, dict):
            input_error(f"candidates[{cid!r}] がオブジェクトでない ({entry!r})。")
        if "kind" not in entry:
            input_error(f"candidates[{cid!r}]: 必須キー 'kind' が無い。")
        kind = entry["kind"]
        if kind not in VALID_KINDS:
            input_error(
                f"candidates[{cid!r}].kind が enum 外 ({kind!r})。既知: {list(VALID_KINDS)}")
        kinds[cid] = kind

    return groups, safe, kinds


def select(groups, safe, kinds):
    dispatch = []
    carry_over = []
    injected_only = []

    # safe: 単独連結成分・非空 files。dispatch 対象候補だけ dispatch・wait 占有者は inject 専用で除外。
    for cid in safe:
        if kinds[cid] in DISPATCH_KINDS:
            dispatch.append(cid)
        else:  # wait_occupant
            injected_only.append(cid)

    # groups: fail-closed 単独候補(size==1)と恒久衝突組(size>=2)で分岐。
    for group in groups:
        if len(group) == 1:
            # fail-closed 単独候補(files=[]): 占有者の有無・代表選出によらず常に持ち越す。
            cid = group[0]
            if kinds[cid] in DISPATCH_KINDS:
                carry_over.append(cid)
            else:  # wait_occupant(非空 files で単独 safe に出るのが通常だが、files=[] の占有者も除外)
                injected_only.append(cid)
            continue

        # size>=2 の恒久衝突組。
        has_occupant = any(kinds[cid] == "wait_occupant" for cid in group)
        dispatch_cands = [cid for cid in group if kinds[cid] in DISPATCH_KINDS]
        occupants = [cid for cid in group if kinds[cid] == "wait_occupant"]

        if has_occupant:
            # live wait 占有者が居る group -> 今 tick は何も dispatch しない。
            carry_over.extend(dispatch_cands)
            injected_only.extend(occupants)
        else:
            # 占有者ゼロ group -> step id 昇順で代表 1 件だけ dispatch、残りは持ち越す。
            # (占有者ゼロ = 全メンバーが dispatch 対象候補。dispatch_cands は空にならないが、
            #  堅牢性のため空なら dispatch なしで扱う。)
            if dispatch_cands:
                rep = min(dispatch_cands)  # step id 昇順(文字列の完全順序・detect 側 sorted と整合)
                dispatch.append(rep)
                carry_over.extend(cid for cid in dispatch_cands if cid != rep)

    return {
        "dispatch": sorted(dispatch),
        "carry_over": sorted(carry_over),
        "injected_only": sorted(injected_only),
    }


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        input_error(f"stdin を JSON として読めない ({e})。")

    groups, safe, kinds = parse_input(data)
    print(json.dumps(select(groups, safe, kinds), ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
