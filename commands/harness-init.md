---
description: 対象 repo に agent-harness-kit (minimal 構成) を導入する。対話で build/test/lint コマンドを聞き取り (証拠錨)、.harness/ (進捗台帳 + スキーマ + 検証器 + 規約断片) を生成し、CLAUDE.md には参照 1 行だけをマーカー付きで追記する (冪等)。台帳検証はローカル validator + Statuses API 自己申告方式 (git 非コミットのローカル台帳・issue #11 F案) のため CI ワークフローは生成しない。
argument-hint: "[target-repo-path]  省略時: CWD"
allowed-tools: [Read, Glob, Grep, Bash, Write, Edit]
---

# /harness-init — minimal 構成の導入 (scaffold)

対象 repo に「1人 + 台帳」の minimal 構成を導入する: plan-progress 台帳・証拠錨。台帳は git にコミットしないローカル台帳で、検証はローカル validator の実行結果を Statuses API で自己申告する方式 (issue #11 F案) のため、CI ワークフローファイルは生成しない。
生成する雛形の原本は `${CLAUDE_PLUGIN_ROOT}/templates/` にある (単一源。ここから複製する)。

## 手順

### 0. 前提コマンドの検査 (ファイル生成前に必ず)

**ファイルを 1 つでも生成する前に**、前提コマンドを検査する。欠けていたら「前提コマンド <名前> が見つからない (または gh が未認証)。インストール / 認証後に再実行すること」とエラーで停止する (中途半端な `.harness/` を残さない):

```
for c in gh python3 jq; do command -v "$c" >/dev/null || { echo "前提コマンド $c が見つからない"; exit 1; }; done
gh auth status >/dev/null 2>&1 || { echo "gh が未認証 (gh auth login で認証してから再実行する)"; exit 1; }
```

- `gh`: 手順 5 のラベル作成、台帳検証の drift 照合 (`--drift`)、および状態遷移時の Statuses API 自己申告の前提。存在に加えて `gh auth status` で認証も確認する。
- `python3`: 検証器 (`validate-plan-progress.py`) の実行に必要。
- `jq`: `/harness-review-pr` の台帳選別に必要。

### 1. 対象 repo の確定

- `$ARGUMENTS` にパスがあればそれを、無ければ CWD を対象とする。
- 対象ディレクトリで `git rev-parse --show-toplevel` を実行して git repo のルートを確認する。git repo でなければ「対象が git repo でない」と明確なエラーで停止する。
- 以降の生成パスはすべてこのルート基準。

### 2. 証拠コマンドの聞き取り (証拠錨)

ユーザーに対話で次の 4 つを聞く。**自動検出はしない** (stack 自動検出は別 issue の範囲。推測で埋めず、必ず本人に入力してもらう):

- `build`: ビルドを実行するコマンド (無ければ null)
- `test`: テストを実行するコマンド (無ければ null — ただし ready 系 status を使う時点で CI が non-null を強制する)
- `lint`: lint を実行するコマンド (無ければ null)
- `done`: 完了ゲートとして実行するコマンド。**既定は test と同じ値** (ユーザーが変えたい場合のみ上書き)

`steps` は既定で `[]` (空。作業単位は運用開始後に足す)。

### 3. 対象 repo への生成

`${CLAUDE_PLUGIN_ROOT}/templates/` の雛形を対象 repo に複製する:

| 生成先 | 内容 |
|---|---|
| `.harness/plan-progress.schema.json` | そのまま複製 |
| `.harness/validate-plan-progress.py` | そのまま複製 (CI は plugin 非インストール環境で走るため、repo 内で自己完結させる) |
| `.harness/plan-progress.json` | `plan-progress.init.json` を元に、`project` = repo 名、`evidence` = 手順 2 の値、`updatedAt` = 今日 (YYYY-MM-DD) を埋める |
| `.harness/CLAUDE.harness.md` | そのまま複製 |

既に同名ファイルがある場合は上書きせず、ユーザーに確認する。CI ワークフロー (`.github/workflows/`) は生成しない — 台帳検証はローカル validator + Statuses API 自己申告方式のため (詳細は `.harness/CLAUDE.harness.md` の「台帳の書込経路」節)。

### 4. 既存 CLAUDE.md の保護 (参照 1 行だけ)

規約本文は `.harness/CLAUDE.harness.md` に隔離してある。対象 repo の `CLAUDE.md` には次の 3 行だけを追記する:

```
<!-- BEGIN agent-harness-kit -->
@.harness/CLAUDE.harness.md
<!-- END agent-harness-kit -->
```

- `CLAUDE.md` が無ければ、この 3 行だけの `CLAUDE.md` を新規作成する。
- `<!-- BEGIN agent-harness-kit -->` マーカーが既にあれば**何もしない (冪等スキップ)**。
- マーカーの外にある既存の記述は一切書き換えない。

### 5. 仕上げ

- `gh label create "ready for merge" --color "0e8a16" --description "reviewer が merge 可能と判定した PR" --force` を実行する (`--force` で冪等。reviewer ロールが使うラベル。**人への作業依頼にしない** — このコマンドがここで作る)。
- 前提 skill の存在を検査する: `reviewing-multi-angle` / `reviewing-pr-architecture` / `reviewing-pr-google-method` は `~/.claude/skills/<name>/SKILL.md` を `test -f` で確認し、`/code-review` は利用可能な skill 一覧にあることを確認する。無いものがあれば**警告**を出す (init 自体は続行してよいが、`/harness-review-pr` の実行には必須と伝える)。
- 最後に、生成物の一覧と次の検証フローを表示する:
  1. `python3 .harness/validate-plan-progress.py --schema .harness/plan-progress.json` が exit 0
  2. `evidence.test` のコマンドを実行して exit 0
  3. 以後、状態遷移のたびに `validate-plan-progress.py` の schema 検査 + drift 照合をローカルで実行し、その結果を対象 PR の head SHA へ Statuses API (context `harness-gate`) で自己申告する (台帳は git にコミットしない。詳細は `.harness/CLAUDE.harness.md` の「台帳の書込経路」節)
