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

## 方針

- **機械検証の正はここ**。手順書側はここを参照し、形式を二重定義しない。
- `.schema.json` = 機械検証用(JSON Schema)。`.template.md` = 人が copy して埋める雛形。
- 新しいエージェント間契約(例: reviewer の返り値 `{has_blocker, escalate, ...}`・
  orchestrator の in-flight マーカー形式)を規定したくなったら、まずここに
  `<name>.schema.json` を足す。
- **doer≠judge を形式で守る**: 収集フェーズが出すもの(`findings.schema.json`)には
  severity・合否を持たせない。判定は pr reviewer が付ける。angle(`collector-angle.schema.json`)も
  収集専任(パターン A)に限定し、判定を伴う skill を受け付けない。

## 検証の強制(現状 = 未強制・follow-up)

現時点でこれらのスキーマは「参照する正」であって、CI や validator による強制はまだ無い。
どのレイヤで強制するか(L3 hook / L4 CI / `validate-plan-progress.py` 相当の追加 validator)は
`harness-engineering` の制約レイヤ判断として別途詰める。
