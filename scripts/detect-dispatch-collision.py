#!/usr/bin/env python3
"""同一 tick の実装役 dispatch 候補間のファイル衝突検知。python3 標準ライブラリのみの 1 ファイル。

`commands/harness-orchestrate.md`「選別(jq)」節の判定器(issue #37・欠落 3)。
`decide-orchestrator-route.py` 等と同型の pure decision script で、同じ設計境界を守る:
「対象ファイルの抽出(issue 本文の Implementation Scope からの backtick パス収集)は prose 側 /
衝突判定(ファイル共有関係の連結成分への分割)は script 側で決定論」。

Why 切り出し(issue #37 レビュー 🟡2): 「どのファイルが衝突するか」の判定は分岐を含み(閾値の無い
機械的な前提整備とは異なる)、prose に複製すると散文分岐の取りこぼしリスクがある。既存 3 script
(decide-orchestrator-route.py / evaluate-stop-condition.py / reaggregate-has-blocker.py)と同じ
「python3 標準ライブラリのみ・pure・stdin 完結」の設計境界を守るため、対象ファイルの取得
(gh 呼出・issue 本文パース)は本 script が行わず、入力 JSON にあらかじめ含める(prose 側の責務)。

使い方:
    stdin に判定入力 JSON を渡す:
        [{"id": "<step id>", "files": ["<path>", ...]}, ...]
    stdout に判定結果 JSON を返す:
        {"groups": [["<id>", ...], ...], "safe": ["<id>", ...]}

判定規則:
- 2 つの異なる候補が files を 1 つ以上共有するなら、その 2 候補は衝突する(推移閉包を取る —
  A-B が 1 ファイル共有・B-C が別の 1 ファイル共有なら A-B-C は同一 group にまとめる)。
- files が空配列の候補は「対象ファイル不明」として fail-closed で扱う: 他候補と衝突していなくても
  単独では safe に含めず、常にその候補単独の group として `groups` に入れる(Implementation Scope
  欠落時に安全側(=保守的に別 tick へ回す)へ倒す)。
- 上記いずれにも該当しない(files が非空 かつ 他のどの候補とも共有ファイルが無い)候補は `safe`。
- `safe` と `groups` の全 id の和集合は入力の全 id 集合と一致し、互いに素(全 id はちょうど 1 箇所に
  現れる)。呼出側(prose)は `safe` の候補のみを今 tick で dispatch し、`groups` に入った候補
  (衝突する組・対象ファイル不明な候補の両方を含む)は group ごと今 tick では dispatch せず、
  marker を書き換えずに次 tick へ持ち越す。

入力(dict でない要素 / id 欠損・非文字列 / files 欠損・非配列・要素が非文字列 / id の重複)は
exit 2 + stderr(判定エラーと入力エラーを区別する。他の decision script と同じ検証スタイル)。
判定自体は groups の有無によらず exit 0。
"""

import json
import sys


def input_error(cause):
    print(f"::error:: detect-dispatch-collision: {cause}", file=sys.stderr)
    sys.exit(2)


def parse_candidates(data):
    if not isinstance(data, list):
        input_error("入力が候補の JSON 配列でない。")
    seen_ids = set()
    candidates = []
    for i, item in enumerate(data):
        if not isinstance(item, dict):
            input_error(f"candidates[{i}] がオブジェクトでない ({item!r})。")
        if "id" not in item:
            input_error(f"candidates[{i}]: 必須キー 'id' が無い。")
        cid = item["id"]
        if not isinstance(cid, str):
            input_error(f"candidates[{i}].id が文字列でない ({cid!r})。")
        if cid in seen_ids:
            input_error(f"id が重複している ({cid!r})。")
        seen_ids.add(cid)
        if "files" not in item:
            input_error(f"candidates[{i}] (id={cid!r}): 必須キー 'files' が無い。")
        files = item["files"]
        if not isinstance(files, list):
            input_error(f"candidates[{i}] (id={cid!r}).files が配列でない ({files!r})。")
        for j, f in enumerate(files):
            if not isinstance(f, str):
                input_error(f"candidates[{i}] (id={cid!r}).files[{j}] が文字列でない ({f!r})。")
        candidates.append((cid, files))
    return candidates


def detect(candidates):
    # Union-Find で「ファイルを共有する候補」の推移閉包(連結成分)を求める。
    parent = {cid: cid for cid, _ in candidates}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    file_owner = {}  # file path -> 最初にそのファイルを持った id(union の起点)
    for cid, files in candidates:
        for f in files:
            if f in file_owner:
                union(cid, file_owner[f])
            else:
                file_owner[f] = cid

    components = {}
    for cid, _ in candidates:
        components.setdefault(find(cid), []).append(cid)

    empty_ids = {cid for cid, files in candidates if not files}

    groups = []
    safe = []
    for members in components.values():
        if len(members) == 1:
            cid = members[0]
            if cid in empty_ids:
                groups.append([cid])  # fail-closed: 対象ファイル不明は単独でも safe にしない
            else:
                safe.append(cid)
        else:
            groups.append(sorted(members))

    groups.sort(key=lambda g: g[0])
    return {"groups": groups, "safe": sorted(safe)}


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        input_error(f"stdin を JSON として読めない ({e})。")

    candidates = parse_candidates(data)
    print(json.dumps(detect(candidates), ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
