---
description: developer(実装役)への dispatch prompt 本体。`commands/harness-orchestrate.md`「developer(実装役)」節の手順 2 から Read されて実行される内部フラグメントであり、単体で `/harness-dispatch-implementer` として直接呼び出すことは想定しない(issue #38・毎 tick の実効トークン削減のための外出し。`commands/harness-review-pr.md` を pr reviewer 節が参照する構造と同型)。
allowed-tools: [Read, Skill, Bash, Grep, Glob]
---

# developer(実装役)dispatch prompt

`commands/harness-orchestrate.md`「developer(実装役)」節の手順 2 が dispatch する subagent 向けの指示本体。**転写しない** — 必ずこのファイルを Read してから、以下をそのまま実行すること。対象 issue 番号は dispatch 元から `#<N>` として渡される。

**★最重要★ 手順を読む前に頭に入れておくこと(issue #37)**:

1. 作業中に `/code-review` 等が内部で finder / verifier を fan-out する場面に出会ったら `subagent_type: "general-purpose"` で起動させよ(`fork` を使わない。fork は呼出元の会話文脈を丸ごと継承し、狭い directive を無視して呼出元の最上位タスクを再実行する不具合が実測されている。文脈は各 subagent に自己完結する形で渡す)。
2. `gh auth switch` を実行するな(active アカウントを変えると orchestrator 自身の `gh` 操作が壊れる)。
3. 観測していないことを書くな。『エラー』と『処理中』を区別せよ。分からないことは未観測と書け。

---

対象 issue #<N> の本文(Problem/Context/Alternatives/Implementation Scope/DoD)を `gh issue view <N>` で Read せよ。次に `creating-git-worktrees` skill を Skill ツールで起動し、その手順に従って worktree を作成せよ。issue の Implementation Scope に従って実装せよ。実装後、`creating-gh-prs` skill を Skill ツールで起動し、その手順に従って PR を作成せよ(base は main、`Closes #<N>` を本文に含める)。最後に `{pr_number, proposed_status, summary}`(`proposed_status` は通常 `"created pr"`。`summary` は実装内容を 1〜2 文で要約したもの — orchestrator が単一 writer として `reports[]` へ代筆する際の `body` に使う。issue #52 症状2)を JSON で返せ。

**人間の判断が必要と感じた場合(実装方針が確定できない・issue の指示が矛盾する等)は、PR を作らずに代わりに `{escalate_to_human: {reason}}` を返してよい(両方を返す必要がある状況は無い — issue #31・v1 は「完了 or 主観エスカレーション」の二択)。**

台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。
