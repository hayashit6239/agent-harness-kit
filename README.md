# agent-harness-kit

AI エージェントと進める開発の「型」を、コマンド 1 つで任意のリポジトリに導入できるようにする Claude Code plugin。
[local-html-viewer](https://github.com/hayashit6239/local-html-viewer) の開発で実証した方式 (進捗台帳の状態機械 / doer≠judge のレビュー体制 / 証拠錨) を、4 ロールの振り返りで見つかった欠陥を修正した版としてテンプレ化する。設計の経緯は issue #1 (rfc) を参照。

## 何が導入されるか (現行版 = minimal 構成)

`/harness-init` を対象リポジトリで実行すると:

- **`.harness/plan-progress.json`** — 進捗の正本 (台帳)。issue 8 段階 / PR 9 段階の状態機械。リポジトリ内のローカルファイルとして置き、ローカル validator で機械検証してその結果を Statuses API で自己申告する (元方式の「`~/.claude` 配下で参照できない」問題の根治。状態遷移は git にコミットしない = main への直接 push を禁止するポリシーでも運用できる。issue #11 F案)
- **`.harness/plan-progress.schema.json` / `.harness/validate-plan-progress.py`** — 台帳の語彙 (status enum の単一源) と検証器。plugin 非インストール環境でも動くよう、対象リポジトリ内に複製して自己完結させる
- **証拠錨** — build / test / lint / done のコマンドを対話で聞き取り、台帳に格納。「done の証拠 (test が exit 0) なしに完了と呼ばない」ための土台
- **ローカル台帳検証 + Statuses API 自己申告** — 台帳を git にコミットしないため、状態遷移のたびに `validate-plan-progress.py` の (a) スキーマ検査 (enum 逸脱・整合規則・証拠の欠落) と (b) GitHub 実態との drift 照合をローカルで実行し、その結果を対象 PR の head SHA に Statuses API (context `harness-gate`) で報告する。branch protection の required check はこの context を指定する (旧 `.github/workflows/harness-gate.yml` の日次 schedule drift 検査はこれに統合・廃止した)
- **`.harness/CLAUDE.harness.md`** — 運用規約の断片。CLAUDE.md 本体にはマーカー付き参照 1 行だけを追記 (冪等・既存内容を壊さない)

## ロール構成 (minimal 構成 = 「1人 + 台帳」)

ロール = 別々の Claude Code セッション。

| ロール | セッション | 責務 |
|---|---|---|
| main developer (doer) | メイン | 実装・issue/PR 作成・証拠 (test) の実行と exit 0 確認・レビュー指摘への対応 |
| reviewer (judge) | orchestrator (`/harness-orchestrate`) が dispatch する subagent (role 規約 `roles/pr-reviewer.md`) | 台帳からレビュー待ち PR を選別 → 3 観点並列レビュー → コメント投稿 → `pr.status` を自動進行 (`ready for merge` が上限) |

- 終端 (`merged pr` / `closed issue`) は人間の merge / close (人間の明示指示によるエージェント代行を含む) に伴ってのみ記録する。`ready for merge` = 人間が最終確認するタイミング。
- merge 可否の判定 (`has_blocker`) は wrapper 側で再集計する: 全観点の 🔴 に加え、アーキテクチャ / 規約観点の 🟡 も blocker に含める (「correctness の明白なバグ以外は素通し」になるゴム印化への対策)。

### orchestrator (Phase 1 の最初の増分)

developer (実装役) は自分で手を動かして進めることもできるが、pr reviewer は単体起動を廃止したため、`/harness-orchestrate` (Phase 1 P13・orchestrator walking skeleton) が developer (実装役・対応役) と pr reviewer への配車を担う唯一の経路になる。orchestrator 自身は判定ロジックを持たず、`Agent` ツールで各ロールの subagent を dispatch し、返答を evidence gate / git status ガードで検証してから台帳へ単一書込する (判断は既存の skill/command に委譲)。詳細は `commands/harness-orchestrate.md` を参照。**issue reviewer 側の自動化・真の無人化 (GitHub Actions 等) は対象外** (現行は `/loop` でセッションを開いている間だけの定期実行)。

## 前提 (重要)

現時点の対象は作者自身 (将来共有を見据えて固有情報は分離)。pr reviewer ロール (`roles/pr-reviewer.md`) の既定 `review-mode=code-review` は個人 skill 不要で動く。opt-in の `review-mode=multi-angle` を使う場合のみ **作者の個人 skill 群に依存し、plugin には同梱していない**:

- `reviewing-multi-angle` (3 観点レビューの統合)
- `/code-review` / `reviewing-pr-architecture` / `reviewing-pr-google-method`

このほか `gh` CLI (認証済み)・`python3`・`jq` が必要。前提が無い環境ではコマンド冒頭の検査で停止する。

`/harness-orchestrate` は review-mode=multi-angle で pr reviewer を dispatch する場合、上記と同じ個人 skill 群に依存する (既定の review-mode=code-review では不要)。加えて `Agent` ツール (subagent dispatch) と `PushNotification` ツール (エスカレーション通知) が使える環境が前提。

## 使い方

```
# 1. plugin を install (Claude Code)
# 2. 対象リポジトリで
/harness-init
# 3. 開発を進め、PR を作ったら developer / pr reviewer への配車を orchestrator に任せる (Phase 1 P13)
/harness-orchestrate
```

台帳への書込主体は orchestrator のみ (`.harness/CLAUDE.harness.md` の単一書込主体の原則)。他のコマンドから同じ台帳を直接編集しない。

台帳の状態遷移はローカルのファイル編集のみで行い、git にコミット/push しない (ローカル台帳・issue #11 F案)。機械検証はローカル validator の実行結果を対象 PR の head SHA へ Statuses API で自己申告する。理由と詳細は `.harness/CLAUDE.harness.md` の「台帳の書込経路」節を参照。

## 開発 (このリポジトリ自体)

このリポジトリは自分自身のテンプレで管理している (dogfood)。台帳は `.harness/plan-progress.json` (ローカル編集・非コミット)、CI は smoke (`.github/workflows/ci.yml`)。台帳検証はローカル validator + Statuses API 自己申告。

```
bash tests/smoke/run-smoke.sh   # 最小動作確認 (LLM 不要・決定論的)
```

進捗台帳を眺めるダッシュボード (`dashboard/`) はローカル専用の道具で、CI には組み込まない。Node `^20.19.0 || >=22.12.0` が必要。

```
cd dashboard && npm install
HARNESS_PROJECT=<対象プロジェクトの絶対パス> npm run dev   # http://localhost:5173
```

## 成熟度の段階

| 開発段階 | 構成名 (製品側の呼び方) | 内容 | 状態 |
|---|---|---|---|
| **Phase 0** | minimal | 1人 + 台帳 (main developer + reviewer 1 + CI gate + 証拠錨) | 現行版 |
| Phase 1 | full (旧 Phase 2 を再定義) | orchestrator loop で developer / pr reviewer を配車、単一書込、停止条件、doer≠judge 分離 (旧 Phase 1 の 5 ロール手動 + capability hook + 敵対的 Verifier + 4 種停止条件は、独立した段階を経ずここへ直接組み込んで吸収) | 一部出荷 (台帳 P13「orchestrator walking skeleton」= `/harness-orchestrate` (developer / pr reviewer の配車) が出荷済み。起動は `/loop` 駆動のまま、人間セッション必須) |
| Phase 2 | auto (旧 Phase 2 の残り) | Automations (discover→enqueue) + scheduled heartbeat による完全無人化 | 未着手 (判定 skill の kit 同梱という前提作業を要するため別 issue へ先送り中) |

※ 2026-07-08 頃、当初「Phase 2」として構想していた orchestrator の内容を「Phase 1」として再定義し、Phase 0 の直後に直接実装する方針に変更した。旧 Phase 1 (5 ロール手動 + capability hook 等) は独立した中間段階を持たず、新 Phase 1 (orchestrator) にその安全機構を直接組み込んで吸収している。経緯は issue #1 参照。

※ 語彙の割当: **Phase 0/1/2 は開発計画の語彙**で、README・進捗台帳・issue にのみ現れる。**製品側 (commands / templates = 対象 repo に導入されるもの) は構成名 (minimal / full / auto) で自己記述**し、開発計画に依存しない。また成熟度 (Phase) と制約強度の L1–L4 (Rules / Skill / Hook・CI / 構造テスト) は別の軸。
