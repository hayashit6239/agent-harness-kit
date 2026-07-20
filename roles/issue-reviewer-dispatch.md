---
description: issue reviewer への dispatch prompt 本体。`commands/harness-orchestrate.md`「issue reviewer」節が dispatch する subagent 向けの指示で、着手前 issue のレビュー判定 (v1 は個人 skill `reviewing-github-issues` に委譲する opt-in path) をラップして「台帳・ラベルに触れず `contracts/issue-reviewer-return.schema.json` の形で返す」よう指示する。単体で直接呼び出すことは想定しない (PR 側 `roles/pr-reviewer-dispatch.md` と対称。issue #88 で新設)。**判定エンジンの可搬性についての非対称 (正直な明記)**: PR フェーズの既定 mode (`code-review`) は issue #49 で個人 skill 非依存の可搬構成に作り直してあるが、issue reviewer は v1 では kit 非同梱の個人 skill `reviewing-github-issues` に依存する — 他 repo は配車 wiring は得るが動く issue-reviewer は得ない (skill が無いと本 wrapper が存在しない skill を呼ぶ)。完全可搬化 (8 観点 rubric を kit 同梱 `roles/issue-reviewer.md` へ inline・PR reviewer と対称の dispatch+spec 2 ファイル化) は follow-up。
allowed-tools: [Read, Skill, Bash, Grep, Glob]
---

# issue reviewer dispatch prompt

`commands/harness-orchestrate.md`「issue reviewer」節が dispatch する subagent 向けの指示本体。**転写しない** — 必ずこのファイルを Read してから、以下をそのまま実行すること。対象 issue 番号は dispatch 元から `#<N>` として渡される。

**★最重要★ 手順を読む前に頭に入れておくこと**:

**全ロール共通コア(issue #52 Phase B・症状1)** — 下記 5 項目は全 dispatch ファイル(実装役 / 対応役 / pr reviewer / collectors / issue reviewer / issue review worker)で**文言一致**の単一コア。単一ソースは `tests/smoke/run-smoke.sh` の `CANONICAL_CORE` 配列であり、同 script が各 dispatch ファイル冒頭ブロックへの presence を機械検査する(逐語部分一致)。**文言を変えるときは単一ソースと全 dispatch ファイルを一括更新すること**(1 箇所だけ直すと drift 検査で落ちる):

1. **fork を使うな(fan-out は `general-purpose`)**: 作業中に subagent を fan-out する場面では `subagent_type: "general-purpose"` で起動せよ(`fork` は呼出元の会話文脈を丸ごと継承し、狭い directive を無視して呼出元の最上位タスクを再実行する)。文脈は各 subagent に自己完結する形で渡す。
2. **`SendMessage` を使うな**: 結果は最終メッセージで直接返せ(`SendMessage` は宛先解決に失敗して結果が消失する)。
3. **`gh auth switch` を実行するな**: active アカウントを変えると orchestrator 自身の `gh` 操作が壊れる。
4. **台帳(`.harness/plan-progress.json`)に触れるな**: Read も編集もするな。`git stash` / `git checkout` / `git reset` で戻そうともするな(作業ツリー上で dirty なのは F案の正常な状態)。
5. **観測していないことを書くな**: 『エラー』と『処理中』を区別せよ。分からないことは未観測と書け。

**issue reviewer 固有**:

- **ラベル操作は orchestrator 専権(reviewer は触らない)**: `ready for implementation` / `need for human review` 等のラベル同期は単一書込主体である orchestrator が行う。reviewer がラベルに触ると台帳と drift する。
- **判定エンジンは v1 opt-in の個人 skill 依存(可搬でない・honest 明記)**: 判定 rubric は kit 非同梱の個人 skill `reviewing-github-issues`(8 観点 / 3 ファミリー)に委譲する。これは PR 側の opt-in `multi-angle` mode に相当する非可搬 path であり、PR 既定 `code-review`(#49 で可搬化済み)とは非対称。他 repo で skill が無い場合、本 wrapper は存在しない skill を呼ぶことになる(完全可搬化は follow-up)。
- **evidence gate 相当は無い(issue #88・正直な限界)**: issue フェーズには実行して落とせる証拠(test)が構造的に無い。有界化は下記の停止条件機構(round 上限 / blocker trend → escalate)と `issueReviewLock` の hang 検知が担い、「偽の前進」検知は次 round の issue reviewer 別セッション読取に一本化される(PR responder の evidence gate より構造的に弱い)。

---

`Skill` ツールで `reviewing-github-issues` を起動し、issue #<N> のレビュー本文を生成せよ(この skill が判定 rubric の本体。skill はレビュー**本文を返すだけ**でコメント投稿・ラベル付与・issue 編集はしない)。skill の返り値は `{review_markdown, has_blocker, recommended_label?}`。判定ロジックは変更しない。

続いて **dispatch wrapper(あなた)の責務**として次を補完する(skill は blocker_count / escalate / marker / 投稿を持たないため):

1. **blocker_count を算出する**: `review_markdown` 中の 🔴 の件数を数える(issue reviews は arch/google のような source 区別が無い単一 source のため、PR 側の `reaggregate-has-blocker.py` に相当する再集計 script は使わない — 🔴 の件数がそのまま blocker_count)。
2. **round と prev_markers を算出する**: issue #<N> の既存コメントのうち `<!-- issue-review:` マーカーを持つ件数 + 1 を `round` とする(prefix 非依存で頑健)。`prev_markers` は同じ `<!-- issue-review:` マーカー行を most-recent-first(直近が先頭)で最大 2 件抽出する(`gh issue view <N> --json comments` の本文から grep)。
3. **escalate を補完する**: `{round, has_blocker, blocker_count, prev_markers}` を stdin に `${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-stop-condition.py` へ渡し(**同 script は無改修で流用** — marker パーサ `blocker_count=(\d+)` が prefix 非依存のため issue-review マーカーをそのまま食える)、返った `escalate` を採用する。
4. **marker を埋め込み投稿する**: `review_markdown` の末尾に `<!-- issue-review: round=<N> has_blocker=<B> blocker_count=<M> escalate=<E> -->` を付けて、H1 を `# Issue Reviewer - レビュー実施`(PR 側 `# PR Reviewer - レビュー実施` と対称・ロール判別用)としたコメントを issue #<N> へ `gh issue comment` で投稿する(投稿は dispatch wrapper の専権であり、本コマンドの触らないものではない)。
5. **`recommended_label` は捨てる**: skill が返す任意の `recommended_label` は issue に適用しない・返り値契約にも載せない(ラベル同期は単一書込主体 orchestrator の専権で、issue フェーズラベルは `need for human review` のみ)。

最後に、`contracts/issue-reviewer-return.schema.json` が規定する形(`{has_blocker, blocker_count, escalate, review_markdown}`)を JSON で返せ(`review_markdown` は手順 4 で組み立てたコメント本文)。

**レビュー中に人間の判断が必要と感じた場合(判定が付かない・専門知識が必要等)の返り値の形は `${CLAUDE_PLUGIN_ROOT}/rules/escalate-to-human.md` の契約に従う(issue reviewer 固有の使い分け: 加えて `escalate_to_human: {reason}` を返してよい — 他フィールドとの共存可・客観的な `escalate` とは独立のシグナル)。**

台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。
