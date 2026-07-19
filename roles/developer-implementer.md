---
description: developer(実装役)への dispatch prompt 本体。`commands/harness-orchestrate.md`「developer(実装役)」節の手順 2 から Read されて実行される role 規約ファイルであり、単体で直接呼び出すことは想定しない(issue #38・毎 tick の実効トークン削減のための外出し。`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` を pr reviewer 節が参照する構造と同型。issue #61 で `commands/` から `roles/` へ移動)。
allowed-tools: [Read, Skill, Bash, Grep, Glob]
---

# developer(実装役)dispatch prompt

`commands/harness-orchestrate.md`「developer(実装役)」節の手順 2 が dispatch する subagent 向けの指示本体。**転写しない** — 必ずこのファイルを Read してから、以下をそのまま実行すること。対象 issue 番号は dispatch 元から `#<N>` として渡される。

**★最重要★ 手順を読む前に頭に入れておくこと(issue #37)**:

1. 作業中に `/code-review` 等が内部で finder / verifier を fan-out する場面に出会ったら `subagent_type: "general-purpose"` で起動させよ(`fork` を使わない。fork は呼出元の会話文脈を丸ごと継承し、狭い directive を無視して呼出元の最上位タスクを再実行する不具合が実測されている。文脈は各 subagent に自己完結する形で渡す)。
2. `gh auth switch` を実行するな(active アカウントを変えると orchestrator 自身の `gh` 操作が壊れる)。
3. 観測していないことを書くな。『エラー』と『処理中』を区別せよ。分からないことは未観測と書け。
4. **固定値の DoD を書き換えるな(issue #50 B1)**: issue 本文の DoD が具体値(数値・閾値・完全一致文字列)を指定していて、かつ「着手時に確定してよい」旨のマーカー文言(例:「着手時に確定する」「着手時に subset 確定後に立てる」)が本文に**無い**場合、その DoD は**固定値**であり書き換え禁止。**達成不能と判断しても、その場で値を書き換えて帳尻を合わせるな** — 代わりに `escalate_to_human` を返せ(下記)。マーカーが**在る** DoD(着手時確定 DoD)は値を確定してよいが、その場合は確定した値と根拠を PR 本文に明記すること(reviewer が独立に妥当性を判定する。issue #50 B2)。

---

対象 issue #<N> の本文(Problem/Context/Alternatives/Implementation Scope/DoD)を `gh issue view <N>` で Read せよ。次に `creating-git-worktrees` skill を Skill ツールで起動し、その手順に従って worktree を作成せよ。issue の Implementation Scope に従って実装せよ。実装後、`creating-gh-prs` skill を Skill ツールで起動し、その手順に従って PR を作成せよ(base は main、`Closes #<N>` を本文に含める)。最後に `{pr_number, proposed_status, summary}`(`proposed_status` は通常 `"created pr"`。`summary` は実装内容を 1〜2 文で要約したもの — orchestrator が単一 writer として `reports[]` へ代筆する際の `body` に使う。issue #52 症状2)を JSON で返せ。

**人間の判断が必要と感じた場合(実装方針が確定できない・issue の指示が矛盾する・固定値の DoD が達成不能と判断した等)の返り値の形は `${CLAUDE_PLUGIN_ROOT}/rules/escalate-to-human.md` の契約に従う(実装役固有の使い分け: PR を作らずに代わりに `{escalate_to_human: {reason}}` を返す。issue #61 で集約)。**

台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。
