---
description: 対象 repo の .harness/plan-progress.json の PR フェーズ status を選別源に、pr.status が 'created pr' または 'waiting for review' の PR をレビューし(既定 review-mode=code-review では Claude Code 組込 `/code-review` 単体、opt-in review-mode=multi-angle では `reviewing-multi-angle` skill 経由で 3 観点並列)、dedup + 優先度付け済みの統合 findings を 1 件の PR コメントとして投稿。`has_blocker` は wrapper 側で再集計(`scripts/reaggregate-has-blocker.py`)し、真偽で pr.status を自動進行(false→'ready for merge'(+ `ready for merge` ラベル付与) / true→'completed review'(+ ラベル除去))する reviewer ロール。round 上限・blocker 傾向による停止条件(escalate)も判定し、マーカーとしてコメントに埋め込む。台帳の状態遷移は main へ直接コミット。別セッションで手動起動 or /loop。
argument-hint: "[owner/repo] [effort] [review-mode]  省略時: CWD の origin から自動判定 / medium(低い順 low/medium/high/max/ultra) / code-review(opt-in: multi-angle)"
allowed-tools: [Bash, Skill, Read, Write]
---

# /harness-review-pr — レビュー待ち PR の自動コードレビュー(reviewer ロール / wrapper / policy 層)

これは **運用(policy)** の層であり、minimal 構成の **reviewer ロール**(doer ≠ judge の judge 側。main developer とは**別の Claude Code セッション**で起動する)。レビュー判断そのものは review-mode に応じた skill に委譲する:

- **既定 `review-mode=code-review`**: Claude Code 組込 `/code-review` skill 単体(correctness 中心)。**個人 skill 不要**で動く可搬構成。
- **opt-in `review-mode=multi-angle`**: `reviewing-multi-angle` skill(orchestration mechanism)経由で `/code-review`(correctness)+ `reviewing-pr-architecture`(アーキ 6 観点)+ `reviewing-pr-google-method`(命名/規約/テスト品質)が 3 並列で動く。個人 skill 依存。

wrapper は「どれを・いつ・結果をどうするか(選別 / findings 正規化 / has_blocker 再集計 / 停止条件判定 / status 進行 / 投稿 / ラベル同期 / 報告)」を担い、レビュー判定の中身には立ち入らない。

> **`reviewing-multi-angle` skill との関係(review-mode=multi-angle のみ)**: skill は 3 review skill を per-PR で並列 spawn → dedup + 優先度付け + 統合 max 10 件 + `summary_markdown` 組み立てまで担う orchestration。出力は `{ findings, has_blocker, truncated, summary_markdown }`。本 wrapper は per-PR の git worktree を用意して skill を呼び(CWD 前提)、skill が返す `summary_markdown` をそのまま PR コメント本文として投稿する。**skill が返す `has_blocker`(「1 件でも 🔴」)は参考値**であり、merge 可否の判定には使わない — 本 wrapper が手順 5.5 で `findings[].severity / sources` から**再集計した `has_blocker`(harness-kit 定義)**を使う(ゴム印対策: arch/google 由来の 🟡 も blocker に含める)。
>
> **`/code-review` 単体との関係(review-mode=code-review、既定)**: `/code-review` は JSON ではなく、`path:line — 何が問題か` の 1 行 findings をプレーンテキストで返すプロンプト型 skill であり、`severity` / `sources` / `has_blocker` / `summary_markdown` は持たない(実装時に実機で出力形状を確認済み)。本 wrapper が手順 4 で正規化する: 各行を 1 finding とし `severity="🔴"`(`/code-review` は low/medium effort では確信度の高い正真の correctness bug のみを報告する設計のため、報告された時点で blocker 相当とみなす)・`sources=["code-review"]` を機械的に付与し、`summary_markdown` は findings を箇条書きにしただけの簡易版を wrapper 側で組み立てる。findings が `(none)` の場合は空配列とする。

## ロールの契約

**Why**: 単一観点のレビューは網羅範囲が狭く、単独判定は「判定の丸投げ」(Cognitive Surrender) を招く。本ロールは doer ≠ judge の judge 側として、3 観点並列 + 作者との往復サイクルで観点の網羅と判定の独立を両立する。

- **触る (専権)**: `pr.status` の判定遷移 (`starting review` → `ready for merge` / `completed review`)、`pr.lastReviewedStatus`、`ready for merge` ラベル (+ 旧名 `merge ready` ラベルの**除去のみ** — 手順 6 の移行掃除)、レビューコメント投稿。
- **触らない**: 終端 status (`merged pr` / `closed issue`)・`githubState`・PR 本文編集・close・merge・`issue.*`・他ラベル・コード修正 (`--fix`)。
- **follow-up の最終判断は reviewer 責務**: 「この指摘は merge 後の対応でよい / もうマージしてよい」を決めるのは作者・対応側ではなく本ロール。対応側は指摘対応後 `waiting for review` に戻すだけ (対応側の規約は `.harness/CLAUDE.harness.md`)。

## 状態源と選別

**選別源は GitHub ラベルではなく、対象 repo 内の `.harness/plan-progress.json`**(CWD の git repo ルート基準。`/harness-init` が生成した進捗台帳)。各 step の PR フェーズ status(enum)を読み、レビュー待ち lifecycle 段階だけを対象にする。台帳が repo 内にあるため、この選別は CI からも同じファイルで検証される(harness-gate)。

**対象(どちらか):**
- `pr.status == "created pr"` — PR 作成直後・初回レビュー未了
- `pr.status == "waiting for review"` — レビュー依頼済み(初回 or review work 後の再レビュー待ち)

**除外:** 上記 status 以外(`starting review` / `completed review` / `ready for merge` / `starting review work` / `implementation-ready` / `merged pr`)/ `pr.number == null`(未作成)/ `pr.githubState != "open"`(GitHub 上で merged/closed)/ `isDraft == true`(下書き)。

## status 自動進行と dedup

**本コマンドはレビュー結果に応じて `pr.status` を自動進行する**(本コマンドが触るのは `pr.status` / `pr.lastReviewedStatus` / GitHub の **`ready for merge` ラベル** + 旧名 `merge ready` ラベルの**除去のみ**。PR 本文・close・merge・`githubState`・issue 側は触らない):

| 再集計 `has_blocker`(harness-kit 定義) | 自動進行先 `pr.status` | `ready for merge` ラベル |
|---|---|---|
| false(🔴 なし、かつ arch/google 由来の 🟡 なし) | `ready for merge` | **付与**(冪等。既に付いていれば no-op) |
| true(🔴 1 件以上、**または** arch/google 由来の 🟡 1 件以上) | `completed review`(分岐点 — 作者が `starting review work` に進める想定) | **除去**(冪等。付いていなければ no-op) |

**has_blocker の再集計(harness-kit 定義・手順 5.5)**: skill 定義の「1 件でも 🔴」より広く blocker を取る(ゴム印対策)。**規則の正は `scripts/reaggregate-has-blocker.py`** — 判定はスクリプト実行で行い、exit 2(入力エラー)なら停止する。

**ラベルの対称運用**: `ready for merge` は「マージ可能と判断された」シグナルなので、再レビューで blocker が見つかったらラベルも下ろす(嘘を残さない)。

**dedup**: `pr.status` が自動進行で対象外 status(`ready for merge` / `completed review`)に変わるため、次の tick で自動的に選別から外れる(重複レビュー回避)。**`pr.lastReviewedStatus` は記録目的でレビュー時の status を残す**が、選別ロジックでは参照しない。

**誤判定リスク(重要)**: 🟡 を blocker に含めたことで、effort=high / max では hold(`completed review`)が増えうる(逆リスク = 過剰 hold)。基本は effort=medium で運用し、hold が頻発してループが回らない場合の緩和策は (a) effort=medium 固定、(b) 🟡 の件数閾値化、の順で検討する。作者は wrapper の判定を盲信せず、findings を読んで採否を判断する。

## 再発火経路

再レビューは **status 遷移**だけで完結する(`lastReviewedStatus` リセットは不要):

1. **初回レビュー入口**: 作者が PR 作成 → `pr.status = "created pr"` → wrapper レビュー → 自動進行
2. **review work 後の再レビュー入口**: 作者が `completed review` を見て「修正必要」と判断 → `starting review work` → 修正完了 → `waiting for review` に戻す → wrapper が再選別・再レビュー
3. **誤 hold の override / 再点検**: wrapper が進めた status を作者が `waiting for review` に巻き戻す → 次回実行で再レビュー(ラベルも自動再評価)

GitHub の `ready for merge` ラベルは wrapper が自動管理(作者は触らない想定。触ると plan-progress と drift する)。

## パラメータ

- `$1` リポジトリ: 省略時は CWD の origin から自動判定(`gh repo view --json nameWithOwner --jq .nameWithOwner`)。`.harness/plan-progress.json` は CWD の repo のものを使う($1 はその repo に対応する前提)。
- `$2` effort: 省略時 `medium`。`review-mode=multi-angle` では `reviewing-multi-angle` skill 経由で内部の `/code-review` に渡される値、`review-mode=code-review` では `/code-review` 自体に直接渡される値(`low` / `medium` / `high` / `max` / `ultra`)。**effort が効くのは `/code-review` のみ**。基本は `medium`(high-confidence の少数 findings)。broad recall が欲しければ `high`、final ゲートは `max`。`ultra` は高コスト・通常不要。
- `$3` review-mode: 省略時 **`code-review`**(Claude Code 組込 `/code-review` skill のみ・**個人 skill 不要**)。opt-in 値 `multi-angle`(現行の 3 skill 並列・`reviewing-multi-angle` 等の個人 skill が必要)。`commands/harness-orchestrate.md` から dispatch される場合も、起動時に受け取った review-mode をそのまま引き継ぐ。
- 1 回の上限: **5 件**(暴走防止)。

## 手順

0. **同期 + 前提検査** — 選別の前に必ず行う:
   - **台帳の同期**: main 上で `git pull --ff-only` を実行する(古い main の台帳で選別しない)。fast-forward できない(ローカルに未 push の変更がある等)場合は、状態を報告して停止する。
   - **前提コマンドの存在検査**: `gh` / `python3` / `jq` がすべて使えることを確認する。1 つでも無ければ「前提コマンド <名前> が見つからない。インストール後に再実行すること」とエラーで停止する。`gh` は存在に加えて `gh auth status` で認証も確認する (`/harness-init` 手順 0 と対称 — 未認証のまま選別・レビューに進まない):
     ```
     for c in gh python3 jq; do command -v "$c" >/dev/null || { echo "前提コマンド $c が見つからない"; exit 1; }; done
     gh auth status >/dev/null 2>&1 || { echo "gh が未認証 (gh auth login で認証してから再実行する)"; exit 1; }
     ```
   - **前提 skill の存在検査(review-mode で分岐)**: 1 つでも無ければ「前提 skill <名前> が見つからない。インストール後に再実行すること」と**明確なエラーで停止する**(観点が欠けたまま黙ってレビューしない):
     - `review-mode=code-review`(既定): `/code-review` が Claude Code 標準 skill として利用可能 skill 一覧にあることのみ確認する。個人 skill 依存を解消するのが本モードの目的のため、`reviewing-multi-angle` 系の検査は**行わない**。
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
   **台帳の書込は main へ直接コミットする**(下記「台帳書込の規約」)。

   > **台帳書込の規約(手順 3 / 6 共通)**: 状態遷移は PR ブランチに載せず、**main 上で `.harness/plan-progress.json` だけを含む小コミットを作って push する**。メッセージ規約は `chore(harness): <step> pr.status -> <new>`(例: `chore(harness): P1 pr.status -> starting review`、`chore(harness): P1 pr.status -> ready for merge`)。push が拒否されたら(doer と同時書込)`git pull --ff-only` してやり直す。
   > ```
   > git add .harness/plan-progress.json
   > git commit -m "chore(harness): <step> pr.status -> <new>"
   > git push origin main
   > ```

4. **各 PR をレビューする(review-mode で分岐)** — CWD のチェックアウトに対して動くため、wrapper は事前に **per-PR git worktree を作成**して隔離する(user の作業ツリーを汚さない):
   ```
   git fetch origin <headRefName> --quiet
   WORKTREE=".claude/worktrees/review-pr-<n>"
   git worktree add --detach "$WORKTREE" "origin/<headRefName>"
   ```

   ### 4-a. `review-mode=multi-angle`

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

   ### 4-b. `review-mode=code-review`(既定)

   `/code-review <effort>` を単体で呼ぶ。**この skill はプロンプト型で、呼び出し元(wrapper を実行している Claude 自身)に「diff を読んで `path:line — 何が問題か` の 1 行 findings を書き出す」よう指示するだけで、JSON や `has_blocker` は返さない**(実機確認済み)。wrapper が以下の手順で `{findings, has_blocker, truncated, summary_markdown}` 相当に正規化する:
   ```
   ( cd "$WORKTREE" && /code-review <effort> )  # プレーンテキストの 1 行 findings(または "(none)")を得る
   ```
   - 出力が `(none)` または空なら `findings = []`
   - それ以外は各行を 1 finding に変換する: `severity = "🔴"`(`/code-review` は low/medium effort では確信度の高い正真の correctness bug のみを報告する設計のため、報告された時点で blocker 相当とみなす。fail-closed)・`sources = ["code-review"]`・`file`/`line` は `path:line` から抽出・`summary` は残りの説明文
   - `truncated = 0`(`/code-review` 自体に truncation の概念がないため)
   - `summary_markdown` は wrapper が findings を箇条書きで組み立てる簡易版(例: `## /code-review findings\n\n1. \`path:line\` — summary\n...` または findings 0 件なら `## /code-review findings\n\nfindings 0 件 ✅`)
   - この正規化後は 4-a と同じ形の findings 配列として手順 4.5 以降(増分レビュー・投稿・再集計・停止条件)にそのまま渡す

   ### 4-c. worktree の後片付け(両モード共通)

   ```
   git worktree remove --force "$WORKTREE"
   ```

4.5. **増分レビュー(既出 findings の差分計算)** — 同一 PR への 2 回目以降のレビューで、前回と同じ指摘をそのまま再掲しない(作者のノイズ削減と 3 観点並列コストの節約。**判定には影響させない**):
   - `gh pr view <n> --repo <repo> --json comments` で過去の `# PR Reviewer` コメントを取得し、既出 findings を `(file, line, summary)` で抽出
   - 今回の `findings[]` と突き合わせ、各 finding を **新規 / 既出(持ち越し)** に分類
   - **判定(手順 5.5)は分類に関係なく全 findings で行う**(未解消の既出 🔴 は依然 blocker — 増分は「見せ方」の工夫であって判定の緩和ではない)
   - 投稿本文(手順 5)では既出分に「(前回指摘・未解消)」の注記を付け、報告(手順 8)の findings 列は `M 新規 / K 既出` で書く
   - 初回レビュー(過去 `# PR Reviewer` コメント無し)はこの手順をスキップ

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

5.6. **停止条件の判定(round_flag / trend_flag / escalate)** — **手動モード(人間が本コマンドを直接叩く運用)でも常に実行する**(マーカー埋め込み・🛑 セクション表示は無条件。ラベル付与や needs-human エスカレーションの**実行**は行わない — それは `commands/harness-orchestrate.md` 側だけの責務):
   - **round の算出**: 手順 4.5 で取得済みの過去 `# PR Reviewer` コメント一覧を再利用する。`ROUND = (過去の "# PR Reviewer" コメント数) + 1`(今回投稿する分が ROUND 回目)
   - **round < 3 の場合**: 停止条件の判定は行わない(`escalate = false` 固定)。マーカーには `round` / `has_blocker` / `blocker_count` のみ正しい値を書く
   - **round >= 3 の場合**: 直近 2 件の過去 `# PR Reviewer` コメント本文末尾のマーカー(`<!-- harness-review-pr: round=<N> has_blocker=<true|false> blocker_count=<M> ... -->`)を正規表現でパースし、`blocker_count(N-1)`(直近 1 件前)・`blocker_count(N-2)`(直近 2 件前)を取得する。マーカーが無い(旧フォーマットの過去コメント・件数不足)場合はその過去分を「不明」として trend_flag の判定を成立させない(fail-closed で escalate させない側に倒す — 誤 escalate の方が実害が大きいため)
     - **round_flag**: `ROUND >= 5` かつ 今回の `has_blocker == true`
     - **trend_flag**: `blocker_count(N) >= blocker_count(N-1)` かつ `blocker_count(N-1) >= blocker_count(N-2)`(2 回連続で改善していない。3 件とも取得できた場合のみ判定)
     - **escalate = (round_flag OR trend_flag) かつ 今回の has_blocker == true**(`has_blocker == false` なら round_flag/trend_flag の値に関わらず `escalate = false` — blocker が無いのに停止条件を立てる自己矛盾を避ける)
   - この手順の結果(`ROUND` / `has_blocker` / `blocker_count` / `escalate`)を手順 5 の投稿本文に反映する

5. **投稿(H1 ヘッダー必須)** — skill が返す(または 4-b で正規化した)`summary_markdown` を本体として、wrapper 側で **H1 ヘッダー + 1 行イントロ + 証拠錨 + (escalate 時のみ 🛑 停止条件節) + マーカー + footer** をラップして投稿する(本文組み立てロジックは skill/正規化側に移譲済みで、wrapper は薄く保つ)。**手順 5.5 / 5.6 を先に実行し、その結果(`RESULT` / `ROUND` / `ESCALATE`)を使って本文を組み立ててから投稿する**:
   ```
   # 台帳から証拠錨を読む(done が無ければ test にフォールバック)
   EVIDENCE_DONE=$(jq -r '.evidence.done // .evidence.test // "未定義"' "$PLAN")
   REVIEW_LABEL_LINE=$([ "$REVIEW_MODE" = "multi-angle" ] \
     && printf '`/reviewing-multi-angle %s` で点検しました(3 観点並列: /code-review + reviewing-pr-architecture + reviewing-pr-google-method、dedup + 優先度付け済み、統合 max 10 件)。\n' "$EFFORT" \
     || printf '`/code-review %s` で点検しました(review-mode=code-review、組込 skill 単体)。\n' "$EFFORT")
   {
     printf '# PR Reviewer - レビュー実施\n\n'
     printf '%s\n' "$REVIEW_LABEL_LINE"
     printf '**証拠錨**: merge 前に `evidence.done`(`%s`)が exit 0 であることを作者が確認すること(台帳 `.harness/plan-progress.json`)。\n\n' "$EVIDENCE_DONE"
     # summary_markdown をそのまま挿入(per-finding 詳細・判定・専担領域メモまで含む完成形。既出分は「(前回指摘・未解消)」を注記)
     printf '%s\n' "$SUMMARY_MARKDOWN"
     if [ "$ESCALATE" = "true" ]; then
       printf '\n### 🛑 停止条件: 人間引き渡し\n\n'
       printf '%s\n\n' "$ESCALATE_REASON"  # 例: "round 上限到達(round 5)" / "blocker 件数が改善していない(round 3 → 4 → 5 の推移: 2 → 3 → 3)"
       printf 'このまま「指摘を直して再提出」を機械的に繰り返すのではなく、**根本原因(設計そのものの問題か、対応方針自体が誤っているか)を人間が判断してください**。\n'
     fi
     printf '\n<!-- harness-review-pr: round=%s has_blocker=%s blocker_count=%s escalate=%s -->\n' "$ROUND" "$HAS_BLOCKER" "$BLOCKER_COUNT" "$ESCALATE"
     printf '\n<sub>🤖 Generated with [Claude Code](https://claude.com/claude-code) — `/harness-review-pr` wrapper (review-mode=%s)</sub>\n' "$REVIEW_MODE"
   } > <tmpfile>
   gh pr comment <n> --repo <repo> --body-file <tmpfile>
   ```
   - H1 ヘッダー(`# PR Reviewer - レビュー実施`)が無いと PR コメント一覧で「どのロールが投稿したか」が一目で分からなくなる(同一 GitHub アカウントから複数ロールが投稿するため)
   - `EVIDENCE_DONE` が `未定義` の場合はその旨を明記し「`/harness-init` で証拠を定義すること」を添える(黙って省略しない)
   - マーカーはコメント本文の**機械可読な末尾**(footer の前)に必ず埋め込む。`commands/harness-orchestrate.md` はこのマーカーではなく、pr reviewer dispatch の返答(`{escalate,...}`)から直接 `escalate` を受け取るため、マーカーの主目的は**人間が PR コメント一覧を見て停止条件の推移を追えるようにする透明性**である
   - `pr.status` の遷移先はこの手順では変更しない(変更は手順 6)。`escalate` は台帳に一切書かない(マーカー・コメント本文のみに現れる)

6. **レビュー完了マーカー(自動進行 + ラベル管理)** — 手順 5.5 の再集計 `has_blocker` の真偽で `pr.status` を自動進行し、`ready for merge` ラベルを同期する:
   - `has_blocker == false`:
     - `pr.status = "ready for merge"`
     - ラベル作成 fallback: `gh label create "ready for merge" --color "0e8a16" --description "reviewer が merge 可能と判定した PR" --force`(冪等。旧版の init で初期化した導入先や手動削除でラベルが無くても、直前に commit した status とラベルが乖離しない — 自己修復。**定義の原本は `/harness-init` の仕上げ節 — 変更時は同文を維持する**。`--force` は既存ラベルの色・説明も上書きするため、片側だけ変えるともう一方の実行のたびに旧定義へ上書きし直されて変更が定着しない)
     - `gh pr edit <n> --repo <repo> --add-label "ready for merge"`(冪等)
     - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(旧版 kit の付与分。新旧の merge 可シグナルが併存し続けるのを防ぐ — true 分岐と対称。無ければ警告のみで実害なし)
   - `has_blocker == true`:
     - `pr.status = "completed review"`
     - `gh pr edit <n> --repo <repo> --remove-label "ready for merge"`(付いていなければ警告のみで実害なし)
     - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(旧版 kit が付与した旧名。残すと台帳は completed review なのに GitHub 上は merge 可シグナルが立ったままになるため、付与側の作成 fallback と対でこの故障クラスを 1 行で閉じる。無ければ警告のみで実害なし)
   ```
   # NEW=自動進行先
   jq --argjson n <n> --arg new "<NEW>" --arg d "$(date +%F)" \
     '(.steps[] | select(.pr.number == $n) | .pr.status) = $new
      | .updatedAt = $d' \
     "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
   ```
   書込後は「台帳書込の規約」(手順 3)に従い main へ直接コミット + push する(例: `chore(harness): P1 pr.status -> ready for merge`)。

7. **触らないものを厳守(doer ≠ judge の固定線)** — `pr.status` / `pr.lastReviewedStatus` / GitHub の `ready for merge` ラベル以外は触らない:
   - **終端 status(`merged pr` / `closed issue`)は書かない** — **`ready for merge` が reviewer の上限**。その先(実際の merge / close と終端 status の記録)は人間の責務
   - `githubState` は**書かない**(GitHub の実態を写す欄。更新は作者の責務で、乖離は CI の drift 検査が検知する)
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
   判定を再点検したい場合は `pr.status` を `waiting for review` に巻き戻す(main へ直接コミット)→ 次回実行で再レビュー(ラベルも自動再評価)。
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

## loop での回し方

- 試行: `/loop 30m /harness-review-pr`(セッション内で定時実行、effort=medium・review-mode=code-review 既定)。
- effort を変えたい場合: `/loop 30m /harness-review-pr owner/repo high`(broad recall に上げる例)。
- review-mode を明示したい場合: `/loop 30m /harness-review-pr owner/repo medium multi-angle`(個人 skill が揃っている環境で 3 観点並列に上げる例)。`/loop` は起動時の引数をそのまま毎 tick 再実行するため、review-mode を含め追加の状態保持は不要。
- dedup は **status 自動進行**が担うので、レビュー済み PR は次の tick で対象外 status になり選別から外れる。作者が `waiting for review` に戻すと自動的に 1 回再レビューが走る。

## 既知の制限・拡張ポイント

- **status 自動進行のトレードオフ(重要)**: 本コマンドは「レビューを実施する者が自分の判定で status を進める」。現行構成の担保は (1) 別セッション起動による doer ≠ judge のロール分離、(2) `ready for merge` を上限とする終端の人間ゲート、(3) 🟡 まで広げた blocker 再集計、の 3 点。reviewer に reject 誘因を持たせる敵対的 Verifier は現行版では未実装(開発計画は kit リポジトリの README / issue #1)。
- **過剰 hold の逆リスク**: 🟡 を blocker に含めたため、effort=high / max では hold が頻発しうる。緩和条件は (a) effort=medium 固定、(b) 🟡 の件数閾値化(足すときに削り方を決めておく)。
- **可搬性(review-mode=code-review が既定)**: 既定の `review-mode=code-review` は Claude Code 組込 `/code-review` のみに依存し、個人 skill 不要で他環境でも動く。opt-in の `review-mode=multi-angle` は個人 skill 群(`reviewing-multi-angle` / `reviewing-pr-architecture` / `reviewing-pr-google-method`)に依存し、それらは plugin に**同梱しない**。multi-angle を使う場合はこれらの skill を先に用意する必要がある(README に前提として明記)。
- **review-mode=code-review の網羅範囲(重要)**: `/code-review` は correctness(実行時バグ)中心で、アーキテクチャ・命名・規約・テスト品質は見ない。既定モードは可搬性と引き換えにこの網羅範囲の狭さを受け入れている。広い観点が要る場面(final gate 等)では `review-mode=multi-angle` への切替を検討する。
- **停止条件(round_flag/trend_flag/escalate)の適用範囲**: 手順 5.5/5.6 は review-mode に関わらず常に実行される(モードごとの has_blocker の出方が違っても、マーカー・停止条件のロジックは共通)。
- **台帳が repo 内にある意味**: 元方式は選別源が `~/.claude` 配下で無人 CI から見えなかったが、本 kit は `.harness/plan-progress.json` に移したため CI(harness-gate)が同じ台帳を機械検証できる。ただし本コマンド自体のレビュー実行は引き続き Claude セッションが必要(無人化は現行版では未対応)。
- **CWD 隔離(worktree)コスト**: PR ごとに worktree 作成・削除のオーバーヘッドあり。1 tick 5 件上限のため許容範囲。残骸が残ったら tick 開始時に `git worktree prune` で掃除推奨。
- **`reviewing-multi-angle` のコスト(3x 化)**: 内部で 3 review skill を並列実行するため、単独 `/code-review` 比で約 3x のトークン消費。`/loop` の間隔は **30 分以上推奨**。
- **PR 本文編集後の再レビュー**: status が `ready for merge` / `completed review` のままなら再発火しない。即時再レビューしたいなら作者が `waiting for review` に巻き戻す。
- **json の鮮度依存**: 選別精度は台帳の status が最新であることに依存する。「状況が変わるたびに main へ直接コミットで更新」の運用(`.harness/CLAUDE.harness.md`)を前提とする。
- **ラベル名の固定依存**: `ready for merge` ラベルが repo に存在することを前提とする(`/harness-init` が冪等に作成する)。
