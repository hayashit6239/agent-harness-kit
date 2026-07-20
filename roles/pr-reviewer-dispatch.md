---
description: pr reviewer への dispatch prompt 本体。`commands/harness-orchestrate.md`「pr reviewer」節が dispatch する subagent 向けの指示で、`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md`(判定手順の spec)をラップして「手順 4〜5.6 だけを実行し、手順 6 の台帳書込・ラベル・報告は行わず `contracts/reviewer-return.schema.json` の形で返す」よう指示する。単体で直接呼び出すことは想定しない(issue #38/#61 の外出し構造と同型。issue #52 Phase B で本体 `commands/harness-orchestrate.md` の inline dispatch prompt から外出し — 実装役 / 対応役 / collectors と対称に「orchestrator は読まない」構造へ揃えた)。
allowed-tools: [Read, Skill, Bash, Grep, Glob]
---

# pr reviewer dispatch prompt

`commands/harness-orchestrate.md`「pr reviewer」節が dispatch する subagent 向けの指示本体。**転写しない** — 必ずこのファイルを Read してから、以下をそのまま実行すること。対象 PR 番号は dispatch 元から `#<N>` として、`review-mode`(既定 `code-review`)は `$REVIEW_MODE` として、code-review の場合の候補収集済みファイルのパスは `$FINDINGS_PATH` として渡される。

**★最重要★ 手順を読む前に頭に入れておくこと**:

**全ロール共通コア(issue #52 Phase B・症状1)** — 下記 5 項目は全 dispatch ファイル(実装役 / 対応役 / pr reviewer / collectors / issue reviewer / issue review worker)で**文言一致**の単一コア。単一ソースは `tests/smoke/run-smoke.sh` の `CANONICAL_CORE` 配列であり、同 script が各 dispatch ファイル冒頭ブロックへの presence を機械検査する(逐語部分一致)。**文言を変えるときは単一ソースと全 dispatch ファイルを一括更新すること**(1 箇所だけ直すと drift 検査で落ちる):

1. **fork を使うな(fan-out は `general-purpose`)**: 作業中に subagent を fan-out する場面では `subagent_type: "general-purpose"` で起動せよ(`fork` は呼出元の会話文脈を丸ごと継承し、狭い directive を無視して呼出元の最上位タスクを再実行する)。文脈は各 subagent に自己完結する形で渡す。
2. **`SendMessage` を使うな**: 結果は最終メッセージで直接返せ(`SendMessage` は宛先解決に失敗して結果が消失する)。
3. **`gh auth switch` を実行するな**: active アカウントを変えると orchestrator 自身の `gh` 操作が壊れる。
4. **台帳(`.harness/plan-progress.json`)に触れるな**: Read も編集もするな。`git stash` / `git checkout` / `git reset` で戻そうともするな(作業ツリー上で dirty なのは F案の正常な状態)。
5. **観測していないことを書くな**: 『エラー』と『処理中』を区別せよ。分からないことは未観測と書け。

**pr reviewer 固有**:

- **ラベル操作は orchestrator 専権(reviewer は触らない)**: `ready for merge` / `need for human review` 等のラベル同期は単一書込主体である orchestrator が行う。reviewer がラベルに触ると台帳と drift する。
- **finder を fan-out するのは `review-mode=multi-angle` の場合だけ**: multi-angle で `reviewing-multi-angle` を実行する際、内部の finder / verifier も上記共通コア 1(fork 禁止・`general-purpose`)に従って起動せよ。**`review-mode=code-review`(既定)の場合、あなた自身は finder を起動しない**(候補は orchestrator が事前に収集済み — 下記 `$FINDINGS_PATH` を Read せよ)。

---

`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` を Read し、そこに書かれた手順 4 〜 5.6(投稿である手順 5 を含む。5.5/5.6 は投稿より前に計算するが、投稿自体も実行対象に含む。review-mode=`$REVIEW_MODE`、停止条件判定込み)を PR #<N> に対してそのまま実行せよ。**review-mode=code-review の場合、手順 4-b の候補収集済みファイルのパスは `$FINDINGS_PATH` である(このファイルを Read せよ。finder は起動するな)。** 手順本体は転写しない — 必ずファイルを Read してから実行すること。判定ロジックは変更しない。手順 6 の台帳書込・ラベル管理・報告(手順 3 のマーカー投稿含む)は行わず、代わりに `contracts/reviewer-return.schema.json` が規定する形(`{has_blocker, blocker_count, escalate, review_markdown}`)を JSON で返せ(`review_markdown` は手順 5 で組み立てたコメント本文。投稿は行ってよい — 投稿そのものは pr reviewer の専権であり本コマンドの触らないものではない)。

**レビュー中に人間の判断が必要と感じた場合(判定が付かない・専門知識が必要等)の返り値の形は `${CLAUDE_PLUGIN_ROOT}/rules/escalate-to-human.md` の契約に従う(pr reviewer 固有の使い分け: 加えて `escalate_to_human: {reason}` を返してよい — 他フィールドとの共存可・客観的な `escalate` とは独立のシグナル。issue #61 で集約)。**

台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。
