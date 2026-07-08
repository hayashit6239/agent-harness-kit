# agent-harness-kit

AI エージェントと進める開発の「型」を、コマンド 1 つで任意のリポジトリに導入できるようにする Claude Code plugin。
[local-html-viewer](https://github.com/hayashit6239/local-html-viewer) の開発で実証した方式 (進捗台帳の状態機械 / doer≠judge のレビュー体制 / 証拠錨) を、4 ロールの振り返りで見つかった欠陥を修正した版としてテンプレ化する。設計の経緯は issue #1 (rfc) を参照。

## 何が導入されるか (現行版 = minimal 構成)

`/harness-init` を対象リポジトリで実行すると:

- **`.harness/plan-progress.json`** — 進捗の正本 (台帳)。issue 8 段階 / PR 9 段階の状態機械。リポジトリ内に置くことで CI から機械検証できる (元方式の「`~/.claude` 配下で CI から見えない」問題の根治)
- **`.harness/plan-progress.schema.json` / `.harness/validate-plan-progress.py`** — 台帳の語彙 (status enum の単一源) と検証器。plugin 非インストール環境の CI でも動くよう、対象リポジトリ内に複製して自己完結させる
- **証拠錨** — build / test / lint / done のコマンドを対話で聞き取り、台帳に格納。「done の証拠 (test が exit 0) なしに完了と呼ばない」ための土台
- **`.github/workflows/harness-gate.yml`** — CI が台帳を機械検証。(a) スキーマ検査 (enum 逸脱・整合規則・証拠の欠落) は常時、(b) GitHub 実態との drift 照合は PR 時 + 日次
- **`.harness/CLAUDE.harness.md`** — 運用規約の断片。CLAUDE.md 本体にはマーカー付き参照 1 行だけを追記 (冪等・既存内容を壊さない)

## ロール構成 (minimal 構成 = 「1人 + 台帳」)

ロール = 別々の Claude Code セッション。

| ロール | セッション | 責務 |
|---|---|---|
| main developer (doer) | メイン | 実装・issue/PR 作成・証拠 (test) の実行と exit 0 確認・レビュー指摘への対応 |
| reviewer (judge) | 別セッションで `/harness-review-pr` | 台帳からレビュー待ち PR を選別 → 3 観点並列レビュー → コメント投稿 → `pr.status` を自動進行 (`ready for merge` が上限) |

- 終端 (`merged pr` / `closed issue`) は人間の merge / close に伴ってのみ記録する。`ready for merge` = 人間が最終確認するタイミング。
- merge 可否の判定 (`has_blocker`) は wrapper 側で再集計する: 全観点の 🔴 に加え、アーキテクチャ / 規約観点の 🟡 も blocker に含める (「correctness の明白なバグ以外は素通し」になるゴム印化への対策)。

## 前提 (重要)

現時点の対象は作者自身 (将来共有を見据えて固有情報は分離)。特に `/harness-review-pr` は **作者の個人 skill 群に依存し、plugin には同梱していない**:

- `reviewing-multi-angle` (3 観点レビューの統合)
- `/code-review` / `reviewing-pr-architecture` / `reviewing-pr-google-method`

このほか `gh` CLI (認証済み)・`python3`・`jq` が必要。前提が無い環境ではコマンド冒頭の検査で停止する。

## 使い方

```
# 1. plugin を install (Claude Code)
# 2. 対象リポジトリで
/harness-init
# 3. 開発を進め、PR を作ったら別セッションで
/harness-review-pr
```

台帳の状態遷移は main へ直接コミットする (`chore(harness): P1 pr.status -> ready for merge` 形式)。理由と例外は `.harness/CLAUDE.harness.md` を参照。

## 開発 (このリポジトリ自体)

このリポジトリは自分自身のテンプレで管理している (dogfood)。台帳は `.harness/plan-progress.json`、CI は harness-gate。

```
bash tests/smoke/run-smoke.sh   # 最小動作確認 (LLM 不要・決定論的)
```

## 成熟度の段階

| 開発段階 | 構成名 (製品側の呼び方) | 内容 | 状態 |
|---|---|---|---|
| **Phase 0** | minimal | 1人 + 台帳 (main developer + reviewer 1 + CI gate + 証拠錨) | 現行版 |
| Phase 1 | standard | 5 ロール + capability hook + 敵対的 Verifier + 4 種停止条件 | 予定 (台帳 P6) |
| Phase 2 | full | orchestrator loop + Automations (discover→enqueue) | 予定 (台帳 P7) |

※ 語彙の割当: **Phase 0/1/2 は開発計画の語彙**で、README・進捗台帳・issue にのみ現れる。**製品側 (commands / templates = 対象 repo に導入されるもの) は構成名 (minimal / standard / full) で自己記述**し、開発計画に依存しない。また成熟度 (Phase) と制約強度の L1–L4 (Rules / Skill / Hook・CI / 構造テスト) は別の軸。
