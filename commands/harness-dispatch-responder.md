---
description: developer(対応役)への dispatch prompt 本体。`commands/harness-orchestrate.md`「developer(対応役)」節の手順 2 から Read されて実行される内部フラグメントであり、単体で `/harness-dispatch-responder` として直接呼び出すことは想定しない(issue #38・毎 tick の実効トークン削減のための外出し。`commands/harness-review-pr.md` を pr reviewer 節が参照する構造と同型)。
allowed-tools: [Read, Skill, Bash, Grep, Glob]
---

# developer(対応役)dispatch prompt

`commands/harness-orchestrate.md`「developer(対応役)」節の手順 2 が dispatch する subagent 向けの指示本体。**転写しない** — 必ずこのファイルを Read してから、以下をそのまま実行すること。対象 PR 番号は dispatch 元から `#<N>` として渡される。

**★最重要★ 手順を読む前に頭に入れておくこと(issue #37)**:

1. 作業中に内部で subagent を fan-out する場面に出会ったら `subagent_type: "general-purpose"` で起動させよ(`fork` を使わない。文脈は各 subagent に自己完結する形で渡す)。
2. `gh auth switch` を実行するな(active アカウントを変えると orchestrator 自身の `gh` 操作が壊れる)。
3. 観測していないことを書くな。『エラー』と『処理中』を区別せよ。分からないことは未観測と書け。

---

PR #<N> に投稿された最新の `# PR Reviewer` コメントを `gh pr view <N> --json comments` で読め。finding ごとに次の 4 分類で判定せよ:

1. **採用**: 指摘を修正し commit する
2. **却下**: 却下理由を明記する(誤検知・意図的な設計判断など)
3. **保留(follow-up)**: merge 後の対応でよいと判断した場合(ただし最終判断は reviewer の責務であり、対応役はここで `ready for merge` を提案してはならない — `.harness/CLAUDE.harness.md` の doer ≠ judge 規約通り)
4. **保留(解消不可)**: 環境依存の実測値が要る等、対応不能な場合(理由を明記)

対応内訳を PR コメントとして投稿し、`{proposed_status: "waiting for review", summary}` を JSON で返せ(`summary` は対応内訳を 1〜2 文で要約したもの — orchestrator が単一 writer として `reports[]` へ代筆する際の `body` に使う。issue #52 症状2)。**`ready for merge` を提案することは絶対に禁止**(採否に関わらず、対応後の提案は常に `waiting for review` 固定)。

**人間の判断が必要と感じた場合(指摘の採否が判断できない・対応方針が確定できない等)は、代わりに `{escalate_to_human: {reason}}` を返してよい。**

台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。
