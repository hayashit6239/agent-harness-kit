# agent-harness-kit Phase 0 規約

この repo は agent-harness-kit (Phase 0) で進捗を管理する。守るものは 3 つ:
①台帳と GitHub 実態の一致 ②merge 前に証拠 (test) が緑 ③作る人と判定する人の分離。

## 進捗台帳 (`.harness/plan-progress.json`)

- 1 つの作業単位 = `steps[]` の 1 要素。issue フェーズと PR フェーズそれぞれの status を持つ。
- status は `statusEnums` にある語だけを使う (語彙の単一源は `.harness/plan-progress.schema.json`)。勝手な語を足さない・言い換えない。
- 状況が変わるたびに status と `updatedAt` (YYYY-MM-DD) を更新する。
- `githubState` は GitHub の実態を写す欄。願望や予定を書かない (CI の drift 検査が失敗する)。
- CI (harness-gate) が常時スキーマ検査を、PR 時と日次で GitHub との突き合わせ (drift 検査) を行う。手元では
  `python3 .harness/validate-plan-progress.py --schema .harness/plan-progress.json` で同じ検査ができる。

## 証拠 (evidence)

- `evidence` の build / test / lint / done は、この repo でそれぞれを実行するコマンド (無いものは null)。
- status を `ready for implementation` / `ready for merge` に進める前に、`evidence.done` (既定 = test) を実際に実行して exit 0 を確認する。実行と確認は実装者 (main developer) の責務。
- ready 系 status の step があるのに `evidence.test` が null だと CI が失敗する (消し忘れ・入れ忘れの防止線)。

## 役割の分離 (doer ≠ judge)

- コードを書く人 (main developer = 普段のセッション) と、レビューして判定する人 (reviewer = 別セッションで `/harness-review-pr` を起動) を分ける。別セッションなので reviewer は変更を初見で見る。
- reviewer が進められる status は `ready for merge` まで。**終端の `merged pr` / `closed issue` は、人間が実際に merge / close した時にだけ書く**。
- `completed review` になったら、実装者が指摘の採否を判断して修正し、`waiting for review` に戻す。

## 台帳の書込経路

- **状態遷移は main へ直接コミットする**。`.harness/plan-progress.json` だけを含む小さいコミットを作る。
  - コミットメッセージの規約: `chore(harness): <step id> pr.status -> <新 status>`
  - 例: `chore(harness): P1 pr.status -> ready for merge`
- PR は原則コードだけを運ぶ。status の書込を PR ブランチに載せない (merge されるまで main の台帳に現れず、reviewer の選別から漏れ続ける)。
- 例外: `.harness/` 自体を導入する PR だけは、自分の台帳項目を自分で運んでよい (PR 番号は作成後に追記して push する)。
- reviewer は開始時に `git pull --ff-only` してから台帳を読む (古い台帳で選別しない)。
- 同時に main へ push して競合したら、後から push した側が pull してやり直す。
