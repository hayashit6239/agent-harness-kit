---
description: 対象 repo のバックログとコードベースの構造的兆候(棚卸し / 依存の鮮度 / 約束の不履行 / レビュー残件)を定期スキャンし、裏取り付きの issue を規約準拠で起票する product manager ロールの入口(policy 層)。`/loop` で日単位に回す manage ループ。起票と提案コメントまでが自律範囲で、台帳・ラベル・epic 配線・close・優先度変更は提案止まり(単一 writer 原則 / doer ≠ judge)。判定 spec は `roles/product-manager.md`。issue #107。
argument-hint: "[target-repo-path]  省略時: CWD"
allowed-tools: [Read, Glob, Grep, Bash, Agent, Skill]
---

# /harness-product-manage — 構造的兆候からの仕事の発見と起票(product manager / policy 層)

これは **運用(policy)** の層であり、minimal 構成の **product manager ロール** の入口。バックログ(GitHub の open issue 群)とコードベース自身の**構造的兆候**から「まだ issue になっていない仕事」を発見し、裏取りを付けて規約準拠で起票する。判定 spec(責務境界・兆候源の中身・起票規約・裏取りの最低基準)は `${CLAUDE_PLUGIN_ROOT}/roles/product-manager.md` が持つ — 本コマンドは「いつ・何型を・何件まで・結果をどう報告するか」を担い、発見・起票の中身には spec 経由でのみ立ち入る。

**このコマンドは転写しない**: 手順を実行する前に必ず `${CLAUDE_PLUGIN_ROOT}/roles/product-manager.md` を Read し、その責務境界・兆候源 4 型の判定・起票規約に従うこと(`commands/harness-orchestrate.md` が `roles/pr-reviewer.md` を Read してから dispatch するのと同型)。

## 2 ループ運用モデル(issue #107・著者合意)

本コマンドと既存オーケストレーター(`/harness-orchestrate`)は、書込ドメインが直交する 2 ループの分担で運用する:

- **manage ループ(本コマンド・`/loop` で日単位)**: 棚卸し・依存整理・構造的兆候からの発見・起票。GitHub 側にのみ書く。
- **orchestrate ループ(`/harness-orchestrate`・常設巡航)**: `discover` ラベルが付いた issue の台帳 enqueue から `ready for merge` まで。台帳の単一 writer。

2 ループの接点は **`discover` ラベルただ 1 つ**(GitHub がキューとして機能する疎結合の producer / consumer)。共有可変状態が無いため、過去に実事故のあった並行台帳書込(F案は競合検知を持たない)が設計上起きない。周期も違う(orchestrate = 分単位 tick / manage = 日単位の兆候変化)ため、同居させず別ループにする(毎 tick の実効トークンを膨らませない・#38 / #61 と同型)。

- **`discover` ラベルは v1 では PM が貼らない(Alternatives A)**: PM は起票時に本文へ「discover 推奨」を明示するだけで、ラベル付与は人間に残す(WIP ゲート = 人間が流量を制御する弁を維持する)。PM が自分で貼る全自動(Alternatives B)は目標状態だが、`rules/issue-tree.md` **前文**(「この規約の改定は人間の判断による。ロールは提案できるが自律で書き換えない」)+ §5(`discover` の付与主体を「人間」と定義)の**改定(人間判断)が先行依存**のため v1 では採らない(D4)。詳細は `roles/product-manager.md`「提案止まりの境界」節。

## 手順

### 0. 前提コマンドの検査

`gh`(issue の検索・起票)と `python3` が必要。`gh auth status` で認証も確認する。欠けていれば「前提コマンド <名前> が見つからない(または gh が未認証)」で停止する(中途半端に起票を始めない)。

### 1. 対象 repo の確定

- `$ARGUMENTS` にパスがあればそれを、無ければ CWD を対象とする。`git rev-parse --show-toplevel` で git repo ルートを確認する(git repo でなければ明確なエラーで停止)。
- 以降のコード/文書 grep(約束の不履行型の裏取り)とラベル解決はこのルート基準。

### 2. 兆候源 whitelist(4 型)のスキャン → DoD (i)

`roles/product-manager.md`「兆候源 4 型」節に従い、次の 4 型を**この順**(確信度の高い順)でスキャンする。各型の逸脱判定・取得契約は spec 側が定義する(ここでは列挙のみ・転写しない):

1. **約束の不履行**(コード/文書が「別途 issue 化する想定」と予告したまま未起票)— repo の code/文書 grep で file/line 根拠を得る
2. **依存の鮮度**(issue 本文の依存記述が実態 merged/closed と食い違う stale 参照)
3. **棚卸し**(epic 帰属漏れ・ラベル不整合・迷子 issue)— `rules/issue-tree.md` §3.3 の 3 シグナル不整合で機械判定。§5 の `.harness/roadmap.json`(phase→epic 逆引き)に依拠する
4. **レビュー残件**(round レビューの 🟡 残件・振り返りの follow-up 未起票)

- **roadmap.json 不在時の fail-soft(D6)**: 棚卸し型(第 1 型ではなく上記 3.)が依拠する `.harness/roadmap.json` の provisioning 所有者は **`/harness-init`**(`rules/issue-tree.md` §6.1)であり本コマンドではない。未整備(ファイル欠損 / `phases: []`)の間、当該検査は §6.3 fail-soft で「解決不能」を 1 行 surface して skip する(crash しない)。**DoD (i)「4 型スキャンが走る」は、この型が fail-soft skip = no-op でも満たす**。
- **whitelist 外は拾わない**: バックログのノイズ膨張を防ぐため、v1 は上記 4 型に限る(機械的兆候源 = CI 失敗 / doc 乖離 / 監査は #102 の射程・スコープ外)。

### 3. 候補ごとの裏取り(起票前) → DoD (ii)

各候補について、`roles/product-manager.md`「裏取りの最低基準」に従い**根拠を実在確認**する(file/line または URL)。裏取りできない候補は起票しない(憶測で issue を生やさない)。

### 4. 起票前 dedup(2 レイヤ)→ DoD (iii)

**PM の起票前 dedup と、enqueue 側 `decide-enqueue-steps.py` の dedup は別レイヤ(D3)**:

- **前段フィルタ(決定論・script 化可)**: 決定論キーがある粗い突合のみ — タイトル完全一致 / 同一 URL / 既存 open issue が既に持つ file:line 根拠の一致。
- **本判定(内容ベース・LLM・非決定論)**: 「既存 issue と同じ問題か」の意味的判断。**起票前の候補は番号未採番**のため `issue.number` 一致で閉じる enqueue 側 dedup(採番済み突合)とは本質的に別物 — 「pure script に切る」は dedup 全体には成立しない。

既存 open/closed issue を `gh issue list` / `gh search issues` で検索し、意味的に重複する候補は起票しない。この LLM 判断部は smoke 対象外 = 手動の最小動作確認(本文のテスト境界と整合)。

### 5. 起票上限 N と超過時挙動(暴走防止)

- **N = 1 tick の起票上限**。v1 目安 = **3**(policy 層の小さな既定値・運用観測で調整可・D2)。
- **候補が N を超えたとき = 兆候型の確信度順に N 件だけ起票し、残りは破棄して次 tick 再スキャン(持ち越さない)**(D2)。選抜順は上記 2. の 4 型順(約束の不履行 > 依存の鮮度 > 棚卸し > レビュー残件)、同型内は検出順(安定)で tie-break。
  - **なぜ持ち越さないか**: enqueue の step は台帳に残るため持ち越せるが、**PM の起票は不可逆**(GitHub に issue が生える)。溢れた候補を持ち越すと二重起票リスクになる。まだ有効な兆候は次 tick で再浮上し、既起票分は上記 dedup が閉じる。
- **機械 backstop は持たない(D7)**: 上限 / dedup / whitelist の 3 点は v1 では L1(本手順の遵守)で受容する(公開起票の不可逆性を承知の上)。起票数の hard cap 等は誤起票が観測された場合の follow-up 候補。

### 6. 起票 → DoD (ii)

上限内の候補を、`roles/product-manager.md`「起票規約」→ `${CLAUDE_PLUGIN_ROOT}/rules/issue-authoring.md`(本文構成・prefix 選定・起票前チェックリスト)+ `rules/issue-tree.md`(層・帰属・prefix 語彙)に準拠して起票する。各 issue には:

- 兆候の**根拠**(file/line または URL)を本文に残す(裏取りの可視化)。
- v1 = Alternatives A のため、本文へ **「discover 推奨」を明示**する(ラベル付与は人間に残す・自分で `discover` を貼らない)。
- 依存を発見した場合は本文へ機械可読マーカー `Depends-on: #N` を書いてよい(台帳 `dependsOn` への変換は enqueue 側 = **#111 の所有**・本コマンドは GitHub にマーカーを書くまで)。

### 7. tick 報告 → DoD (iv) の確認

1 tick の結果を人間可読で 1 ブロック報告する: スキャンした 4 型と各型の件数(fail-soft skip を含む)/ 起票した issue 番号と型 / dedup で見送った候補 / 上限超過で破棄した件数。**台帳・ラベル・epic 配線への書込が 0 件であること(提案止まり)を明示的に確認して報告する**(DoD (iv))。

## 書込境界 / 禁止事項(doer ≠ judge をこの経路でも保つ)

- **自律で許すのは GitHub への issue 起票と提案コメントまで**。台帳(`.harness/plan-progress.json`)には**一切触れない**(Read も編集も。単一 writer は orchestrator)。epic 配線(sub-issue)・ラベル操作(`discover` 含む)・close・優先度変更は**提案止まり**(人間または人間の明示指示でのみ)。
- **fan-out するなら `general-purpose`**: 兆候スキャンや裏取りで subagent を fan-out する場面は `subagent_type: "general-purpose"` で起動する(`fork` は呼出元文脈を丸ごと継承し狭い directive を無視して最上位タスクを再実行する)。文脈は各 subagent へ自己完結する形で渡す。
- **`gh auth switch` を実行しない**(active アカウントを変えると他セッションの `gh` が壊れる)。GitHub 操作は `gh` CLI のみ。
- **観測していないことを書かない**: 「エラー」と「処理中」を区別する。裏取りできない兆候は「未確認」と報告し、起票しない。

## 参照

- `${CLAUDE_PLUGIN_ROOT}/roles/product-manager.md` — 本コマンドが実行する判定 spec(責務境界・兆候源 4 型・起票規約・裏取り基準)
- `${CLAUDE_PLUGIN_ROOT}/rules/issue-tree.md` — tree 3 層・prefix 語彙・ラベル 3 直交信号・帰属と逸脱・`roadmap.json` 契約
- `${CLAUDE_PLUGIN_ROOT}/rules/issue-authoring.md` — 起票の本文構成・prefix 選定・チェックリスト
- `commands/harness-orchestrate.md`「discover→enqueue フェーズ」 — PM が起票 → 人間が `discover` ラベル → orchestrate ループが台帳 enqueue、の下流配線
