# ゲート検出力の定期抜き打ち検査 — 手順書

> issue #90。smoke(`tests/smoke/run-smoke.sh`)が「ゲートの機構が仕様どおり動くか」を常時検査するのに対し、
> 本手順は「**ゲートの検出力が腐っていないか**」を定期的に抜き打ちで実測する。実施記録は
> [`gate-detection-audit-log.md`](./gate-detection-audit-log.md) に追記する(記録先固定)。

## この検査が防ぐもの — 「ゲートの腐り」の 2 つの様態

Phase 2(有人自律運転 = `ready for merge` まで人間の中間介入ゼロ)では、ゲート(smoke の assert 群)の
検出力が唯一の防衛線になる。検出力の腐敗が静かに進むと「smoke は緑のまま壊れている」状態になる。
腐り方を次の 2 つに分けて扱う。

- **Mode 1(assert の形骸化 / vacuity)**: 何も縛っていない(常に通る)assert は緑のまま検出力を失う。
  ただし「smoke 自身では原理的に検知できない」のは **負の自己検証を持たない assert に限る**。smoke は
  最重要の構造 assert に対し、既に **負の自己検証**(下記)を埋めており、それらは形骸化すれば負ケースが
  緑になって smoke 自身が落ちる = **閉ループで捕捉済み**。したがって本検査で狙うのは **負の自己検証を
  まだ同伴していない assert**。Mode 1 の恒久対策は「D. 負の自己検証規約の一般化」(下記)であり、
  抜き打ちは規約が行き渡るまでの穴を人手で拾う補完。
- **Mode 2(意味的な取り零し / semantic gap)**: merged PR の想定失敗様態が、smoke のどの assert にも
  対応していない場合、その欠陥類型はゲートを永久に素通りする。self-check する対象 assert がそもそも
  無いため負の自己検証では届かず、**merged-PR 照合が本当に要る唯一の領域**。抜き打ち儀式(A 案)の
  主眼はここ。

### スコープ外(暗黙の未対応にしないための明示)

- **第 3 の防御 = 件数ガード(行数ガード)**: assert の削除・書き忘れの検知は既存 smoke が常時担うため、
  抜き打ちの対象外(下表の「件数ガード」を参照)。
- **assert drift**(リファクタで非 vacuous のまま別物を検査するようになる)/ **fixture rot**(fixture が
  現実入力を代表しなくなる)は本検査のスコープ外。必要になれば別 issue で扱う。
- **mutation testing の自動化**(B 案)はスコープ外。抜き打ちで検出力の穴が **累計 3 件** 観測されたら
  昇格を検討する(下記「A→B 昇格閾値」)。

## smoke に既にある自己検証の分類(重要 — 混同すると「どれが穴か」がぶれる)

抜き打ちの選定規則は「負の自己検証を **持たない** assert を優先して狙う」。そのため、既存 smoke の
どれが負の自己検証を持ち、どれが持たないのかの線引きが検査の前提になる。**2 つのカテゴリを混同しない。**

| カテゴリ | 何をするか | Mode 1 を閉ループで捕まえるか | 現物の例 |
|---|---|---|---|
| **負の自己検証(mutation 型)** | assert が読む正準物 / fixture を **1 本抜いた/壊したコピー**を作り、そのコピーで assert が **fail することを assert** する | **する**(形骸化すれば負ケースが緑になり smoke が落ちる) | セク13 L1449-1455(canonical 行を 1 本抜いたコピーが presence 検査で fail)/ セク14a L1516-1525(凍結トークンを 1 本抜いたコピーが集合不一致で fail) |
| **件数ガード(行数ガード・count cross-check)** | 2 つの数(assert ケース数 と 定義エントリ数 等)の **一致を検査**する。assert の追加・削除・書き忘れを機械検知する第 3 の防御 | **しない**(個々の assert が「実際に欠陥を捕まえるか」は測らない — 数が合うかだけ) | セク8 L789(`ROUTE_CASES == TABLE_ENTRIES`)/ セク8 L859(`LABEL_TOKEN_COUNT == 4`)/ セク14a L1505(`EXPECTED_COUNT == 18`) |

- **負の自己検証(mutation 型)の canonical 例はセク13 / セク14a に一本化する。** セク8 の件数ガードは
  mutation 型ではない(コピーを作って fail を assert する形ではなく、数の一致検査)。件数ガードは
  「第 3 の防御 = 行数ガード」に一本化して数え、負の自己検証とは別カテゴリとして扱う。
- 帰結として、**decision script の判定表 assert(セク6/7/8/9/12 の positive assert 群)は、大半が
  per-assert の負の自己検証を持たない**(表全体の件数ガードはあるが、個々の assert が SUT の
  リアルな欠陥を捕まえるかは未検証)。ここが本抜き打ちの主対象。

## A 案:手動の定期抜き打ち — 実施手順

各回、次の 2 本立てを実施する。所要は初回実測で数分程度(下記「頻度」)。

### ① 欠陥注入(injection)— Mode 1 の穴 + 検出力の実測

1. **注入対象を選ぶ**(下記「注入対象プール」+「選定規則」)。
2. 選んだ decision script / 実行体に **意図的な欠陥を 1 つ注入する**(下記「欠陥の最小類型表」から選ぶ)。
   自明に捕まる欠陥ではなく「形骸化していそうな assert を狙う」欠陥にする。
3. `bash tests/smoke/run-smoke.sh` を実行する。
   - **smoke が落ちた(non-zero)= 陽性対照 通過**。どの assert が落としたかを記録する。
   - **smoke が緑のまま = 検出力の穴**。その欠陥類型を捕まえる assert が無い or 形骸化している。
     → **修正 issue を起票**し、記録に穴として残す。
4. **注入を revert する**(`git checkout -- <file>`)。注入は一時的で **commit しない**(#90 は
   run-smoke.sh / decision script へコミットを残さない — 注入は実施後に必ず戻す)。
5. 結果を [`gate-detection-audit-log.md`](./gate-detection-audit-log.md) に追記する。

### ② merged-PR 照合(reconciliation)— Mode 2 の取り零し

1. 直近の merged PR から **1 件抽出する**。
2. その変更の **想定失敗様態**(この PR が防ごうとしたバグ / 退行)を言語化する。
3. その失敗様態に対応する assert が smoke に **存在するか** を照合する。
   - **対応 assert あり** = 取り零しなし。どの assert かを記録する。
   - **対応 assert なし** = Mode 2 の取り零し。→ **修正 issue を起票**し、記録に穴として残す。
4. 結果を記録に追記する。

## 注入対象プール(injection target pool)

`scripts/` の pure decision script 5 本 + shell 実行体 2 本。

| 種別 | ファイル | smoke の検査セクション |
|---|---|---|
| decision script | `scripts/decide-orchestrator-route.py` | セク8 |
| decision script | `scripts/detect-dispatch-collision.py` | セク12 |
| decision script | `scripts/evaluate-stop-condition.py` | セク7 |
| decision script | `scripts/reaggregate-has-blocker.py` | セク6 |
| decision script | `scripts/reconcile-dispatch-marker.py` | セク9 |
| shell 実行体 | `scripts/report-ledger-status.sh` | セク11(#82 で機能テスト拡充予定) |
| shell 実行体 | `scripts/run-orchestrator-evidence-gate.sh` | セク11(#82 で機能テスト拡充予定) |

## 選定規則(selection rule)

優先順に:

1. **負の自己検証を持たない assert を検査する script を優先**(上記「分類」参照 — decision script の
   判定表 assert 群が該当)。形骸化のリスクが最も高い。
2. **直近変更された script を優先**(退行が入りやすい)。
3. **巡回**(前回と別の script を選ぶ — 記録の「今回の対象」を見て一巡させる)。

## 欠陥の最小類型表(defect type table)

「形骸化していそうな assert を狙う」代表的な欠陥。自明に捕まる欠陥は避ける。

| 類型 | 例 | 狙う退行 |
|---|---|---|
| 比較演算子の反転 | `== → !=` / `< → >` / `> 0 → >= 0` | 判定境界の反転 |
| 分岐の削除 | 条件枝を 1 本落とす | fail-closed / fail-open 分岐の消失 |
| 定数 return | 判定関数が常に同じ値を返す | assert が「常に緑」の値だけを見ている形骸化を暴く |
| 境界のオフバイワン | `>= → >` | 締切・上限の 1 ずれ |
| enum メンバの取り違え | role / outcome の値をずらす | 決定表のマッピング退行 |

## トリガー(今日存在するもの)

書かれた予定は「実行を強制するトリガー」ではないため、今日存在する定期作業に相乗りさせる。

- **① 欠陥注入 = 月初の最初の `/goal`(orchestrator tick)稼働に相乗り**。その月の最初に harness を
  回すとき、本手順 ① を 1 回実施する。
- **② merged-PR 照合 = smoke に assert を足す / 変える PR を merge する時**。その新規 assert に負の
  自己検証があるか / 想定失敗様態に対応する assert があるかを、merge の場で点検する。
- **将来強化(#83 landing 後)**: #83(merge ゲート差し戻し指標)が入れば、差し戻し頻度を実施
  トリガーにできる(検出力が落ちている兆候での抜き打ち)。#83 は現時点 OPEN 未実装のため、今日の
  トリガーは上記 2 つが正。閉ループ化(`docs/` の last-audit-date を読み 1ヶ月超で orchestrator tick が
  促す)も将来の选项。

## A→B 昇格閾値(数で固定)

- 抜き打ちで **検出力の穴が累計 3 件** 観測されたら、B(mutation testing の自動化)への昇格を検討する
  (harness の「同じすり抜けが 3 回」規約に倣う)。累計は本手順の記録(穴として起票した issue の数)で
  数える。3 件未満なら手動抜き打ち(A)で足りるとみなす。

## D 案:負の自己検証規約の一般化(Mode 1 の恒久対策・明文化)

**規約(この節が単一の正)**: **smoke に新しい構造 assert を足すときは、その assert が読む正準物 /
fixture を「1 本抜いた/壊したコピー」を作り、そのコピーで assert が fail することを assert する
負ケースを、必ずセットで書く。**(既存パターン: セク13 / セク14a・issue #52 Phase B / #89 が踏んだ型。)

- **狙い**: Mode 1(形骸化)を smoke 自身が閉ループで捕捉する。手動抜き打ち(A)の「書き忘れうる」
  弱点が無い。負の自己検証を持つ assert は、形骸化すれば負ケースが緑になって smoke が落ちる。
- **最初の適用対象**: #82 / #87 / #93 が smoke に足す新規 assert(= 本手順の被監査対象と一致)。
  これらの PR を merge する時(上記トリガー ②)、新規 assert が負の自己検証を同伴し、mutation で
  実際に fail する陽性対照を確認する。
- **正直な限界(🟡-2)**: この規約の **採用自体は散文(L1)であり自動強制されない** —
  assert を足す人が負ケースを書き忘れても smoke は止まらない。これは本 issue が問題視する腐り方
  (書き忘れうる手動規律)と同じ class である。**「全構造 assert に対応する負の自己検証が存在する」
  ことを smoke が assert する meta-guard(規約採用そのものの機械強制)は本 issue のスコープ外**とし、
  規約の適用実績が溜まった段階で別 issue として検討する(過剰実装を避ける YAGNI 判断)。それまでは
  トリガー ② での人手点検が担う。

## 頻度と記録先

- **頻度: 月次**(初回実施の所要が数分程度と実測できたため。トリガー ① の「月初の `/goal` 相乗り」と
  整合)。ノイズが多ければ四半期へ緩める。
- **記録先: [`gate-detection-audit-log.md`](./gate-detection-audit-log.md)**(本 repo 限定の
  プロセスノート。issue 固定コメントより検索性・可搬性が高い)。kit 配布物(`templates/`)への昇格は
  #93 の可搬化路線 landing 後に判断する。

## 記録様式(record format)

各回、[`gate-detection-audit-log.md`](./gate-detection-audit-log.md) に次の様式で 1 節を追記する。

```
## <YYYY-MM-DD> 第 N 回

- 実施者 / トリガー: <実施した主体 / どのトリガーで発火したか>

### ① 欠陥注入
- 対象: <file>(選定理由: <選定規則のどれで選んだか>)
- 注入した欠陥: <類型> — <具体的な変更(行・前後)>
- smoke の結果: <落ちた assert のラベル / 緑のままだった>
- 判定: 陽性対照 通過 / 穴(→ issue #<N> 起票)
- revert: 済(commit していない)

### ② merged-PR 照合
- 対象 PR: #<N> <タイトル>
- 想定失敗様態: <この PR が防ごうとしたバグ / 退行>
- 対応 assert: <smoke のセクション・ラベル / 無し>
- 判定: 取り零しなし / 穴(→ issue #<N> 起票)

### 累計
- 検出力の穴 累計: <M> 件(3 件で B 昇格検討)
```

## 参考

- `tests/smoke/run-smoke.sh` — 被監査対象の smoke 本体。
- issue #90(本手順の設計 issue)/ #82(実行体の機能テスト)/ #87(散文 vs script 棚卸し表 →
  被監査対象リストへ再利用可)/ #93(kit 可搬化 → `templates/` 昇格判断の前提)/ #83(merge ゲート
  差し戻し指標 → 将来の実施トリガー候補)/ #21(Phase 2 — 介入ゼロ化で検出力が唯一の防衛線)。
