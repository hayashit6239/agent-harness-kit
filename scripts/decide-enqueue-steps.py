#!/usr/bin/env python3
"""discover→enqueue の純 enqueue/dedup 判定器 (issue #78・能力3 v1=A / issue #107 で epic 除外拡張 /
issue #111 で `Depends-on: #N` → 台帳 `dependsOn` 変換を追加)。
python3 標準ライブラリのみの 1 ファイル。

`commands/harness-orchestrate.md` の「discover→enqueue フェーズ」の判定器。
`decide-orchestrator-route.py` / `reconcile-dispatch-marker.py` / `evaluate-stop-condition.py`
と同型の pure decision script で、同じ設計境界を守る:「network な発見 (ラベル付き open issue の
問い合わせ) と台帳への書込 (append) は prose / orchestrator 側 / dedup・batch 採番・step 雛形生成・
epic 除外・`Depends-on` marker parse・依存解決の決定論的な判定は script 側」。**network 非依存・
LLM 非依存**なので `tests/smoke/run-smoke.sh` の決定論テストに乗る (issue #78 round2 🟡1 のテスト境界)。

3 層分離 (issue #78 round2 🔴2) の**中間層**を担う:
  1. network discover (orchestrator の prose・smoke 対象外): `gh issue list --label <discover-label>
     --state open --json number,labels,title,body` で候補 issue と epic 判定材料 + 本文を得る。
  2. 純 enqueue/dedup/epic 除外/依存変換 (本 script・smoke 対象): {候補, 現台帳の steps} →
     {追加 step 群 / no-op, fail-closed skip した候補群}。
  3. 台帳書込 (orchestrator・単一 writer): 本 script が返す追加 step を台帳へ append し、`skipped` を
     human へ 1 行 relay する。
本 script は発見も書込もしない (候補と現 steps を受け取り、追加すべき step 群と skip 群を返すだけ)。

確定した仕様 (issue #78 の round1/round2 レビューで収束・issue #107 で epic 除外・issue #111 で依存変換):
  - **epic 除外 fail-safe (issue #107・D1)**: `isEpic: true` の候補は enqueue 対象から**決定論的に
    落とす** (dedup / 採番の前段で drop する。id 番号を消費しない)。**除外は batch 全体・順序非依存**
    (round1 🟡6): 同一 batch 内で同じ number が epic と非 epic の両形で現れても (退化入力) その number は
    enqueue しない (epic 判定を先に batch 全体から集めてから畳む)。epic は最下層の実装単位ではなく
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
    - **id は dedup 生存候補へ pass 1 で先行割当する (issue #111・D1)**: 依存解決 (pass 2) の前に
      candidate 順で全 dedup 生存候補へ id を確定する。後で fail-closed skip される候補も pass 1 で
      id を消費する (skip 候補の id は出力に出ないため id 番号に gap が出るが、validator は id の連続性を
      要求しないため無害。skip の有無に依らず生存候補の id が決まる決定論的性質を優先する)。
  - **新規 id は既存台帳の形式に追随する** (issue #78 round1 🔴)。この repo の実台帳は `P1`..`P21`
    のような **`P<n>` 形式** を採るため、`P<n>` 台帳へ enqueue すると新 id は `P<max+1>` になる
    (旧実装は `int(sid)` で `P<n>` を全除外し起点を 1 に落とす = id 名前空間の分断だった)。純数値
    台帳なら従来どおり `<max+1>`。採番スキーム (prefix と最大数値) は `_id_scheme` を参照。
  - **`Depends-on: #N` → 台帳 `dependsOn` 変換 (issue #111)**: PM が issue 本文へ書く機械可読な依存
    マーカーを、enqueue 時に台帳の `dependsOn` (依存 **step id** の一覧) へ変換する。PM の書込境界を
    「GitHub のみ」に保ったまま、台帳反映を単一 writer (orchestrator の enqueue) が担う経路を繋ぐ。
    - **marker parse (D3)**: `_parse_depends_on` が候補の `body` から `Depends-on: #N` を parse する。
      `rules/issue-tree.md` §4.2 (`Part of #<N>` prose 規約) の parse の *形* を新規移植: リテラル
      `Depends-on:` (先頭大文字・case sensitive) + 空白 + `#<連続数字>`。表記ゆれ非許容・コードフェンス
      (```) と引用 (行頭 `>`) の内側は除外。複数依存 (1 行複数 `#N` / 複数 `Depends-on:` 行) を許容し
      distinct union を取る。**`Depends-on` 書式の暫定唯一の正は本 parser (script + docstring)** で
      (issue #111・D6)、authoring 側 doc への書式追記は #107/#109 の領分。
    - **番号 → step id 解決 (2-pass・D1)**: マーカーは issue 番号・台帳 `dependsOn` は step id という
      表現ギャップを 2-pass で埋める。pass 1 = id 先行割当 (上記)。pass 2 = 各候補の依存先番号を
      「既存 step の `issue.number` → step id」∪「同一 batch で pass 1 に割り当てた number → 割当予定 id」
      で解決する。
    - **接地 (grounding) の least fixpoint = 推移的 skip 閉包 (D8)**: pass 2 の解決を単発の rule 適用では
      なく不動点計算にする。ある候補が **enqueue 可能 (grounded)** であるのは、その依存集合の全 `#N` が
      (i) 既存 step、または (ii) **別の grounded な同一 batch 候補**に解決するとき、かつそのときに限る。
      依存が既存 step のみ (batch 内依存なし) の候補を初期集合とし、「全依存先が既存 step か既に grounded」
      の候補を反復追加して不動点まで回す。不動点で grounded にならなかった候補が **fail-closed skip 集合**。
      この 1 条件が (a) 未解決 `#N` (D1-iii)、(b) self-loop、(c) 同一 batch 循環、(d) 推移 skip (skip された
      候補への依存元) の 4 ケースを同時に閉じ、**ghost id を構造的に出さない** — enqueue される候補の
      `dependsOn` は定義上すべて「既存 step か enqueue される batch 候補」を指すため、
      `validate-plan-progress.py` が reject する `dependsOn` (非存在 step id / self-loop / 循環) を出力しない。
    - **skip の surface (D9)**: fail-closed skip した候補は stdout の `skipped: [{number, reason}]` へ出す
      (`{"enqueue":[…], "skipped":[…]}`)。**exit code は 0 を維持** (skip は判定結果であって入力エラーでは
      ない)。`reason` は非接地要因を区別する (`self-loop` / `unresolved-dependency` / `cycle` /
      `unresolved-transitive`)。**dedup no-op と既存終端 no-op は `enqueue` にも `skipped` にも出さない**
      (`skipped` は「変換器が依存 fail-closed で意図的に落とした候補」だけに絞る)。orchestrator prose は
      同じ JSON の `skipped` を読んで human へ 1 行 relay する (D2 の緩和の閉ループ)。
    - **受容コスト (D5)**: dedup key = `issue.number` のため、既に step 化済みの issue に後から
      `Depends-on:` を足しても no-op で台帳へ届かない (変換は enqueue 時 1 回きり・後付けは未反映)。
      `Depends-on` は当該 issue に `discover` を付ける前 (= 初回 enqueue 前) に書くことで回避できる。
      再同期経路は follow-up 候補。
  - **step 雛形** (round1 🟡1・schema `step.required=[id, issue, pr]` を充足):
      {"id": "<既存形式の max+1 以降の string。例: P<n> 台帳なら P<max+1>>",
       "issue": {"number": <N>, "status": "created issue", "githubState": "open"},
       "pr": {"number": null, "status": null, "githubState": null},
       "dependsOn": [<解決済み step id>, ...]}  # 依存が無ければ dependsOn キー自体を省略 (round1 🟡1)
    依存が空の候補は `dependsOn` キーを付けない (自動 enqueue step は依存なし = 常に eligible の従来挙動)。
    `created issue` は ready 系でないため個別 evidence 不要 (top-level evidence を継承・本 script は
    evidence を書かない)。
  - **空入力 = no-op** (round1 🟡2)。候補が空なら追加 step は空。dedup / epic 除外で全滅した場合も空。
  - **batch 内の重複も dedup**: 同一 tick の候補リストに同じ `issue.number` が複数現れたら 1 件だけ
    enqueue する (既存 step との突合と同じ key で、走査済みの batch 内 number も突合対象に加える)。

**入力契約 (candidates 要素・issue #107 で拡張・issue #111 が後方拡張した共有契約)**:
  `candidates` 要素は次の 2 形を受理する (後方互換 + 前方拡張):
    - **裸の int** (`78`): `{number: 78, isEpic: false, body: ""}` の短縮形として扱う (issue #78 の元契約・
      後方互換)。epic 判定材料・依存マーカー無し = 除外しない・依存なし。
    - **dict** (`{"number": 78, "isEpic": true, "body": "...", ...}`): `number` (bool を除く int) を必須、
      `isEpic` (bool・省略時 false) と `body` (string・省略時 "") を任意に持つ。**その他のキーは無視して
      読み飛ばす** — 破壊的変更なしに前方拡張できる点として残す (issue #107 が epic 除外用に切り、
      issue #111 が `body` を後付けした着地順 = #107 先行 → #111 追随・issue #107 round2 🟡1)。
      `body` 欠損 / null / 空文字は「依存なし」= 後方互換 (D4)。既存 smoke fixture (裸 int 相当) は
      body 無し = 依存なしとして従来挙動不変。
  裸の int と dict は同一 `candidates` 配列に混在してよい (要素ごとに正規化する)。

使い方:
    stdin に判定入力 JSON を渡す:
        {
          "candidates": [<int | {"number": <int>, "isEpic": <bool>, "body": <string>, ...}>, ...],
          "steps": [<step object>, ...]                # 現台帳の steps 配列 (dedup / max id / 依存解決の突合元)
        }
    stdout に判定結果 JSON を返す:
        {"enqueue": [<追加すべき step object>, ...],    # 空配列 = no-op
         "skipped": [{"number": <int>, "reason": <str>}, ...]}  # 依存 fail-closed で落とした候補 (空配列 = 無し)

不正入力 (dict でない / candidates が list でない / 要素が int でも dict でもない / dict 要素に
有効な `number` が無い / `isEpic` が bool でない / `body` が string でも null でもない / steps が list
でない / steps 要素が dict でない) は exit 2 + stderr (判定エラーと入力エラーを区別する。他の decision
script と同じ検証スタイル)。判定自体 (enqueue / skip の中身によらず) は exit 0。

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


# `Depends-on:` marker (先頭大文字・case sensitive・表記ゆれ非許容・issue #111・D3)。
_DEPENDS_ON_MARKER = re.compile(r"Depends-on:")
# マーカーが所有する `#N` の run を 1 件ずつ食う (カンマ / 空白区切り・複数 `#N` を許容・D3-ii)。
_DEP_NUM_RUN = re.compile(r"[,\s]*#([0-9]+)")


def _parse_depends_on(body):
    """issue 本文から `Depends-on: #N` マーカーを parse し、依存先 issue 番号の distinct union を
    出現順で返す (issue #111・D3。**書式の暫定唯一の正 = 本 parser・D6**)。

    `rules/issue-tree.md` §4.2 (`Part of #<N>` prose 規約) の parse の *形* を `Depends-on` へ新規移植:
      - (i) リテラル `Depends-on:` (先頭大文字・case sensitive) + 空白 + `#<連続数字>`。数字以外で停止。
        **表記ゆれ (全角・大文字小文字違い・空白無し) は許容しない** (deterministic parse 優先)。
        **コードフェンス (```) と引用 (行頭 `>`) の内側は除外** — 規約説明・他 issue 引用の偶発言及を
        拾わない (§4.2 と同じ除外)。
      - (ii) 複数依存 (§4.2 に前例なし・#111 の新規決定): **1 行に複数 `#N` (カンマ / 空白区切り) と
        複数 `Depends-on:` 行の双方を許容し、全マーカーの `#N` の distinct union** を依存集合とする
        (§4.2 が複数 distinct `Part of` を union で扱うのと対称)。
      - (iii) 走査範囲: 本文全体 (フェンス・引用を除外)。行頭限定にしない (§4.2 と同じく mid-line も拾う)。

    body が str でない / 空なら [] (依存なし・後方互換 D4)。返り値は int の list (出現順・distinct)。
    """
    if not isinstance(body, str) or not body:
        return []
    numbers = []
    seen = set()
    in_fence = False
    for line in body.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("```"):
            in_fence = not in_fence  # フェンスの開始 / 終了行そのものも除外 (トグル後 continue)
            continue
        if in_fence:
            continue
        if stripped.startswith(">"):
            continue  # 引用行は除外 (他 issue の引用に含まれる偶発マーカーを拾わない)
        for marker in _DEPENDS_ON_MARKER.finditer(line):
            pos = marker.end()
            # (i) 「Depends-on: + 空白」を要求する — 直後が空白でなければこのマーカーは無効
            #     (`Depends-on:#5` のような空白無しは deterministic parse として拾わない)。
            if pos >= len(line) or not line[pos].isspace():
                continue
            # マーカーが所有する `#N` の run を consume する (カンマ / 空白区切りで連結・(ii))。
            # `#N` でも区切りでもないトークンに当たったら停止 (§4.2 の「数字以外で停止」と同型)。
            while pos < len(line):
                m = _DEP_NUM_RUN.match(line, pos)
                if m is None:
                    break
                n = int(m.group(1))
                if n not in seen:
                    seen.add(n)
                    numbers.append(n)
                pos = m.end()
    return numbers


def _normalize_candidate(c):
    """候補要素を `(number, is_epic, depends_numbers)` に正規化する
    (issue #107 で epic 拡張・issue #111 で依存マーカー parse を追加した共有契約)。

    受理する 2 形 (後方互換 + 前方拡張):
      - **裸の int** (`78`): `(78, False, [])`。epic 判定材料・依存マーカー無し (#78 元契約)。
      - **dict** (`{"number": 78, "isEpic": true, "body": "...", ...}`): `number` (bool を除く int) 必須・
        `isEpic` (bool・省略時 False) 任意・`body` (string・省略時 "") 任意。**その他のキーは無視して
        読み飛ばす**。`body` から `Depends-on: #N` を parse して依存先 issue 番号 list を得る (issue #111)。
    それ以外 (str / bool / list / None / number の無い dict / isEpic 非 bool / body 非 str・非 null) は
    input_error で exit 2 (判定エラーと入力エラーの区別・他の decision script と同じ流儀)。"""
    if _is_valid_int(c):
        return c, False, []
    if isinstance(c, dict):
        number = c.get("number")
        if not _is_valid_int(number):
            input_error(
                f"'candidates' の dict 要素に有効な整数 'number' が無い ({c!r})。")
        is_epic = c.get("isEpic", False)
        if not isinstance(is_epic, bool):
            input_error(
                f"'candidates' の dict 要素の 'isEpic' が真偽値でない ({c!r})。")
        body = c.get("body")
        if body is not None and not isinstance(body, str):
            input_error(
                f"'candidates' の dict 要素の 'body' が文字列でも null でもない ({c!r})。")
        return number, is_epic, _parse_depends_on(body)
    input_error(
        f"'candidates' の要素が整数でも {{number, isEpic, body}} dict でもない ({c!r})。")


def _existing_number_to_id(steps):
    """現台帳の全 step から `issue.number` (有効な int) → step id の写像を返す
    (dedup の突合元 + 依存解決 (番号→id) の解決元・issue #111)。

    status は見ない — 終端 step も含めて number だけで突合する (round1 🔴2)。step / issue / id が
    欠けている・number が無い等の部分データは寛容に読み飛ばす (台帳の schema 妥当性は
    validate-plan-progress.py が別途担保する。本 script は number の突合と id 解決だけに責務を絞る)。
    同一 number が複数 step にある退化台帳では最初に現れた step の id を採る (決定論)。"""
    mapping = {}
    for step in steps:
        if not isinstance(step, dict):
            continue
        issue = step.get("issue")
        sid = step.get("id")
        if (isinstance(issue, dict) and _is_valid_int(issue.get("number"))
                and isinstance(sid, str) and sid):
            mapping.setdefault(issue["number"], sid)
    return mapping


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


def _skip_reason(survivor, existing, batch_numbers, batch_deps):
    """非接地 (skip) と判定された dedup 生存候補について、skip 要因を区別する文字列を返す
    (issue #111・D9。`reason` は「skip トリガーを区別できる粒度」が要件)。

    優先順に判定する (複数該当時は上を採る・決定論):
      1. `self-loop`         — 自番号に依存 (`#自番号`)。schema の self-loop reject を出さないため落とす。
      2. `unresolved-dependency` — 既存 step でも batch 生存候補でもない `#N` を直接持つ (D1-iii)。
                                    typo / 未 enqueue の依存先。human が surface で気付く緩和の入口。
      3. `cycle`             — batch 生存候補内の依存グラフで自分自身へ到達する (同一 batch 循環)。
      4. `unresolved-transitive` — 上のいずれでもないが、skip された batch 候補への依存で連鎖 skip
                                   (D8 の推移的 skip 閉包で巻き込まれた依存元)。
    """
    number = survivor["number"]
    deps = survivor["deps"]
    if number in deps:
        return "self-loop"
    for d in deps:
        if d not in existing and d not in batch_numbers:
            return "unresolved-dependency"
    # batch 内依存グラフ (batch 生存候補への辺のみ) で自分自身に到達できれば循環。
    if _reaches_self(number, batch_deps):
        return "cycle"
    return "unresolved-transitive"


def _reaches_self(start, batch_deps):
    """batch 生存候補内の依存グラフ (`batch_deps`: number -> [batch 依存先 number, ...]) で、
    `start` から 1 辺以上たどって `start` へ戻れるか (循環に属すか) を返す (issue #111・_skip_reason 用)。
    self-loop (start が自番号を持つ) も True になるが、_skip_reason 側で self-loop を先に判定するため
    ここへは非 self-loop の循環だけが実質到達する。"""
    visited = set()
    stack = list(batch_deps.get(start, []))
    while stack:
        node = stack.pop()
        if node == start:
            return True
        if node in visited:
            continue
        visited.add(node)
        stack.extend(batch_deps.get(node, []))
    return False


def decide_enqueue(normalized, steps):
    """正規化済み候補 `[(number, is_epic, deps), ...]` と現台帳 steps から、追加すべき step 群と
    fail-closed skip した候補群を返す (純関数・決定論)。
    epic 除外 (issue #107) → dedup + id 先行割当 (pass 1) → 接地の least fixpoint による依存解決
    (pass 2・issue #111・D8) → step 雛形生成 (`dependsOn` 付与) の順で決定論的に畳む。

    **epic 除外は batch 全体・順序非依存** (issue #107 round1 🟡6): 同一 batch 内に同じ number が
    epic と非 epic の両形で現れる退化入力でも、その number は enqueue しない (epic_numbers で先に
    集めてから畳む)。

    **接地の least fixpoint (issue #111・D8)**: enqueue される候補の `dependsOn` は定義上すべて
    「既存 step か enqueue される batch 候補」を指すため、`validate-plan-progress.py` が reject する
    `dependsOn` (非存在 step id / self-loop / 循環) を構造的に出力しない (ghost id を出さない)。"""
    existing_map = _existing_number_to_id(steps)
    existing = set(existing_map.keys())
    prefix, current_max = _id_scheme(steps)
    next_num = current_max + 1
    # epic 除外 fail-safe を batch 全体・順序非依存にするため epic の number を先に集める
    # (issue #107・D1 / round1 🟡6)。id 番号は消費しない (集めるだけ・enqueue しない)。
    epic_numbers = {number for number, is_epic, _deps in normalized if is_epic}

    # --- pass 1: epic 除外 + dedup + id 先行割当 (issue #111・D1) --------------------------------
    # dedup を通過した候補へ candidate 順で id を先に全件割り当てる (依存を見ずに id だけ確定)。
    # 後で skip される候補も id を消費する (skip 候補の id は出力に出ない = gap は無害・validator は
    # id の連続性を要求しない)。survivors は candidate 順を保つ。
    survivors = []  # [{"number", "deps", "id"}]
    seen = set()    # batch 内で既に採用した number (batch 内重複の dedup)
    for number, is_epic, deps in normalized:
        if is_epic or number in epic_numbers:
            # epic 除外 fail-safe (issue #107・D1): id 番号を消費せず落とす (dedup も skipped も出さない)。
            continue
        if number in existing or number in seen:
            # dedup: 既存 step と一致 (終端含む) or batch 内既出 = no-op (skipped にも出さない・D9)。
            continue
        seen.add(number)
        survivors.append({
            "number": number,
            "deps": deps,
            "id": f"{prefix}{next_num}",
        })
        next_num += 1

    batch_numbers = {s["number"] for s in survivors}
    batch_id = {s["number"]: s["id"] for s in survivors}
    # batch 生存候補内の依存グラフ (batch への辺のみ・循環判定 / 推移 skip の解決に使う)。
    batch_deps = {
        s["number"]: [d for d in s["deps"] if d in batch_numbers]
        for s in survivors
    }

    # --- pass 2: 接地 (grounding) の least fixpoint (issue #111・D8) -----------------------------
    # grounded = 依存集合の全 `#N` が「既存 step」or「別の grounded な batch 候補」に解決する候補。
    # 依存が既存 step のみ (batch 内依存なし) の候補を初期集合とし不動点まで反復追加する。
    # 不動点で grounded にならなかった生存候補が fail-closed skip 集合。
    grounded = set()
    changed = True
    while changed:
        changed = False
        for s in survivors:
            number = s["number"]
            if number in grounded:
                continue
            if all(d in existing or d in grounded for d in s["deps"]):
                grounded.add(number)
                changed = True

    # --- step 雛形生成 + skip surface ------------------------------------------------------------
    enqueue = []
    skipped = []
    for s in survivors:
        number = s["number"]
        if number in grounded:
            # 依存先番号を step id へ解決する (既存 step → step id / batch 生存候補 → 割当予定 id)。
            # grounded の定義上、各 `#N` は existing か batch_id のどちらかに必ず解決する (ghost id 不発)。
            depends_on = [existing_map[d] if d in existing else batch_id[d]
                          for d in s["deps"]]
            step = {
                "id": s["id"],
                "issue": {"number": number, "status": "created issue", "githubState": "open"},
                "pr": {"number": None, "status": None, "githubState": None},
            }
            if depends_on:
                # 依存が無ければ dependsOn キー自体を省略する (自動 enqueue step は依存なし = 常に
                # eligible の従来挙動・round1 🟡1)。依存があるときだけ付与する。
                step["dependsOn"] = depends_on
            enqueue.append(step)
        else:
            skipped.append({
                "number": number,
                "reason": _skip_reason(s, existing, batch_numbers, batch_deps),
            })
    return {"enqueue": enqueue, "skipped": skipped}


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
