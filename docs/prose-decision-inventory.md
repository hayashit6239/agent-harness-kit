# 散文依存の判断ロジック 棚卸し表(prose decision inventory)

> issue #87。orchestrator / roles の散文仕様のうち、**判断ロジック**(分岐を含む決定)を列挙・分類し、
> どこが tested decision script で machine-enforce され、どこが散文依存で検証不能なまま残っているかの
> **境界を文書化する**。#1 ADR の確立済み方針(「ルーティング・停止条件・blocker 再集計の判定は tested
> decision script が唯一の正で、prose に複製しない」)を残存領域へ適用する続行作業であり、新しい設計判断
> ではない。
>
> **この表は checked-in doc**(即 stale になる issue コメントではなく)。`docs/gate-detection-audit.md`
> の「注入対象プール」の上流ソースとして再利用される(同 doc 参照)。**更新閉ループは v1 では持たず
> best-effort**(新しい prose 判断点が分類漏れしていないかを machine-enforce する仕組みは無い —
> `reports[]` と同じく「書き忘れは痕跡を残さない受容コスト」。smoke 強制化は将来 Phase 2 / 事故再発時の
> 昇格候補)。行番号ではなく**節見出しでアンカーする**(対象ファイルの churn で行番号が即 stale になるため)。

## 分類の operational 判定規則(I/O 境界)

既存 decision script が確立した I/O 境界を、そのまま分類の判定規則として採用する(棚卸し人が変わっても
分類が揺れないよう明文化):

> **状況を outcome トークンへ解決するのは LLM(prose)/ 規則の適用は決定論 script**
> (`scripts/decide-orchestrator-route.py` docstring)。

この境界に照らし、各判断点を **最低 3 カテゴリ**へ分類する:

| カテゴリ | 定義 | 抽出可否 |
|---|---|---|
| **① script 化可能** | 決定論であり **pure**(入力 → 決定・台帳 state を読まずに引数で完結)。規則の適用が LLM 裁量を含まない。 | 抽出対象(本表の主眼) |
| **② 決定論だが v1 は意図的に prose 維持** | 機械規則だが、判定に**台帳 state / GitHub state を要する**ため pure・stdin 完結境界を壊す。または抽出が複数箇所横断で blast radius 過大。 | 境界コストで留保(follow-up / 別 issue) |
| **③ 原理的に LLM 裁量** | 状況→outcome の解決・自然文の意味解釈・非決定的なパラフレーズ等。pure decision script では原理的に塞げない。 | 抽出不能(**境界を文書化するのが成果**) |

補助表示: **✅ 抽出済み**(既に decision script が担う)/ **Ⓜ mechanical-prose**(jq 等で決定論だが python
decision script ではなく、smoke が同一 jq を再実行して固定する中間形)。

## 現状の抽出実績(この PR 適用後)

**決定論判定器 = python decision script 7 本**(本 PR で 1 本追加):

| script | 担う判断 | smoke |
|---|---|---|
| `decide-orchestrator-route.py` | (role, outcome) → (ledger_write, route, label_action) | [8] |
| `reaggregate-has-blocker.py` | findings[] → has_blocker(fail-closed) | [6] |
| `evaluate-stop-condition.py` | round/trend/counts → escalate | [7] |
| `reconcile-dispatch-marker.py` | marker → eligible/clear/wait/redispatch/sink | [9] |
| `detect-dispatch-collision.py` | [{id, files}] → {groups, safe}(Union-Find grouping) | [12] |
| `decide-statuses-post-action.py` | (count, exit) → (new_count, halt)(#54) | [9] |
| **`select-dispatch-representatives.py`** | **{groups, safe, kinds} → {dispatch, carry_over, injected_only}(代表選出・本 PR #87)** | **[12]** |

**shell gate 実行体 2 本**(`report-ledger-status.sh` / `run-orchestrator-evidence-gate.sh`)は「判断ロジックの
抽出物」ではなく gate 実行体であり本表の判定器勘定とは別(#82 が機能テスト拡充の対象)。

## 棚卸し表 A — `commands/harness-orchestrate.md`(orchestrator)

### ✅ 抽出済み(decision script が唯一の正・prose に複製しない)

| 判断点(節) | 規則の要旨 | script |
|---|---|---|
| ルーティング判定 | (role, outcome) → 台帳書込 / route(normal/skip/sink)/ label_action | `decide-orchestrator-route.py` |
| 失敗経路 sink トリガー | どの (role, outcome) が `route=sink` か(17 種 + git-status-guard 1 = 18) | `decide-orchestrator-route.py`(guard 除く) |
| tick 冒頭 reconciliation | marker → eligible/clear/wait/redispatch/sink(締切・リトライ上限) | `reconcile-dispatch-marker.py` |
| ファイル衝突検知(grouping 層) | [{id, files}] → {groups, safe}(連結成分) | `detect-dispatch-collision.py` |
| **ファイル衝突検知(代表選出層)** | **{groups, safe, kinds} → dispatch/carry_over/injected_only(本 PR)** | **`select-dispatch-representatives.py`** |
| Statuses post 失敗 global halt | counter 更新 + 3-strike halt 判定 | `decide-statuses-post-action.py` |

### ① script 化可能(pure・未抽出 / 本 PR で 1 本抽出)

| 判断点(節) | 規則の要旨 | 状態 |
|---|---|---|
| **代表選出述語(ファイル衝突検知)** | 占有者ゼロ group から step id 昇順で 1 件・占有者 group から 0 件・fail-closed 単独は常に持ち越し | **本 PR #87 で抽出**(`select-dispatch-representatives.py`)。事故 #55(デッドロック)直結・issue が挙げた「選別フィルタの script 化」候補 |
| reviewLock / issueReviewLock の役割解決 map(reconciliation) | `pr.status`/`issue.status` → reviewer/responder/issue-reviewer/issue-review-worker の lookup | **follow-up**。pure な lookup map だが小規模(4〜前後のエントリ)。抽出は低リスクだが 些末寄り |
| responder / worker の proposed_status 越権無効化 | 返り status が `ready for merge`/`ready for implementation` でも無視 | **実質 ✅**(`decide-orchestrator-route.py` の DECISION_TABLE が worker/responder の前進 outcome を `waiting for review` に限定し、越権 status を構造的に到達不能化。doer≠judge を script で担保)。prose は補助的な二重明記 |

### ② 決定論だが台帳 state 参照で v1 は prose 維持

| 判断点(節) | なぜ ② か |
|---|---|
| **git-status ガードの処理判断(単一書込)** | **事故 #37(台帳書込 4/4 作動)直結**。ただし判定に台帳スナップショット / `git status` state を要する(台帳 vs 他ファイル・自身の交互書込の勘案)。**唯一 decision script 外の sink 経路**として意図的に留保されている(「既知の制限」(c):「分岐が無い自明な guard→sink」)。**事故が示す改善(並行 writer の誤 sink 回避)は挙動変化 = fix であり behavior-preserving な #87 のスコープ外**(別 issue)。現状挙動の pure な slice は「2 bool の AND」で 些末。→ 抽出せず境界を文書化 |
| dispatchMarker 3-way ライフサイクル(削除/永続/永続+notified) | `marker_disposition` 相当の追加は **4 箇所横断**(DECISION_TABLE + smoke [8] 全件 + 適用手続き + reconciliation timeout 分岐)で 1 フィールドでは済まない(🟡2)。marker は transient state。→ 過大 blast radius で v1 スコープ外 |
| 選別(jq)status→eligibility フィルタ(5 ロール) | 台帳を読む。**Ⓜ**: python script ではないが smoke [9] が同一 jq を再実行し、marker/dependsOn/githubState/cross-phase ガードを固定(部分的に machine-enforce 済み) |
| dependsOn 終端解決(選別) | 台帳を読む。**Ⓜ**: smoke [9] + schema 整合規則(authoring-time)の 2 段安全網で部分検証 |
| 5 件 budget cap + cross-role 優先順 tie-break(配車テーブル) | 決定論の tie-break だが入力が「組み立て済み候補リスト」(runtime)。並列 dispatch は bash smoke では原理的に検証不能(DoD (ii-b))。kind を pre-resolve すれば ① 化余地あるが v1 は留保 |
| `notified` による reconciliation 早期スキップ | marker フィールドを読む state 依存 |
| reports[] 代筆の発火条件((role, outcome)→append) | 台帳を書く・**best-effort**(smoke 対象外・既知のギャップ) |

### ③ 原理的に LLM 裁量(pure script では塞げない・境界を文書化)

| 判断点(節) | なぜ ③ か |
|---|---|
| **sink の状況→outcome 解決** | **事故 #75(sink 誤断 7 回)直結**。「観測不能」を「失敗(timeout/invalid/evidence_fail)」と断定する解決は LLM 側(設計境界)。緩和 A1(観測必須)は**存在・型のみ検証で内容は spoof 可能・独立検証ではない**(owner 決定 (b))。**真の受け皿は #75 の独立検証主体(別セッション gate/監査)**であって pure script ではない。liveness 部分(「dispatch が死んだ」等)は既に `reconcile-dispatch-marker.py` に抽出済み。→ 境界を文書化し #75 へ委譲 |
| 主観的エスカレーション(escalate_to_human)| 「人間の判断が必要」の主観判断(3 role 共通)。reason の形式検証は L1 防護線で machine-checked ではない |
| 自由文モードの停止条件パラフレーズ(`/goal` 組み立て) | 非決定的な自然文言い換え(構造化モードは #89 で凍結し drift を除去済み。自由文は後方互換) |
| 委譲先返り値(has_blocker / escalate)の真偽 | reviewer 自身の自己申告で orchestrator 側の独立裏取り手段が無い(捏造 reviewer が clean_pass を返せば ready for merge まで進む・既知の限界) |
| ファイル衝突の対象ファイル抽出規則(backtick パス収集) | issue 本文 Implementation Scope の自然文パース。fail-closed(`files: []`)で実害を保守側へ倒すのみ(既知のギャップ) |

## 棚卸し表 B — `roles/*.md`(委譲先ロール spec)

対象は**その時点の全ロール spec + dispatch**(🟡5・動的定義)。現状: `pr-reviewer.md` / `pr-reviewer-dispatch.md`
/ `issue-reviewer.md`(#93 で kit 同梱)/ `issue-reviewer-dispatch.md` / `issue-review-worker.md` /
`developer-implementer.md` / `developer-responder.md`。

### ✅ 抽出済み / 構造担保

| 判断点 | script |
|---|---|
| PR reviewer の has_blocker 再集計 | `reaggregate-has-blocker.py`(severity emoji 包含 + source 既知集合の完全一致・fail-closed) |
| 停止条件 escalate(PR / issue 両相) | `evaluate-stop-condition.py`(issue 相は無改修で流用) |
| 各ロールの outcome→status 書込 | `decide-orchestrator-route.py`(reviewer / issue-reviewer / worker / responder) |
| worker≠`ready for implementation` / responder≠`ready for merge` の越権禁止 | `decide-orchestrator-route.py` の DECISION_TABLE が前進 outcome を限定し**構造で担保**(prose は補助明記) |

### ③ 原理的に LLM 裁量(ロール判断の中核)

| 判断点(ロール) | なぜ ③ か |
|---|---|
| finding severity 🔴/🟡/🟢 付与(pr reviewer) | summary + failure_scenario の**意味判断**(キーワード表に依らない)。has_blocker script の入力を作る最も load-bearing な prose 判断だが、意味判断自体は LLM |
| CONFIRMED/PLAUSIBLE/REFUTED 検証(pr reviewer) | diff 上に finding が実在するかの意味確認(集計前の gate)。fail-closed で PLAUSIBLE は残す |
| 固定値 DoD の識別 + 書き換え有無 + 根拠妥当性(pr reviewer / implementer / responder / worker) | いずれも自然文解釈を要するため **decision script 化していない**(明示)。実装役の compliance は prose・独立検証は別セッションの reviewer が担う |
| issue reviewer の判定(8 観点 / 3 ファミリー rubric) | #93 で kit 同梱 spec `roles/issue-reviewer.md`(既定 `ISSUE_REVIEW_MODE=spec`)へ可搬化済みだが、rubric の適用自体は LLM 裁量(③)。個人 skill `reviewing-github-issues` は opt-in へ後退 |
| per-finding 採用/却下/保留 分類(responder / worker) | 最新レビューの各 finding の採否判断(自然文)。台帳 status には写らず本文編集を駆動 |
| 主観的エスカレーション(全ロール) | 主観判断 |

### Ⓜ mechanical-prose(jq / grep / count・部分的に machine-enforce)

| 判断点 | 備考 |
|---|---|
| 選別フィルタ(各ロールの status/lock/githubState jq) | smoke [9] が同一 jq を再実行して固定(marker/dependsOn/cross-phase ガード) |
| round = 過去コメント数 + 1 / prev-marker grep(most-recent-first, max 2) | GitHub コメントを読む I/O。stop-condition script の入力を作る(誤ると script が fail-open) |
| issue reviewer の blocker_count = 🔴 の件数 | PR 側の reaggregate 相当の再集計 script は使わない(🔴 件数がそのまま)。issue 相は evidence gate 相当が無い非対称(#88 正直な限界) |

## 事故集中領域の境界画定(#87 の中核成果)

issue が根拠に挙げた 2 事故クラスタを判定規則の所在で切ると、**両者とも pure category ① の抽出余地は既に
尽きている**ことが棚卸しで判明した — これ自体が検証不能領域の境界画定である:

- **台帳書込 4/4(#37 系)= git-status ガード**: 唯一 decision script 外の sink 経路。だが判定に台帳
  スナップショット state を要し(**②**)、事故が示す改善(並行 writer の誤 sink 回避)は **behavior-preserving
  な #87 のスコープ外の fix**。現状挙動の pure slice は 些末(2 bool の AND)。真因(F案がローカル台帳の
  並行書込を無音で許す)は decision script では直せない設計特性。→ **抽出せず ② として境界を明記**。
- **sink 誤断 7 回(#75)= sink の状況→outcome 解決**: 原理的に LLM 裁量(**③**)。A1 は spoof 可能で
  独立検証ではない。liveness 部分は既に `reconcile-dispatch-marker.py` に抽出済み。真の受け皿は #75 の
  独立検証主体(別セッション)。→ **抽出せず ③ として境界を明記・#75 へ委譲**。
- **#55 デッドロック = 代表選出述語**: 検証不能領域(smoke は grouping 層までしか届かなかった)で起きた
  **実事故**であり、規則は **pure category ①**(kind を prose が解決すれば規則適用は決定論)。
  `harness-orchestrate.md`「既知の制限」節が「将来 #87 の decision script 抽出パターンが定まれば script
  抽出候補とする」と**予告していた領域**そのもの。→ **本 PR #87 で抽出**(`select-dispatch-representatives.py`)。

**結論**: 事故集中領域直結で pure ① 抽出が成立するのは **代表選出(#55)ただ 1 点**。#37 は ②(behavior-change
の fix / 台帳 state 依存)、#75 は ③(LLM 裁量 / 独立検証主体待ち)であり、pure decision script では塞げない
—この**非対称の明記**が #87 本来の「検証不能領域の境界画定」の成果である。

## この PR の抽出(代表選出)

- **新規**: `scripts/select-dispatch-representatives.py`(`detect-dispatch-collision.py` の下流・pure decision
  script)。入力 `{groups, safe, candidates(id→kind)}` → 出力 `{dispatch, carry_over, injected_only}`。
- **kind の解決は prose 側に残る seam**(🟡4): 占有者判定は台帳 state を要するため抽出しない。抽出は
  **代表選出規則の回帰検知を効かせる**が「seam が消える」わけではない(検証可能領域は単調増加しない)。
- **smoke [12]** に全分岐 + **負の自己検証**(占有者 presence が load-bearing / tie-break が入力順非依存 /
  fail-closed 配置が load-bearing)+ kind 網羅ガード + 不正入力 exit 2 を追加。
- **挙動不変は operational**(#37 前例): 抽出元 prose に baseline test が無く機械的 before/after 等価検証は
  原理的に不成立。smoke ケースが prose「代表選出述語」の規則を符号化し、人間が prose↔script の一致を
  目視確認する(**機械的な等価性検証は不可能という限界を正直に受容**)。

## 参照

- #1(ADR「tested decision script が唯一の正」)/ #37(台帳ガード・等価性オラクルの operational 定義前例)
  / #50(sink 観測必須 A1・spoof 可能の正直な明記)/ #54(statusesPostFailCount 抽出)/ #55(代表選出・
  本 PR の抽出元)/ #75(sink 誤断 7 回・独立検証主体)/ #82(gate 実行体の機能テスト)/ #88(issue 相の
  対称配線)/ #90(`docs/gate-detection-audit.md` — 本表を注入対象プールに再利用)/ #93(issue reviewer
  可搬化)/ #21(Phase 2 — 検出力が唯一の防衛線)。
- 分類の単一の正: `scripts/decide-orchestrator-route.py` docstring の I/O 境界。
