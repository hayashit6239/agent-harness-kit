---
description: 対象 repo の .harness/plan-progress.json の PR フェーズ status を選別源に、pr.status が 'created pr' または 'waiting for review' の PR を `reviewing-multi-angle` skill 経由で 3 観点並列レビュー(`/code-review` correctness + `reviewing-pr-architecture` YAGNI/6 観点 + `reviewing-pr-google-method` 命名/規約/テスト品質)し、dedup + 優先度付け済みの統合 findings(max 10 件)を 1 件の PR コメントとして投稿。`has_blocker` は wrapper 側で再集計(全 source の 🔴 に加え arch/google 由来の 🟡 も blocker)し、真偽で pr.status を自動進行(false→'ready for merge'(+ `merge ready` ラベル付与) / true→'completed review'(+ ラベル除去))する reviewer ロール。台帳の状態遷移は main へ直接コミット。別セッションで手動起動 or /loop。
argument-hint: "[owner/repo] [effort]  省略時: CWD の origin から自動判定 / medium(低い順 low/medium/high/max/ultra)"
allowed-tools: [Bash, Skill, Read, Write]
---

# /harness-review-pr — レビュー待ち PR の自動コードレビュー(reviewer ロール / wrapper / policy 層)

これは **運用(policy)** の層であり、minimal 構成の **reviewer ロール**(doer ≠ judge の judge 側。main developer とは**別の Claude Code セッション**で起動する)。レビュー判断そのものは **`reviewing-multi-angle` skill**(orchestration mechanism)に委譲し、その下で `/code-review`(correctness)+ `reviewing-pr-architecture`(アーキ 6 観点)+ `reviewing-pr-google-method`(命名/規約/テスト品質)が 3 並列で動く。wrapper は「どれを・いつ・結果をどうするか(選別 / has_blocker 再集計 / status 進行 / 投稿 / ラベル同期 / 報告)」を担い、レビュー判定の中身には立ち入らない。

> **`reviewing-multi-angle` skill との関係**: skill は 3 review skill を per-PR で並列 spawn → dedup + 優先度付け + 統合 max 10 件 + `summary_markdown` 組み立てまで担う orchestration。出力は `{ findings, has_blocker, truncated, summary_markdown }`。本 wrapper は per-PR の git worktree を用意して skill を呼び(CWD 前提)、skill が返す `summary_markdown` をそのまま PR コメント本文として投稿する。**skill が返す `has_blocker`(「1 件でも 🔴」)は参考値**であり、merge 可否の判定には使わない — 本 wrapper が手順 5.5 で `findings[].severity / sources` から**再集計した `has_blocker`(harness-kit 定義)**を使う(ゴム印対策: arch/google 由来の 🟡 も blocker に含める)。

## ロールの契約

**Why**: 単一観点のレビューは網羅範囲が狭く、単独判定は「判定の丸投げ」(Cognitive Surrender) を招く。本ロールは doer ≠ judge の judge 側として、3 観点並列 + 作者との往復サイクルで観点の網羅と判定の独立を両立する。

- **触る (専権)**: `pr.status` の判定遷移 (`starting review` → `ready for merge` / `completed review`)、`pr.lastReviewedStatus`、`merge ready` ラベル、レビューコメント投稿。
- **触らない**: 終端 status (`merged pr` / `closed issue`)・`githubState`・PR 本文編集・close・merge・`issue.*`・他ラベル・コード修正 (`--fix`)。
- **follow-up の最終判断は reviewer 責務**: 「この指摘は merge 後の対応でよい / もうマージしてよい」を決めるのは作者・対応側ではなく本ロール。対応側は指摘対応後 `waiting for review` に戻すだけ (対応側の規約は `.harness/CLAUDE.harness.md`)。

## 状態源と選別

**選別源は GitHub ラベルではなく、対象 repo 内の `.harness/plan-progress.json`**(CWD の git repo ルート基準。`/harness-init` が生成した進捗台帳)。各 step の PR フェーズ status(enum)を読み、レビュー待ち lifecycle 段階だけを対象にする。台帳が repo 内にあるため、この選別は CI からも同じファイルで検証される(harness-gate)。

**対象(どちらか):**
- `pr.status == "created pr"` — PR 作成直後・初回レビュー未了
- `pr.status == "waiting for review"` — レビュー依頼済み(初回 or review work 後の再レビュー待ち)

**除外:** 上記 status 以外(`starting review` / `completed review` / `ready for merge` / `starting review work` / `implementation-ready` / `merged pr`)/ `pr.number == null`(未作成)/ `pr.githubState != "open"`(GitHub 上で merged/closed)/ `isDraft == true`(下書き)。

## status 自動進行と dedup

**本コマンドはレビュー結果に応じて `pr.status` を自動進行する**(本コマンドが触るのは `pr.status` / `pr.lastReviewedStatus` / GitHub の **`merge ready` ラベル**のみ。PR 本文・close・merge・`githubState`・issue 側は触らない):

| 再集計 `has_blocker`(harness-kit 定義) | 自動進行先 `pr.status` | `merge ready` ラベル |
|---|---|---|
| false(🔴 なし、かつ arch/google 由来の 🟡 なし) | `ready for merge` | **付与**(冪等。既に付いていれば no-op) |
| true(🔴 1 件以上、**または** arch/google 由来の 🟡 1 件以上) | `completed review`(分岐点 — 作者が `starting review work` に進める想定) | **除去**(冪等。付いていなければ no-op) |

**has_blocker の再集計(harness-kit 定義・手順 5.5)**: skill の `has_blocker` は「1 件でも 🔴」だったが、それだと `reviewing-pr-architecture` / `reviewing-pr-google-method` の 🟡 が素通しになり ready for merge へ倒れやすい(ゴム印)。本 wrapper は `findings[]` を再判定する — **いずれかの finding が 🔴、または sources に arch/google 系を含む 🟡 が 1 件でもあれば true**。🟢(nit・好み)は blocker にしない。

**ラベルの対称運用**: `merge ready` は「マージ可能と判断された」シグナルなので、再レビューで blocker が見つかったらラベルも下ろす(嘘を残さない)。

**dedup**: `pr.status` が自動進行で対象外 status(`ready for merge` / `completed review`)に変わるため、次の tick で自動的に選別から外れる(重複レビュー回避)。**`pr.lastReviewedStatus` は記録目的でレビュー時の status を残す**が、選別ロジックでは参照しない。

**誤判定リスク(重要)**: 🟡 を blocker に含めたことで、effort=high / max では hold(`completed review`)が増えうる(逆リスク = 過剰 hold)。基本は effort=medium で運用し、hold が頻発してループが回らない場合の緩和策は (a) effort=medium 固定、(b) 🟡 の件数閾値化、の順で検討する。作者は wrapper の判定を盲信せず、findings を読んで採否を判断する。

## 再発火経路

再レビューは **status 遷移**だけで完結する(`lastReviewedStatus` リセットは不要):

1. **初回レビュー入口**: 作者が PR 作成 → `pr.status = "created pr"` → wrapper レビュー → 自動進行
2. **review work 後の再レビュー入口**: 作者が `completed review` を見て「修正必要」と判断 → `starting review work` → 修正完了 → `waiting for review` に戻す → wrapper が再選別・再レビュー
3. **誤 hold の override / 再点検**: wrapper が進めた status を作者が `waiting for review` に巻き戻す → 次回実行で再レビュー(ラベルも自動再評価)

GitHub の `merge ready` ラベルは wrapper が自動管理(作者は触らない想定。触ると plan-progress と drift する)。

## パラメータ

- `$1` リポジトリ: 省略時は CWD の origin から自動判定(`gh repo view --json nameWithOwner --jq .nameWithOwner`)。`.harness/plan-progress.json` は CWD の repo のものを使う($1 はその repo に対応する前提)。
- `$2` effort: 省略時 `medium`。`reviewing-multi-angle` skill 経由で内部の `/code-review` に渡される値(`low` / `medium` / `high` / `max` / `ultra`)。**effort が効くのは `/code-review` のみ**。基本は `medium`(high-confidence の少数 findings)。broad recall が欲しければ `high`、final ゲートは `max`。`ultra` は高コスト・通常不要。
- 1 回の上限: **5 件**(暴走防止)。

## 手順

0. **同期 + 前提検査** — 選別の前に必ず行う:
   - **台帳の同期**: main 上で `git pull --ff-only` を実行する(古い main の台帳で選別しない)。fast-forward できない(ローカルに未 push の変更がある等)場合は、状態を報告して停止する。
   - **前提コマンドの存在検査**: `gh` / `python3` / `jq` がすべて使えることを確認する。1 つでも無ければ「前提コマンド <名前> が見つからない。インストール後に再実行すること」とエラーで停止する:
     ```
     for c in gh python3 jq; do command -v "$c" >/dev/null || { echo "前提コマンド $c が見つからない"; exit 1; }; done
     ```
   - **前提 skill の存在検査**: 次の 4 つがすべて使えることを確認する。1 つでも無ければ「前提 skill <名前> が見つからない。インストール後に再実行すること」と**明確なエラーで停止する**(観点が欠けたまま黙ってレビューしない):
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

4. **各 PR を `/reviewing-multi-angle` skill でレビュー(3 観点並列)** — skill は `/code-review`(correctness)+ `reviewing-pr-architecture`(YAGNI/6 観点)+ `reviewing-pr-google-method`(命名/規約/テスト品質)を per-PR で 3 並列 spawn → dedup + 優先度付け + 統合 max 10 件 + `summary_markdown` 組み立てまで担う。CWD のチェックアウトに対して動くため、wrapper は事前に **per-PR git worktree を作成**して隔離する(user の作業ツリーを汚さない):
   ```
   git fetch origin <headRefName> --quiet
   WORKTREE=".claude/worktrees/review-pr-<n>"
   git worktree add --detach "$WORKTREE" "origin/<headRefName>"
   ( cd "$WORKTREE" && /reviewing-multi-angle <effort> )  # 統合 findings JSON + summary_markdown を取得
   git worktree remove --force "$WORKTREE"
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

4.5. **増分レビュー(既出 findings の差分計算)** — 同一 PR への 2 回目以降のレビューで、前回と同じ指摘をそのまま再掲しない(作者のノイズ削減と 3 観点並列コストの節約。**判定には影響させない**):
   - `gh pr view <n> --repo <repo> --json comments` で過去の `# PR Reviewer` コメントを取得し、既出 findings を `(file, line, summary)` で抽出
   - 今回の `findings[]` と突き合わせ、各 finding を **新規 / 既出(持ち越し)** に分類
   - **判定(手順 5.5)は分類に関係なく全 findings で行う**(未解消の既出 🔴 は依然 blocker — 増分は「見せ方」の工夫であって判定の緩和ではない)
   - 投稿本文(手順 5)では既出分に「(前回指摘・未解消)」の注記を付け、報告(手順 8)の findings 列は `M 新規 / K 既出` で書く
   - 初回レビュー(過去 `# PR Reviewer` コメント無し)はこの手順をスキップ

5. **投稿(H1 ヘッダー必須)** — skill が返す `summary_markdown` を本体として、wrapper 側で **H1 ヘッダー + 1 行イントロ + 証拠錨 + footer** だけラップして投稿する(本文組み立てロジックは skill 側に移譲済みで、wrapper は薄く保つ):
   ```
   # 台帳から証拠錨を読む(done が無ければ test にフォールバック)
   EVIDENCE_DONE=$(jq -r '.evidence.done // .evidence.test // "未定義"' "$PLAN")
   {
     printf '# PR Reviewer - レビュー実施\n\n'
     printf '`/reviewing-multi-angle %s` で点検しました(3 観点並列: /code-review + reviewing-pr-architecture + reviewing-pr-google-method、dedup + 優先度付け済み、統合 max 10 件)。\n\n' "$EFFORT"
     printf '**証拠錨**: merge 前に `evidence.done`(`%s`)が exit 0 であることを作者が確認すること(台帳 `.harness/plan-progress.json`)。\n\n' "$EVIDENCE_DONE"
     # skill の summary_markdown をそのまま挿入(per-finding 詳細・判定・専担領域メモまで含む完成形。既出分は「(前回指摘・未解消)」を注記)
     printf '%s\n' "$SUMMARY_MARKDOWN"
     printf '\n<sub>🤖 Generated with [Claude Code](https://claude.com/claude-code) — `/harness-review-pr` wrapper, `/reviewing-multi-angle %s` skill</sub>\n' "$EFFORT"
   } > <tmpfile>
   gh pr comment <n> --repo <repo> --body-file <tmpfile>
   ```
   - H1 ヘッダー(`# PR Reviewer - レビュー実施`)が無いと PR コメント一覧で「どのロールが投稿したか」が一目で分からなくなる(同一 GitHub アカウントから複数ロールが投稿するため)
   - `EVIDENCE_DONE` が `未定義` の場合はその旨を明記し「`/harness-init` で証拠を定義すること」を添える(黙って省略しない)

5.5. **has_blocker 再集計(harness-kit 定義)** — **判定は LLM の解釈で行わない**。skill の `findings[]` JSON を stdin で `${CLAUDE_PLUGIN_ROOT}/scripts/reaggregate-has-blocker.py` に渡し、その出力を判定として使う(決定論):
   ```
   # FINDINGS_JSON = skill 出力の findings 配列(JSON 文字列)
   RESULT=$(printf '%s' "$FINDINGS_JSON" | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/reaggregate-has-blocker.py")
   # -> {"has_blocker": true|false, "blocker_count": N, "unknown_source_blockers": [...]}
   ```
   スクリプトが実装する規則(prose は参照用。実際の判定は必ず上のスクリプトで行う):
   - いずれかの finding が **severity 🔴** → `has_blocker = true`
   - **severity 🟡 かつ sources に arch 系(`arch` / `reviewing-pr-architecture` を含む)/ google 系(`google` を含む)の識別子を含むものが 1 件でもある** → `has_blocker = true`
   - **🟡 の sources が既知の識別子(code-review 系 / arch 系 / google 系)のいずれにも一致しない場合は blocker 扱い(fail-closed)**(表記ゆれ・skill 出力の変化で 🟡 が素通しになるのを防ぐ)
   - 上記に該当しない(findings 0 件、または残りが 🟢、または 🟡 が code-review 系単独由来のみ)→ `has_blocker = false`
   - `unknown_source_blockers` が空でなければ、報告に「未知の source 表記 X を blocker 扱いした」と 1 行残す
   - skill が返した `has_blocker` と再集計結果が異なる場合は、報告にその旨を 1 行残す(判定の透明性)
   - スクリプトが exit 2(入力エラー)の場合はレビューを進めず、状態を報告して停止する(黙って LLM 判定に切り替えない)

6. **レビュー完了マーカー(自動進行 + ラベル管理)** — 手順 5.5 の再集計 `has_blocker` の真偽で `pr.status` を自動進行し、`merge ready` ラベルを同期する:
   - `has_blocker == false`:
     - `pr.status = "ready for merge"`
     - `gh pr edit <n> --repo <repo> --add-label "merge ready"`(冪等)
   - `has_blocker == true`:
     - `pr.status = "completed review"`
     - `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(付いていなければ警告のみで実害なし)
   ```
   # NEW=自動進行先
   jq --argjson n <n> --arg new "<NEW>" --arg d "$(date +%F)" \
     '(.steps[] | select(.pr.number == $n) | .pr.status) = $new
      | .updatedAt = $d' \
     "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
   ```
   書込後は「台帳書込の規約」(手順 3)に従い main へ直接コミット + push する(例: `chore(harness): P1 pr.status -> ready for merge`)。

7. **触らないものを厳守(doer ≠ judge の固定線)** — `pr.status` / `pr.lastReviewedStatus` / GitHub の `merge ready` ラベル以外は触らない:
   - **終端 status(`merged pr` / `closed issue`)は書かない** — **`ready for merge` が reviewer の上限**。その先(実際の merge / close と終端 status の記録)は人間の責務
   - `githubState` は**書かない**(GitHub の実態を写す欄。更新は作者の責務で、乖離は CI の drift 検査が検知する)
   - PR 本文の編集・close・merge は**しない**
   - `issue.status` / `issue.lastReviewedStatus` は**触らない**(作者の責務)
   - GitHub 上の他のラベル(`bug` / `enhancement` 等)も**触らない**
   - issue へのコメント投稿も**しない**(本コマンドは PR コメントのみ)
   - **自動修正モード(`--fix` 系)は使わない**(findings は作者が検証して採否)

8. **報告** — 「次に作者が何をすべきか」が一目で分かるレポートを出す。**対象あり / 対象なし** で 2 形式を使い分け、PR 参照は番号 + タイトル併記。

   ### A. 対象あり(N ≥ 1 件処理)

   ````markdown
   ## 📋 Step 8 報告: PR レビュー wrapper 1 tick 完了

   **実施: HH:MM**(local time、`date +%H:%M` 出力)

   ### 📊 処理サマリ(N 件)

   | PR | タイトル | レビュー時 status → 自動進行先 | findings | 再集計 has_blocker | merge ready ラベル | コメント |
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

- 試行: `/loop 30m /harness-review-pr`(セッション内で定時実行、effort=medium 既定)。
- effort を変えたい場合: `/loop 30m /harness-review-pr owner/repo high`(broad recall に上げる例)。
- dedup は **status 自動進行**が担うので、レビュー済み PR は次の tick で対象外 status になり選別から外れる。作者が `waiting for review` に戻すと自動的に 1 回再レビューが走る。

## 既知の制限・拡張ポイント

- **status 自動進行のトレードオフ(重要)**: 本コマンドは「レビューを実施する者が自分の判定で status を進める」。現行構成の担保は (1) 別セッション起動による doer ≠ judge のロール分離、(2) `ready for merge` を上限とする終端の人間ゲート、(3) 🟡 まで広げた blocker 再集計、の 3 点。reviewer に reject 誘因を持たせる敵対的 Verifier は現行版では未実装(開発計画は kit リポジトリの README / issue #1)。
- **過剰 hold の逆リスク**: 🟡 を blocker に含めたため、effort=high / max では hold が頻発しうる。緩和条件は (a) effort=medium 固定、(b) 🟡 の件数閾値化(足すときに削り方を決めておく)。
- **可搬性の判断ギャップ(明示)**: 本コマンドは個人 skill 群(`reviewing-multi-angle` / `reviewing-pr-architecture` / `reviewing-pr-google-method`)に依存し、それらは plugin に**同梱しない**。他環境で使う場合はこれらの skill を先に用意する必要がある(README に前提として明記)。
- **台帳が repo 内にある意味**: 元方式は選別源が `~/.claude` 配下で無人 CI から見えなかったが、本 kit は `.harness/plan-progress.json` に移したため CI(harness-gate)が同じ台帳を機械検証できる。ただし本コマンド自体のレビュー実行は引き続き Claude セッションが必要(無人化は現行版では未対応)。
- **CWD 隔離(worktree)コスト**: PR ごとに worktree 作成・削除のオーバーヘッドあり。1 tick 5 件上限のため許容範囲。残骸が残ったら tick 開始時に `git worktree prune` で掃除推奨。
- **`reviewing-multi-angle` のコスト(3x 化)**: 内部で 3 review skill を並列実行するため、単独 `/code-review` 比で約 3x のトークン消費。`/loop` の間隔は **30 分以上推奨**。
- **PR 本文編集後の再レビュー**: status が `ready for merge` / `completed review` のままなら再発火しない。即時再レビューしたいなら作者が `waiting for review` に巻き戻す。
- **json の鮮度依存**: 選別精度は台帳の status が最新であることに依存する。「状況が変わるたびに main へ直接コミットで更新」の運用(`.harness/CLAUDE.harness.md`)を前提とする。
- **ラベル名の固定依存**: `merge ready` ラベルが repo に存在することを前提とする(`/harness-init` が冪等に作成する)。
