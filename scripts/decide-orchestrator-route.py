#!/usr/bin/env python3
"""orchestrator の失敗経路ルーティング判定器。python3 標準ライブラリのみの 1 ファイル。

`commands/harness-orchestrate.md` のルーティング判定器。LLM の散文解釈で分岐させず、
ここで (role, outcome) → (ledger_write, route, label_action) を決定論的に解決する。
`evaluate-stop-condition.py` / `reaggregate-has-blocker.py` と同型の pure decision script で、
同じ設計境界を守る:「状況を outcome トークンに解決するのは LLM (orchestrator prose) 側 /
ルーティング規則の適用は script 側で決定論」。

Why 切り出し: orchestrator の失敗経路ルーティングが全て散文だと、分岐の取りこぼし
(例: reviewer の dispatch 結果失敗を単一 sink に落とす分岐の欠落) を回帰検知できない。
規則を本 script に集約し smoke で全 (role × outcome) を網羅すれば、散文分岐の齟齬を機械的に塞げる。

入出力の型/形 (envelope) の正: contracts/orchestrator-route.schema.json (issue #68 で抽出。
definitions.input / definitions.output)。以下の「使い方」は同じ形の運用向け説明であり、
形の単一の正はその schema 側 — ルーティング規則 (どの outcome がどう解決するか) の正は本ファイルの
DECISION_TABLE。

使い方:
    stdin に判定入力 JSON を渡す:
        {"role": "<implementer|responder|reviewer|issue-reviewer|issue-review-worker>",
         "outcome": "<token>",
         "observation": <sink 系 outcome のみ必須。下記「観測必須フィールド (A1)」参照>}
    outcome トークン (role ごとに定義。orchestrator prose が状況をこのトークンに解決してから渡す):
      - implementer: no_pr / ambiguous / pr_evidence_pass / pr_evidence_fail / timeout / subjective_escalate
      - responder:   evidence_pass / evidence_fail / timeout / subjective_escalate
      - reviewer:    invalid / escalate / clean_pass / blockers / timeout / subjective_escalate
      - issue-reviewer: invalid / escalate / clean_pass / blockers / timeout / subjective_escalate
        (reviewer を issue フェーズへ写したもの。issue #88。ledger_write は pr.status ではなく
         issue.status を書く。clean_pass の遷移先は "ready for implementation"(issue reviewer の
         天井 = PR の "ready for merge" と対称)。ラベルは issue 側の "ready for implementation")
      - issue-review-worker: done / subjective_escalate / timeout
        (responder を issue フェーズへ写したもの。issue #88。ただし issue フェーズには実行して
         落とせる証拠 (test) が構造的に無いため、responder の evidence_pass/evidence_fail 二分岐は
         持てず、単一の前進 outcome "done"(→ "waiting for review")のみ。"ready for implementation"
         は worker からは書けない = issue-reviewer の clean_pass 経由でのみ到達する doer≠judge の構造担保)

観測必須フィールド (A1・issue #50 round1 決定 🔴1 + owner 決定 (b)):
    `route=sink` に解決する (role, outcome) の組は、判定入力に `observation`
    (「観測した事実」= コマンド + 終了コード + 出力要約の構造化フィールド) を必須で持たせる。
    無ければ判定器は受け付けず exit 2 (fail-closed。`role`/`outcome` 必須キーの検証と同じ
    スタイルで、`reconcile-dispatch-marker.py` の fail-closed 思想を踏襲する)。
        {"command": "<str, 非空>", "exit_code": <int (bool 不可)>, "summary": "<str, 非空>"}
    route が `sink` でない (role, outcome) には `observation` は不要 (渡されても無視する) —
    既存の `{role, outcome}` 入力契約はそのまま維持し、この検証は追加のみで既存呼出を壊さない。

    **Why sink のみに絞るか**: issue #50 の振り返り(悪かった点 #1)が示した実害は例外なく
    「orchestrator prose が状況を sink 系 outcome へ解決する」段で起きた (7 回すべて)。
    正常系 (`normal`/`skip`) の断定コストを一律に上げても実害箇所を塞がない。

    **spoof 可能性を正直に明記する (owner 決定 (b)・issue #50)**: この検証は `observation` の
    **存在・型**を確認するだけで、**内容の真偽は検証しない** — prose (orchestrator 自身) が
    虚偽の観測を書けばそのまま通る。独立した第二の判定者は存在しない。issue #50 の owner は
    「症状1 (orchestrator/doer 自身の sink 判断) の常用経路は独立検証ゼロを正直に受容する」と
    決定した (#17 round2 の Statuses API 自己申告「security boundary ではなく便宜シグナル」と
    同じ流儀)。本フィールドが上げるのは **捏造コスト** (書かなければ即 exit 2 で止まる・書けば
    虚偽でも通る) だけであり、真の独立検証ではない。**症状2 (DoD 書き換え) とは非対称** —
    そちらは PR reviewer という独立読み手 (別セッション) が居るため機械的に塞がれるが、症状1
    (orchestrator が sink へ倒す判断そのもの) には対称の独立読み手が存在しない。この非対称は
    構造的なものであり、本 script 単体では解消しない (詳細: issue #50 本文「レビュー反映 —
    決定事項(round1/round2)」+ owner 決定コメント)。

`timeout` (issue #26): dispatch の in-flight マーカー (`scripts/reconcile-dispatch-marker.py` が
判定) が (a) 締切超過でリトライ上限 (N=2) に到達した、または (b) マーカーが壊れている/不整合
(fail-closed) と判定したときに解決する outcome。**P1 決定 (issue #26 所有者判断) により `no_pr`
(完了したが PR 未作成) は独立に観測できる枝ではなく、締切超過と同じリトライカウンタに畳み込まれる**
— したがって `no_pr` の連続発生が `reconcile-dispatch-marker.py` でリトライ上限に到達した場合も
この `timeout` outcome に解決する (`no_pr` outcome 自体は 1 回ごとの skip 判定のまま変更しない)。

`timeout` (reviewer / responder・issue #71): reviewer / 対応役の `reviewLock` が
`reconcile-dispatch-marker.py` (max_retries=0) で締切超過 (hang) と判定されたときに解決する
outcome。reviewLock は正常時 dispatch した同一 tick 内で削除されるため、次 tick 以降まで残ること
自体が「dispatch call がセッションを止めた真の hang」のシグナルになる。実装役 timeout と対称に
`ledger_write=null` (hang は無状態 tick では検証不能なので status 遷移を捏造しない)・route=sink。
reviewer の `invalid` (不正 JSON = dispatch 結果失敗) とは別事象のため別 outcome にする
(observation で混同させない)。役割 (reviewer か responder か) は reconciliation 側が pr.status から
解決する (`commands/harness-orchestrate.md`「tick 冒頭 reconciliation」節)。
    stdout に判定結果 JSON を返す:
        {"ledger_write": <null|{...}>, "route": "<normal|skip|sink>",
         "label_action": "<null|add_ready_for_merge|remove_ready_for_merge|"
                         "add_ready_for_implementation|remove_ready_for_implementation>"}
        (add/remove_ready_for_implementation は issue-reviewer の clean_pass/blockers 用・issue #88。
         PR の ready for merge ラベルを issue フェーズの ready for implementation ラベルへ写したもの)

route の意味:
  - normal = 台帳書込のみ (ledger_write があれば書く)。sink・ラベル以外の副作用なし。
  - skip   = 書込なし・副作用なしで次 tick 再試行 (PR 未作成など、状態が変わるまで待つ)。
  - sink   = 失敗経路 (need for human review ラベル + PushNotification)。ledger_write が非 null
             なら書いた上で sink する (実装役 evidence 失敗は「PR は実在する」事実を書いてから sink。
             reviewer の escalate は「停止条件到達」事実として pr.status="need for human review" を
             書いてから sink する)。

`subjective_escalate` (issue #31・3 role 共通): 委譲先 (実装役 / 対応役 / reviewer) が dispatch 応答で
`escalate_to_human: {reason}` (reason は空でない文字列) を返した場合に解決する outcome。既存の客観的な
`escalate` (reviewer が `evaluate-stop-condition.py` で算出する round/blocker trend) とは別のトリガーだが、
合流先は同じ need for human review sink。脅威モデル (issue #31 Problem 節で確定): この経路の唯一の力は
「人間の注意を得る」ことのみで、merge・台帳書込・越権実行はできない (capability 分離・単一書込・
evidence gate が別途封鎖済み) — 悪用されても実害は「人間が無駄に見る」に留まる fail-safe 方向。
**PR 未作成の実装役** (`pr.number` が確定していない場合) は進める PR が無いため `ledger_write=None`
(書込なし) で sink する (`no_pr`/`ambiguous` と同型の空状態)。**実装役が PR 作成後に主観エスカレーション
する複合ケース (完了と申告の同時) は v1 では扱わない** (issue #31 set1 Implementation Scope 6 の決定:
v1 は「完了 (pr_number 返却) or 主観エスカレーション」の二択。実装役が両方を返しても
`escalate_to_human` を優先しこの outcome に解決する — pr_number 側の扱いは follow-up)。
`reason` が空・欠損・非文字列の場合は形式不正として扱い、この outcome には解決しない
(呼出側 prose が `escalate_to_human` 自体を無視し通常の outcome 解決へフォールバックする —
この形式検証は本 script の入力に reason 自体を含まないため prose 側の責務。詳細は
`commands/harness-orchestrate.md`「主観的エスカレーション」節)。

ledger_write の "pr.number": true は「呼出側 (orchestrator prose) が持つ pr_number を書く」ことを
示す真偽フラグ。本 script は具体的な PR 番号を知らない (pure decision) ため真偽で返し、実際の
番号埋め込みは prose 側が行う。他のキー ("pr.githubState" / "pr.status") は書き込むリテラル値を
そのまま返す。

不正入力 (dict でない / role が enum 外 / outcome が role に対応しない / 必須キー欠損 / 型不正) は
exit 2 + stderr (判定エラーと入力エラーを区別する。evaluate-stop-condition.py と同じ検証スタイル)。
判定自体は route の値によらず exit 0。
"""

import json
import sys

# (role, outcome) → 決定結果。ルーティング規則の唯一の正 (prose に決定表を複製しない)。
# reviewer の "invalid" → sink が、dispatch 結果失敗 (subagent クラッシュ / 不正 JSON /
# escalate を読めない) を単一 sink に落とす分岐。実装役の復旧検索・対応役の evidence gate と
# 対称に、reviewer にも dispatch 失敗分岐を持たせて「reviewer だけ単一 sink をすり抜ける」を塞ぐ。
DECISION_TABLE = {
    "implementer": {
        # PR 未作成 (返答不正 かつ 復旧検索 0 件): 書込なしで次 tick 再試行
        "no_pr": {
            "ledger_write": None, "route": "skip", "label_action": None},
        # 復旧検索が複数一致 (曖昧): 誤番号を書かず sink
        "ambiguous": {
            "ledger_write": None, "route": "sink", "label_action": None},
        # pr_number 確定 かつ evidence exit 0: 台帳書込のみ
        "pr_evidence_pass": {
            "ledger_write": {
                "pr.number": True, "pr.githubState": "open",
                "pr.status": "created pr"},
            "route": "normal", "label_action": None},
        # pr_number 確定 かつ evidence 非 0: 「PR は実在する」事実を書いた上で sink
        "pr_evidence_fail": {
            "ledger_write": {
                "pr.number": True, "pr.githubState": "open",
                "pr.status": "created pr"},
            "route": "sink", "label_action": None},
        # in-flight マーカーが締切超過でリトライ上限 (N=2) に到達、または壊れている/不整合
        # (fail-closed): PR が実在しない (pr.number は null のまま) ため ambiguous と同型で
        # 書込なし・sink (issue #26・P1 決定で no_pr はここに畳み込まれる)
        "timeout": {
            "ledger_write": None, "route": "sink", "label_action": None},
        # 主観的エスカレーション (issue #31): PR 未作成の実装役が escalate_to_human で
        # 「人間の判断が必要」と自己申告。進める PR が無いため書込なしで sink
        # (no_pr/ambiguous と同型の空状態。PR 作成後の複合ケースは v1 対象外 — 上記 docstring 参照)
        "subjective_escalate": {
            "ledger_write": None, "route": "sink", "label_action": None},
    },
    "responder": {
        # evidence exit 0: 再レビュー待ちへ
        "evidence_pass": {
            "ledger_write": {"pr.status": "waiting for review"},
            "route": "normal", "label_action": None},
        # evidence 非 0: 書込なし (status は completed review のまま = 未解決 blocker が残る事実) で sink
        "evidence_fail": {
            "ledger_write": None, "route": "sink", "label_action": None},
        # 主観的エスカレーション (issue #31): 対応役は既に PR が実在するため、reviewer の
        # escalate と同じく「need for human review」への遷移を書いてから sink する
        "subjective_escalate": {
            "ledger_write": {"pr.status": "need for human review"},
            "route": "sink", "label_action": None},
        # reviewLock が締切超過 (hang) と判定された (issue #71): 対応役 dispatch が
        # セッションを止めたため判定物が無い。hang は検証不能なので status 遷移を捏造せず
        # 書込なしで sink (実装役 timeout の ledger_write=null と対称)。reviewLock 自体は
        # reconciliation 側の変則手続きで削除せず notified で永続化する (reviewer/timeout と同型)
        "timeout": {
            "ledger_write": None, "route": "sink", "label_action": None},
    },
    "reviewer": {
        # dispatch 結果失敗 (返答が JSON でない / escalate を読めない): 書込なしで sink
        "invalid": {
            "ledger_write": None, "route": "sink", "label_action": None},
        # 停止条件到達 (escalate=true): 「need for human review」への遷移を書いてから sink
        # (ready for merge と対称に、reviewer が設定できる終端手前の状態。issue #12 決定事項)
        "escalate": {
            "ledger_write": {"pr.status": "need for human review"},
            "route": "sink", "label_action": None},
        # escalate=false かつ has_blocker=false: merge 可へ進め、ラベル付与
        "clean_pass": {
            "ledger_write": {"pr.status": "ready for merge"},
            "route": "normal", "label_action": "add_ready_for_merge"},
        # escalate=false かつ has_blocker=true: 手戻りへ戻し、merge 可ラベルを外す
        "blockers": {
            "ledger_write": {"pr.status": "completed review"},
            "route": "normal", "label_action": "remove_ready_for_merge"},
        # 主観的エスカレーション (issue #31): reviewer 自身が escalate_to_human で
        # 「人間の判断が必要」と自己申告。客観的な escalate (evaluate-stop-condition.py 算出) とは
        # 別物だが同じ sink に合流させる。escalate と同じく書いてから sink する
        "subjective_escalate": {
            "ledger_write": {"pr.status": "need for human review"},
            "route": "sink", "label_action": None},
        # reviewLock が締切超過 (hang) と判定された (issue #71): reviewer dispatch が hang。
        # invalid (不正 JSON = dispatch 結果失敗) とは別事象で observation を混同させないため
        # 別 outcome にする。hang は検証不能なので書込なしで sink (実装役 timeout と対称)
        "timeout": {
            "ledger_write": None, "route": "sink", "label_action": None},
    },
    # issue-reviewer (issue #88): reviewer を issue フェーズへ写す。ledger_write は issue.status を書く。
    # PR reviewer との唯一の非対称は「判定エンジンが v1 では kit 非同梱の個人 skill
    # reviewing-github-issues に依存する opt-in path」である点だが、これはルーティング (本 table)
    # ではなく dispatch wrapper (roles/issue-reviewer-dispatch.md) 側の関心事で、本 table は PR
    # reviewer と同型 (invalid/escalate/clean_pass/blockers/subjective_escalate/timeout の 6 outcome)。
    "issue-reviewer": {
        # dispatch 結果失敗 (返答が JSON でない / escalate を読めない): 書込なしで sink
        "invalid": {
            "ledger_write": None, "route": "sink", "label_action": None},
        # 停止条件到達 (escalate=true): 「need for human review」への遷移を書いてから sink
        # (ready for implementation と対称に、issue reviewer が設定できる終端手前の状態。issue #12 の
        # PR 版結線を issue フェーズへ写す — status を書いてから sink するのでラベル除去だけでは再 dispatch されない)
        "escalate": {
            "ledger_write": {"issue.status": "need for human review"},
            "route": "sink", "label_action": None},
        # escalate=false かつ has_blocker=false: 実装着手可へ進め、ラベル付与
        # (issue reviewer の天井 = ready for implementation。PR reviewer の ready for merge と対称)
        "clean_pass": {
            "ledger_write": {"issue.status": "ready for implementation"},
            "route": "normal", "label_action": "add_ready_for_implementation"},
        # escalate=false かつ has_blocker=true: 対応待ちへ戻し、実装着手可ラベルを外す
        "blockers": {
            "ledger_write": {"issue.status": "completed review"},
            "route": "normal", "label_action": "remove_ready_for_implementation"},
        # 主観的エスカレーション (issue #31): issue reviewer 自身が escalate_to_human で
        # 「人間の判断が必要」と自己申告。escalate と同じく書いてから sink する
        "subjective_escalate": {
            "ledger_write": {"issue.status": "need for human review"},
            "route": "sink", "label_action": None},
        # issueReviewLock が締切超過 (hang) と判定された (issue #88・PR の reviewLock timeout と対称):
        # issue reviewer dispatch が hang。hang は検証不能なので書込なしで sink
        "timeout": {
            "ledger_write": None, "route": "sink", "label_action": None},
    },
    # issue-review-worker (issue #88): responder を issue フェーズへ写す。ただし issue フェーズには
    # 実行して落とせる証拠 (test) が構造的に無いため、responder の evidence_pass/evidence_fail の
    # 二分岐 (evidence gate) を持てない。前進 outcome は単一の "done" のみ (→ waiting for review)。
    # worker は "ready for implementation" を書けない = ready for implementation は issue-reviewer の
    # clean_pass 経由でのみ到達する (doer≠judge を構造で担保。個人 wrapper working-triaged-issues-for-loop
    # の「ready for implementation の設定は絶対禁止」を kit の decision table に落とす)。
    "issue-review-worker": {
        # 指摘対応が済んだ: 再レビュー待ちへ (責め返す reviewer の再検出に一本化される — evidence gate が
        # 無いため「偽の前進」= 無作業 dispatch でも done へ進む。PR responder より構造的に弱い正直な限界)
        "done": {
            "ledger_write": {"issue.status": "waiting for review"},
            "route": "normal", "label_action": None},
        # 主観的エスカレーション (issue #31): worker は既に issue が実在するため、reviewer の
        # escalate と同じく「need for human review」への遷移を書いてから sink する
        "subjective_escalate": {
            "ledger_write": {"issue.status": "need for human review"},
            "route": "sink", "label_action": None},
        # issueReviewLock が締切超過 (hang) と判定された (issue #88): worker dispatch が hang。
        # hang は検証不能なので書込なしで sink (責め返し不能な twins の PR responder/timeout と対称)
        "timeout": {
            "ledger_write": None, "route": "sink", "label_action": None},
    },
}


def input_error(cause):
    print(f"::error:: decide-orchestrator-route: {cause}", file=sys.stderr)
    sys.exit(2)


def require_str(data, key):
    if key not in data:
        input_error(f"必須キー '{key}' が無い。")
    v = data[key]
    if not isinstance(v, str):
        input_error(f"'{key}' が文字列でない ({v!r})。")
    return v


def require_observation(data):
    """A1 (issue #50): route=sink への解決には observation (観測した事実) を必須とする。
    存在・型のみ検証する (内容の真偽は検証しない・spoof 可能。モジュール docstring
    「観測必須フィールド (A1)」参照)。不備があれば他の必須キー検証と同じ exit 2 (fail-closed)。"""
    if "observation" not in data:
        input_error(
            "route=sink の解決には 'observation' (観測した事実) が必須。"
            "{'command': str, 'exit_code': int, 'summary': str} の形で渡すこと"
            " (issue #50 A1・fail-closed)。")
    obs = data["observation"]
    if not isinstance(obs, dict):
        input_error(f"'observation' がオブジェクトでない ({obs!r})。")
    for key in ("command", "summary"):
        if key not in obs:
            input_error(f"observation に必須キー '{key}' が無い。")
        if not isinstance(obs[key], str) or not obs[key]:
            input_error(f"observation.'{key}' が非空文字列でない ({obs[key]!r})。")
    if "exit_code" not in obs:
        input_error("observation に必須キー 'exit_code' が無い。")
    exit_code = obs["exit_code"]
    if not isinstance(exit_code, int) or isinstance(exit_code, bool):
        input_error(f"observation.'exit_code' が整数でない ({exit_code!r})。")


def decide(role, outcome):
    by_outcome = DECISION_TABLE.get(role)
    if by_outcome is None:
        input_error(f"role が enum 外 ({role!r})。既知: {sorted(DECISION_TABLE)}")
    result = by_outcome.get(outcome)
    if result is None:
        input_error(
            f"outcome {outcome!r} が role {role!r} に対応しない。"
            f"既知: {sorted(by_outcome)}")
    return result


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        input_error(f"stdin を JSON として読めない ({e})。")
    if not isinstance(data, dict):
        input_error("入力が判定 JSON オブジェクトでない。")

    role = require_str(data, "role")
    outcome = require_str(data, "outcome")

    result = decide(role, outcome)
    if result["route"] == "sink":
        # A1 (issue #50): sink 系 outcome への解決だけ観測必須 (fail-closed)。
        # normal/skip は既存の {role, outcome} 契約のまま変更しない。
        require_observation(data)

    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
