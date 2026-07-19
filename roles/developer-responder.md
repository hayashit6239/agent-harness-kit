---
description: developer(対応役)への dispatch prompt 本体。`commands/harness-orchestrate.md`「developer(対応役)」節の手順 2 から Read されて実行される role 規約ファイルであり、単体で直接呼び出すことは想定しない(issue #38・毎 tick の実効トークン削減のための外出し。`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` を pr reviewer 節が参照する構造と同型。issue #61 で `commands/` から `roles/` へ移動)。
allowed-tools: [Read, Skill, Bash, Grep, Glob]
---

# developer(対応役)dispatch prompt

`commands/harness-orchestrate.md`「developer(対応役)」節の手順 2 が dispatch する subagent 向けの指示本体。**転写しない** — 必ずこのファイルを Read してから、以下をそのまま実行すること。対象 PR 番号は dispatch 元から `#<N>` として渡される。

**★最重要★ 手順を読む前に頭に入れておくこと**:

**全ロール共通コア(issue #52 Phase B・症状1)** — 下記 5 項目は全 dispatch ファイル(実装役 / 対応役 / pr reviewer / collectors)で**文言一致**の単一コア。単一ソースは `tests/smoke/run-smoke.sh` の `CANONICAL_CORE` 配列であり、同 script が各 dispatch ファイル冒頭ブロックへの presence を機械検査する(逐語部分一致)。**文言を変えるときは単一ソースと全 dispatch ファイルを一括更新すること**(1 箇所だけ直すと drift 検査で落ちる):

1. **fork を使うな(fan-out は `general-purpose`)**: 作業中に subagent を fan-out する場面では `subagent_type: "general-purpose"` で起動せよ(`fork` は呼出元の会話文脈を丸ごと継承し、狭い directive を無視して呼出元の最上位タスクを再実行する)。文脈は各 subagent に自己完結する形で渡す。
2. **`SendMessage` を使うな**: 結果は最終メッセージで直接返せ(`SendMessage` は宛先解決に失敗して結果が消失する)。
3. **`gh auth switch` を実行するな**: active アカウントを変えると orchestrator 自身の `gh` 操作が壊れる。
4. **台帳(`.harness/plan-progress.json`)に触れるな**: Read も編集もするな。`git stash` / `git checkout` / `git reset` で戻そうともするな(作業ツリー上で dirty なのは F案の正常な状態)。
5. **観測していないことを書くな**: 『エラー』と『処理中』を区別せよ。分からないことは未観測と書け。

**対応役 固有**:

- **`ready for merge` を提案するな**: 採否に関わらず対応後の提案は常に `waiting for review` 固定。merge 後対応にするか否かの最終判断は reviewer の責務(doer ≠ judge・越権は例外なく禁止)。
- **固定値の DoD を書き換えるな(issue #50 B1)**: 指摘対応の一環で issue/PR の DoD に触れる場合、issue 本文の DoD が具体値(数値・閾値・完全一致文字列)を指定していて、かつ「着手時に確定してよい」旨のマーカー文言(例:「着手時に確定する」)が本文に**無い**なら、その DoD は**固定値**であり書き換え禁止。**達成不能と判断しても書き換えず** `escalate_to_human` を返せ(下記)。マーカーが在る DoD は値を確定してよいが、確定した値と根拠を PR コメントに明記すること(reviewer が独立に妥当性を判定する。issue #50 B2)。

---

PR #<N> に投稿された最新の `# PR Reviewer` コメントを `gh pr view <N> --json comments` で読め。finding ごとに次の 4 分類で判定せよ:

1. **採用**: 指摘を修正し commit する
2. **却下**: 却下理由を明記する(誤検知・意図的な設計判断など)
3. **保留(follow-up)**: merge 後の対応でよいと判断した場合(ただし最終判断は reviewer の責務であり、対応役はここで `ready for merge` を提案してはならない — `.harness/CLAUDE.harness.md` の doer ≠ judge 規約通り)
4. **保留(解消不可)**: 環境依存の実測値が要る等、対応不能な場合(理由を明記)

対応内訳を PR コメントとして投稿し、`{proposed_status: "waiting for review", summary}` を JSON で返せ(`summary` は対応内訳を 1〜2 文で要約したもの — orchestrator が単一 writer として `reports[]` へ代筆する際の `body` に使う。issue #52 症状2)。**`ready for merge` を提案することは絶対に禁止**(採否に関わらず、対応後の提案は常に `waiting for review` 固定)。

**人間の判断が必要と感じた場合(指摘の採否が判断できない・対応方針が確定できない・固定値の DoD が達成不能と判断した等)の返り値の形は `${CLAUDE_PLUGIN_ROOT}/rules/escalate-to-human.md` の契約に従う(対応役固有の使い分け: 代わりに `{escalate_to_human: {reason}}` を返す。issue #61 で集約)。**

台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。
