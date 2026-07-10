# agent-harness-kit 運用規約

この repo は agent-harness-kit (minimal 構成 = 「1人 + 台帳」) で進捗を管理する。守るものは 3 つ:
①台帳と GitHub 実態の一致 ②merge 前に証拠 (test) が緑 ③作る人と判定する人の分離。

## 進捗台帳 (`.harness/plan-progress.json`)

- 1 つの作業単位 = `steps[]` の 1 要素。issue フェーズと PR フェーズそれぞれの status を持つ。
- status は schema (`.harness/plan-progress.schema.json`) の enum にある語だけを使う。一覧は下の status 表。勝手な語を足さない・言い換えない。
- 状況が変わるたびに status と `updatedAt` (YYYY-MM-DD) を更新する。
- `githubState` は GitHub の実態を写す欄。願望や予定を書かない (CI の drift 検査が失敗する)。
- 任意フィールド: `lastReviewedStatus` は reviewer がレビュー時の status を記録用に書く欄 (選別では参照しない・作者は触らない)。`isDraft` は GitHub の draft 実態を写す任意欄 (drift 照合はキーがある場合のみ行われる)。
- CI (harness-gate) が常時スキーマ検査を、PR 時と日次で GitHub との突き合わせ (drift 検査) を行う。手元では
  `python3 .harness/validate-plan-progress.py --schema .harness/plan-progress.json` で同じ検査ができる。
  GitHub との突き合わせは `--drift` (要 gh 認証)。

### status 一覧 (意味と遷移)

issue フェーズ (8 status):

| status | 主体 | 意味 | 次の遷移先 |
|---|---|---|---|
| null | — | 未着手 (issue 未起票) | created issue |
| created issue | 作者 | issue を起票した (初回レビュー待ち) | starting review |
| starting review | reviewer | reviewer がレビュー実行中 | completed review / ready for implementation |
| completed review | reviewer | レビュー完了・blocker あり (作者の対応待ち) | starting review work |
| ready for implementation | reviewer | レビュー完了・blocker なし (実装に着手できる) | — (PR フェーズへ) |
| starting review work | 作者 | 作者が指摘対応を開始した | waiting for review |
| waiting for review | 作者 | 指摘対応が済み再レビュー待ち | starting review |
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

- コードを書く人 (main developer = 普段のセッション) と、レビューして判定する人 (reviewer = 別セッションで `/harness-review-pr` を起動) を分ける。別セッションなので reviewer は変更を初見で見る。
- reviewer が進められる status は `ready for merge` / `need for human review` まで (どちらも reviewer が設定できる終端手前の状態)。**終端の `merged pr` / `closed issue` は、人間が実際に merge / close した時にだけ書く**(ただし人間の明示指示がある場合の代行は例外 — 詳細は下記『終端の記録と merge 代行』節を参照)。
- `completed review` になったら、実装者が指摘の採否を判断して修正し、`waiting for review` に戻す。
- **対応側が `ready for merge` を立てるのは越権 (例外なし)**。指摘が解消不可 (環境依存の実測値が要る等) でも、「merge 後の対応でよい」と作者間で合意した場合でも、対応側は `waiting for review` に戻すだけ。merge 後対応にするか否かの最終判断は reviewer の責務。
  (実事故の教訓: 対応側が「作者と合意済みの follow-up」を根拠に直接 `ready for merge` へ進め、reviewer の検証を飛ばした)

## 台帳の書込経路

- **状態遷移は main へ直接コミットする**。`.harness/plan-progress.json` だけを含む小さいコミットを作る。
  - コミットメッセージの規約: `chore(harness): <step id> pr.status -> <新 status>`
  - 例: `chore(harness): P1 pr.status -> ready for merge`
- PR は原則コードだけを運ぶ。status の書込を PR ブランチに載せない (merge されるまで main の台帳に現れず、reviewer の選別から漏れ続ける)。
- 例外: `.harness/` 自体を導入する PR だけは、自分の台帳項目を自分で運んでよい (PR 番号は作成後に追記して push する)。
- reviewer は開始時に `git pull --ff-only` してから台帳を読む (古い台帳で選別しない)。
- 同時に main へ push して競合したら、後から push した側が pull してやり直す。
- orchestrator モードで運用する場合、台帳の書込主体は orchestrator のみとし、同じ台帳に対して手動コマンド (`/harness-review-pr` 等) から直接 commit しない (モードは台帳ごとに択一)。

## 終端の記録と merge 代行

- 終端 status (`merged pr` / `closed issue`) は原則として人間が実際に merge / close した時にだけ書く (「役割の分離」参照)。ただし **人間の明示指示がある場合に限り**、エージェントが merge と終端記録を代行してよい。守るのは判断の所在が人間にあることであって、誰がコマンドを叩くかは守らない。
- **orchestrator モードの単一書込主体原則との関係**: merge 代行は、人間が明示的に指示した際に別セッションで一回性に行う手動操作であり、orchestrator モードの単一書込主体原則 (orchestrator モードでは同じ台帳に対して手動コマンドから直接 commit しない、という原則) とは矛盾しない。ただし orchestrator ループが稼働中の台帳に対して人間が merge 代行を指示する場合、push タイミングが重なる可能性があるため、既存の競合対処 (`git pull --ff-only` してやり直す) に従う。
- 代行するときの必須手順:
  1. 事前確認 — `pr.status == "ready for merge"` かつ CI が緑であることを確認する。
  2. merge する。既定方式は merge commit。導入先の branch protection が squash-only / rebase-only を強制する場合はその設定が優先する (本 kit の既定値は「他に制約が無い場合」に適用される)。この既定 (merge commit) は代行時に限らず、人間による通常の merge 判断にも同様に適用される。
  3. 終端 status (`merged pr` + `githubState: merged`) を main へ直接コミットする。コミットメッセージには**人間の明示指示による代行である旨**を注記する (メッセージ規約: `chore(harness): <step id> pr.status -> merged pr (merge 代行: 人間の明示指示による)`)。加えて、代行を実施した旨を対象 PR へコメントとして残す (監査証跡)。
  4. `--drift` を検算し、merge で自動 close された issue の終端 (`closed issue` + `githubState: closed`) もここで記録する。
- **スコープ外(意図的)**: 本節が定義するのは PR merge に伴う終端記録の代行のみ。PR を伴わない issue 単体の close 代行(人間の明示指示によるスタンドアロン close)は本節の対象外とし、必要になった時点で別途手順を定義する。
- **1. の事前確認が失敗した場合 (`pr.status != "ready for merge"` または CI 未緑)、エージェントは merge を拒否し、状況を人間へ報告してエスカレーションする。** 人間の明示指示があっても、機械検証可能なゲートを自己判断で上書きしない — doer ≠ judge の精神を merge 代行にも適用する。
- **merge commit を既定にする根拠**: 各 round のレビュー往復そのものが「経験還元」の記録であり (issue #1 の設計思想)、squash で潰すとこの記録が失われる。
