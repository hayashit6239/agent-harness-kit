# contracts/ — エージェント間・ファイルの形式規定

harness の各エージェント(orchestrator / developer / pr reviewer / collector の finder 等)が
やり取りするデータの形と、ユーザーが書くカスタマイズファイルの形を、ここに集約する。
散文(手順書 = `roles/*.md`・`commands/*.md`・`collectors/strategy.md`)に形式を散らさず、**ここを単一の正**とする。

## 収録物

| ファイル | 規定するもの | 使う主体 |
|---|---|---|
| `findings.schema.json` | collector の finder が出す候補配列 `{file,line,summary,failure_scenario}` | finder(出力) / pr reviewer(入力・検証) |
| `collector-angle.schema.json` | `collectors/angles/*.md`(kit デフォルト)・`.harness/collectors/angles/*.md`(導入先追加。issue #65)の frontmatter | collector 機構(`collectors/strategy.md`。読取) / 観点を書くユーザー |
| `collector-angle.template.md` | 上記 angle を新規作成するときの雛形 | 観点を追加するユーザー |
| `reviewer-return.schema.json` | pr reviewer が orchestrator へ返す判定結果 `{has_blocker,blocker_count,escalate,review_markdown,escalate_to_human?}`(issue #66・round2) | pr reviewer(出力) / orchestrator(入力・検証) |
| `orchestrator-route.schema.json` | `scripts/decide-orchestrator-route.py` の入出力(実行時 IPC)。入力 `{role,outcome,observation?}` / 出力 `{ledger_write,route,label_action}`(issue #68。`definitions.input` / `definitions.output`) | orchestrator(入力) / decide-orchestrator-route.py(出力) |

**別ファイルに置く契約(意図的・issue #68 で解消)**: `dispatchMarker` / `reviewLock`(in-flight マーカー)と `reports[]`(作業レポート)は、実行時 IPC ではなく**台帳(`.harness/plan-progress.json`)の step に永続する構造**なので、`contracts/` ではなく `.harness/plan-progress.schema.json` に定義する(`definitions.dispatchMarker` / `definitions.reviewLock` / `definitions.report`)。判断基準は下記「置き場の判断基準」節を参照(PR #66 時点では「follow-up」だったが、本 issue #68 で置き場を確定して解消済み)。

## 置き場の判断基準(`contracts/` か `plan-progress.schema.json` か・issue #68 C 案)

エージェント間契約のスキーマを新設するとき、置き場は契約の**性質**で決める(将来また同じ議論を繰り返さないための明文化):

- **実行時にのみ流れ、tick を跨いで台帳に永続しない値**(呼出のたびに使われて捨てられる純粋 IPC)→ **`contracts/`**。
  例: `orchestrator-route.schema.json`(decide-orchestrator-route.py の入出力)、`reviewer-return.schema.json`、`findings.schema.json`。
- **台帳(`.harness/plan-progress.json`)の step オブジェクトに書き込まれ、tick を跨いで永続する値** → **`.harness/plan-progress.schema.json`**。
  例: `reports[]`(作業レポート)、`dispatchMarker` / `reviewLock`(in-flight マーカー)。
  - マーカーは issue #26 決定により validator/drift/smoke の**検査対象外**に留める。schema には optional(`step.required` 非追加・`step` の `additionalProperties` 不変)で宣言し、型/形のみを規定する(検査挙動は不変)。手続き(tick 計測・有界リトライ等)の正は `commands/harness-orchestrate.md` 側。

## 方針

- **機械検証の正はここ**。手順書側はここを参照し、形式を二重定義しない。
- `.schema.json` = 機械検証用(JSON Schema)。`.template.md` = 人が copy して埋める雛形。
- 新しいエージェント間契約(例: orchestrator の in-flight マーカー形式)を規定したくなったら、
  まずここに `<name>.schema.json` を足す。
- **doer≠judge を形式で守る**: 収集フェーズが出すもの(`findings.schema.json`)には
  severity・合否を持たせない。判定は pr reviewer が付ける。angle(`collector-angle.schema.json`)も
  収集専任(パターン A)に限定し、判定を伴う skill を受け付けない。

## 検証の強制(現状 = 未強制・follow-up)

現時点でこれらのスキーマは「参照する正」であって、CI や validator による強制はまだ無い。
どのレイヤで強制するか(L3 hook / L4 CI / `validate-plan-progress.py` 相当の追加 validator)は
`harness-engineering` の制約レイヤ判断として別途詰める。
