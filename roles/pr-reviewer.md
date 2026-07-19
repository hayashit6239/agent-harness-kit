---
description: 対象 repo の .harness/plan-progress.json の PR フェーズ status を選別源に、pr.status が 'created pr' または 'waiting for review' の PR をレビューし(既定 review-mode=code-review では角度別 finder(`collectors/strategy.md`。kit デフォルト角度 ∪ 導入先追加)が収集した候補(orchestrator が pr reviewer dispatch 前に事前収集)を独立検証、opt-in review-mode=multi-angle では `reviewing-multi-angle` skill 経由で 3 観点並列)、dedup + 優先度付け済みの統合 findings を 1 件の PR コメントとして投稿。`has_blocker` は wrapper 側で再集計(`scripts/reaggregate-has-blocker.py`)し、真偽で pr.status を自動進行(false→'ready for merge'(+ `ready for merge` ラベル付与) / true→'completed review'(+ ラベル除去))する reviewer ロール。round 上限・blocker 傾向による停止条件(escalate)も判定し、マーカーとしてコメントに埋め込むとともに、escalate=true なら pr.status を 'need for human review' に遷移させ `need for human review` ラベルを付与する(2026-07-10 決定事項。escalate=false に戻ればラベルは除去)。台帳の状態遷移はローカル編集(commit/push しない)+ 対象 PR の head SHA へ Statuses API 自己申告(issue #11 F案)。`commands/harness-orchestrate.md`「pr reviewer」節から dispatch される role 規約ファイル(issue #61 で `commands/` から `roles/` へ移動・単体起動は廃止)。
allowed-tools: [Bash, Skill, Read, Write, Agent]
---

# pr reviewer — レビュー待ち PR の自動コードレビュー(reviewer ロール / role 規約)

これは **運用(policy)** の層であり、minimal 構成の **reviewer ロール**(doer ≠ judge の judge 側。`commands/harness-orchestrate.md` が main developer の作業とは別の subagent として dispatch する)。レビュー判断そのものは review-mode に応じた skill/委譲先に委ねる:

- **既定 `review-mode=code-review`**: 角度別 finder(`${CLAUDE_PLUGIN_ROOT}/collectors/strategy.md`。kit デフォルト角度 ∪ 導入先 `.harness/collectors/angles/` の追加観点 — issue #63・#65)が機械的に収集した候補を、本 role(pr reviewer)自身が**独立検証**(候補ごとの CONFIRMED/PLAUSIBLE/REFUTED 判定による事実確認 + 意味的な severity 判定)する(issue #49・**個人 skill 不要**で動く可搬構成)。候補収集は orchestrator が pr reviewer dispatch 前に実行する — 詳細は手順 4-b 参照。
- **opt-in `review-mode=multi-angle`**: `reviewing-multi-angle` skill(orchestration mechanism)経由で `/code-review`(correctness)+ `reviewing-pr-architecture`(アーキ 6 観点)+ `reviewing-pr-google-method`(命名/規約/テスト品質)が 3 並列で動く。個人 skill 依存。**本 issue #49 のスコープ外**(現状維持)。

wrapper は「どれを・いつ・結果をどうするか(選別 / findings 正規化 / has_blocker 再集計 / 停止条件判定 / status 進行 / 投稿 / ラベル同期 / 報告)」を担い、レビュー判定の中身には立ち入らない。

> **`reviewing-multi-angle` skill との関係(review-mode=multi-angle のみ)**: skill は 3 review skill を per-PR で並列 spawn → dedup + 優先度付け + 統合 max 10 件 + `summary_markdown` 組み立てまで担う orchestration。出力は `{ findings, has_blocker, truncated, summary_markdown }`。本 wrapper は per-PR の git worktree を用意して skill を呼び(CWD 前提)、skill が返す `summary_markdown` をそのまま PR コメント本文として投稿する。**skill が返す `has_blocker`(「1 件でも 🔴」)は参考値**であり、merge 可否の判定には使わない — 本 wrapper が手順 5.5 で `findings[].severity / sources` から**再集計した `has_blocker`(harness-kit 定義)**を使う(ゴム印対策: arch/google 由来の 🟡 も blocker に含める)。
>
> **角度別 finder 収集との関係(review-mode=code-review、既定・issue #49)**: 収集された候補は `contracts/findings.schema.json` が規定する形(`{file, line, summary, failure_scenario}`)の JSON 配列で、`severity` / `sources` / `has_blocker` / `summary_markdown` は持たない(旧 `/code-review` 直接呼出時と同じ形)。**medium 相当の候補収集でも correctness bug に加えて reuse/simplification/efficiency 等の cleanup 提案が混在しうる**(round 2 で実機再検証済みだった旧仕様を踏襲)。本 wrapper が手順 4-b で正規化する: まず各候補を wrapper を実行している Claude 自身が PR の diff と突き合わせて **CONFIRMED / PLAUSIBLE / REFUTED を判定し(REFUTED は除外)**、残った候補について `summary` + `failure_scenario` を読んで **意味的に** `severity`(🔴/🟡)を付与し(correctness に影響するかで判断。判断が付かなければ 🔴 に倒す)・`sources=["code-review"]` を機械的に付与し、`summary_markdown` は findings を箇条書きにしただけの簡易版を wrapper 側で組み立てる。findings が空配列の場合はそのまま `[]` とする。**この正規化(CONFIRMED/PLAUSIBLE/REFUTED 判定・severity 付与・採否判断)が独立検証にあたり、finder が担うのは候補の機械的な列挙だけ**(doer ≠ judge は収集の機械性 + この独立検証で保たれる。旧 `/code-review` が内部で持っていた Phase 2 検証(幻覚・事実誤認のふるい)に相当する)。

## ロールの契約

**Why**: 単一観点のレビューは網羅範囲が狭く、単独判定は「判定の丸投げ」(Cognitive Surrender) を招く。本ロールは doer ≠ judge の judge 側として、3 観点並列 + 作者との往復サイクルで観点の網羅と判定の独立を両立する。

- **触る (専権)**: `pr.status` の判定遷移 (`starting review` → `ready for merge` / `completed review` / `need for human review`)、`pr.lastReviewedStatus`、`ready for merge` ラベル (+ 旧名 `merge ready` ラベルの**除去のみ** — 手順 6 の移行掃除)、`need for human review` ラベル (停止条件到達時の付与・解除。2026-07-10 決定事項)、対象 step の `reports[]` への作業レポート 1 件の追記 (判定確定時・手順 6。返り値として単一 writer (`commands/harness-orchestrate.md`) へ渡す。規約は `.harness/CLAUDE.harness.md`「作業レポートの書込」節)、レビューコメント投稿。
- **触らない**: 終端 status (`merged pr` / `closed issue`)・`githubState`・PR 本文編集・close・merge・`issue.*`・他ラベル・コード修正 (`--fix`)。
- **follow-up の最終判断は reviewer 責務**: 「この指摘は merge 後の対応でよい / もうマージしてよい」を決めるのは作者・対応側ではなく本ロール。対応側は指摘対応後 `waiting for review` に戻すだけ (対応側の規約は `.harness/CLAUDE.harness.md`)。

## 状態源と選別

**選別源は GitHub ラベルではなく、対象 repo 内の `.harness/plan-progress.json`**(CWD の git repo ルート基準。`/harness-init` が生成した進捗台帳)。各 step の PR フェーズ status(enum)を読み、レビュー待ち lifecycle 段階だけを対象にする。台帳が repo 内のローカルファイルにあるため、この選別はローカル validator(+ Statuses API 自己申告)で同じファイルを検証できる。

**対象(どちらか):**
- `pr.status == "created pr"` — PR 作成直後・初回レビュー未了
- `pr.status == "waiting for review"` — レビュー依頼済み(初回 or review work 後の再レビュー待ち)

**除外:** 上記 status 以外(`starting review` / `completed review` / `ready for merge` / `need for human review` / `starting review work` / `implementation-ready` / `merged pr`)/ `pr.number == null`(未作成)/ `pr.githubState != "open"`(GitHub 上で merged/closed)/ `isDraft == true`(下書き)。エスカレーション解除後に再レビューしたい場合は、人間が `pr.status` を `waiting for review` に戻す(「再発火経路」参照)。

## status 自動進行と dedup

**本コマンドはレビュー結果に応じて `pr.status` を自動進行する**(本コマンドが触るのは `pr.status` / `pr.lastReviewedStatus` / GitHub の **`ready for merge` ラベル** + 旧名 `merge ready` ラベルの**除去のみ** / **`need for human review` ラベル**(停止条件到達時の付与・解除)。PR 本文・close・merge・`githubState`・issue 側は触らない):

**`ESCALATE`(手順 5.6 の判定)を最優先で分岐する**(`evaluate-stop-condition.py` の定義上、`escalate=true` は `has_blocker=true` を必ず伴うため、`ESCALATE` が `has_blocker` に優先する):

| `ESCALATE` | 再集計 `has_blocker`(harness-kit 定義) | 自動進行先 `pr.status` | `ready for merge` ラベル | `need for human review` ラベル |
|---|---|---|---|---|
| true(停止条件到達) | true(必然) | `need for human review`(reviewer が設定できる終端手前の状態。`ready for merge` と対称) | **除去**(冪等) | **付与**(冪等) |
| false | false(🔴 なし、かつ arch/google 由来の 🟡 なし) | `ready for merge` | **付与**(冪等。既に付いていれば no-op) | **除去**(冪等。エスカレーション解除後の掃除) |
| false | true(🔴 1 件以上、**または** arch/google 由来の 🟡 1 件以上) | `completed review`(分岐点 — 作者が `starting review work` に進める想定) | **除去**(冪等。付いていなければ no-op) | **除去**(冪等。エスカレーション解除後の掃除) |

**has_blocker の再集計(harness-kit 定義・手順 5.5)**: skill 定義の「1 件でも 🔴」より広く blocker を取る(ゴム印対策)。**規則の正は `scripts/reaggregate-has-blocker.py`** — 判定はスクリプト実行で行い、exit 2(入力エラー)なら停止する。

**ラベルの対称運用**: `ready for merge` は「マージ可能と判断された」シグナルなので、再レビューで blocker が見つかったらラベルも下ろす(嘘を残さない)。`need for human review` も同様に対称運用する — `ESCALATE == false` に戻ったら(エスカレーションが解消した / 元々該当しない)ラベルを外す。

**dedup**: `pr.status` が自動進行で対象外 status(`ready for merge` / `completed review` / `need for human review`)に変わるため、次の tick で自動的に選別から外れる(重複レビュー回避)。**`pr.lastReviewedStatus` は記録目的でレビュー時の status を残す**が、選別ロジックでは参照しない。

**誤判定リスク(重要)**: 🟡 を blocker に含めたことで、effort=high / max では hold(`completed review`)が増えうる(逆リスク = 過剰 hold)。基本は effort=medium で運用し、hold が頻発してループが回らない場合の緩和策は (a) effort=medium 固定、(b) 🟡 の件数閾値化、の順で検討する。作者は wrapper の判定を盲信せず、findings を読んで採否を判断する。

## 再発火経路

再レビューは **status 遷移**だけで完結する(`lastReviewedStatus` リセットは不要):

1. **初回レビュー入口**: 作者が PR 作成 → `pr.status = "created pr"` → wrapper レビュー → 自動進行
2. **review work 後の再レビュー入口**: 作者が `completed review` を見て「修正必要」と判断 → `starting review work` → 修正完了 → `waiting for review` に戻す → wrapper が再選別・再レビュー
3. **誤 hold の override / 再点検**: wrapper が進めた status を作者が `waiting for review` に巻き戻す → 次回実行で再レビュー(ラベルも自動再評価)
4. **エスカレーション解除の入口(2026-07-10 決定事項)**: `pr.status = "need for human review"` は選別対象外(除外リスト参照)のため、人間が続行可否を判断したうえで `pr.status` を `waiting for review` に手動で戻さない限り再レビューされない。戻した場合、次回実行で再レビューされ、`ESCALATE == false` なら `need for human review` ラベルも自動的に外れる(まだ停止条件に該当するなら再び `need for human review` へ戻る)。

GitHub の `ready for merge` / `need for human review` ラベルは wrapper が自動管理(作者は触らない想定。触ると plan-progress と drift する)。

## パラメータ(orchestrator が dispatch 時に渡す値)

- **リポジトリ**: orchestrator が実行している CWD の repo。`.harness/plan-progress.json` はこの repo のものを使う。
- **effort**: 省略時 `medium`。`review-mode=multi-angle` では `reviewing-multi-angle` skill 経由で内部の `/code-review` に渡される値(`low` / `medium` / `high` / `max` / `ultra`)。`review-mode=code-review`(既定)では、issue #49 以降 `/code-review` を直接呼ばないため、`${CLAUDE_PLUGIN_ROOT}/collectors/strategy.md` が起動する角度別 finder への「どこまで広く/深く探すか」の目安として渡す(finder は `collectors/strategy.md` 手順 2 が解決した角度分割を常に行うため、effort は角度数そのものではなく各 finder の探索の広さに効く緩やかな指示に留まる — 旧 `/code-review` 呼出時ほど厳密な段階制御ではない)。基本は `medium`(high-confidence の少数 findings)。broad recall が欲しければ `high`、final ゲートは `max`。`ultra` は高コスト・通常不要。
- **review-mode**: 省略時 **`code-review`**(角度別 finder による候補収集 + 独立検証・issue #49・**個人 skill 不要**)。opt-in 値 `multi-angle`(現行の 3 skill 並列・`reviewing-multi-angle` 等の個人 skill が必要)。`commands/harness-orchestrate.md` から dispatch される場合、起動時に受け取った review-mode をそのまま引き継ぐ。
- 1 回の上限: **5 件**(暴走防止)。

## 手順

0. **同期 + 前提検査** — 選別の前に必ず行う:
   - **台帳の参照**: 台帳 (`.harness/plan-progress.json`) は git にコミットしないローカル台帳(issue #11 F案)なので、`git pull` は行わず、main checkout の所定位置にあるローカルファイルをそのまま読む。台帳の書込主体は単一(orchestrator のみ)なので、選別に使う台帳は常にこのローカルファイルが正(`.harness/CLAUDE.harness.md` の「台帳の書込経路」節)。
   - **前提コマンドの存在検査**: `gh` / `python3` / `jq` がすべて使えることを確認する。1 つでも無ければ「前提コマンド <名前> が見つからない。インストール後に再実行すること」とエラーで停止する。`gh` は存在に加えて `gh auth status` で認証も確認する (`/harness-init` 手順 0 と対称 — 未認証のまま選別・レビューに進まない):
     ```
     for c in gh python3 jq; do command -v "$c" >/dev/null || { echo "前提コマンド $c が見つからない"; exit 1; }; done
     gh auth status >/dev/null 2>&1 || { echo "gh が未認証 (gh auth login で認証してから再実行する)"; exit 1; }
     ```
   - **前提の存在検査(review-mode で分岐)**: 1 つでも無ければ「前提 <名前> が見つからない。インストール後に再実行すること」と**明確なエラーで停止する**(観点が欠けたまま黙ってレビューしない):
     - `review-mode=code-review`(既定・issue #49): 候補収集は orchestrator が pr reviewer dispatch 前に完了させている前提のため、候補ファイルパスは常に渡される(この前提検査は不要)。**個人 skill には依存しない**(`/code-review` 呼出をやめたため、Claude Code 標準 skill の存在確認も不要)。
     - `review-mode=multi-angle`: 現行通り次の 4 つがすべて使えることを確認する:
       - `reviewing-multi-angle` / `reviewing-pr-architecture` / `reviewing-pr-google-method`: `test -f ~/.claude/skills/<name>/SKILL.md`
       - `/code-review`: Claude Code 標準 skill として利用可能 skill 一覧にあること

1. **選別** — 台帳を `jq` で読み、対象を上限 5 件抽出(`PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"`。無ければ「`/harness-init` 未実行」とエラーで停止)。`unique_by(.number)` は複数 step が同一 PR を共有するケースで同じ PR を 1 tick に複数回レビューしないための重複除去(`[:5]` の前に掛ける):
   ```
   jq -c '[ .steps[]
     | select(.pr.number != null and .pr.githubState == "open")
     | select(.pr.status == "created pr" or .pr.status == "waiting for review")
     | {id, number: .pr.number, status: .pr.status} ] | unique_by(.number) | .[:5]' "$PLAN"
   ```
   0 件なら「レビュー対象 PR なし」と報告して終了。

2. **open / non-draft 再確認(stale json ガード)** — 各対象 PR を `gh pr view <n> --repo <repo> --json state,isDraft,headRefName,headRefOid,baseRefName` で取得。`state != OPEN` または `isDraft == true` なら json が stale もしくはレビュー対象外。レビューせずスキップし、報告に「#N は GitHub 上 closed/merged/draft(json stale)」と出す。

3. **レビュー開始マーカーを立てる** — レビュー実行前に `pr.status` を **`starting review`** に進めて、選別時の status を `pr.lastReviewedStatus` に保存(透明性: 「いま wrapper がレビュー実行中」を観測可能に):
   ```
   # ORIG = 選別時の status(レビュー時の status として記録)
   jq --argjson n <n> --arg orig "<ORIG>" --arg d "$(date +%F)" \
     '(.steps[] | select(.pr.number == $n) | .pr.status) = "starting review"
      | (.steps[] | select(.pr.number == $n) | .pr.lastReviewedStatus) = $orig
      | .updatedAt = $d' \
     "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
   ```
   **台帳の書込はローカルファイル編集のみ**(下記「台帳書込の規約」)。書込後は Statuses API 自己申告を行う(下記「台帳検証の自己申告」)。

   > **台帳書込の規約(手順 3 / 6 共通)**: 台帳 (`.harness/plan-progress.json`) は git にコミットしないローカル台帳(issue #11 F案)。状態遷移は上記の `jq` によるローカルファイル編集だけで完結させ、**`git add` / `git commit` / `git push` は行わない**(main への直接 push を禁止するポリシーのリポジトリでもそのまま動く)。作業ツリー上で台帳が「変更あり」の状態になるのは正常。書込主体は単一(`commands/harness-orchestrate.md` のみ)。
   >
   > **台帳検証の自己申告(手順 3 / 6 共通・Statuses API)**: 状態遷移をローカルに書いたら、ローカル validator の実行結果を **対象 PR の head SHA**(手順 2 で取得した `headRefOid`)に対して Statuses API で報告する。これが「commit されない台帳」の機械検証の代わり(GitHub ホスト CI は commit されない台帳を検証できないため)。branch protection の required check はこの context(`harness-gate`)を指定する。
   > ```
   > # schema/drift をローカル実行し、結果を PR head SHA に Statuses API で報告する
   > # (実体は scripts/report-ledger-status.sh — commands/harness-orchestrate.md と共有する
   > #  単一 script。ROOT="$(git rev-parse --show-toplevel)" から PLAN/validator を全て
   > #  絶対パスで解決するため CWD が repo ルート以外でも失敗しない。報告ロジックを散文に複製しない)
   > bash "${CLAUDE_PLUGIN_ROOT}/scripts/report-ledger-status.sh" "<repo>" "<headRefOid>"
   > # 引数: $1=<owner/repo> $2=<head_sha(=手順 2 の headRefOid)> [$3=context(省略時 harness-gate)]
   > ```
   > Check Run 作成(Checks API)は GitHub App 認証専用で個人 `gh auth`(PAT/OAuth)では作れないため、必ず **Statuses API**(`POST /repos/{owner}/{repo}/statuses/{sha}`)を使う。**この自己申告は独立検証ゲートではなく便宜シグナルである**(spoof 可能。詳細は `.harness/CLAUDE.harness.md`「台帳の書込経路」節)。

4. **各 PR をレビューする(review-mode で分岐)**:

   ### 4-a. `review-mode=multi-angle`

   CWD のチェックアウトに対して動くため、事前に **per-PR git worktree を作成**して隔離する(user の作業ツリーを汚さない):
   ```
   git fetch origin <headRefName> --quiet
   WORKTREE=".claude/worktrees/review-pr-<n>"
   git worktree add --detach "$WORKTREE" "origin/<headRefName>"
   ```

   > **finder / verifier は `subagent_type: "general-purpose"` で起動する(`fork` を使わない)**: `/reviewing-multi-angle` は内部で `/code-review` を含む 3 skill を fan-out し、`/code-review` はさらに角度ごとの finder と候補ごとの verifier を Agent ツールで fan-out する。ここで `fork` を使うと壊れる — fork は呼出元の会話コンテキストを丸ごと継承する設計のため、finder が「この角度だけ見ろ」という狭い directive を無視し、継承した文脈から**呼出元の最上位タスクを再実行**する(別 schema での応答・呼出元が使用中の worktree の無断削除を実測)。`general-purpose` は文脈を継承しないためこの逸脱が起きない。実測: fork は 6/6 で逸脱し 1 件も findings を返せず、general-purpose は完了確認できた finder が全て割り当てられた角度のみを正しい schema で返した。**このモードは finder が reviewer(orchestrator から見れば孫)の子として起動される構造のまま**であり、issue #49 が解消した観測不能問題(下記 4-b 参照)は本モードには適用されない — `review-mode=multi-angle` は issue #49 のスコープ外(現状維持・follow-up 対象)。

   `/reviewing-multi-angle` skill が `/code-review`(correctness)+ `reviewing-pr-architecture`(YAGNI/6 観点)+ `reviewing-pr-google-method`(命名/規約/テスト品質)を per-PR で 3 並列 spawn → dedup + 優先度付け + 統合 max 10 件 + `summary_markdown` 組み立てまで担う:
   ```
   ( cd "$WORKTREE" && /reviewing-multi-angle <effort> )  # 統合 findings JSON + summary_markdown を取得
   ```
   - 取得する出力(skill が返す JSON):
     ```json
     {
       "findings": [{"file","line","summary","failure_scenario","severity","sources"}, ...],
       "has_blocker": true|false,
       "truncated": N,
       "summary_markdown": "## Multi-angle review findings\n..."
     }
     ```
   - `summary_markdown` は **per-finding 詳細・判定・専担領域メモまで含む完成形** で、手順 5 の本文組み立てでそのまま使う
   - **skill が返す `has_blocker` は参考値**(「1 件でも 🔴」の skill 定義)。merge 可否は手順 5.5 の再集計で決める
   - worktree の後片付け(このモードのみ・4-b は自分で worktree を作らないため不要): `git worktree remove --force "$WORKTREE"`

   ### 4-b. `review-mode=code-review`(既定・issue #49 — finder を reviewer の子にしない)

   **候補収集(finder)は reviewer 自身が担わない**。**finder は「収集を実行する主体」(orchestrator)の直接の子であり、reviewer の子(≒ orchestrator から見た孫)にはならない**:

   - dispatch prompt に、orchestrator が自身の直接の子として角度別 finder を起動し収集済みの候補ファイルのパス(例: `<OUT_DIR>/findings.json`)が渡されている。**この手順では finder を起動せず、そのファイルを Read するだけでよい**(orchestrator が pr reviewer を dispatch する前に候補収集を完了させている — 詳細は `commands/harness-orchestrate.md`「pr reviewer」節)。
     ```
     FINDINGS_JSON=$(cat "<渡された findings.json のパス>")
     ```

   `contracts/findings.schema.json` が規定する形(`{file, line, summary, failure_scenario}`)の JSON 配列(0 件なら `[]`)を得る(`severity` フィールドは無い。角度別 finder の収集は correctness に加えて reuse/simplification/efficiency 等の cleanup 角度も含むため、cleanup 系の finding が混在しうる)。**ここから先(候補ごとの事実確認・severity 付与・採否判断)が独立検証であり、finder には行わせず reviewer 自身が行う**(doer ≠ judge — 収集は機械的、判定は reviewer):
   - **Phase 2 検証(CONFIRMED/PLAUSIBLE/REFUTED・旧 `/code-review` の幻覚除外に相当・severity 付与より先に行う)**: severity を付与する前に、各候補が diff 上に実在するかを wrapper 自身が確認する。角度別 finder は収集専任(手順本文でも「判定は行わない」と明言)であり幻覚・事実誤認を含みうるため、この検証を欠くと `has_blocker` 判定やコメント投稿が虚偽の候補に基づくことになる:
     - **diff の取得**: `gh pr diff <n> --repo <repo>` で PR の diff を取得する(finder が使った候補収集用 worktree は `${CLAUDE_PLUGIN_ROOT}/collectors/strategy.md` 手順 6 で既に削除済みのため、reviewer 側で改めて取得する)
     - 各候補について、`file` / `line` 付近の diff 内容と `summary` / `failure_scenario` を照合し、3 値で判定する:
       - **CONFIRMED**: diff の該当箇所を確認し、指摘する問題が実在すると判断できる
       - **PLAUSIBLE**: 実在の疑いは残るが diff だけでは断定できない(周辺コード・呼び出し元の追加確認が要る等) — fail-closed で「除外しない」側に倒し、次の severity 判定へ進める(このリポジトリの「過剰 hold の方が安全」哲学と一致)
       - **REFUTED**: diff を確認した結果、指摘対象の箇所が存在しない・diff の内容と矛盾する・finder の事実誤認や幻覚だと判断できる
     - **REFUTED と判定した候補は、severity 付与・has_blocker 集計・投稿する findings から除外する**(そのまま fail-closed で 🔴 に倒すと幻覚が blocker として merge を止めてしまうため)。除外理由は捨てずに残す — `summary_markdown` の末尾に「検証で REFUTED として除外した候補(参考)」として一覧化し、手順 5 で投稿する(何を・なぜ除外したかを作者が確認できるようにする。除外自体を隠さない)
     - CONFIRMED / PLAUSIBLE と判定された候補のみ、次の severity 分類に進む
   - **severity の分類(意味判断・独立検証)**: Phase 2 検証を通過した各 finding について、wrapper を実行している Claude 自身が `summary` + `failure_scenario` を読み、**意味的に** severity を付与する(キーワード表には依らない — 表に無い語彙の真正 correctness bug を 🟡 に落として素通しさせる過補正を避けるため):
     - **correctness 欠陥**(誤挙動・crash・データ破損・security・ロジックバグ・選別条件の逆・境界誤り等、**正しさに影響するもの**)→ `severity = "🔴"`
     - **cleanup / simplification / efficiency / style の提案**で**正しさに影響しないもの** → `severity = "🟡"`
     - **fail-closed の傾け方**: その finding が正しさに影響するか**判断が付かない場合は 🔴 に倒す**(このリポジトリの「過剰 hold の方が安全」哲学と一致。実バグが 🟡 に落ちて ready for merge を素通りするのを防ぐ)
     - **multi-angle モード(4-a)と同じ構造**: multi-angle でも各 sub-skill が 🔴/🟡 を**意味的に**付与し、その後 `reaggregate-has-blocker.py` で決定論的に集約する。code-review モードも同じ境界を保つ — **severity タグは意味判断、has_blocker 集約は script(手順 5.5)による決定論**。severity タグの付け方が変わるだけで、集約の決定論性は失われない
   - `sources = ["code-review"]`・`file`/`line`/`summary` はそのまま JSON の値を使う
   - `truncated = 0`(角度別 finder の収集は角度ごとの上限を持たないため、旧 `/code-review` 呼出時にあった「8 件超は最も重大な 8 件に絞る」truncation は発生しない。ただし個々の finder が探索を打ち切った可能性はあり、その検出手段は無い — 既知の限界として報告に残すに留める)
   - `summary_markdown` は wrapper が findings を箇条書きで組み立てる簡易版(例: `## code-review findings\n\n1. \`path:line\` — summary(severity)\n...` または findings 0 件なら `## code-review findings\n\nfindings 0 件 ✅`)。REFUTED 判定で除外した候補があれば、末尾に `### 検証で REFUTED として除外した候補(参考)\n\n- \`path:line\` の指摘: 除外理由\n...` を追記する(0 件ならこの節自体を省略)
   - この正規化後は 4-a と同じ形の findings 配列として手順 4.5 以降(増分レビュー・投稿・再集計・停止条件)にそのまま渡す

4.5. **増分レビュー(既出 findings の差分計算)** — 同一 PR への 2 回目以降のレビューで、前回と同じ指摘をそのまま再掲しない(作者のノイズ削減と 3 観点並列コストの節約。**判定には影響させない**):
   - `gh pr view <n> --repo <repo> --json comments` で過去の `# PR Reviewer` コメントを取得し、既出 findings を `(file, line, summary)` で抽出
   - 今回の `findings[]` と突き合わせ、各 finding を **新規 / 既出(持ち越し)** に分類
   - **判定(手順 5.5)は分類に関係なく全 findings で行う**(未解消の既出 🔴 は依然 blocker — 増分は「見せ方」の工夫であって判定の緩和ではない)
   - 投稿本文(手順 5)では既出分に「(前回指摘・未解消)」の注記を付け、報告(手順 8)の findings 列は `M 新規 / K 既出` で書く
   - 初回レビュー(過去 `# PR Reviewer` コメント無し)はこの手順をスキップ

4.6. **DoD 照合(issue #50 B2・固定値 DoD の独断書き換え検出)** — 症状2(doer が受け入れ条件(DoD)を独断で書き換えられる問題。issue #50)への対策。**decision script ではなく reviewer 自身の意味判断**(DoD の識別・書き換えの有無・根拠の妥当性はいずれも自然文の解釈を要するため。`has_blocker` への反映は既存の決定論的な手順 5.5 がそのまま担う — 新設 source を `reaggregate-has-blocker.py` に追加する必要は無い、詳細は下記):
   - **対象 issue の特定(読み取りのみ・issue には一切書き込まない)**: PR 本文(手順 0 で取得済み、無ければ `gh pr view <n> --json body` で改めて取得)から `Closes #<N>` / `Fixes #<N>` 等で紐づく issue 番号を抽出する(実装役の pr_number 復旧検索と同型の抽出パターン)。紐づく issue が無ければこの手順をスキップする。
   - `gh issue view <N> --json body` で issue 本文の DoD(受け入れ条件)節を読む。
   - **固定値 DoD の識別規則(issue #50 round1 決定 🔴3)**: DoD が具体値(数値・閾値・完全一致文字列)を指定していて、かつ「着手時に確定してよい」旨のマーカー文言(例:「着手時に確定する」「着手時に subset 確定後に立てる」)が issue 本文に**無い**節は**固定値 DoD**(書き換え禁止)。マーカーが**在る**節は**着手時確定 DoD**(実装役が値を確定してよいが、根拠の独立判定が必要)。
   - 対象 PR の diff・PR 本文・commit 履歴を確認し、DoD の値が issue 本文の値と異なる形で実装されている(= 書き換えられている)兆候が無いか点検する:
     - **兆候なし**(DoD どおりに実装されている) → 何もしない。
     - **兆候あり かつ 固定値 DoD(マーカー無し)** → **blocker finding を 1 件追加する**(`.harness/CLAUDE.harness.md`「対応側が `ready for merge` を立てるのは越権」と同じ精神 — DoD の独断書き換えも越権):
       ```json
       {"file": "issue #<N> DoD", "line": 0,
        "summary": "固定値 DoD の独断書き換え(マーカー無し)",
        "failure_scenario": "issue #<N> の DoD『<原文抜粋>』はマーカー無しの固定値だが、PR は<書き換え後の値/実装>に合わせて実装している。受け入れ条件を doer が独断で反証不能にした越権(issue #50 症状2)。",
        "severity": "🔴", "sources": ["dod-check"]}
       ```
     - **兆候あり かつ 着手時確定 DoD(マーカー有り)**: PR 本文に確定した値と根拠が明記されているか確認する。**明記が無い**、または**根拠が薄い**(実測値に事後で合わせただけ等、反証可能性を失わせる確定)と判断したら、上記と同型の blocker finding を 1 件追加する(`summary`: 「着手時確定 DoD の根拠不備」)。**根拠が明記され妥当と判断できれば finding は追加しない**(合格 — PR #41 が無害だった前例と同型の判定)。
   - この手順の finding(あれば)は手順 4 の `findings[]` に合流させ、以降(手順 4.5 の増分計算・5.5 の has_blocker 再集計)へ通常の finding と同じ扱いで乗せる。**severity=🔴 は `reaggregate-has-blocker.py` の規則上 source に関わらず必ず blocker になる**ため、`sources: ["dod-check"]` が未知の source 表記でも判定は正しく機能する(fail-closed の恩恵をそのまま受ける)。
   - **触らない**: この手順は issue 本文・DoD を**読むだけ**で、issue 側には一切書き込まない(issue の書換は issue review worker の責務であり本コマンドの対象外。「触らないものを厳守」節参照)。

5.5. **has_blocker 再集計(harness-kit 定義)** — **判定は LLM の解釈で行わない**。手順 4 の `findings[]`(4-a は skill 出力そのまま、4-b は wrapper 正規化後)を stdin で `${CLAUDE_PLUGIN_ROOT}/scripts/reaggregate-has-blocker.py` に渡し、その出力を判定として使う(決定論)。**手順 5 の投稿本文にマーカー(手順 5.6)を含めるため、この手順は手順 5 より前に実行する**(番号は既存の慣習(5.5 = 手順 5 の直後で行う集計処理)を踏襲するが、依存関係上は投稿前に計算が必要):
   ```
   # FINDINGS_JSON = 手順 4 の findings 配列(JSON 文字列)
   RESULT=$(printf '%s' "$FINDINGS_JSON" | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/reaggregate-has-blocker.py")
   # -> {"has_blocker": true|false, "blocker_count": N,
   #     "unknown_source_blockers": [...], "unknown_severity_blockers": [...]}
   ```
   - 意図: 🔴 に加え arch/google 由来の 🟡 も blocker に含める(ゴム印対策)。**規則の正は `scripts/reaggregate-has-blocker.py`**(prose に規則を複製しない。判定は必ずスクリプト実行で行い、exit 2(入力エラー)ならレビューを進めず状態を報告して停止する — 黙って LLM 判定に切り替えない)
   - `unknown_source_blockers` / `unknown_severity_blockers` が空でなければ、報告に「未知の source / severity 表記を blocker 扱いした(fail-closed)」と 1 行残す
   - skill が返した `has_blocker`(review-mode=multi-angle の参考値。review-mode=code-review では該当なし)と再集計結果が異なる場合は、報告にその旨を 1 行残す(判定の透明性)

5.6. **停止条件の判定(round_flag / trend_flag / escalate)** — **判定は LLM の解釈で行わない**。has_blocker 再集計(手順 5.5)と同じく、規則の正は `${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-stop-condition.py`。wrapper の責務は I/O のみ(マーカー抽出 → JSON 組み立て → script 実行 → 結果を投稿本文に反映)で、round_flag/trend_flag/escalate の規則そのものは prose に複製しない。**この手順は常に実行する**(マーカー埋め込み・🛑 セクション表示は無条件)。**エスカレーション時の状態遷移(`pr.status = "need for human review"`)・ラベル管理の実際の実行(単一書込主体)は `commands/harness-orchestrate.md` 側が担う**(2026-07-10 決定事項。reviewer subagent は `escalate` 等の返り値を返すだけ。「触る(専権)」節参照):
   - **round の算出**: 手順 4.5 で取得済みの過去 `# PR Reviewer` コメント一覧を再利用する。`ROUND = (過去の "# PR Reviewer" コメント数) + 1`(今回投稿する分が ROUND 回目)
   - **直近 2 件のマーカー抽出(wrapper の I/O 責務)**: 直近 2 件の過去 `# PR Reviewer` コメント本文末尾のマーカー行(`<!-- harness-review-pr: round=<N> has_blocker=... blocker_count=<M> escalate=... -->`)を **most-recent-first** で grep 抽出する(最大 2 件。旧フォーマット・件数不足で無ければ、その分は渡さず少ない件数のまま渡す — パースと欠損時の fail-open 判定は script 側が担う)。
   - **`$HAS_BLOCKER` / `$BLOCKER_COUNT` の抽出(手順 5.5 の再集計結果 `$RESULT` から)**: 次項の STOP_INPUT 構築とマーカー(手順 5)で使う `$HAS_BLOCKER` / `$BLOCKER_COUNT` は、**手順 5.5 の再集計結果 `$RESULT` を唯一の source として抽出する**。review-mode=multi-angle の手順 4-a skill 出力にも同名 `has_blocker` フィールドがあるが、それは「参考値であり merge 可否判定には使わない」ものなので **ここでは使わない** — 参考値をそのまま `$HAS_BLOCKER` に流用すると、手順 5.5 のゴム印対策の再集計(arch/google 由来の 🟡 も blocker に含める)が escalate 判定・マーカー・`blocker_count` 推移から抜け落ちる。review-mode=code-review / multi-angle どちらも source は手順 5.5 の `$RESULT` で一貫させる:
     ```
     HAS_BLOCKER=$(printf '%s' "$RESULT" | jq -r '.has_blocker')      # "true" / "false"(STOP_INPUT の sys.argv[2] 判定に合わせる)
     BLOCKER_COUNT=$(printf '%s' "$RESULT" | jq -r '.blocker_count')  # 整数
     ```
   - **JSON を組み立てて script に渡す**(判定は必ず script 実行で行う。`reaggregate-has-blocker.py` と同じ扱い):
     ```
     STOP_INPUT=$(python3 -c 'import json,sys; print(json.dumps({
       "round": int(sys.argv[1]),
       "has_blocker": sys.argv[2] == "true",
       "blocker_count": int(sys.argv[3]),
       "prev_markers": [m for m in sys.argv[4:] if m]  # most-recent-first, 最大 2 件
     }))' "$ROUND" "$HAS_BLOCKER" "$BLOCKER_COUNT" "$MARKER_N_MINUS_1" "$MARKER_N_MINUS_2")
     STOP=$(printf '%s' "$STOP_INPUT" | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-stop-condition.py")
     # -> {"escalate": bool, "round_flag": bool, "trend_flag": bool, "reason": str}
     ESCALATE=$(printf '%s' "$STOP" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["escalate"]).lower())')
     ESCALATE_REASON=$(printf '%s' "$STOP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])')
     ```
     - script 内のロジック(prose に複製しない・テストは `tests/smoke/run-smoke.sh` [7] が担保): `round < 3` は escalate 固定 false / `round_flag = round≥5 かつ has_blocker` / `trend_flag = blocker_count が 2 回連続で非改善(履歴不足・マーカー不正時は不成立の fail-open)` / `escalate = (round_flag or trend_flag) かつ has_blocker` / `reason` は成立条件に応じた文字列(escalate=false なら空)。
     - **script が exit 2**(入力エラー)なら、レビューを進めず状態を報告して停止する — **黙って LLM 判定に切り替えない**(`reaggregate-has-blocker.py` の扱いと同じ)。
   - script が返した `ESCALATE` / `ESCALATE_REASON` を手順 5 の投稿本文(🛑 節・マーカーの `escalate` フィールド)に使う(手順 5 は `ESCALATE == "true"` のときだけ `ESCALATE_REASON` を参照する)。

5. **投稿(H1 ヘッダー必須)** — skill が返す(または 4-b で正規化した)`summary_markdown` を本体として、wrapper 側で **H1 ヘッダー + 1 行イントロ + 証拠錨 + (escalate 時のみ 🛑 停止条件節) + マーカー + footer** をラップして投稿する(本文組み立てロジックは skill/正規化側に移譲済みで、wrapper は薄く保つ)。**手順 5.5 / 5.6 を先に実行し、その結果(`RESULT` / `ROUND` / `ESCALATE`)を使って本文を組み立ててから投稿する**:
   ```
   # 台帳から証拠錨を読む(done が無ければ test にフォールバック)
   EVIDENCE_DONE=$(jq -r '.evidence.done // .evidence.test // "未定義"' "$PLAN")
   REVIEW_LABEL_LINE=$([ "$REVIEW_MODE" = "multi-angle" ] \
     && printf '`/reviewing-multi-angle %s` で点検しました(3 観点並列: /code-review + reviewing-pr-architecture + reviewing-pr-google-method、dedup + 優先度付け済み、統合 max 10 件)。\n' "$EFFORT" \
     || printf '角度別 finder が収集した候補(effort=%s 目安)を独立検証して点検しました(review-mode=code-review)。\n' "$EFFORT")
   {
     printf '# PR Reviewer - レビュー実施\n\n'
     printf '%s\n' "$REVIEW_LABEL_LINE"
     printf '**証拠錨**: merge 前に `evidence.done`(`%s`)が exit 0 であることを作者が確認すること(台帳 `.harness/plan-progress.json`)。\n\n' "$EVIDENCE_DONE"
     # summary_markdown をそのまま挿入(per-finding 詳細・判定・専担領域メモまで含む完成形。既出分は「(前回指摘・未解消)」を注記)
     printf '%s\n' "$SUMMARY_MARKDOWN"
     if [ "$ESCALATE" = "true" ]; then
       printf '\n### 🛑 停止条件: 人間引き渡し\n\n'
       printf '%s\n\n' "$ESCALATE_REASON"  # 例: "round 上限到達(round 5)" / "blocker 件数が改善していない(round 3 → 4 → 5: 2 → 3 → 3 の推移)"
       printf 'このまま「指摘を直して再提出」を機械的に繰り返すのではなく、**根本原因(設計そのものの問題か、対応方針自体が誤っているか)を人間が判断してください**。\n'
     fi
     printf '\n<!-- harness-review-pr: round=%s has_blocker=%s blocker_count=%s escalate=%s -->\n' "$ROUND" "$HAS_BLOCKER" "$BLOCKER_COUNT" "$ESCALATE"
     printf '\n<sub>🤖 Generated with [Claude Code](https://claude.com/claude-code) — pr reviewer role (review-mode=%s)</sub>\n' "$REVIEW_MODE"
   } > <tmpfile>
   gh pr comment <n> --repo <repo> --body-file <tmpfile>
   ```
   - H1 ヘッダー(`# PR Reviewer - レビュー実施`)が無いと PR コメント一覧で「どのロールが投稿したか」が一目で分からなくなる(同一 GitHub アカウントから複数ロールが投稿するため)
   - `EVIDENCE_DONE` が `未定義` の場合はその旨を明記し「`/harness-init` で証拠を定義すること」を添える(黙って省略しない)
   - マーカーはコメント本文の**機械可読な末尾**(footer の前)に必ず埋め込む。`commands/harness-orchestrate.md` はこのマーカーではなく、pr reviewer dispatch の返答(`{escalate,...}`)から直接 `escalate` を受け取るため、マーカーの主目的は**人間が PR コメント一覧を見て停止条件の推移を追えるようにする透明性**である
   - `pr.status` の遷移先はこの手順では変更しない(変更は手順 6)。`escalate` は台帳に一切書かない(マーカー・コメント本文のみに現れる)

6. **レビュー完了マーカー(自動進行 + ラベル管理)** — 手順 5.5 の再集計 `has_blocker` と手順 5.6 の `ESCALATE` で `pr.status` を自動進行し、`ready for merge` / `need for human review` ラベルを同期する。**`ESCALATE` を最優先で分岐する**(`evaluate-stop-condition.py` の定義上 `escalate=true` は `has_blocker=true` を必ず伴うため、`ESCALATE == "true"` の分岐が `has_blocker` の分岐に優先する):
   - `ESCALATE == "true"`(停止条件到達。2026-07-10 決定事項 — `ready for merge` と対称に、reviewer が設定できる終端手前の状態):
     - `pr.status = "need for human review"`
     - ラベル作成 fallback: `gh label create "need for human review" --color "d93f0b" --description "reviewer が停止条件に到達し人間の判断を要求した PR" --force`(冪等。色は `commands/harness-orchestrate.md` の同名ラベル付与と揃える — 単一ラベルを両経路が共有するため)
     - `gh pr edit <n> --repo <repo> --add-label "need for human review"`(冪等)
     - `gh pr edit <n> --repo <repo> --remove-label "ready for merge"`(`has_blocker == true` 分岐と同じ理由で除去。付いていなければ警告のみで実害なし)
     - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(無ければ警告のみで実害なし)
   - `ESCALATE == "false"` かつ `has_blocker == false`:
     - `pr.status = "ready for merge"`
     - ラベル作成 fallback: `gh label create "ready for merge" --color "0e8a16" --description "reviewer が merge 可能と判定した PR" --force`(冪等。旧版の init で初期化した導入先や手動削除でラベルが無くても、直前に commit した status とラベルが乖離しない — 自己修復。**定義の原本は `/harness-init` の仕上げ節 — 変更時は同文を維持する**。`--force` は既存ラベルの色・説明も上書きするため、片側だけ変えるともう一方の実行のたびに旧定義へ上書きし直されて変更が定着しない)
     - `gh pr edit <n> --repo <repo> --add-label "ready for merge"`(冪等)
     - `gh pr edit <n> --repo <repo> --remove-label "need for human review"`(エスカレーション解除後の掃除。付いていなければ警告のみで実害なし)
     - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(旧版 kit の付与分。新旧の merge 可シグナルが併存し続けるのを防ぐ — true 分岐と対称。無ければ警告のみで実害なし)
   - `ESCALATE == "false"` かつ `has_blocker == true`:
     - `pr.status = "completed review"`
     - `gh pr edit <n> --repo <repo> --remove-label "ready for merge"`(付いていなければ警告のみで実害なし)
     - `gh pr edit <n> --repo <repo> --remove-label "need for human review"`(エスカレーション解除後の掃除。付いていなければ警告のみで実害なし)
     - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(旧版 kit が付与した旧名。残すと台帳は completed review なのに GitHub 上は merge 可シグナルが立ったままになるため、付与側の作成 fallback と対でこの故障クラスを 1 行で閉じる。無ければ警告のみで実害なし)
   ```
   # NEW=自動進行先
   jq --argjson n <n> --arg new "<NEW>" --arg d "$(date +%F)" \
     '(.steps[] | select(.pr.number == $n) | .pr.status) = $new
      | .updatedAt = $d' \
     "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
   ```

   **作業レポートの追記 (`reports[]`)** — 判定を確定させた本手順で、対象 step の `reports[]` へ pr reviewer の作業レポートを 1 件追記する (規約は `.harness/CLAUDE.harness.md`「作業レポートの書込」節。best-effort・ローカル編集のみ・commit/push しない)。**追記は上の status 書込に隣接させ、下記「台帳検証の自己申告」(`report-ledger-status.sh`) より前に行う** — 自己申告 (head SHA への Statuses post) が status と reports を含む遷移後の台帳全体を写すようにするため (report 単体の妥当性は書込側の責務。現行 `--schema` は reports を検査しない — 詳細は規約節)。**書込主体**: reviewer subagent は台帳へ直接書かず、`contracts/reviewer-return.schema.json` が規定する形(`{has_blocker, blocker_count, escalate, review_markdown}`。手順 5.5/5.6/5 で確定済みの値)を返り値として返す。実際の `reports[]` 書込は単一 writer (`commands/harness-orchestrate.md`) が行う (単一書込主体原則 — 子が直接台帳を書くと規律違反)。**配線は issue #52 症状2で実装済み** — `author`/`role` = `"pr reviewer"`/`"reviewer"`、`timestamp` の付与、`body`(判定結果 + `blocker_count`)の組み立てはいずれも単一 writer 側(`commands/harness-orchestrate.md`「作業レポートの代筆」節)が行うため、reviewer subagent の返り値に追加の report 専用フィールドは不要(既存の判定結果フィールドから合成する)。

   status と reports の書込後は「台帳書込の規約」(手順 3)に従いローカルファイル編集のみで完結させ(commit/push しない)、続けて「台帳検証の自己申告」(手順 3)に従い対象 PR の head SHA へ Statuses API で報告する。

7. **触らないものを厳守(doer ≠ judge の固定線)** — `pr.status` / `pr.lastReviewedStatus` / GitHub の `ready for merge` / `need for human review` ラベル以外は触らない:
   - **終端 status(`merged pr` / `closed issue`)は書かない** — **`ready for merge` / `need for human review` が reviewer の上限**。その先(実際の merge / close と終端 status の記録、またはエスカレーション後の続行可否判断)は人間の責務(ただし人間の明示指示がある場合の代行は例外 — 詳細は `.harness/CLAUDE.harness.md`『終端の記録と merge 代行』節を参照)
   - `githubState` は**書かない**(GitHub の実態を写す欄。更新は作者の責務で、乖離は台帳検証の drift 照合が検知する)
   - PR 本文の編集・close・merge は**しない**
   - `issue.status` / `issue.lastReviewedStatus` は**触らない**(作者の責務)
   - GitHub 上の他のラベル(`bug` / `enhancement` 等)も**触らない**(唯一の例外: 旧名 `merge ready` の**除去** — 手順 6 の移行掃除。付与は例外にしない)
   - issue へのコメント投稿も**しない**(本コマンドは PR コメントのみ)
   - **自動修正モード(`--fix` 系)は使わない**(findings は作者が検証して採否)

8. **報告** — 「次に作者が何をすべきか」が一目で分かるレポートを出す。**対象あり / 対象なし** で 2 形式を使い分け、PR 参照は番号 + タイトル併記。

   ### A. 対象あり(N ≥ 1 件処理)

   ````markdown
   ## 📋 Step 8 報告: PR レビュー wrapper 1 tick 完了

   **実施: HH:MM**(local time、`date +%H:%M` 出力)

   ### 📊 処理サマリ(N 件)

   | PR | タイトル | レビュー時 status → 自動進行先 | findings | 再集計 has_blocker | ready for merge ラベル | コメント |
   |---|---|---|---|---|---|---|
   | #N | (PR タイトル) | (lastReviewedStatus) → **(新 status)** | M 新規 / K 既出 | true/false(skill 値と差異あれば注記) | 付与 / 除去(冪等) | [#issuecomment-...](URL) |

   ### 🔍 各 PR の findings(per-PR 詳細)

   **#N (PR タイトル)** — 再集計 has_blocker=true/false
   1. `path/to/file.py:42` — summary 1 行(severity / sources)
      failure_scenario を 80〜120 字程度で要約(長文は省略)
   2. ...

   (findings 0 件の PR は `findings 0 件 ✅` の 1 行のみ)

   ### ⚠️ 注目 finding(あれば)
   - **`#N file.py:42` CONFIRMED real bug**: 影響と 1 行 fix を簡潔に
   - (他に重要な指摘があれば箇条書き、無ければセクションごと省略)

   ### ⏭️ スキップ(あれば)
   - #M は GitHub 上 closed/merged/draft(json stale)— `pr.githubState` 更新は作者責務

   ### 🔁 解除条件チェック(loop コンテキストの任意)
   - ✅ 全 open PR が settled(`completed review` or `ready for merge`)→ loop 解除候補
   - もしくは ⏳ 未達(継続中: #?: starting review work, …)

   ### ↩️ 誤判定の巻き戻し方
   判定を再点検したい場合は `pr.status` を `waiting for review` に巻き戻す(台帳のローカル編集)→ 次回実行で再レビュー(ラベルも自動再評価)。
   ````

   ### B. 対象なし(0 件、空 tick)

   ````markdown
   ## 📭 レビュー対象 PR なし(0 件)

   **実施: HH:MM**(local time)

   - (open PR 一覧と現 status を箇条書き 3〜5 行 / open がゼロなら「open PR なし」)
   - (前回 tick から変化があれば 1 行コメント、無ければ「変化なし」)
   ````

   ### 形式選択・記述ルール
   - **冒頭の集約表は対象あり時のみ必須**(空 tick で 7 列の表は過剰)
   - PR は必ず `#N (PR タイトル)` 形式で(番号単独 NG)
   - **`failure_scenario` 全文転載は避ける**: 80〜120 字に要約し、詳細は PR コメント本文(投稿済み)に委ねる
   - **注目 finding callout は CONFIRMED bug / 重大度の高い 1〜2 件に絞る**
   - **H2 / H3 見出しに絵文字を必ず付与**(視認性向上。絵文字選定は固定)
   - **実施時刻は冒頭 1 行で `**実施: HH:MM**`**(秒・タイムゾーン不要。複数 PR を同 tick で処理しても 1 行に集約)

単体起動は廃止した(issue #61)。`/loop` での定時実行は `commands/harness-orchestrate.md`「loop での回し方」節を参照 — dispatch された pr reviewer は `$REVIEW_MODE` を orchestrator からそのまま引き継ぐ。dedup は **status 自動進行**が担うので、レビュー済み PR は次の tick で対象外 status になり選別から外れる。作者が `waiting for review` に戻すと自動的に 1 回再レビューが走る。

## 既知の制限・拡張ポイント

- **DoD 照合(手順 4.6・issue #50 B2)は doer ≠ judge の枠に乗る独立検証(症状2 は塞げる)**: 対応役(実装役)が固定値 DoD を独断で書き換えても、本コマンドが独立読み手(別セッション reviewer)として issue 本文と PR 差分を照合し blocker として検出する。**issue #50 が指摘した「症状1(orchestrator/doer 自身の sink 判断)は独立検証ゼロ(自己規律のみ・spoof 可能)」とは非対称** — 症状2(DoD 書き換え)はこの手順により機械的に塞がれるが、症状1 は塞がれない(詳細は `commands/harness-orchestrate.md`「既知の制限・拡張ポイント」の A1 の項、および issue #50 本文「レビュー反映 — 決定事項」+ owner 決定コメントを参照)。DoD の識別・書き換えの有無・根拠の妥当性の判断自体は自然文解釈のため decision script 化していない(手順 4.6 参照)。
- **status 自動進行のトレードオフ(重要)**: 本コマンドは「レビューを実施する者が自分の判定で status を進める」。現行構成の担保は (1) 別セッション起動による doer ≠ judge のロール分離、(2) `ready for merge` を上限とする終端の人間ゲート、(3) 🟡 まで広げた blocker 再集計、の 3 点。reviewer に reject 誘因を持たせる敵対的 Verifier は現行版では未実装(開発計画は kit リポジトリの README / issue #1)。
- **過剰 hold の逆リスク**: 🟡 を blocker に含めたため、effort=high / max では hold が頻発しうる。緩和条件は (a) effort=medium 固定、(b) 🟡 の件数閾値化(足すときに削り方を決めておく)。
- **可搬性(review-mode=code-review が既定)**: 既定の `review-mode=code-review` は Claude Code 標準の `Agent` ツール(`subagent_type: general-purpose`)のみに依存し、個人 skill にも Claude Code 組込 `/code-review` にも依存しない(issue #49 で `/code-review` 呼出をやめた)ため、他環境でも動く。opt-in の `review-mode=multi-angle` は個人 skill 群(`reviewing-multi-angle` / `reviewing-pr-architecture` / `reviewing-pr-google-method`)に依存し、それらは plugin に**同梱しない**。multi-angle を使う場合はこれらの skill を先に用意する必要がある(README に前提として明記)。
- **review-mode=code-review の網羅範囲(重要)**: 角度別 finder(`${CLAUDE_PLUGIN_ROOT}/collectors/strategy.md`)は correctness に加え reuse/simplification/efficiency 等の cleanup 観点も見る(角度の内訳は `${CLAUDE_PLUGIN_ROOT}/collectors/angles/*.md` 自体を単一の正とする — 角度の増減に伴う本節の更新は不要。いずれも本文の指示だけで探す収集専任・`skill:` 委譲は kit デフォルト角度では使っていない)が、アーキテクチャ全体設計や既存 `/code-review` 内部実装が持っていたかもしれない検出精度までは保証しない(本 repo が独自に定義した軽量プロンプトのため)。広い観点や高精度が要る場面(final gate 等)では `review-mode=multi-angle` への切替を検討する。
- **角度別 finder のシャドー保守コスト(issue #49・意図的に抑制)**: `${CLAUDE_PLUGIN_ROOT}/collectors/angles/*.md` の角度分けは既存 `/code-review` の 8 角度分けに倣うが、プロンプト文面は本 repo が独自定義したものであり Anthropic 非公開実装の逐語コピーではない。ゆえに `/code-review` 側の内部実装が変わっても追従不要(独立した資産)である一方、収集される候補の質・網羅性は `/code-review` 本家と一致する保証が無い(既知の限界。悪化が観測されたら reviewer 側の独立検証コストで吸収する方針・角度プロンプト自体は高度化しない — Implementation Scope 参照)。
- **finder の diff/対象コード取得手段(round 2 レビュー指摘・実装で確定)**: `${CLAUDE_PLUGIN_ROOT}/collectors/strategy.md` の実行者(orchestrator)が per-PR worktree(`git fetch` + `git worktree add`)を用意し、finder には worktree の絶対パスと `git diff` の取り方を自己完結する形で渡す。worktree の作成・後片付けは同ファイルの手順に閉じている。
- **角度のユーザーカスタマイズ(issue #65)**: kit デフォルト角度(`${CLAUDE_PLUGIN_ROOT}/collectors/angles/*.md`)に加え、導入先が `.harness/collectors/angles/` に独自観点を追加できる(kit デフォルトとのユニオン。同名ファイルは導入先が上書き・`enabled: false` で無効化)。角度は `skill:` フィールドで既存 skill に収集を委譲できるが、判定を伴う skill は置けない(収集専任のみ・パターン A)。解決ロジックは `collectors/strategy.md` 手順 2 を参照。
- **停止条件(round_flag/trend_flag/escalate)の適用範囲**: 手順 5.5/5.6 は review-mode に関わらず常に実行される(モードごとの has_blocker の出方が違っても、マーカー・停止条件のロジックは共通)。停止条件の規則は `scripts/evaluate-stop-condition.py` に切り出し済みで、`has_blocker` 再集計(`reaggregate-has-blocker.py`)と同じく `tests/smoke/run-smoke.sh` が決定論的に検証する(prose に規則を複製しない)。マーカー埋め込みは reviewer 自身が行うが、**`ESCALATE` に応じた `pr.status = "need for human review"` への状態遷移・ラベル管理の実際の実行(単一書込主体)は `commands/harness-orchestrate.md` 側が担う(2026-07-10 決定事項)** — 詳細は「ロールの契約」節・手順 5.6 の末尾を参照。
- **台帳が repo 内にある意味**: 元方式は選別源が `~/.claude` 配下で参照しづらかったが、本 kit は `.harness/plan-progress.json`(repo 内のローカルファイル)に移したため、ローカル validator が同じ台帳を機械検証し、その結果を Statuses API で自己申告できる。ただし本コマンド自体のレビュー実行・自己申告は引き続き Claude セッションが必要(無人化は現行版では未対応)。
- **CWD 隔離(worktree)コスト**: PR ごとに worktree 作成・削除のオーバーヘッドあり。1 tick 5 件上限のため許容範囲。残骸が残ったら tick 開始時に `git worktree prune` で掃除推奨。
- **`reviewing-multi-angle` のコスト(3x 化)**: 内部で 3 review skill を並列実行するため、単独 `/code-review` 比で約 3x のトークン消費。`/loop` の間隔は **30 分以上推奨**。
- **PR 本文編集後の再レビュー**: status が `ready for merge` / `completed review` / `need for human review` のままなら再発火しない。即時再レビューしたいなら作者(または `need for human review` の場合は人間)が `waiting for review` に巻き戻す。
- **json の鮮度依存**: 選別精度は台帳の status が最新であることに依存する。「状況が変わるたびにローカル台帳を編集で更新」の運用(`.harness/CLAUDE.harness.md`)を前提とする。
- **ラベル名の固定依存**: `ready for merge` ラベルが repo に存在することを前提とする(`/harness-init` が冪等に作成する)。`need for human review` ラベルは `/harness-init` では作成せず、手順 6 が初回エスカレーション時に create-fallback で冪等作成する(`commands/harness-orchestrate.md` の sink 共通手続きも同じラベルを共有するため、色 `d93f0b` を両ファイルで揃える必要がある — 変更時は両方を同時に更新すること。既知の drift リスクは `commands/harness-orchestrate.md` の「ラベル同期ロジックの複製」節と同種)。
