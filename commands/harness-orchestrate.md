---
description: 対象 repo の .harness/plan-progress.json を単一の書込主体として、developer(実装役・対応役)と pr reviewer の 2 ロールを配車する orchestrator(v1 walking skeleton・PR ライフサイクルのみ)。判断ロジックは一切持たず、既存の判定 skill/command(`/code-review` または `reviewing-multi-angle` 経由の `commands/harness-review-pr.md`)に委譲し、返答を検証してから台帳へ書き込む。needs-human ラベルによるエスカレーション判断も行う。
argument-hint: "[owner/repo] [review-mode]  省略時: CWD の origin から自動判定 / code-review(opt-in: multi-angle)"
allowed-tools: [Bash, Skill, Read, Write]
---

# /harness-orchestrate — developer / pr reviewer を配車する orchestrator(v1 walking skeleton)

これは **運用(policy)** の層であり、minimal 構成の上に乗る **orchestrator ロール**(Phase 2 の中核機構の最初の増分)。対象は **developer(実装役・対応役)と pr reviewer の 2 ロール、PR ライフサイクルのみ**(issue reviewer 側の自動化は対象外)。

## orchestrator の性質(判断を持たない調整層)

**本コマンドは判定ロジックを一切持たない。** レビュー当否・実装内容の良し悪しを判断するのは常に dispatch 先の subagent(pr reviewer / developer)であり、orchestrator はその**提案を検証し、台帳へ書き込むかどうかを機械的なゲート(evidence gate / git status ガード)でのみ判定する**。orchestrator が持つ責務は次の 5 つだけ:

1. 配車判断(下記の配車テーブルに従い、どの step にどのロールを dispatch するか決める)
2. dispatch 先 subagent への委譲(判定・実装ロジックは転写せず、参照すべき command/skill を読ませて実行させる)
3. 返答の検証(evidence gate・git status ガード)
4. 台帳への単一書込
5. 人間へのエスカレーション(needs-human ラベル + PushNotification)

## 単一書込

**台帳(`.harness/plan-progress.json`)への書込は本コマンドだけが行う。** dispatch する subagent には台帳の書込ツールを渡さない:

- **実装手段**: `Agent` ツールで subagent を起動する際、渡すツールを `Read, Skill, Bash, Grep, Glob` 程度に絞り、**`Write` を渡さない**(subagent が台帳ファイルを直接 Write できないようにする)。
- **限界を正直に明記する**: `Bash` を渡す以上(`gh` コマンド実行・`reaggregate-has-blocker.py` 実行に必要)、subagent が `Bash` 経由で `.harness/plan-progress.json` を編集すること自体は**技術的に完全には防げない**(この repo の他の「触らないものを厳守」規約と同様、L1 policy 相当の制約であり L3 hook 相当の強制ではない)。
- **技術的バックストップ**: dispatch から subagent の返答を受け取った後、**台帳へ書き込む前に必ず** `git status --short -- .harness/` を実行する。出力が空でなければ(= subagent が dispatch 中に `.harness/` へ意図しない変更を加えた形跡がある)、その提案を**破棄**し、当該 step を「needs-human エスカレーション」として扱う(4 節の手段を流用。`git checkout -- .harness/` 等の破壊的な巻き戻しは行わず、状態を報告して人間の判断を待つ)。

## 配車テーブル(v1・PR ライフサイクルのみ)

**`needs-human` ラベル付きの PR は無条件でスキップする**(ラベルの有無は各対象 step ごとに `gh pr view <n> --json labels` で確認)。**1 tick あたりの dispatch 上限は 5 件**(`commands/harness-review-pr.md` の暴走防止パターンを踏襲)。

| 条件 | dispatch するロール | orchestrator が行うこと |
|---|---|---|
| `issue.status == "ready for implementation"` かつ `pr.number == null` | developer(実装役) | dispatch → 返答検証 → evidence gate → git status ガード → 書込 |
| `pr.status == "completed review"` | developer(対応役) | dispatch → 返答検証 → evidence gate → git status ガード → 書込 |
| `pr.status in ("created pr", "waiting for review")` | pr reviewer | dispatch → 返答の `escalate` を確認 → true ならエスカレーション(4 節) / false なら書込 + ラベル同期 |
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

対象 step の issue 番号を渡し、次を Agent ツールで dispatch する(subagent には `Read, Skill, Bash, Grep, Glob` のみ渡す。`Write` は渡さない):

> 「対象 issue #<N> の本文(Problem/Context/Alternatives/Implementation Scope/DoD)を `gh issue view <N>` で Read せよ。次に `creating-git-worktrees` skill を Skill ツールで起動し、その手順に従って worktree を作成せよ。issue の Implementation Scope に従って実装せよ。実装後、`creating-gh-prs` skill を Skill ツールで起動し、その手順に従って PR を作成せよ(base は main、`Closes #<N>` を本文に含める)。最後に `{pr_number, proposed_status}`(`proposed_status` は通常 `"created pr"`)を JSON で返せ。台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

**返答検証**: `pr_number` が実在し `gh pr view` で取得できること、dispatch 済み worktree で `evidence.done` を実行して exit 0 であることを確認する。**evidence gate 失敗時は台帳に一切書込まずスキップする**(次 tick で `issue.status == "ready for implementation"` かつ `pr.number == null` が成立していれば再試行する。暴走しない)。両方通れば `pr.number = pr_number` / `pr.status = "created pr"` / `pr.githubState = "open"` を書き込む。

### developer(対応役)

対象 PR 番号を渡し、次を Agent ツールで dispatch する(ツール制限は実装役と同じ):

> 「PR #<N> に投稿された最新の `# PR Reviewer` コメントを `gh pr view <N> --json comments` で読め。finding ごとに次の 4 分類で判定せよ:
> 1. **採用**: 指摘を修正し commit する
> 2. **却下**: 却下理由を明記する(誤検知・意図的な設計判断など)
> 3. **保留(follow-up)**: merge 後の対応でよいと判断した場合(ただし最終判断は reviewer の責務であり、対応役はここで `ready for merge` を提案してはならない — `.harness/CLAUDE.harness.md` の doer ≠ judge 規約通り)
> 4. **保留(解消不可)**: 環境依存の実測値が要る等、対応不能な場合(理由を明記)
>
> 対応内訳を PR コメントとして投稿し、`{proposed_status: "waiting for review"}` を JSON で返せ。**`ready for merge` を提案することは絶対に禁止**(採否に関わらず、対応後の提案は常に `waiting for review` 固定)。台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

**返答検証**: `proposed_status` が `"waiting for review"` 以外(特に `"ready for merge"`)を返した場合は**その提案を無視し**、`"waiting for review"` に強制する(対応役の越権を orchestrator 側で機械的に無効化する — `.harness/CLAUDE.harness.md` の「対応側が `ready for merge` を立てるのは越権(例外なし)」を orchestrator が技術的に担保する)。evidence gate(対応後の worktree で `evidence.done` が exit 0)を確認し、失敗時は台帳に書込まずスキップする(次 tick で `pr.status == "completed review"` が成立していれば再試行)。通れば `pr.status = "waiting for review"` を書き込む。

### pr reviewer

対象 PR 番号と `$REVIEW_MODE` を渡し、次を Agent ツールで dispatch する(ツール制限は実装役と同じ。**`gh pr comment` 投稿は許可するが台帳・ラベルには触れさせない**):

> 「`commands/harness-review-pr.md` を Read し、そこに書かれた手順 4 〜 5.6(review-mode=`$REVIEW_MODE`、停止条件判定込み)を PR #<N> に対してそのまま実行せよ。手順本体は転写しない — 必ずファイルを Read してから実行すること。判定ロジックは変更しない。手順 6 の台帳書込・ラベル管理・報告(手順 3 のマーカー投稿含む)は行わず、代わりに `{has_blocker, blocker_count, escalate, review_markdown}` を JSON で返せ(`review_markdown` は手順 5 で組み立てたコメント本文。投稿は行ってよい — 投稿そのものは pr reviewer の専権であり本コマンドの触らないものではない)。台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

**返答検証**: `escalate` を確認する。
- `escalate == true`: 4 節の手段でエスカレーションする。台帳には一切書込まない(`pr.status` は変更せず、次に人間が対応するまで現状維持)。
- `escalate == false`: evidence gate は不要(reviewer 役に実装物は無い)。`has_blocker` の真偽で `pr.status` を `ready for merge` / `completed review` に書込み、`ready for merge` ラベルを同期する(`commands/harness-review-pr.md` 手順 6 と同じ jq パターン + ラベル操作)。

## エスカレーション手段

`escalate == true` の場合(pr reviewer dispatch の返答、または単一書込の git status ガードで意図しない変更を検知した場合)、次を行う:

1. `needs-human` ラベルを PR に付与する: `gh pr edit <n> --repo <repo> --add-label "needs-human"`。ラベルが存在しなければ冪等作成する: `gh label create "needs-human" --color "d93f0b" --description "orchestrator が人間の判断を要求した PR" --force`(色・説明は `commands/harness-review-pr.md` 手順 6 の `ready for merge` ラベル作成パターンに倣う)。
2. `PushNotification` ツールで人間に通知する(離席中でも気づけるように。内容は「PR #<n> が停止条件に到達した」または「PR #<n> の dispatch 中に台帳への意図しない変更を検知した」等、理由を明記する)。
3. `pr.status` は enum を変えず現状(`completed review`)のまま維持する。台帳には `escalate` を一切書かない(needs-human ラベルと PushNotification のみがエスカレーションの記録)。
4. **ラベル解除は人間が手動で行う想定**(orchestrator 側で自動解除ロジックは持たない)。

## evidence gate 失敗時の扱い

developer(実装役・対応役)いずれも、dispatch 済み worktree で `evidence.done`(台帳 `.harness/plan-progress.json` の `evidence.done`、無ければ `evidence.test` にフォールバック)を実行して非 0 の場合は、**台帳に一切書込まずスキップする**。次 tick で dispatch 条件が成立していれば再試行する(暴走しない)。

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

| step | ロール | 遷移前 → 提案 → 書込結果 | evidence gate | エスカレーション |
|---|---|---|---|---|
| P8 | developer(実装役) | null → created pr → **書込済み(#N)** | ✅ exit 0 | — |
| P13 | pr reviewer | created pr → escalate=false → **ready for merge** | — | — |
| P11 | pr reviewer | waiting for review → escalate=true → **書込なし** | — | 🛑 needs-human 付与 + 通知済み |

### ⏭️ スキップ(あれば)
- #M は `needs-human` ラベル付きのため無条件スキップ
- #K は evidence gate 失敗(非 0)のため書込せずスキップ(次 tick 再試行)

### 🛑 エスカレーション(あれば)
- #N: 理由(round 上限到達 / blocker 傾向未改善 / git status ガード検知)

### ↩️ 誤判定の巻き戻し方
台帳の書込は main への直接コミットのため、誤りがあれば手動で `pr.status` / `issue.status` を巻き戻し、次 tick で再評価させる。
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
- **capability 分離の技術的限界**: subagent に `Write` を渡さなくても `Bash` 経由での `.harness/` 編集は完全には防げない。git status ガードはこの限界を補うバックストップであり、hook 等による L3 相当の強制ではない。
- **dispatch 上限 5 件のトレードオフ**: 1 tick で処理しきれない場合は次 tick へ持ち越される(dedup は各ロールの status 遷移が担う)。
