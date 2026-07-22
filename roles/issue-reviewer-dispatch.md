---
description: issue reviewer への dispatch prompt 本体。`commands/harness-orchestrate.md`「issue reviewer」節が dispatch する subagent 向けの指示で、着手前 issue のレビュー判定をラップして「台帳・ラベルに触れず `contracts/issue-reviewer-return.schema.json` の形で返す」よう指示する。単体で直接呼び出すことは想定しない (PR 側 `roles/pr-reviewer-dispatch.md` と対称。issue #88 で新設・issue #93 で判定エンジンを kit 同梱化)。**判定エンジンは 2 モード (PR 側 `code-review` / `multi-angle` と対称・issue #93)**: 既定 `ISSUE_REVIEW_MODE=spec` は kit 同梱の判定 spec (`roles/issue-reviewer.md`・8 観点 / 3 ファミリー rubric を inline) を Read して実行する可搬構成 (PR 既定 `code-review` を issue #49 で可搬化したのと同型)。opt-in `ISSUE_REVIEW_MODE=skill` は個人 skill `reviewing-github-issues` へ委譲する非可搬 path (PR opt-in `multi-angle` と対称)。他 repo は既定モードだけで動く issue-reviewer を得る (skill 不在でも既定の spec 経路で完結し、opt-in 指定時に skill 不在なら既定へ fail-soft)。
allowed-tools: [Read, Skill, Bash, Grep, Glob]
---

# issue reviewer dispatch prompt

`commands/harness-orchestrate.md`「issue reviewer」節が dispatch する subagent 向けの指示本体。**転写しない** — 必ずこのファイルを Read してから、以下をそのまま実行すること。対象 issue 番号は dispatch 元から `#<N>` として、review-mode(既定 `spec`)は `$ISSUE_REVIEW_MODE` として渡される。

**★最重要★ 手順を読む前に頭に入れておくこと**:

**全ロール共通コア(issue #52 Phase B・症状1)** — 下記 5 項目は全 dispatch ファイル(実装役 / 対応役 / pr reviewer / collectors / issue reviewer / issue review worker / product manager)で**文言一致**の単一コア。単一ソースは `tests/smoke/run-smoke.sh` の `CANONICAL_CORE` 配列であり、同 script が各 dispatch ファイル冒頭ブロックへの presence を機械検査する(逐語部分一致)。**文言を変えるときは単一ソースと全 dispatch ファイルを一括更新すること**(1 箇所だけ直すと drift 検査で落ちる):

1. **fork を使うな(fan-out は `general-purpose`)**: 作業中に subagent を fan-out する場面では `subagent_type: "general-purpose"` で起動せよ(`fork` は呼出元の会話文脈を丸ごと継承し、狭い directive を無視して呼出元の最上位タスクを再実行する)。文脈は各 subagent に自己完結する形で渡す。
2. **`SendMessage` を使うな**: 結果は最終メッセージで直接返せ(`SendMessage` は宛先解決に失敗して結果が消失する)。
3. **`gh auth switch` を実行するな**: active アカウントを変えると orchestrator 自身の `gh` 操作が壊れる。
4. **台帳(`.harness/plan-progress.json`)に触れるな**: Read も編集もするな。`git stash` / `git checkout` / `git reset` で戻そうともするな(作業ツリー上で dirty なのは F案の正常な状態)。
5. **観測していないことを書くな**: 『エラー』と『処理中』を区別せよ。分からないことは未観測と書け。

**issue reviewer 固有**:

- **ラベル操作は orchestrator 専権(reviewer は触らない)**: `ready for implementation` / `need for human review` 等のラベル同期は単一書込主体である orchestrator が行う。reviewer がラベルに触ると台帳と drift する。
- **判定エンジンは 2 モード(既定=kit 同梱 spec / opt-in=個人 skill・可搬化済み・issue #93)**: 既定 `ISSUE_REVIEW_MODE=spec` は kit 同梱の判定 spec `${CLAUDE_PLUGIN_ROOT}/roles/issue-reviewer.md`(8 観点 / 3 ファミリー rubric を parity 深さで inline)を Read して実行する — PR 側の既定 `code-review`(#49 で可搬化)と対称の**可搬構成**で、他 repo は skill 無しでも動く。opt-in `ISSUE_REVIEW_MODE=skill` は個人 skill `reviewing-github-issues` へ委譲する非可搬 path(PR opt-in `multi-angle` と対称)。**kit 版 spec と個人 skill の rubric drift は機械検知不可・best-effort 手動同期**(個人 skill は repo 外 `~/.claude/skills` にあり smoke から読めない — 受容コストの正直な明記。詳細は `roles/issue-reviewer.md`「kit 版 rubric と個人 skill の drift」節)。どちらのモードでも判定ロジック(8 観点 rubric)は変更しない。
- **evidence gate 相当は無い(issue #88・正直な限界)**: issue フェーズには実行して落とせる証拠(test)が構造的に無い。有界化は下記の停止条件機構(round 上限 / blocker trend → escalate)と `issueReviewLock` の hang 検知が担い、「偽の前進」検知は次 round の issue reviewer 別セッション読取に一本化される(PR responder の evidence gate より構造的に弱い)。

---

## レビュー本文の生成(モード分岐 — issue #93)

`$ISSUE_REVIEW_MODE`(既定 `spec`)に応じて判定エンジンを選ぶ。**どちらのモードでも成果物は同じ**「レビュー本文 + `has_blocker`(🔴 が 1 件以上で true)」で、以降の wrapper 責務(blocker_count / escalate / marker / 投稿)は共通。**既定は kit 同梱 spec 経路**であり、個人 skill 委譲は opt-in 分岐の内側にある(既定を skill にしない — 他 repo で skill 不在でも動くのが issue #93 の核心)。

### 既定モード(`ISSUE_REVIEW_MODE=spec`)— kit 同梱 spec を Read して実行

`$ISSUE_REVIEW_MODE` が未指定 or `spec`(既定)の場合、`${CLAUDE_PLUGIN_ROOT}/roles/issue-reviewer.md` を Read し、そこに書かれた 8 観点 / 3 ファミリー rubric・ワークフロー・出力フォーマット・原則をそのまま issue #<N> に適用してレビュー本文を生成せよ(この spec が判定 rubric の本体・kit 同梱で可搬)。手順本体は転写しない — 必ずファイルを Read してから実行すること。spec はレビュー**本文を組み立てるだけ**でコメント投稿・マーカー埋込・ラベル付与・台帳書込はしない(それらは下記の wrapper 責務)。判定ロジック(8 観点 rubric)は変更しない。

### opt-in モード(`ISSUE_REVIEW_MODE=skill`)— 個人 skill `reviewing-github-issues` へ委譲

`$ISSUE_REVIEW_MODE == "skill"` が明示指定された場合に限り、`Skill` ツールで `reviewing-github-issues` を起動し、issue #<N> のレビュー本文を生成せよ(この個人 skill は kit 非同梱・作者環境専用の熟成 rubric。skill はレビュー**本文を返すだけ**でコメント投稿・ラベル付与・issue 編集はしない)。skill の返り値は `{review_markdown, has_blocker, recommended_label?}`。判定ロジックは変更しない。**skill 不在時のフォールバック**: opt-in 指定でも個人 skill が導入先に無い場合は **kit 既定モード(上記 spec 経路)へ fail-soft** し、tick 報告に「opt-in skill 不在のため既定 spec へフォールバック」の 1 行を残す(hard fail より配布先で壊れにくい — 「kit で完結」の目的と整合)。

---

続いて **dispatch wrapper(あなた)の責務**として次を補完する(判定エンジン(spec / skill)は blocker_count / escalate / marker / 投稿を持たないため):

1. **blocker_count を算出する**: `review_markdown` 中の 🔴 の件数を数える(issue reviews は arch/google のような source 区別が無い単一 source のため、PR 側の `reaggregate-has-blocker.py` に相当する再集計 script は使わない — 🔴 の件数がそのまま blocker_count)。
2. **round と prev_markers を算出する**: issue #<N> の既存コメントのうち `<!-- harness-review-issue:` マーカーを持つ件数 + 1 を `round` とする(PR 側 `harness-review-pr:` と対称の `harness-` 名前空間・両フェーズ共通の marker 走査が単一 prefix 族で成立する・round1 🟡9)。`prev_markers` は同じ `<!-- harness-review-issue:` マーカー行を most-recent-first(直近が先頭)で最大 2 件抽出する(`gh issue view <N> --json comments` の本文から grep)。
3. **escalate を補完する**: `{round, has_blocker, blocker_count, prev_markers}` を stdin に `${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-stop-condition.py` へ渡し(**同 script は無改修で流用** — marker パーサ `blocker_count=(\d+)` が prefix 非依存のため issue-review マーカーをそのまま食える)、返った `escalate` を採用する。
4. **marker を埋め込み投稿する**: `review_markdown` の末尾に `<!-- harness-review-issue: round=<N> has_blocker=<B> blocker_count=<M> escalate=<E> -->`(PR 側 `<!-- harness-review-pr: ... -->` と同型・`harness-` 名前空間で対称・round1 🟡9)を付けて、H1 を `# Issue Reviewer - レビュー実施`(PR 側 `# PR Reviewer - レビュー実施` と対称・ロール判別用)としたコメントを issue #<N> へ `gh issue comment` で投稿する(投稿は dispatch wrapper の専権であり、本コマンドの触らないものではない)。
5. **`recommended_label` は捨てる**: skill が返す任意の `recommended_label` は issue に適用しない・返り値契約にも載せない(ラベル同期は単一書込主体 orchestrator の専権で、issue フェーズラベルは `need for human review` のみ)。

最後に、`contracts/issue-reviewer-return.schema.json` が規定する形(`{has_blocker, blocker_count, escalate, review_markdown}`)を JSON で返せ(`review_markdown` は手順 4 で組み立てたコメント本文)。

**レビュー中に人間の判断が必要と感じた場合(判定が付かない・専門知識が必要等)の返り値の形は `${CLAUDE_PLUGIN_ROOT}/rules/escalate-to-human.md` の契約に従う(issue reviewer 固有の使い分け: 加えて `escalate_to_human: {reason}` を返してよい — 他フィールドとの共存可・客観的な `escalate` とは独立のシグナル)。**

台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。
