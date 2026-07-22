# issue tree 規約 — 3 層構造・prefix 語彙・ラベル意味論・帰属と逸脱

導入先 repo に依らない **issue の構造規約 (文法)**。tree 3 層構造・prefix 語彙 13 種・ラベルの 3 直交信号・sub-issue 配線・帰属規則をここで定義する。role 横断規約のため `rules/` に置き (`rules/escalate-to-human.md` と同じ置き場・`${CLAUDE_PLUGIN_ROOT}/rules/` 経由で配布)、次の 4 者が共通参照する:

- **product manager ロール (棚卸し・依存整理・逸脱の発見)**
- **orchestrator の discover→enqueue フェーズ** (epic を実装 step として enqueue しない fail-safe が層意味論を参照する)
- **issue reviewer** (issue の構造判定)
- **人間** (起票・棚卸し)

起票の書式 (Problem/Context/Alternatives の本文構成・prefix 判断フロー・起票前チェックリスト) は別ファイル `rules/issue-authoring.md` にある。本ファイルは prefix 語彙の**唯一の正**であり、`issue-authoring.md` はここを参照する (重複定義を避ける)。

この規約の改定は**人間の判断**による。ロール (PM 等) は改定を提案できるが自律で書き換えない。

---

## 1. tree の 3 層構造

本 repo の issue は「rfc → epic → 実装 issue」の 3 層 tree で運用する。

| 層 | 役割 | 例 |
|---|---|---|
| **最上位 (rfc)** | ロードマップ正本。tree の根。単一インスタンス | ロードマップ ADR (#1) |
| **中間構造層 (epic)** | Phase epic・複数 issue の束ね | Phase 3 epic (#106) |
| **最下層 (実装 / 決定 issue)** | PR を生む実装単位・決定を生む議論 | feat / fix / discuss の各 issue |

親子は **GitHub の sub-issue** で結線し、本文に `Part of #<epic>` を併記する (下記 §4)。

---

## 2. prefix 語彙 13 種 → 3 層の全射割当

タイトル先頭の Conventional Commits ベース prefix (13 種) は、3 層のいずれか 1 つへ全射で割り当たる。これが prefix 語彙の唯一の正である (`issue-authoring.md` はこの表を参照する)。

| 層 | prefix | 役割 |
|---|---|---|
| **最上位 (rfc)** | `rfc` | ロードマップ正本 (#1)。tree の根。単一インスタンス。epic 帰属を持たない (根そのもの) |
| **中間構造層 (epic)** | `epic` | Phase epic・複数 issue の束ね。`epic` ラベル + 自身の phase ラベルを持つ。**別の epic の sub-issue にはならない** (層違反) |
| **最下層 — 実装 issue (10 種)** | `feat` / `fix` / `docs` / `refactor` / `perf` / `test` / `build` / `ci` / `chore` / `revert` | PR を生む実装単位。epic 帰属 (phase ラベル) を持つことも orphan のこともある (§3) |
| **最下層 — 決定 issue (1 種)** | `discuss` | 決定 / ADR を生む issue (成果物は PR 必須でない)。epic に帰属してもよいし orphan でもよい |

合計 = 1 (rfc) + 1 (epic) + 10 (実装) + 1 (discuss) = **13 全種**。`rfc` / `epic` が構造層・残り 11 が最下層。

- 導入先で prefix 語彙・層数・ラベル語彙を差し替え可能にするプラガブル機構は **v1 では作り込まない** (固定の文法 + repo 側インスタンスデータ (§5) の最小分離で始める)。

---

## 3. 帰属 (epic membership) と逸脱 (迷子) の定義

### 3.1 「phase ラベルの不在」だけで迷子と判定してはならない

最下層 issue の**多く**は phase ラベル無し (orphan) で正規に運用される (単発保守・epic 非スコープの作業)。したがって **「phase ラベルが無い」だけで「帰属漏れ / 迷子」と判定してはならない** — リポジトリの大半を誤検知する。

### 3.2 帰属が必須になる条件 = ある issue が epic スコープ内であると主張したとき

主張シグナルは 3 つ:

1. **phase ラベル**を持つ
2. 本文に **`Part of #<epic>`** を書く
3. **GitHub sub-issue** として epic に配線されている

**この 3 シグナルが相互に整合していることが必須**。

### 3.3 逸脱 (迷子・帰属漏れ) = 3 シグナル間の不整合 (機械判定可能)

PM が機械執行する対象は「不在」ではなく「不整合」。4 パターン:

1. **帰属漏れ (配線忘れ)**: phase ラベルはあるが sub-issue 配線が無い
2. **phase 不一致**: `Part of #<epic>` はあるが phase ラベル無し / epic の phase (逆引き §4.3) と食い違う
3. **stale 帰属**: phase ラベルの epic (§5 の `roadmap.json` で解決) が close 済みなのに issue が open
4. **層違反**: `epic` ラベルの issue が別の epic の sub-issue になっている

### 3.4 orphan は逸脱ではない

どの帰属シグナルも持たない最下層 issue (orphan) は逸脱ではない。PM は orphan を「棚卸し情報」として surface してよいが、**逸脱として扱わない**。

---

## 4. 3 直交信号の取得契約

逸脱判定 (§3.3) が依拠する 3 信号を、信号ごとに取得経路を確定する。**下流 (PM / issue reviewer) は各信号を必ずこの経路で読む** — 取得契約が無いと再発明・誤検知を招く。

### 4.1 sub-issue 配線信号の取得 = `gh api graphql`

`repository.issue(number:<N>).parent { number }` (親 epic) と `issue.subIssues { nodes { number } }` (子) で読む:

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$n:Int!){
    repository(owner:$owner,name:$repo){
      issue(number:$n){
        parent { number }
        subIssues(first:50){ nodes { number } }
      }
    }
  }' -F owner=<owner> -F repo=<repo> -F n=<N>
```

> **⚠ 警告: 標準の `gh issue view <N> --json ...` には `parent` / `subIssues` フィールドが存在しない** (`--json parent` は `Unknown JSON field: "parent"` で失敗する)。`--json` を叩いて「配線無し」と誤検知しないこと。sub-issue 配線は **GraphQL 経路でしか読めない**。

### 4.2 `Part of #<N>` のパース規約 (prose 版・第 2 信号)

本文中の**リテラル `Part of #<N>`** (先頭大文字 `Part of ` + `#` + 連続数字) を親 epic 番号として取る。数字以外 (句読点・空白・全角句点「。」等) で停止する。**表記ゆれは許容しない** (deterministic parse 優先)。`Part of #<N>` は GitHub native の sub-issue 配線 (§4.1) とは**独立した第 2 信号**であり、両者が一致することが 3 信号整合の一部。起票側は `issue-authoring.md` でこの唯一形を必須化する。

**走査範囲 (偶発的言及の除外)**: 本文全体を走査するが、**コードフェンス (` ``` ` で囲まれた範囲) と引用 (行頭 `>`) の内側は除外する**。規約説明・別 issue の引用・例示で書かれた `Part of #<N>` は権威ある帰属宣言ではないため拾わない (これを除外しないと、規約や他 issue を引用しただけの issue が偽の帰属先を持ち、複数 epic 検出で偽の逸脱を発火させる)。除外後に残った distinct な epic 番号を帰属主張とする。**複数の distinct な `Part of #<N>` が異なる epic を指す場合は不整合 = 逸脱として surface** する。

### 4.3 phase→epic 前方 lookup と epic→phase 逆引き

いずれも §5 の `roadmap.json` を読み取り専用で引く:

- **phase→epic (前方)**: issue の phase ラベル名を `phases[].phase` に一致させ、その `phases[].epic` を epic 番号として得る (逸脱パターン 3 の stale 判定に使う)。`epic` が `null` の場合は「epic 未解決」として当該 phase の帰属整合検査を**スキップして 1 行 surface** する (fail-soft・§5.3)。
- **epic→phase (逆引き)**: `Part of #<epic>` (§4.2) の epic 番号から phase を引くには、`phases[]` を `epic` 値で逆走査し一致要素の `phase` を得る (逸脱パターン 2 の phase 不一致判定に使う)。epic 番号が表に不在 → 解決不能 → fail-soft surface。同一 epic に複数 phase が対応する (通常起きない) 場合は ambiguous として surface (crash しない)。`epic: null` エントリは実数 epic の逆走査に一致しないため ambiguous を生まない。

---

## 5. ラベルの 3 直交信号 (完全列挙)

kit が意味を与えるラベルは 3 つの直交信号に分かれる。**3 集合は互いに素** (1 ラベルは高々 1 信号に属す) で、これが「直交」の中身。

| 信号 | ラベル集合 | 付与主体 | 備考 |
|---|---|---|---|
| **帰属 (membership)** | `phase<X>` (`roadmap.json` の `phases[].phase` から列挙。`epic: null` エントリも含む) + `epic` (issue 自身が epic である印) | 人間 | 帰属先の宣言 |
| **着手指示 (start directive)** | `discover` (単一ラベル・**最下層 issue のみ**・人間が付ける opt-in 入力ラベル・`/harness-init` が provisioning) | 人間 | discover→enqueue フェーズ (`commands/harness-orchestrate.md`) が拾う |
| **状態 (state)** | `ready for implementation` / `ready for merge` / `need for human review` | orchestrator | 台帳 status の GitHub 側写し |

**kit の意味論の外 (out-of-band)**: GitHub テンプレート既定ラベル (`bug` / `documentation` / `duplicate` / `enhancement` / `good first issue` / `help wanted` / `invalid` / `question` / `wontfix`) は kit の 3 信号に属さない。3 信号の完全性は「kit が意味を与えるラベル」に限った主張であり、GitHub 既定ラベルは対象外。

---

## 6. インスタンスデータ = `.harness/roadmap.json` (phase → epic 対応表)

`phase3 → #106` のような対応は導入先ごとに違うため kit にハードコードしない。導入先 repo の `.harness/roadmap.json` (JSON) が **phase → epic の唯一の正 (canonical source)**。

### 6.1 ファイルパスと形式

`.harness/roadmap.json`。roadmap 順序を保つ配列:

```json
{
  "phases": [
    {"phase": "phase3", "epic": 106,  "title": "Phase 3 仕事の自動発見"},
    {"phase": "phaseB", "epic": null, "title": "PhaseB メンテナンス統括"}
  ]
}
```

- `phase` = GitHub の phase ラベル名と一致する文字列 (帰属シグナルとの結線)。
- `epic` = epic issue 番号。**型は `number | null`** — epic issue 未割当の phase (phaseA / phaseB のような、実在・使用中だが epic 番号を持たない帰属ラベル) は `null`。
- `title` = 人間可読名。
- **`phases[]` は全 phase ラベルの唯一の列挙元** (`epic: null` エントリも含む)。「phase→epic 番号の宣言表」と「全 phase ラベルの列挙元」の二役を `epic: null` 許容で両立させる。

### 6.2 canonical source の根拠 (なぜラベル記述文を使わないか)

phase ラベルの GitHub 記述文は機械ソースとして不完全である (実測: 記述に epic 番号を含むものがある一方、`phaseA` は記述が空・`phaseB` は記述に epic 番号が無い)。したがってラベル記述文の解析・タイトル照合は脆く、**明示的な対応表ファイルだけが「完全・機械解析可能・versionable」を満たす**。phase → epic の解決には `roadmap.json` のみを使い、ラベルの GitHub 記述文は使わない。

### 6.3 書込主体・空 / 欠損 / stale / 型不正時の縮退 (すべて fail-soft)

- **書込主体**: このファイルはインスタンス設定であり、**ロールは書かない** (人間 / `/harness-init` が編集する)。消費者は**読み取り専用**で開く。
- **縮退はすべて fail-soft** (discover 節の「クエリ失敗は no-op で続行・1 行 surface」と同型)。消費者は沈黙して壊れず 1 行 surface する (crash しない):
  - **ファイル欠損 or `phases: []` (空)**: 「phase → epic を解決できない」状態。kit 新規導入直後の空表がこの経路。
  - **stale (epic 番号が close 済み / 削除 / 改番)**: 対応表は「宣言された意図」として使い、宣言どおり解決する。epic が close 済みなのに phase に open sub-issue が残る状態は PM が逸脱候補として surface する。「epic issue が実在するか」の GitHub 側照合は対応表ファイルの契約外。
  - **新規 phase に epic 未割当 (`epic: null`)**: 当該 phase の帰属整合検査をスキップして 1 行 surface (§4.3)。
  - **JSON パースエラー / 型不正 (`epic` が文字列 `"106"` 等) / キー欠落 (`phase` or `epic` が無い)**: いずれも「解決不能 → fail-soft surface (1 行)」に畳む。crash しない。
    - **正直な明記 (受容コスト・#93 流儀)**: `roadmap.json` には schema / validator を持たせない (v1 は作り込まない)。したがって型不正・キー欠落・パースエラーは**機械検知されず best-effort** で、消費者が読み取り時に解決不能として surface するだけである。同格のインスタンスデータ `plan-progress.json` が `validate-plan-progress.py` + schema で型・整合を検査する (強制層あり) のに対し、`roadmap.json` は強制層を持たない**非対称**を正直に受容する。将来「型不正を検知したい」必要が観測されたら validator 導入を follow-up として検討する。
- **受容コスト (drift)**: 対応表 (`roadmap.json`) と GitHub の phase ラベル / epic issue 実態の drift は**機械検知の外**であり **best-effort の手動同期**。これは #93 (kit 版 spec ⇔ 個人 skill の drift 手動同期) と同型の受容コスト。将来オーナーが「ラベル記述を正して記述文を正にしたい」と判断するなら本決定は覆せる。
