# escalate_to_human — 3 role 共通返り値契約

developer(実装役)・developer(対応役)・pr reviewer の 3 role が dispatch prompt で共通して持つ、委譲先自身による人間への主観的エスカレーション経路(issue #31・A案)。各 dispatch prompt ファイル(`${CLAUDE_PLUGIN_ROOT}/roles/developer-implementer.md` / `${CLAUDE_PLUGIN_ROOT}/roles/developer-responder.md` / `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer-dispatch.md`)はこの契約を参照し、文言を複製しない(issue #61。pr reviewer 分は issue #52 Phase B で `commands/harness-orchestrate.md` の inline dispatch prompt から `roles/pr-reviewer-dispatch.md` へ外出しした)。

`gh auth switch` 禁止・fork 禁止・観測していないこと原則・`SendMessage` 禁止・台帳保護の 5 項目は本ファイルの対象外(`#52` Phase B の担当領域。各 dispatch ファイル冒頭にインラインのまま残る)。

## 契約

作業中に「これは人間の判断を仰ぎたい」と判断した場合、通常の返り値の代わりに(pr reviewer のみ、通常の返り値に加えて)次の形を返してよい:

```json
{"escalate_to_human": {"reason": "<理由>"}}
```

- `reason` は空でない文字列であること。**検出条件(JSON として解釈できるか・`escalate_to_human.reason` の有無)・形式検証の唯一の正は `commands/harness-orchestrate.md`「主観的エスカレーション(issue #31・A案)」節の「最小の形式検証(A案)」** — ここでは複製しない。
- 3 role とも同じフィールド名・同じ形にする(発火機構の統一)。

## role ごとの使い分け(排他性)

- **developer(実装役)**: PR を作成した場合は通常どおり `{pr_number, proposed_status, summary}` を返す。人間の判断が必要と感じた場合は **PR を作らずに** 代わりに `{escalate_to_human: {reason}}` を返す(両方を返す必要がある状況は無い — v1 は「完了 or 主観エスカレーション」の二択。issue #31 set1 Implementation Scope 6 の決定)。
- **developer(対応役)**: 対応内訳を投稿した場合は通常どおり `{proposed_status: "waiting for review", summary}` を返す。人間の判断が必要と感じた場合は代わりに `{escalate_to_human: {reason}}` を返す。
- **pr reviewer**: 判定確定時は通常どおり `contracts/reviewer-return.schema.json` が規定する形(`{has_blocker, blocker_count, escalate, review_markdown}`)を返す。レビュー中に人間の判断が必要と感じた場合は、**加えて** `escalate_to_human: {reason}`(同 schema の任意プロパティ)を返してよい(他フィールドとの共存可 — 客観的な `escalate`(round/blocker trend の停止条件)とは独立のシグナル)。

## orchestrator 側の扱い(参照のみ・ここでは複製しない)

検出条件・outcome 解決(`subjective_escalate`)・sink 経路・marker の扱いは `commands/harness-orchestrate.md`「主観的エスカレーション(issue #31・A案)」節および「ルーティング判定」節が唯一の正。
