---
description: 対象 repo の .harness/plan-progress.json を単一の書込主体として、developer(実装役・対応役)と pr reviewer の 2 ロールを配車する orchestrator(v1 walking skeleton・PR ライフサイクルのみ)。判断ロジックは一切持たず、既存の判定 skill/command(`/code-review` または `reviewing-multi-angle` 経由の `commands/harness-review-pr.md`)に委譲し、返答を検証してから台帳へ書き込む。前進できない状況は原因を問わず単一の失敗経路(needs-human sink)に集約する。
argument-hint: "[owner/repo] [review-mode]  省略時: CWD の origin から自動判定 / code-review(opt-in: multi-angle)"
allowed-tools: [Bash, Agent, PushNotification, Skill, Read]
---

# /harness-orchestrate — developer / pr reviewer を配車する orchestrator(v1 walking skeleton)

これは **運用(policy)** の層であり、minimal 構成の上に乗る **orchestrator ロール**(Phase 2 の中核機構の最初の増分)。対象は **developer(実装役・対応役)と pr reviewer の 2 ロール、PR ライフサイクルのみ**(issue reviewer 側の自動化は対象外)。

## orchestrator の性質(判断を持たない調整層)

**本コマンドは判定ロジックを一切持たない。** レビュー当否・実装内容の良し悪しを判断するのは常に dispatch 先の subagent(pr reviewer / developer)であり、orchestrator はその**提案を検証し、台帳へ書き込むかどうかを機械的なゲート(evidence gate / git status ガード)でのみ判定する**。orchestrator が持つ責務は次の 5 つだけ:

1. 配車判断(下記の配車テーブルに従い、どの step にどのロールを dispatch するか決める)
2. dispatch 先 subagent への委譲(判定・実装ロジックは転写せず、参照すべき command/skill を読ませて実行させる)
3. 返答の検証(evidence gate・git status ガード)
4. 台帳への単一書込
5. 前進できない状況の集約(下記「失敗経路(単一の needs-human sink)」へルーティングする)

## 単一書込

**台帳(`.harness/plan-progress.json`)への書込は本コマンドだけが行う。** dispatch する subagent には台帳の書込ツールを渡さない:

- **実装手段**: `Agent` ツールで subagent を起動する際、渡すツールを `Read, Skill, Bash, Grep, Glob` に絞り、**`Write` を渡さない**(subagent が台帳ファイルを直接 Write できないようにする)。
- **限界を正直に明記する**: `Bash` を渡す以上(`gh` コマンド実行・`reaggregate-has-blocker.py` 実行に必要)、subagent が `Bash` 経由で `.harness/plan-progress.json` を編集すること自体は**技術的に完全には防げない**(この repo の他の「触らないものを厳守」規約と同様、L1 policy 相当の制約であり L3 hook 相当の強制ではない)。
- **技術的バックストップ(git status ガード)**: dispatch から subagent の返答を受け取った後、**台帳へ書き込む前に必ず** `git status --short -- .harness/` を実行する。出力が空でなければ(= subagent が dispatch 中に `.harness/` へ意図しない変更を加えた形跡がある)、その提案を採用せず、当該 step を下記「失敗経路(単一の needs-human sink)」へルーティングする(`git checkout -- .harness/` 等の破壊的な巻き戻しは行わず、状態を報告して人間の判断を待つ)。

## 失敗経路(単一の needs-human sink)

**原則: orchestrator が step を安全に前進させられない状況は、原因を問わず単一の失敗経路に集約する。** すなわち **`needs-human` ラベル付与 + `PushNotification` + 事実に即した台帳書込(あれば)→ 以後その step は人間がラベルを外すまで配車テーブルで無条件スキップ**。実装役・対応役・reviewer 経路すべてで**対称に**扱う(どのロールでも「前進不能 = この sink に到達」であり、片方だけ有界停止・片方は無界ループ、という非対称を作らない)。

### この sink にルーティングされるトリガー(全経路の一覧)

| トリガー | 呼出元 | この sink で書き込む事実 status |
|---|---|---|
| reviewer dispatch が `escalate=true` を返した(round/trend 停止条件) | pr reviewer 節 | 書込なし(`pr.status` は `completed review` のまま。reviewer に実装物は無い) |
| 実装役 dispatch 後の evidence gate 失敗 | developer(実装役)節 | `pr.number` + `pr.githubState="open"` + `pr.status="created pr"`(PR は実在するという事実。単一コミット) |
| 対応役 dispatch 後の evidence gate 失敗 | developer(対応役)節 | 書込なし(`pr.status` は `completed review` のまま。未解決の review blocker が残っているという事実) |
| git-status ガードが `.harness/` への意図しない変更を検知 | 単一書込 節 | 書込なし(提案を破棄する) |
| 実装役の `pr_number` 復旧検索(`Closes #N`)が複数一致(曖昧) | developer(実装役)節 | 書込なし(誤った番号を書かない) |

**書き込む事実 status がトリガーごとに異なる**のは、「その時点で GitHub 上に確定している事実」を写すため(reviewer-escalate と対応役 evidence 失敗は `completed review` のまま / 実装役 evidence 失敗は `created pr`)。`escalate` や「停止条件」そのものは台帳に一切書かない(needs-human ラベルと PushNotification のみがエスカレーションの記録)。

### sink の共通手続き

事実に即した台帳書込(上表・あれば)を行った**うえで**、次を実行する:

1. `needs-human` ラベルを PR に付与する。**必ず create(fallback・冪等)を先、add を後の順で実行する**(`gh` はラベル未存在の状態で `add-label` するとエラーになるため。同ファイル内「pr reviewer」節の `ready for merge` ラベル操作と同じ順序に揃える。色・説明は `commands/harness-review-pr.md` 手順 6 の `ready for merge` ラベル作成パターンに倣う):
   ```
   gh label create "needs-human" --color "d93f0b" --description "orchestrator が人間の判断を要求した PR" --force
   gh pr edit <n> --repo <repo> --add-label "needs-human"
   ```
2. `PushNotification` ツールで人間に通知する(離席中でも気づけるように)。内容にトリガー(上表のどれか)と PR 番号を明記する — 例: 「PR #<n> が停止条件に到達した」「PR #<n> の evidence gate が失敗した(実装役 / 対応役)」「PR #<n> の dispatch 中に台帳への意図しない変更を検知した」「issue #<N> を Closes する open PR が複数見つかった(曖昧)」等。
3. **以後その step は無条件スキップ**: 次 tick 以降、配車テーブルの選別より前で `needs-human` ラベルの有無を確認し、付いていればどのロールにも dispatch しない。**ラベルの解除は人間が手動で行う**(orchestrator 側で自動解除ロジックは持たない)。

**有界停止の保証**: この sink に入った step は「人間がラベルを外す」以外に配車対象へ戻る経路が無い。したがって、どのロール(実装役・対応役・reviewer)から入っても、evidence が通らない/停止条件に達した step が無限に再 dispatch され続けることはない(無界ループは残さない)。

## 配車テーブル(v1・PR ライフサイクルのみ)

**`needs-human` ラベル付きの PR は無条件でスキップする**(ラベルの有無は各対象 step ごとに `gh pr view <n> --json labels` で確認)。**1 tick あたりの dispatch 上限は 5 件**(`commands/harness-review-pr.md` の暴走防止パターンを踏襲)。

| 条件 | dispatch するロール | orchestrator が行うこと |
|---|---|---|
| `issue.status == "ready for implementation"` かつ `pr.number == null` | developer(実装役) | dispatch → 返答検証(復旧検索)→ evidence gate → git status ガード → 原子的書込 / 失敗 sink |
| `pr.status == "completed review"` | developer(対応役) | dispatch → 返答検証 → evidence gate → git status ガード → 書込 / 失敗 sink |
| `pr.status in ("created pr", "waiting for review")` | pr reviewer | dispatch → 返答の `escalate` を確認 → true なら失敗 sink / false なら書込 + ラベル同期 |
| `pr.status == "ready for merge"` | なし | dispatch しない(終端は人間の専権) |
| `pr.status in ("merged pr")` / issue 終端(`closed issue`) | なし | 何もしない |

issue サイドの走査は台帳の `issue.status` を読むだけ(追加の GitHub ポーリングは実装しない)。

### 選別(jq)

```
PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
REVIEW_MODE="${2:-code-review}"

# 実装役 dispatch 対象
jq -c '[ .steps[]
  | select(.issue.status == "ready for implementation" and .pr.number == null)
  | {id, issueNumber: .issue.number} ]' "$PLAN"

# 対応役 dispatch 対象
jq -c '[ .steps[]
  | select(.pr.number != null and .pr.githubState == "open")
  | select(.pr.status == "completed review")
  | {id, number: .pr.number} ]' "$PLAN"

# pr reviewer dispatch 対象
jq -c '[ .steps[]
  | select(.pr.number != null and .pr.githubState == "open")
  | select(.pr.status == "created pr" or .pr.status == "waiting for review")
  | {id, number: .pr.number} ] | unique_by(.number)' "$PLAN"
```

3 カテゴリを合算して **上限 5 件**に切り詰める(優先順は「対応役 > pr reviewer > 実装役」— 手戻り修正を優先し、新規 dispatch は余裕がある時だけ行う。この優先順位付け自体は機械的な tie-break であり、レビュー判断ではない)。各対象を処理する前に `needs-human` ラベルの有無を確認しスキップする。

## dispatch 先ごとの委譲方式(転写しない)

### developer(実装役)

**flow(原子的書込 + 復旧検索の分岐網羅)**:

1. **dispatch**(subagent には `Read, Skill, Bash, Grep, Glob` のみ渡す。`Write` は渡さない)し、返答から `pr_number` の取得を試みる:

   > 「対象 issue #<N> の本文(Problem/Context/Alternatives/Implementation Scope/DoD)を `gh issue view <N>` で Read せよ。次に `creating-git-worktrees` skill を Skill ツールで起動し、その手順に従って worktree を作成せよ。issue の Implementation Scope に従って実装せよ。実装後、`creating-gh-prs` skill を Skill ツールで起動し、その手順に従って PR を作成せよ(base は main、`Closes #<N>` を本文に含める)。最後に `{pr_number, proposed_status}`(`proposed_status` は通常 `"created pr"`)を JSON で返せ。台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

   subagent の返答が JSON として解釈でき、含まれる `pr_number` が `gh pr view <pr_number> --repo <repo>` で実在確認できれば、それを採用して手順 3 へ。

2. **`pr_number` が取得できない/不正な場合**(subagent のクラッシュ・不正な JSON・実在確認失敗): 諦める前に、GitHub 側で実際に PR が作られていないか復旧検索する(dispatch prompt で PR 本文に `Closes #<N>` を含めるよう指示済みのため拾える)。**復旧検索の全 3 分岐を必ず定義する**:
   ```
   gh pr list --repo <repo> --search "Closes #<N> in:body" --state open --json number
   ```
   - **0 件** → PR 未作成。台帳に一切書込まずスキップする(次 tick で `issue.status == "ready for implementation"` かつ `pr.number == null` が成立していれば再 dispatch。**副作用が無いので暴走しない**)。
   - **複数件** → 曖昧(同一 issue を Closes する open PR が 2 本以上)。**誤った番号を台帳に書かず、この step を「失敗経路(単一の needs-human sink)」へルーティングする**(書込なし。人間が正しい PR を確定する)。
   - **1 件** → その番号を `pr_number` として採用し、手順 3 へ。

3. **`pr_number` 確定後、evidence gate を書込より前に実行する**。**subagent が dispatch 中に作った worktree は削除済みの可能性があり参照できないため、orchestrator 自身が独立して PR の head ブランチを取得し専用の一時 worktree を作って実行する**(`commands/harness-review-pr.md` 手順 4 の per-PR worktree パターンと同じ)。**worktree は `EVIDENCE_EXIT` の成否に関わらず必ず `git worktree remove --force` する**(失敗経路でも後片付けを行い worktree を残さない):
   ```
   HEAD_REF=$(gh pr view <pr_number> --repo <repo> --json headRefName --jq .headRefName)
   git fetch origin "$HEAD_REF" --quiet
   WORKTREE=".claude/worktrees/orchestrate-pr-<pr_number>"
   git worktree add --detach "$WORKTREE" "origin/$HEAD_REF"
   ( cd "$WORKTREE" && eval "$EVIDENCE_DONE" ); EVIDENCE_EXIT=$?
   git worktree remove --force "$WORKTREE"
   ```
   (`$EVIDENCE_DONE` は台帳の `evidence.done`、無ければ `evidence.test` にフォールバック。)

4. **台帳は単一コミットで `pr.number` + `pr.githubState="open"` + `pr.status` を一度に書く**(evidence を書込より前に実行済みなので、`pr.number` だけ書いて `pr.status` 未書込、という中間状態を作らない ⇒ 非原子的多段書込を排除する)。`pr.status` の値は `EVIDENCE_EXIT` で分岐するが、**書込は常に 1 コミット**:
   ```
   # ST = "created pr"(成否に関わらず。evidence は "PR が存在するか" ではなく "green か" を測る)
   jq --argjson n <pr_number> --arg st "created pr" --arg d "$(date +%F)" \
     '(.steps[] | select(.id == "<step id>") | .pr.number)      = $n
      | (.steps[] | select(.id == "<step id>") | .pr.githubState) = "open"
      | (.steps[] | select(.id == "<step id>") | .pr.status)      = $st
      | .updatedAt = $d' \
     "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
   ```
   書込後は「書込方式」節に従い main へ直接コミット + push する(1 コミット。例: `chore(harness): <step> pr.status -> created pr`)。
   - **`EVIDENCE_EXIT == 0`**: 上記単一コミットで完了(`pr.status = "created pr"`)。次 tick で pr reviewer に dispatch される。
   - **`EVIDENCE_EXIT != 0`**: 上記単一コミット(`pr.status = "created pr"`)を書き込んだ**うえで、この step を「失敗経路(単一の needs-human sink)」へルーティングする**(needs-human ラベル + PushNotification)。`"completed review"` にはしない — reviewer が一度も走っていない PR には `# PR Reviewer` コメントが存在せず、対応役 dispatch しても直す finding が無い。needs-human ラベル付与後は次 tick から無条件スキップされ、人間が介入するまで安全に停止する。

5. **orphan 防止は write-early ではなく復旧検索が担う**: 手順 3〜4 の途中で tick が中断しても、次 tick は `pr.number == null` のままなので手順 2 の復旧検索が既存 PR(`Closes #<N>`)を再発見して self-heal する。だから `pr.number` を先行コミットする必要はなく、書込は手順 4 のとおり原子的にできる(先行コミット → evidence → 本コミット の 2 段書込は取らない)。

### developer(対応役)

**flow(実装役と完全対称。evidence 失敗は必ず失敗 sink に到達し、無界ループを残さない)**:

1. **選別ガード**: 選別 jq に `.pr.githubState == "open"` を含める(GitHub 上で既に merged/closed の PR を対応役へ回さない)。

2. **dispatch**(ツール制限は実装役と同じ。`gh pr comment` 投稿は許可するが台帳・ラベルには触れさせない):

   > 「PR #<N> に投稿された最新の `# PR Reviewer` コメントを `gh pr view <N> --json comments` で読め。finding ごとに次の 4 分類で判定せよ:
   > 1. **採用**: 指摘を修正し commit する
   > 2. **却下**: 却下理由を明記する(誤検知・意図的な設計判断など)
   > 3. **保留(follow-up)**: merge 後の対応でよいと判断した場合(ただし最終判断は reviewer の責務であり、対応役はここで `ready for merge` を提案してはならない — `.harness/CLAUDE.harness.md` の doer ≠ judge 規約通り)
   > 4. **保留(解消不可)**: 環境依存の実測値が要る等、対応不能な場合(理由を明記)
   >
   > 対応内訳を PR コメントとして投稿し、`{proposed_status: "waiting for review"}` を JSON で返せ。**`ready for merge` を提案することは絶対に禁止**(採否に関わらず、対応後の提案は常に `waiting for review` 固定)。台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

3. **返答検証**: `proposed_status` が `"waiting for review"` 以外(特に `"ready for merge"`)を返した場合は**その提案を無視し `"waiting for review"` に強制する**(対応役の越権を orchestrator 側で機械的に無効化する — `.harness/CLAUDE.harness.md` の「対応側が `ready for merge` を立てるのは越権(例外なし)」を技術的に担保する)。

4. **evidence gate**(実装役の手順 3 と同じ方法で、orchestrator 自身が独立した一時 worktree を用意して実行する。対象 PR は既に `pr.number` が確定しているため subagent の dispatch 済み worktree の生死に依存しない。**worktree は `EVIDENCE_EXIT` の成否に関わらず必ず `git worktree remove --force` する**):
   ```
   HEAD_REF=$(gh pr view <n> --repo <repo> --json headRefName --jq .headRefName)
   git fetch origin "$HEAD_REF" --quiet
   WORKTREE=".claude/worktrees/orchestrate-pr-<n>"
   git worktree add --detach "$WORKTREE" "origin/$HEAD_REF"
   ( cd "$WORKTREE" && eval "$EVIDENCE_DONE" ); EVIDENCE_EXIT=$?
   git worktree remove --force "$WORKTREE"
   ```
   - **`EVIDENCE_EXIT == 0`**: `pr.status = "waiting for review"` を書き込む(「書込方式」節。次 tick で pr reviewer が再レビュー)。
   - **`EVIDENCE_EXIT != 0`**: **この step を「失敗経路(単一の needs-human sink)」へルーティングする**(needs-human ラベル + PushNotification)。**`pr.status` は `completed review` のまま**(事実: 未解決の review blocker が残っている)。これで対応役も有界停止になり、実装役と対称になる — 「evidence が通らないまま `completed review` 固定で毎 tick 再 dispatch され、reviewer が選別しないので round カウンタが進まず永久に停止しない」という旧・無界ループを根絶する。

### pr reviewer

対象 PR 番号と `$REVIEW_MODE` を渡し、次を Agent ツールで dispatch する(ツール制限は実装役と同じ。**`gh pr comment` 投稿は許可するが台帳・ラベルには触れさせない**):

> 「`commands/harness-review-pr.md` を Read し、そこに書かれた手順 4 〜 5.6(投稿である手順 5 を含む。5.5/5.6 は投稿より前に計算するが、投稿自体も実行対象に含む。review-mode=`$REVIEW_MODE`、停止条件判定込み)を PR #<N> に対してそのまま実行せよ。手順本体は転写しない — 必ずファイルを Read してから実行すること。判定ロジックは変更しない。手順 6 の台帳書込・ラベル管理・報告(手順 3 のマーカー投稿含む)は行わず、代わりに `{has_blocker, blocker_count, escalate, review_markdown}` を JSON で返せ(`review_markdown` は手順 5 で組み立てたコメント本文。投稿は行ってよい — 投稿そのものは pr reviewer の専権であり本コマンドの触らないものではない)。台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

**返答検証**: `escalate` を確認する。

- **`escalate == true`**: この step を「失敗経路(単一の needs-human sink)」へルーティングする(トリガー: reviewer dispatch が `escalate=true`)。台帳には一切書込まない(`pr.status` は `completed review` のまま。次に人間が対応するまで現状維持)。
- **`escalate == false`**: evidence gate は不要(reviewer 役に実装物は無い)。`has_blocker` の真偽で `pr.status` を書込み、`ready for merge` ラベルを同期する。単一書込の設計上(pr reviewer subagent はラベル・台帳に触らせない)、このロジックは orchestrator 側が実コマンドとして持つ(`commands/harness-review-pr.md` 手順 6 の内容と同じ):
  - `has_blocker == false`:
    - `pr.status = "ready for merge"`
    - ラベル作成 fallback(冪等): `gh label create "ready for merge" --color "0e8a16" --description "reviewer が merge 可能と判定した PR" --force`
    - `gh pr edit <n> --repo <repo> --add-label "ready for merge"`(冪等)
    - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(無ければ警告のみで実害なし)
  - `has_blocker == true`:
    - `pr.status = "completed review"`
    - `gh pr edit <n> --repo <repo> --remove-label "ready for merge"`(付いていなければ警告のみで実害なし)
    - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(無ければ警告のみで実害なし)

## evidence gate(対称モデル)

evidence gate は orchestrator 自身が独立した一時 worktree を用意して `evidence.done`(台帳 `.harness/plan-progress.json` の `evidence.done`、無ければ `evidence.test` にフォールバック)を実行する(具体的な worktree の作り方は「developer(実装役)」節の手順 3 参照)。**実装役・対応役いずれも、evidence gate 失敗時は「失敗経路(単一の needs-human sink)」へ到達する(対称)**:

- **developer(実装役)**: `pr_number` が確定した(PR は実在する)場合、evidence gate 失敗時は `pr.number` / `pr.githubState="open"` / `pr.status="created pr"` を単一コミットで書き込んだうえで失敗 sink へ。`pr_number` が確認できない(復旧検索でも 0 件 = PR 未作成)場合のみ、書込まずスキップして次 tick 再 dispatch(副作用が無いので暴走しない)。復旧検索が複数一致(曖昧)なら書込まず失敗 sink へ。
- **developer(対応役)**: 対象 PR は既に存在し `pr.number` も書込済み。evidence gate 失敗時は `pr.status` を `completed review` のまま(事実: 未解決 blocker が残る)にして失敗 sink へ。**旧版の「書込まずスキップ + 再試行」は取らない** — `completed review` は reviewer が選別しないため round カウンタが進まず、round≥5 の停止条件に永久に到達しない無界ループになるため。

これで「どのロールの evidence 失敗も needs-human に到達し、無界ループを残さない」という対称性が保たれる(失敗経路の一元化)。

## 書込方式

`commands/harness-review-pr.md` の手順 3/6 と同じ jq パターンを踏襲する: main 上で `.harness/plan-progress.json` だけを含む小コミットを作り push する。push が拒否された場合(doer と同時書込)は `git pull --ff-only` してからやり直す。コミットメッセージ規約は `chore(harness): <step id> <issue|pr>.status -> <新 status>`(例: `chore(harness): P8 pr.status -> created pr`)。

```
git add .harness/plan-progress.json
git commit -m "chore(harness): <step> <issue|pr>.status -> <new>"
git push origin main
```

## 既知のリスク(明示)

**orchestrator の単一書込は現行方式(main 直接コミット + push)を前提にしている。** issue #11(台帳の git 非依存化・main push 禁止ポリシー)が実装されると、この前提が崩れる。皮肉なことに、issue #11 自体が本 orchestrator 最初の実仕事の対象(配車テーブル該当 step)であり、orchestrator 自身がこの変更を実装した後、orchestrator の書込ロジックへの追従修正が別途必要になる。v1 ではこれを解消せず、既知の負債として明示するに留める。

## 報告

`commands/harness-review-pr.md` 手順 8 に倣い、tick サマリを分かりやすく出す:

````markdown
## 🚦 Orchestrator tick 報告

**実施: HH:MM**(local time)

### 📊 dispatch サマリ(N 件、上限 5)

| step | ロール | 遷移前 → 提案 → 書込結果 | evidence gate | 失敗 sink |
|---|---|---|---|---|
| P8 | developer(実装役) | null → created pr → **書込済み(#N)** | ✅ exit 0 | — |
| P9 | developer(実装役) | null → created pr → **書込済み(#M)** | ❌ 非 0 | 🛑 needs-human 付与 + 通知済み |
| P13 | pr reviewer | created pr → escalate=false → **ready for merge** | — | — |
| P11 | pr reviewer | waiting for review → escalate=true → **書込なし** | — | 🛑 needs-human 付与 + 通知済み |
| P12 | developer(対応役) | completed review → waiting for review → **書込なし(evidence 失敗)** | ❌ 非 0 | 🛑 needs-human 付与 + 通知済み |

### ⏭️ スキップ(あれば)
- #M は `needs-human` ラベル付きのため無条件スキップ
- #K は復旧検索 0 件(PR 未作成)のため書込せずスキップ(次 tick 再試行)

### 🛑 失敗 sink 到達(あれば)
- #N: 理由(round 上限到達 / blocker 傾向未改善 / 実装役 evidence 失敗 / 対応役 evidence 失敗 / git status ガード検知 / `Closes #N` 復旧検索が複数一致)

### ↩️ 誤判定の巻き戻し方
台帳の書込は main への直接コミットのため、誤りがあれば手動で `pr.status` / `issue.status` を巻き戻し、`needs-human` ラベルを外して、次 tick で再評価させる。
````

0 件 tick の場合は「dispatch 対象なし」の 1 行報告に簡略化する。

## loop での回し方

- 試行: `/loop 15m /harness-orchestrate`(review-mode=code-review 既定、15 分間隔)。
- review-mode を明示したい場合: `/loop 15m /harness-orchestrate owner/repo multi-angle`。
- `/loop` は起動時の引数をそのまま毎 tick 再実行するため、review-mode は起動時の引数が毎 tick 引き継がれる。追加の状態保持は不要。

## 既知の制限・拡張ポイント

- **真の無人化はまだできない**: `/loop` はセッションが開いている間だけ定期実行できる方式であり無人ではない。GitHub Actions `on: schedule` / `/schedule` クラウド routine による真の無人化は、判定 skill(`reviewing-multi-angle` 等)の kit 同梱が前提になるため別途対応が必要(現行は個人 skill 依存または `/code-review` 単体のみ)。
- **issue #11 との既知のリスク**: 上記「既知のリスク」節参照。orchestrator の単一書込は main 直接コミット + push が前提。
- **issue サイド(issue reviewer / issue review worker)の自動化は対象外**: v1 は PR ライフサイクルのみ。issue フェーズの配車は別 issue の範囲。
- **capability 分離の技術的限界**: subagent に `Write` を渡さなくても `Bash` 経由での `.harness/` 編集は完全には防げない。git status ガードはこの限界を補うバックストップ(検知したら失敗 sink へ)であり、hook 等による L3 相当の強制ではない。
- **dispatch 上限 5 件のトレードオフ**: 1 tick で処理しきれない場合は次 tick へ持ち越される(dedup は各ロールの status 遷移が担う)。
- **失敗経路は単一 sink に集約(重要)**: 実装役・対応役・reviewer のどの経路でも「前進不能 = needs-human sink 到達」で対称に扱う。個別ロールに独自の失敗処理(片方だけ有界停止・片方は無界ループ)を持たせない。書き込む事実 status だけがトリガーごとに異なる(「失敗経路(単一の needs-human sink)」節の一覧表を参照)。
- **ラベル同期ロジックの複製(drift リスク)**: 本コマンドのラベル同期ロジックは `commands/harness-review-pr.md` 手順 6 の内容を単一書込の都合上複製している。将来どちらかの label 定義(色・説明・名称)を変更する場合は両ファイルを同時に更新すること(自動で同期されない、既知の drift リスク)。
