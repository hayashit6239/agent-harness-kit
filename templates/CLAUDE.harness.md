# agent-harness-kit 運用規約

この repo は agent-harness-kit (minimal 構成 = 「1人 + 台帳」) で進捗を管理する。守るものは 3 つ:
①台帳と GitHub 実態の一致 ②merge 前に証拠 (test) が緑 ③作る人と判定する人の分離。

## 進捗台帳 (`.harness/plan-progress.json`)

- 1 つの作業単位 = `steps[]` の 1 要素。issue フェーズと PR フェーズそれぞれの status を持つ。
- status は schema (`.harness/plan-progress.schema.json`) の enum にある語だけを使う。一覧は下の status 表。勝手な語を足さない・言い換えない。
- 状況が変わるたびに status と `updatedAt` (YYYY-MM-DD) を更新する。
- `githubState` は GitHub の実態を写す欄。願望や予定を書かない (台帳検証の drift 照合が失敗する)。
- 任意フィールド: `lastReviewedStatus` は reviewer がレビュー時の status を記録用に書く欄 (選別では参照しない・作者は触らない)。`isDraft` は GitHub の draft 実態を写す任意欄 (drift 照合はキーがある場合のみ行われる)。
- 台帳の機械検証は **ローカル validator の実行結果を Statuses API で自己申告する**方式で行う (台帳は git にコミットしないため、GitHub ホストの CI が committed な台帳を検証する方式は取らない。詳細は「台帳の書込経路」節)。手元では
  `python3 .harness/validate-plan-progress.py --schema .harness/plan-progress.json` で schema 検査ができる。
  GitHub との突き合わせ (drift 照合) は `--drift` (要 gh 認証)。

### status 一覧 (意味と遷移)

issue フェーズ (9 status):

| status | 主体 | 意味 | 次の遷移先 |
|---|---|---|---|
| null | — | 未着手 (issue 未起票) | created issue |
| created issue | 作者 | issue を起票した (初回レビュー待ち) | starting review |
| starting review | reviewer | reviewer がレビュー実行中 | completed review / ready for implementation |
| completed review | reviewer | レビュー完了・blocker あり (作者の対応待ち) | starting review work |
| ready for implementation | reviewer | レビュー完了・blocker なし (実装に着手できる) | — (PR フェーズへ) |
| starting review work | 作者 | 作者が指摘対応を開始した | waiting for review |
| waiting for review | 作者 | 指摘対応が済み再レビュー待ち | starting review |
| need for human review | reviewer | 停止条件到達 (round 上限 / blocker 傾向未改善)・人間が続行可否を判断 (PR フェーズ同名 status の issue 版・非終端の sink。issue #88) | 人間の判断による (継続するなら waiting for review 等へ戻す) |
| closed issue | 人間 (明示指示によるエージェント代行を含む) | 実際に close した (終端。githubState=closed) | — |

PR フェーズ (10 status):

| status | 主体 | 意味 | 次の遷移先 |
|---|---|---|---|
| null | — | 未着手 (実装前) | implementation-ready / created pr |
| implementation-ready | 作者 | **実装完了・PR 未作成** (PR を作れば created pr) | created pr |
| created pr | 作者 | PR を作成した (初回レビュー待ち) | starting review |
| starting review | reviewer | reviewer がレビュー実行中 | ready for merge / completed review |
| completed review | reviewer | レビュー完了・blocker あり (作者の対応待ち) | starting review work |
| need for human review | reviewer | 停止条件到達 (round 上限 / blocker 傾向未改善)・人間が続行可否を判断 | 人間の判断による (継続するなら waiting for review 等へ戻す) |
| ready for merge | reviewer | レビュー完了・blocker なし (merge 可。reviewer の上限) | merged pr (merge は人間。明示指示による代行は例外) |
| starting review work | 作者 | 作者が指摘対応を開始した | waiting for review |
| waiting for review | 作者 | 指摘対応が済み再レビュー待ち | starting review |
| merged pr | 人間 (明示指示によるエージェント代行を含む) | 実際に merge した (終端。githubState=merged) | — |

紛らわしい 3 点:
- `starting review` = **reviewer** がレビューを実行中 (レビュー開始マーカー)。
- `starting review work` = **作者** が指摘対応を開始 (レビューではなく対応作業)。
- `implementation-ready` = **実装完了・PR 未作成**。「実装に着手できる」ではない — それは issue 側の `ready for implementation` で、別物。

## 証拠 (evidence)

- `evidence` の build / test / lint / done は、この repo でそれぞれを実行するコマンド (無いものは null)。
- status を `ready for implementation` / `ready for merge` に進める前に、`evidence.done` (既定 = test) を実際に実行して exit 0 を確認する。実行と確認は実装者 (main developer) の責務。
- ready 系 status の step があるのに `evidence.test` が null だと CI が失敗する (消し忘れ・入れ忘れの防止線)。

## 役割の分離 (doer ≠ judge)

- コードを書く人 (main developer = 普段のセッション) と、レビューして判定する人 (reviewer = pr reviewer ロール規約 (`roles/pr-reviewer.md`) に従い orchestrator (`/harness-orchestrate`) が dispatch する別セッション相当の subagent) を分ける。dispatch は main developer のセッションとは独立した subagent 呼出であり、reviewer は変更を初見で見る。issue フェーズも対称で、issue reviewer (`roles/issue-reviewer-dispatch.md`) と issue review worker (`roles/issue-review-worker.md`) を orchestrator が別 subagent として dispatch する (issue #88)。
- reviewer が進められる status は `ready for merge` / `need for human review` まで (どちらも reviewer が設定できる終端手前の状態)。**終端の `merged pr` / `closed issue` は、人間が実際に merge / close した時にだけ書く**(ただし人間の明示指示がある場合の代行は例外 — 詳細は下記『終端の記録と merge 代行』節を参照)。
- **issue フェーズの単一 sink (`need for human review`・issue #88)**: PR フェーズの `need for human review` sink を issue フェーズへ対称に写す。前進不能な issue (停止条件到達 = round 上限 / blocker 傾向未改善、または主観的エスカレーション) は原因を問わず単一の失敗経路 `issue.status = "need for human review"` へ集約し、`need for human review` ラベルを **issue に** 付与して人間へ surface する。issue reviewer が進められる status は `ready for implementation` / `need for human review` まで (PR reviewer の `ready for merge` / `need for human review` と対称の終端手前状態)。**issue review worker が `ready for implementation` を立てるのは越権 (例外なし)** — worker の前進 outcome は `waiting for review` 固定で、`ready for implementation` は issue reviewer の判定 (`clean_pass`) 経由でのみ到達する (decision script が構造的に担保。doer ≠ judge)。ラベル解除だけでは再 dispatch されない #12 結線を保つため、sink は status を書いてから集約する (詳細な配線は `commands/harness-orchestrate.md`「失敗経路」節)。**非対称の正直な明記 (issue #88)**: 「issue フェーズ = PR フェーズと対称」の主張は 2 点で成立しない — (i) issue フェーズには実行して落とせる証拠 (test) が構造的に無く **evidence gate 相当が無い** (有界化は停止条件機構 + issueReviewLock hang 検知が担い、「偽の前進」検知は issue reviewer の別セッション読取に一本化される = PR responder より弱い)、(ii) issue reviewer の判定エンジンは v1 では kit 非同梱の個人 skill `reviewing-github-issues` に依存する **opt-in path** で可搬でない (PR 側の既定 `code-review` は #49 で可搬化済み・個人 skill 依存は opt-in `multi-angle` 限定)。完全可搬化 (8 観点 rubric を `roles/issue-reviewer.md` へ inline) は follow-up。**PR を伴わない issue 単体の close 代行は本 kit のスコープ外** (『終端の記録と merge 代行』「スコープ外(意図的)」を踏襲)。
- `completed review` になったら、実装者が指摘の採否を判断して修正し、`waiting for review` に戻す。
- **対応側が `ready for merge` を立てるのは越権 (例外なし)**。指摘が解消不可 (環境依存の実測値が要る等) でも、「merge 後の対応でよい」と作者間で合意した場合でも、対応側は `waiting for review` に戻すだけ。merge 後対応にするか否かの最終判断は reviewer の責務。
  (実事故の教訓: 対応側が「作者と合意済みの follow-up」を根拠に直接 `ready for merge` へ進め、reviewer の検証を飛ばした)

## 台帳の書込経路

台帳 (`.harness/plan-progress.json`) は **ローカル台帳** = main checkout の所定位置に置く単一のローカルファイルとして扱う。**状態遷移はこのファイルのローカル編集だけで行い、git にコミット/push しない** (issue #11 F案)。main への直接 push を禁止する branch protection / 組織ポリシーのリポジトリでもそのまま運用できる。

- **状態遷移はローカルのファイル編集のみ** (`jq` / python でファイルを書き換えるだけ)。`git add` / `git commit` / `git push` は行わない。
  - `.harness/plan-progress.json` は git 追跡対象のままだが、状態遷移によるローカル編集分はコミットしない (作業ツリー上は常に「変更あり」の状態になる — これは F案の正常な状態)。
  - 新規 step の追加など構造的な変更も同様にローカル編集のみで完結させる (コミットしない)。単一マシンへの依存によるバックアップ・災害復旧はスコープ外 (#11 Decision で履歴喪失は受容済み)。
- PR は原則コードだけを運ぶ。台帳 (状態遷移) を PR ブランチに載せない。
- **機械検証は「ローカル validator の実行結果を Statuses API で自己申告する」方式**で維持する (台帳が commit されないため、GitHub ホストの CI が committed な台帳を検証する方式は成立しない)。**この機械検証 (schema/drift) は、F案では台帳がローカル (非コミット) であり独立ランナー (旧 harness-gate.yml) から見えないため、状態遷移を書いた本人セッションによる自己申告に必然的に縮退する。これは main-push 禁止ポリシー (台帳ローカル化) が生む受容コストである。台帳に対する ③ (作る人 ≠ 判定する人) の実質は、ほぼ**別セッションで起動する PR reviewer が実際の diff/状態を初見で読むこと単独**に依存する — F案では状態遷移をローカルにのみ書きコミットしないため、台帳の git history は遷移の監査証跡にならない (この点は下記『終端の記録と merge 代行』節「台帳はローカルで git 履歴に残らない」とも整合する)。自己申告は独立検証の代替ではなく便宜シグナル (convenience signal) である**:
  - 状態遷移を書くたびに、ローカルで `python3 .harness/validate-plan-progress.py --schema` と `--drift` を実行し、その結果を **対象 PR の head SHA** に対して Statuses API で報告する:
    `gh api repos/<owner>/<repo>/statuses/<head_sha> -f state=<success|failure> -f context=harness-gate -f description="..."`
    (この schema/drift 実行 → Statuses post は `scripts/report-ledger-status.sh` に抽出済み。`ROOT="$(git rev-parse --show-toplevel)"` から `PLAN` / validator を全て**絶対パス**で解決するので CWD が repo ルート以外でも失敗しない。`commands/harness-orchestrate.md` と `roles/pr-reviewer.md` 手順 3/6 が共有する単一の実体で、報告ロジックを散文に複製しない。)
  - 報告対象は常に「その時点で処理対象になっている PR の head SHA」、報告内容は「その処理の瞬間にローカル台帳が schema 妥当・drift 無しであった」という attestation。PR のライフサイクル中、状態遷移のたびに最新化される。
  - branch protection の required check はこの Statuses API の context (`harness-gate`) を指定する — ただし**便宜シグナルとしての required check (spoof 可能性を承知の上)** である。**Statuses API** (`POST /repos/{owner}/{repo}/statuses/{sha}`) を使うのは、個人アカウントの `gh auth` (PAT/OAuth) で書き込めるため — Check Run 作成 (Checks API) は GitHub App 認証が必須 (このリポジトリの個人 `gh auth` では不可能) なので使わない (issue #17 round 2 決定)。**この選定の帰結として、Statuses API は書込権限を持つ主体が validator を実行せず直接 `state=success` を打てる (spoof 可能) — Checks API より弱い。したがって自己申告は security boundary ではなく、真の検証は上記 PR reviewer の別セッション読み取りが担う。**
  - **日次 cron drift 検査は「統合」ではなく廃止した**: 旧 harness-gate.yml の日次 schedule による drift 検査は**廃止**した (issue #17 round 2 で deprecate 決定)。F案ではローカル台帳を自動で定期検証する手段が原理的に無いため、**drift は状態遷移時の自己申告 + reviewer の台帳読み取り時にのみ検知される**。遷移が無い間 (例: `waiting for review` 放置中) の GitHub 側乖離は次遷移まで見逃されうる — これは F案の**受容された帰結**である。
  - **`--drift` の呼出頻度増 (受容コスト + follow-up)**: 状態遷移のたびに `--drift` (実台帳で 1 回あたり O(N)・約 23 回の gh 呼出) が走るため、旧方式 (日次 1 回) より gh API 呼出頻度が大幅に増える。これは F案の受容コストとして許容する。**対象 PR の head SHA に紐づく step のみへ drift を絞る (full O(N) を避ける) 最適化は follow-up** とする (本 PR ではコード最適化はせず文書化のみ)。
- 台帳の書込主体は orchestrator のみとし、同じ台帳に対して他のコマンドから直接編集しない。
- developer / reviewer は同一マシンの同一ローカル台帳ファイルを共有する。書込主体を orchestrator 単一に保つことで、ローカルファイルへの競合書込を避ける (別セッションでも同じファイルを読む)。

### 作業レポートの書込 (`reports[]`)

各ロールは作業を終えたとき、対象 step の `reports[]` へ作業レポートを 1 件追記できる (issue #25 レイヤ1b / #29)。目的はダッシュボードの作業フィード (`WorkFeed`) へ「誰が・いつ・何をしたか」を人間可読で流すこと。台帳の status / evidence の正しさとは独立した**可視化の付加価値**であり、**v1 は best-effort** (書き忘れても台帳は妥当) とする。

- **書込経路は状態遷移と同じ**: `reports[]` もローカル台帳への直接編集で書く (F案・issue #11)。`git add` / `git commit` / `git push` は**しない** (作業ツリー上で台帳が「変更あり」になるのは正常)。
- **1 件の形 (schema `definitions.report`)**: `{author, role, timestamp, body}` の 4 つすべて必須。
  - `author` / `role`: 作業したロールの識別名とロール区分 (developer / reviewer 等)。下表「作業ロール」列の値。
  - `body`: ロールごとの簡潔な自由文サマリ (下表「`body` の目安」列。`WorkFeed` は本文を 1 段落として表示するため構造化は不要)。
  - `timestamp`: **`date -u +%Y-%m-%dT%H:%M:%SZ` で生成する** (UTC・`Z` 終端)。schema の timestamp pattern はオフセットに**コロン必須** (`+09:00`) か `Z` を要求するが、macOS/BSD の `date +%z` は `+0900` (コロン無し) を返しこの pattern に**マッチしない** — `updatedAt` に使う `date +%F` の延長で `date +%FT%T%z` と書くとここで不正値になる。`Z` 終端に固定して pattern の `Z` 枝へ確実に乗せる。
- **保持は最新 10 件・FIFO / trim は書込側の責務**: append した後に**最新 10 件へ切り詰める** (`(.reports + [$new])[-10:]` 相当。jq では `(.steps[] | select(...) | .reports) |= (((. // []) + [$rep])[-10:])`)。schema の `maxItems: 10` は超過を**拒否する契約**であって自動削除はしない (11 件目を append しただけでは古いものは消えない) ため、append と trim を一体で行う。
- **機械強制されない (best-effort の帰結・正直な明記)**: 現行の `validate-plan-progress.py --schema` は台帳の status / evidence / 整合規則のみを**限定的に手書き検査**する validator で (JSON Schema ライブラリは使わない)、`reports[]` の件数・timestamp 形式・必須キーは**検査しない**。したがって上の timestamp 形式・10 件 trim・4 キー必須は「書込側が守る規約」であって、状態遷移時の自己申告 (`--schema`) が捕まえるゲートではない。これは A1 (v1 best-effort・status 遷移へのレポート同伴を機械強制しない) の帰結であり、reports の妥当性は書込側の遵守と読取側 `deriveFeed` の fail-soft (壊れた要素は読み飛ばす) が担保する。
- **昇格条件 (自動計数機構は持たない)**: 書き忘れによるフィード欠落が 3 回観測されたら validator 検査 (L3 相当) への昇格を検討する。ただし best-effort は「書かなくても台帳は妥当」= 欠落が痕跡を残さないため、この「3 回」を**自動計数する機構は持たない** — 人間がレビュー時などに観測して判断する目安であり、自動発火するゲートではない。
- **単一 writer 整合 — 「誰が作業したか」と「誰が台帳へ書くか」を分ける**: 本 repo は Phase 1 完了まで**単一 writer (orchestrator / ルート) だけが台帳を書く**運用 (上記「台帳の書込経路」節)。作業レポートも例外ではなく、**委譲先の子ロールは `reports[]` を直接書かない**。作業したロールは単一 writer に報告し、**単一 writer がそのロールを `author` / `role` に記録して書く**。したがって下表「作業ロール」列は `author` / `role` に入る値であって、台帳へ書き込む主体 (= 単一 writer) とは別である。

  | 作業ロール (= `author` / `role` の値) | 書くタイミング | `body` の目安 |
  |---|---|---|
  | main developer (実装役) | 実装完了・PR 作成 / status を進めた時 | 何を実装したかの要約 |
  | main developer (対応役) | レビュー指摘への対応完了時 | 採用 / 却下した指摘の概要 |
  | pr reviewer | 判定確定時 (`ready for merge` / `completed review` / `need for human review`) | 判定結果 + finding 件数 |
  | pr review worker | 対応完了時 | 対応内訳の要約 |
  | issue reviewer | レビュー判定確定時 | 判定結果 (`ready for implementation` / `completed review`) + finding 件数 |
  | issue review worker | 指摘対応完了時 | 対応内訳の要約 |
  | orchestrator | dispatch 結果確定時 (evidence gate 通過後など) | dispatch した相手・結果の要約 |

- **kit で編集できる範囲の区別**: 本規約 (`.harness/CLAUDE.harness.md` + `templates/` 複製) が全ロール共通の正。kit 同梱の role 規約のうち **`roles/pr-reviewer.md` (pr reviewer) だけが実際の判定結果を持つ** (手順 6・orchestrator へ返り値として渡し、`commands/harness-orchestrate.md` が単一 writer として台帳へ代筆する。配線は完了している — issue #52 Phase A)。kit 未同梱の個人 skill 側ロール (issue reviewer / issue review worker / pr review worker 等) は本規約を読んで best-effort で手編集するのみで、kit からは強制できない。**したがって現在稼働する自動書込経路は orchestrator が単一 writer として代筆する経路のみ**であり、他ロールは orchestrator 未経由の best-effort を待つ。

## 終端の記録と merge 代行

- 終端 status (`merged pr` / `closed issue`) は原則として人間が実際に merge / close した時にだけ書く (「役割の分離」参照)。ただし **人間の明示指示がある場合に限り**、エージェントが merge と終端記録を代行してよい。守るのは判断の所在が人間にあることであって、誰がコマンドを叩くかは守らない。
- **単一書込主体原則との関係**: merge 代行は、人間が明示的に指示した際に別セッションで一回性に行う手動操作であり、単一書込主体原則 (orchestrator 以外から同じ台帳を直接編集しない、という原則) とは矛盾しない。ただし orchestrator ループが稼働中の同一ローカル台帳に対して人間が merge 代行を指示する場合、ローカルファイルへの書込タイミングが重なる可能性があるため、書込主体を単一に保つ原則に従い、タイミングを分ける。
- 代行するときの必須手順:
  1. 事前確認 — `pr.status == "ready for merge"` かつ CI が緑であることを確認する。
  2. merge する。既定方式は merge commit。導入先の branch protection が squash-only / rebase-only を強制する場合はその設定が優先する (本 kit の既定値は「他に制約が無い場合」に適用される)。この既定 (merge commit) は代行時に限らず、人間による通常の merge 判断にも同様に適用される。
  3. 終端 status (`merged pr` + `githubState: merged`) を **ローカル台帳に記録する** (「台帳の書込経路」節に従いローカル編集のみ・コミットしない)。**人間の明示指示による代行である旨**を対象 PR へコメントとして残す (監査証跡。台帳はローカルで git 履歴に残らないため、代行の事実は PR コメントで担保する)。書込後は「台帳の書込経路」節の Statuses API 自己申告を対象 PR の head SHA に対して行う。
  4. `--drift` を検算し、merge で自動 close された issue の終端 (`closed issue` + `githubState: closed`) もここで記録する。
- **スコープ外(意図的)**: 本節が定義するのは PR merge に伴う終端記録の代行のみ。PR を伴わない issue 単体の close 代行(人間の明示指示によるスタンドアロン close)は本節の対象外とし、必要になった時点で別途手順を定義する。
- **1. の事前確認が失敗した場合 (`pr.status != "ready for merge"` または CI 未緑)、エージェントは merge を拒否し、状況を人間へ報告してエスカレーションする。** 人間の明示指示があっても、機械検証可能なゲートを自己判断で上書きしない — doer ≠ judge の精神を merge 代行にも適用する。
- **merge commit を既定にする根拠**: 各 round のレビュー往復そのものが「経験還元」の記録であり (issue #1 の設計思想)、squash で潰すとこの記録が失われる。
