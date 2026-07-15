---
description: 対象 repo の .harness/plan-progress.json を単一の書込主体として、developer(実装役・対応役)と pr reviewer の 2 ロールを配車する orchestrator(v1 walking skeleton・PR ライフサイクルのみ)。判断ロジックは一切持たず、既存の判定 skill/command(`/code-review` または `reviewing-multi-angle` 経由の `commands/harness-review-pr.md`)に委譲し、返答を検証してから台帳へ書き込む。前進できない状況は原因を問わず単一の失敗経路(need for human review sink)に集約する。ルーティング(台帳書込・sink・ラベル操作)は各ロールが状況を outcome トークンに解決したうえで tested decision script(`scripts/decide-orchestrator-route.py`)で決定論的に解決し、規則を散文に複製しない。
argument-hint: "[owner/repo] [review-mode]  省略時: CWD の origin から自動判定 / code-review(opt-in: multi-angle)"
allowed-tools: [Bash, Agent, PushNotification, Skill, Read]
---

# /harness-orchestrate — developer / pr reviewer を配車する orchestrator(v1 walking skeleton)

これは **運用(policy)** の層であり、minimal 構成の上に乗る **orchestrator ロール**(Phase 1 の中核機構の最初の増分)。対象は **developer(実装役・対応役)と pr reviewer の 2 ロール、PR ライフサイクルのみ**(issue reviewer 側の自動化は対象外)。

## orchestrator の性質(判断を持たない調整層)

**本コマンドは判定ロジックを一切持たない。** レビュー当否・実装内容の良し悪しを判断するのは常に dispatch 先の subagent(pr reviewer / developer)であり、orchestrator はその**提案を検証し、台帳へ書き込むかどうかを機械的なゲート(evidence gate / git status ガード)でのみ判定する**。orchestrator が持つ責務は次の 5 つだけ:

1. 配車判断(下記の配車テーブルに従い、どの step にどのロールを dispatch するか決める)
2. dispatch 先 subagent への委譲(判定・実装ロジックは転写せず、参照すべき command/skill を読ませて実行させる)
3. 返答の検証(evidence gate・git status ガード)
4. 台帳への単一書込
5. 前進できない状況の集約(下記「失敗経路(単一の need for human review sink)」へルーティングする)

## 単一書込

**台帳(`.harness/plan-progress.json`)への書込は本コマンドだけが行う。** dispatch する subagent には台帳の書込ツールを渡さない:

- **実装手段**: `Agent` ツールで subagent を起動する際、渡すツールを `Read, Skill, Bash, Grep, Glob` に絞り、**`Write` を渡さない**(subagent が台帳ファイルを直接 Write できないようにする)。
- **限界を正直に明記する**: `Bash` を渡す以上(`gh` コマンド実行・`reaggregate-has-blocker.py` 実行に必要)、subagent が `Bash` 経由で `.harness/plan-progress.json` を編集すること自体は**技術的に完全には防げない**(この repo の他の「触らないものを厳守」規約と同様、L1 policy 相当の制約であり L3 hook 相当の強制ではない)。
- **技術的バックストップ(git status ガード)**: dispatch から subagent の返答を受け取った後、**台帳へ書き込む前に必ず** `.harness/` の変更を検査する。**ローカル編集方式(F案)では台帳(`.harness/plan-progress.json`)を commit しないため、これは常に `git status` 上「変更あり」になる** — したがって「dirty か否か」では subagent の変更と区別できない。ベースラインは 2 本立てで持つ: (i) `.harness/plan-progress.json` は **orchestrator が最後に書いた内容のスナップショット**(tick 開始時、または orchestrator 自身の直前の書込直後に控える `sha256sum` 等)と照合し、そこからの逸脱を subagent の変更と判定する。orchestrator は自身の各書込の直後にこのスナップショットを更新する。(ii) `.harness/` の**それ以外のファイル**(schema / validator / 規約断片)は orchestrator が触らないので、`git status --short -- .harness/` が `plan-progress.json` 以外の変更を示したら subagent の変更と判定する。この 2 本立ての照合を具体的には次のように行う(パスは絶対化する。`$PLAN` は `git rev-parse` 基準で解決するので CWD が repo ルート以外でも失敗しない):

  ```
  PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
  # (i) 台帳スナップショット照合: dispatch 前(または orchestrator 自身の直前の書込直後)に控える
  PRE=$(sha256sum "$PLAN" | cut -d' ' -f1)
  # ... subagent を dispatch し、返答を受け取る ...
  # dispatch 後・orchestrator 自身の書込前に再計算して照合する
  POST=$(sha256sum "$PLAN" | cut -d' ' -f1)
  # PRE != POST なら subagent が台帳を触った形跡 → その提案を破棄し need for human review sink へ
  # (ii) それ以外の .harness/ ファイルは HEAD 一致で検査(plan-progress.json 以外の変更が出たら同様に sink へ):
  #   git status --short -- .harness/ | grep -v plan-progress.json
  ```

  いずれかで逸脱を検知したら(= subagent が dispatch 中に orchestrator の checkout 内の `.harness/` へ意図しない変更を加えた形跡)、その提案を採用せず、当該 step を下記「失敗経路(単一の need for human review sink)」へルーティングする(`git checkout -- .harness/` 等の破壊的な巻き戻しは行わず、状態を報告して人間の判断を待つ)。**このガードの限界(subagent の worktree 編集は見えない=部分的バックストップに過ぎず、主たる防御は「Write を渡さない」ツール制限であること)は「既知の制限・拡張ポイント」節に正直に明記する**。

  **PRE 計測タイミングの明確化**: 上記の PRE は「tick 開始時点」を指すのではなく、**「dispatch 直前・orchestrator 自身の直近の書込が完了した直後」**を指す。tick 冒頭の `orchestratorTick` インクリメント(「tick 冒頭 reconciliation」節)や、実装役手順 1 の `dispatchMarker` 書込は、いずれも orchestrator 自身が行う正当な書込であり、**PRE を控えるより前に完了させる**(PRE 計測をこれらの書込の後まで遅らせる、と言い換えてもよい)。この順序を守れば PRE→POST 間に挟まるのは「dispatch 中に subagent が加えた変更」だけになり、tick カウンタや `dispatchMarker` の書込自体を subagent の改変と誤検知することはない。具体的には、実装役の手順としては **手順 1(marker 書込)の直後・手順 2(dispatch)の直前に PRE を再計測する**(tick 冒頭で 1 度だけ控えて使い回さない — 使い回すと手順 1 の marker 書込自体が PRE→POST 間に挟まり、実装役 dispatch の正常系まで含めて毎回誤検知することになる)。

## 失敗経路(単一の need for human review sink)

**原則: orchestrator が step を安全に前進させられない状況は、原因を問わず単一の失敗経路に集約する。** すなわち **`need for human review` ラベル付与 + `PushNotification` + 事実に即した台帳書込(あれば)→ 以後その step は人間がラベルを外すまで配車テーブルで無条件スキップ**。実装役・対応役・reviewer 経路すべてで**対称に**扱う(どのロールでも「前進不能 = この sink に到達」であり、片方だけ有界停止・片方は無界ループ、という非対称を作らない)。**どの状況が sink に落ちるかは「ルーティング判定」節の decision script が `route=sink` として決める**(下表はその sink 経路を人間向けに列挙したもので、規則そのものは script が正)。

### この sink にルーティングされるトリガー(全経路の一覧)

| トリガー(状況) | role/outcome(判定器トークン) | この sink で書き込む事実 status |
|---|---|---|
| reviewer dispatch が `escalate=true` を返した(round/trend 停止条件) | reviewer/`escalate` | `pr.status="need for human review"`(停止条件到達の事実。1 回のローカル書込後に sink) |
| reviewer dispatch の返答が JSON でない / `escalate` を読めない(dispatch 結果失敗) | reviewer/`invalid` | 書込なし(dispatch 失敗のため状態を変えない。`pr.status` は dispatch 元のまま) |
| 実装役 dispatch 後の evidence gate 失敗 | implementer/`pr_evidence_fail` | `pr.number` + `pr.githubState="open"` + `pr.status="created pr"`(PR は実在するという事実。1 回のローカル書込後に sink) |
| 対応役 dispatch 後の evidence gate 失敗 | responder/`evidence_fail` | 書込なし(`pr.status` は `completed review` のまま。未解決の review blocker が残っているという事実) |
| 実装役の `pr_number` 復旧検索(`Closes #N`)が複数一致(曖昧) | implementer/`ambiguous` | 書込なし(誤った番号を書かない) |
| 実装役 dispatch が主観的エスカレーション(`escalate_to_human`)を返した(PR 未作成。issue #31) | implementer/`subjective_escalate` | 書込なし(進める PR が無い。`ledger_write=None` である点は `ambiguous` と同型だが、`dispatchMarker` は削除せず永続させ `notified: true` を追加する(`timeout` と同型)— 詳細は「developer(実装役)」手順 6/7) |
| 対応役 dispatch が主観的エスカレーション(`escalate_to_human`)を返した(issue #31) | responder/`subjective_escalate` | `pr.status="need for human review"`(1 回のローカル書込後に sink) |
| reviewer dispatch が主観的エスカレーション(`escalate_to_human`)を返した(客観的な `escalate` とは別トリガー。issue #31) | reviewer/`subjective_escalate` | `pr.status="need for human review"`(1 回のローカル書込後に sink) |
| git-status ガードが `.harness/` への意図しない変更を検知 | (判定器の外・単一書込ガード) | 書込なし(提案を破棄する) |

**注**: 上表の「書き込む事実 status」列は decision script の `ledger_write` 出力を人間向けに説明するものであり、status リテラルの唯一の正は decision script。実行時は各ロール節が `$ROUTE.ledger_write` を台帳へ書く(適用手続きは「ルーティング判定」節の **`ledger_write` の適用**参照)。表内の status 文字列は表示・説明用途に留まり、実行される書込は script 出力から来る。**最終行の git-status ガードだけは decision script を通らない**(role/outcome 列が「判定器の外」と示すとおり)— その扱いは「既知の制限・拡張ポイント」節 (c) を参照。

**書き込む事実 status がトリガーごとに異なる**のは、「その時点で GitHub 上に確定している事実」を写すため:
- **reviewer/`escalate`**: 停止条件到達(round 上限 / blocker trend)という事実そのものが `pr.status="need for human review"` として書ける確定事実であるため、書込のうえで sink する(`ready for merge` と対称に、reviewer が設定できる終端手前の状態)。
- **reviewer/`invalid`**: reviewer は選別 jq 上 `created pr` / `waiting for review` からしか dispatch されないが、dispatch 結果自体が失敗(不正 JSON・`escalate` を読めない)しているため、停止条件に到達したという事実を確認できない。書込なら status は**その dispatch 元のまま**(reviewer に実装物は無く status を進める根拠が無い)。旧記述の「`completed review` のまま」は誤りだった(reviewer が `completed review` を選別することはない)。
- **対応役 evidence 失敗**: `completed review` のまま(未解決 blocker が残る事実)。
- **実装役 evidence 失敗**: `created pr`(PR 実在の事実)。
- **`subjective_escalate`(issue #31・3 role 共通)**: 委譲先自身が「人間の判断が必要」と自己申告した事実(`escalate_to_human: {reason}`)。客観的な停止条件(`escalate`)とは別のトリガーだが、書き込む事実は同型(PR が実在するロール(対応役・reviewer)は `need for human review` へ遷移を書いてから sink・PR 未作成の実装役は書込なしで sink)。詳細は「主観的エスカレーション(issue #31)」節を参照。

`escalate` の真偽値そのものや round/blocker 件数などの詳細は台帳に書かない(それらは GitHub コメントのマーカーが記録する)。**台帳に書くのは `pr.status="need for human review"` という遷移結果だけ**(need for human review ラベルと PushNotification が人間への到達経路)。

**sink の出口を人間の意図と結線(issue #12 で実装済み)**: reviewer/`escalate` の sink は `pr.status="need for human review"` を書いてから sink するため、人間が `need for human review` ラベルを外すだけでは配車テーブルの選別対象(`pr.status in (created pr, waiting for review)`)に戻らない — status も人為的に(続けるなら `waiting for review` 等へ)戻して初めて次 tick で再選別される。これにより、旧設計(status 無書込のまま sink)で「ラベルだけ外すと dispatch 元の status のまま再 dispatch され、原因未解消なら即座に再 escalate する」ループを構造的に防ぐ。**この結線の恩恵は escalate 経路のみに適用される**: reviewer/`invalid`(dispatch 結果失敗)は引き続き無書込のため、ラベルを外せば dispatch 元の status のまま再 dispatch される(dispatch 失敗は「停止条件に到達した」という確定事実が無く、書ける status が無いため — この非対称は意図的)。

### sink の共通手続き

事実に即した台帳書込(上表・あれば)を行った**うえで**、次を実行する:

1. `need for human review` ラベルを PR に付与する。**必ず create(fallback・冪等)を先、add を後の順で実行し、`add-label` の exit code を確認する**(`gh` はラベル未存在の状態で `add-label` するとエラーになるため。同ファイル内「ルーティング判定」節の `ready for merge` ラベル操作と同じ順序に揃える。色・説明は `commands/harness-review-pr.md` 手順 6 の `ready for merge` ラベル作成パターンに倣う):
   ```
   gh label create "need for human review" --color "d93f0b" --description "orchestrator が人間の判断を要求した PR" --force
   if gh pr edit <n> --repo <repo> --add-label "need for human review"; then LABEL_OK=1; else LABEL_OK=0; fi
   ```
   `LABEL_OK` は手順 4 の報告に反映する(**成否を検証せず無条件に「付与済み」と報告しない** — 報告虚偽の防止)。
2. `PushNotification` ツールで人間に通知する(離席中でも気づけるように)。内容にトリガー(上表のどれか)と PR 番号を明記する — 例: 「PR #<n> が停止条件に到達した」「PR #<n> の reviewer dispatch が失敗した(不正応答)」「PR #<n> の evidence gate が失敗した(実装役 / 対応役)」「PR #<n> の dispatch 中に台帳への意図しない変更を検知した」「issue #<N> を Closes する open PR が複数見つかった(曖昧)」「PR #<n> で**主観的エスカレーション**が発生した(委譲先の自己申告: `<reason>`)」「issue #<N> の実装役 dispatch が**主観的エスカレーション**を返した(PR 未作成・委譲先の自己申告: `<reason>`)」等。**主観的エスカレーション(issue #31・`subjective_escalate`)は客観的な停止条件到達と区別できるよう、通知本文に「主観的エスカレーション」の 1 語を必ず添える**(ラベルは単一の `need for human review` のまま分割しない — 区別は通知本文のみで行う)。通知の成否も確認する(離席中の唯一の気づき経路のため)。
3. **以後その step は無条件スキップ**: 次 tick 以降、配車テーブルの選別より前で `need for human review` ラベルの有無を確認し、付いていればどのロールにも dispatch しない。**ラベルの解除は人間が手動で行う**(orchestrator 側で自動解除ロジックは持たない)。
4. **報告への反映(虚偽防止)**: tick 報告の「失敗 sink」列は `LABEL_OK` と通知の成否を**実際に反映する**。付与成功時のみ「🛑 need for human review 付与 + 通知済み」と書き、`add-label` 失敗時は「⚠️ ラベル付与失敗(手動付与が必要)」と正直に書く(無条件に「付与 + 通知済み」と書かない)。

**有界停止の保証**: この sink に入った step は「人間がラベルを外す」以外に配車対象へ戻る経路が無い。したがって、どのロール(実装役・対応役・reviewer)から入っても、evidence が通らない/停止条件に達した/dispatch 結果が失敗した step が無限に再 dispatch され続けることはない(無界ループは残さない)。**実装役の `no_pr`(dispatch 後 PR 未作成 + 復旧検索 0 件)は、issue #26(P1 決定)により「tick 冒頭 reconciliation」節の in-flight マーカー機構(締切 K=2 tick・リトライ上限 N=2)で有界化された** — `no_pr` は sink には入らず route=skip のまま毎 tick 即時再 dispatch されるが、原因が持続的なら最大 N=2 回のリトライで outcome=`timeout` に解決し sink(この sink はラベルではなく永続する `dispatchMarker` 自体が「無条件スキップ」を実装する変則形 — 詳細は「tick 冒頭 reconciliation」節参照)。これで本コマンドが掲げる「無界ループを残さない」不変条件に唯一残っていた例外が解消された(旧版はこの段落で `no_pr` を唯一の例外と明記していたが、issue #26 で解消済み)。加えて、reviewer/`escalate` は `pr.status="need for human review"` を書いてから sink するため(上記「sink の出口を人間の意図と結線」参照)、人間がラベルを外しただけでは再 dispatch されず、この経路での再 escalate ループは構造的に防がれる(`invalid` 経路は書込が無いため対象外)。

## ルーティング判定(`scripts/decide-orchestrator-route.py`)

各ロール節の post-dispatch 処理は、**状況を outcome トークンに解決 → `${CLAUDE_PLUGIN_ROOT}/scripts/decide-orchestrator-route.py` を呼ぶ → 返った `{ledger_write, route, label_action}` を実行**、という構造に統一する。**ルーティング規則(どの (role, outcome) がどう書くか・どの route か・ラベルをどう操作するか)は script が唯一の正**であり、prose に決定表を複製しない(`evaluate-stop-condition.py` / `reaggregate-has-blocker.py` と同じ「規則は script・prose は I/O」境界)。prose が担うのは (1) 状況を outcome へ解決する方法(各ロール節)と (2) 返った route / label_action の**実行方法**(本節)だけ。

- **呼び方**:
  ```
  ROUTE=$(printf '{"role":"<implementer|responder|reviewer>","outcome":"<token>"}' \
    | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/decide-orchestrator-route.py")
  # -> {"ledger_write": <null|{...}>, "route": "normal|skip|sink",
  #     "label_action": "null|add_ready_for_merge|remove_ready_for_merge"}
  ```
  outcome トークン(role ごと。全網羅は `tests/smoke/run-smoke.sh` [8] が決定論検証):
  - **implementer**: `no_pr`(返答不正 かつ 復旧検索 0 件)/ `ambiguous`(復旧検索 複数件)/ `pr_evidence_pass`(pr_number 確定 かつ evidence exit 0)/ `pr_evidence_fail`(pr_number 確定 かつ evidence 非 0)/ `timeout`(issue #26: 「tick 冒頭 reconciliation」節の in-flight マーカーが締切超過でリトライ上限 N=2 に到達、またはマーカーが壊れている/不整合)/ `subjective_escalate`(issue #31・PR 未作成のまま `escalate_to_human` を返した)
  - **responder**: `evidence_pass` / `evidence_fail` / `subjective_escalate`(issue #31)
  - **reviewer**: `invalid`(返答が JSON でない・`escalate` を読めない=dispatch 結果失敗)/ `escalate`(escalate=true)/ `clean_pass`(escalate=false かつ has_blocker=false)/ `blockers`(escalate=false かつ has_blocker=true)/ `subjective_escalate`(issue #31・客観的な `escalate` とは別に `escalate_to_human` を返した)

  **3 role 共通の `subjective_escalate` の解決方法(issue #31・詳細は「主観的エスカレーション」節)**: 各ロールの dispatch 応答が `escalate_to_human: {reason}`(`reason` は空でない文字列)を含む場合、その他の分岐より**先に** outcome=`subjective_escalate` へ解決する。**この検出条件(JSON として解釈できるか・`escalate_to_human.reason` の有無)の唯一の正はここに置き、各ロール節(実装役手順 3・対応役手順 3・reviewer 手順 2)では複製せずここを参照する**(役割ごとに異なるのは「他の分岐より先に判定する」という優先順位の適用箇所と「解決後にどの手順へ進むか」だけで、検出条件自体は共通)。`reason` の形式検証(空・欠損・非文字列なら無視してフォールバック)は「主観的エスカレーション」節の「最小の形式検証(A案)」を参照(判定ロジックの唯一の正はそちらに置き、ここでは複製しない)。

  script が exit 2(role enum 外 / outcome が role に対応しない / 必須キー欠損)なら、その step の処理を止め状態を報告する(黙って散文判定に切り替えない — `reaggregate-has-blocker.py` の扱いと同じ)。

- **`ledger_write` の適用(status リテラルは decision script が唯一の正)**: decision script の出力(`$ROUTE`)から `ledger_write` を取り出し、**非 null ならその中のキーだけを台帳へ書く**(script が返したフィールドのみ・**prose 側で status 文字列をハードコードしない**)。`null` かつ `<clear_marker>` も `false`(既定)なら台帳書込なし。**`null` でも `<clear_marker>`="true" が渡された場合は `dispatchMarker` の削除だけを行う**(`ambiguous` outcome がこれに該当。詳細は下記手続き参照)。ロールごとに書くフィールドが異なる(実装役=number+githubState+status / 対応役・reviewer=status のみ)ため、**`ledger_write` のキー集合に応じて書込を動的に組み立てる**。キーの解釈は 2 通りだけ:
  - `"pr.number": true` → orchestrator が保持する実 `pr_number` を書く(script は番号を知らないので真偽フラグ。この 1 点だけ prose が実値を供給する)
  - `"pr.githubState"` / `"pr.status"` → script が返したリテラル値をそのまま書く

  抽出と適用は次の 1 手続きで行う(`<step id>` は対象 step、`<pr_number>` は orchestrator が保持する確定番号。`pr.number` を含まない経路では空文字でよい。`<clear_marker>` は省略可・既定 `false` — `true` を渡すと同じ書込内で `dispatchMarker` キーも削除する。実装役の `pr_evidence_pass`/`pr_evidence_fail`/`ambiguous` がこれを `true` で呼ぶ理由は「developer(実装役)」手順 6 参照 — `ambiguous` は `ledger_write` が無い(=null)ため、他のフィールド書込を伴わない marker 単独削除としてこの同じ手続きで扱われる。**`subjective_escalate` はこの手続きを呼ばない**(marker を削除せず永続させるため。代わりに上記「`notified` フラグの付与」の手続きを使う — 詳細は「developer(実装役)」手順 6/7)。`ledger_write` の全キー(と、渡された場合は `dispatchMarker` 削除)を 1 回のファイル書込で適用するため原子的(`pr.number` だけ書いて `pr.status` 未書込という中間状態や、`dispatchMarker` だけ消えて `pr.number` 未書込という中間状態を作らない):
  ```
  PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
  python3 - "$PLAN" "<step id>" "$ROUTE" "<pr_number>" "<clear_marker>" <<'PY'
  import datetime, json, os, sys
  argv = sys.argv[1:]
  if len(argv) > 5:
      # 決め打ちパースへの将来のパラメータ追加が黙って切り捨てられるのを防ぐ。
      print(f"::error:: ledger_write 適用: 引数が5個を超えている ({len(argv)}個)。"
            "この決め打ちパースにパラメータを追加した場合は本ブロックの更新が必要。", file=sys.stderr)
      sys.exit(2)
  argv = argv + ["false"] * (5 - len(argv))  # <clear_marker> 省略時は "false" 扱い
  plan_path, step_id, route_json, pr_number, clear_marker = argv[:5]
  lw = json.loads(route_json)["ledger_write"]  # decision script の出力を消費 (唯一の正)
  if lw is not None or clear_marker == "true":
      # lw が null でも clear_marker="true" なら marker 単独削除のためファイルを開く。
      # (旧条件 `if lw is not None:` では `ledger_write=null` の outcome
      #  (= ambiguous) がこのブロックに到達できず、marker が永久に残っていた)
      with open(plan_path, encoding="utf-8") as f:
          plan = json.load(f)
      step = next(s for s in plan["steps"] if s["id"] == step_id)
      if lw is not None:
          for key, val in lw.items():             # script が返したキーだけを書く (動的)
              section, field = key.split(".", 1)  # "pr.status" -> ("pr","status")
              if key == "pr.number" and val is True:
                  val = int(pr_number)            # script は真偽フラグ。実値は orchestrator が供給
              step[section][field] = val          # status 等は script の返値をそのまま (prose で複製しない)
      if clear_marker == "true":
          step.pop("dispatchMarker", None)    # marker 削除を ledger_write と同一書込で原子化
      plan["updatedAt"] = datetime.date.today().isoformat()
      with open(plan_path + ".tmp", "w", encoding="utf-8") as f:
          json.dump(plan, f, ensure_ascii=False, indent=2)
      os.replace(plan_path + ".tmp", plan_path)  # 原子的な置換
  PY
  ```
  これで**実行される書込は decision script の `ledger_write` から来る**(prose に status リテラルを複製しない)。書込後は「書込方式」節に従いローカルファイル編集のみで完結させ(commit/push しない)、続けて Statuses API 自己申告を行う。

- **`notified` フラグの付与(marker 永続 + 通知 1 回化の共通手続き)**: `route=sink` の中には、marker を削除せず**永続させたまま**「以後は通知済みとして再判定をスキップする」ことだけを記録したいケースがある(`timeout`・実装役 `subjective_escalate` が該当。両者とも PR が実在しないため上記 `ledger_write` の適用手続き(`<clear_marker>`)は使わない — 削除ではなく永続が目的のため)。この場合は `dispatchMarker` の既存 3 キー(`dispatched_tick`/`deadline_tick`/`retry_count`)は変更せず、`notified: true` を追加する 1 回の書込だけを行う(`ledger_write` が伴わない sink でも、この 1 回のファイル書込で完結する):
  ```
  PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
  python3 - "$PLAN" "<step id>" <<'PY'
  import datetime, json, os, sys
  plan_path, step_id = sys.argv[1], sys.argv[2]
  with open(plan_path, encoding="utf-8") as f:
      plan = json.load(f)
  step = next(s for s in plan["steps"] if s["id"] == step_id)
  step["dispatchMarker"]["notified"] = True   # 既存 3 キーは変更せず追加のみ
  plan["updatedAt"] = datetime.date.today().isoformat()
  with open(plan_path + ".tmp", "w", encoding="utf-8") as f:
      json.dump(plan, f, ensure_ascii=False, indent=2)
  os.replace(plan_path + ".tmp", plan_path)
  PY
  ```
  これにより次 tick 以降は「tick 冒頭 reconciliation」節の「`notified` 済みマーカーの早期スキップ」に該当し、この step は無条件スキップされる(解除は人間が `dispatchMarker` を手動削除するまで行われない — ラベル解除に相当する手段が無い点も `timeout` と同じ)。

- **`route` の実行**:
  - **`normal`**: `ledger_write`(あれば)を書いて完了。sink・ラベル以外の副作用なし。
  - **`skip`**: 書込なし・副作用なし。次 tick で条件が再成立すれば再 dispatch される(副作用が無いので暴走しない)。
  - **`sink`**: 「失敗経路(単一の need for human review sink)」へ。`ledger_write` が非 null なら**先に書いてから** sink 共通手続きを実行する(例: 実装役 evidence 失敗は「PR は実在する」事実を書いた上で sink)。

- **`label_action` の実行**(reviewer 経路のみ非 null。`ready for merge` ラベルの同期。単一書込の設計上 pr reviewer subagent はラベルに触らせないため orchestrator が実コマンドとして持つ — `commands/harness-review-pr.md` 手順 6 と同内容):
  - **`add_ready_for_merge`**:
    - ラベル作成 fallback(冪等): `gh label create "ready for merge" --color "0e8a16" --description "reviewer が merge 可能と判定した PR" --force`
    - `gh pr edit <n> --repo <repo> --add-label "ready for merge"`(冪等)
    - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(無ければ警告のみで実害なし)
  - **`remove_ready_for_merge`**:
    - `gh pr edit <n> --repo <repo> --remove-label "ready for merge"`(付いていなければ警告のみで実害なし)
    - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(無ければ警告のみで実害なし)
  - **`null`**: ラベル操作なし。

## tick 冒頭 reconciliation(in-flight マーカー・issue #26)

**目的**: 実装役 dispatch が唯一持っていた無界再 dispatch(`no_pr`= dispatch 後 PR 未作成が原因不明のまま毎 tick 再試行され、人間に一切 surface されない)を有界化する。issue #26 の owner 決定(**P1**)に従い、**無状態 tick が前提**であり、跨 tick で参照できる永続シグナルは **台帳 (on-disk) のマーカー + PR の有無だけ**(dispatch した subagent からの完了通知が live セッションへ届くことには依存しない)。**P1 決定により `no_pr` は独立に観測できる枝ではなく締切超過(timeout)と同じリトライカウンタへ畳み込む**(set3 で検討された独立 `no_pr_count` は v1 では採らない)。

**tick カウンタ(`orchestratorTick`)**: 台帳 top-level に transient な整数フィールド `orchestratorTick` を持つ(schema 非宣言・キー無しは 0 扱い)。**各 tick の最初に 1 回だけ** 1 加算して書き、以後この tick の reconciliation・marker 書込すべてで同じ値(`$TICK` と呼ぶ)を使う:
```
PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
TICK=$(python3 - "$PLAN" <<'PY'
import json, os, sys
plan_path = sys.argv[1]
with open(plan_path, encoding="utf-8") as f:
    plan = json.load(f)
tick = int(plan.get("orchestratorTick") or 0) + 1
plan["orchestratorTick"] = tick
with open(plan_path + ".tmp", "w", encoding="utf-8") as f:
    json.dump(plan, f, ensure_ascii=False, indent=2)
os.replace(plan_path + ".tmp", plan_path)
print(tick)
PY
)
```

**in-flight マーカー(`dispatchMarker`)**: 実装役が dispatch する直前(下記「developer(実装役)」手順 1・dispatch は手順 2)に、対象 step へ transient object を書く:
```json
{"dispatched_tick": <TICK>, "deadline_tick": <TICK + K>, "retry_count": <int>}
```
- `K` = 締切オフセット(v1: **K=2** tick。校正根拠は無い best-effort 値 — 「loop 間隔が実装役の想定所要時間より十分長い」という前提を置く。健全だが遅い dispatch を誤って timeout 判定しうるリスクは観測に応じて見直す)。
- `retry_count` は初回 dispatch では 0、再 dispatch では下記 reconciliation が返す値を引き継ぐ。
- **schema には宣言しない**(issue #26 決定: transient なフィールドは validator/drift/smoke の検査対象外に留める。`plan-progress.schema.json` の `step` は `additionalProperties` を制限していないため、宣言しない追加キーがあっても `--schema` は壊れない)。
- 消去は `step` から `dispatchMarker` キーそのものを取り除く(`null` を書くのではなくキー削除。「マーカーが無い」= `eligible` の判定と一致させるため)。

**reconciliation(各 tick・選別より前に実行)**: `dispatchMarker` を持つ全 step について、次の手順で処理する。

- **`notified` 済みマーカーの早期スキップ**: `dispatchMarker.notified == true` が既に立っている step は、下記の復旧検索(`progressed` の判定)も `scripts/reconcile-dispatch-marker.py` の呼出も行わずスキップする(この step は既に下記 `sink`(timeout)の変則手続きを通過済みで永続的に無条件スキップされている状態が確定しており、再判定しても結果は変わらない — 判定するだけ無駄な GitHub 検索と重複通知を生む)。この step はそれ以上何もせず今 tick の処理を終える(marker が残っているため選別(jq)からは従来どおり除外される)。`notified` が無い(または false の)step だけ、以下の通常手順を行う。

  ```
  ROUTE_MARKER=$(printf '{"marker":<dispatchMarker か null>,"current_tick":%d,"progressed":<bool>}' "$TICK" \
    | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/reconcile-dispatch-marker.py")
  ```
  `progressed` は「この step が前進した事実が確認できたか」を prose が解決して渡すフラグ(script は判定しない)— 実装役の手順 4 の復旧検索(`Closes #<N>` 一致)で `pr_number` が確定できれば true、まだ確定できなければ false。返る `action` ごとに:

  - **`eligible`**(`dispatchMarker` 無し): 通常どおり配車選別の対象(下記「選別(jq)」に変更なし)。
  - **`clear`**: `dispatchMarker` は**この時点では削除せず保持したまま**、確定した `pr_number` で「developer(実装役)」手順 5(evidence gate)以降へ進む(通常の `pr_evidence_pass`/`pr_evidence_fail` 経路と合流する。timeout/no_pr は関与しない。新規 dispatch を伴わないため下記 5 件上限の対象外)。**marker の削除は手順 6/7 の原子化された適用手続きに委ねる**(旧版はここで単独削除していたが、evidence gate(時間がかかる)の実行中や `ledger_write` 完了前に orchestrator セッションが中断すると、台帳が `dispatchMarker` 無し かつ `pr.number == null` の状態で永続化され、次 tick の選別(jq)が二重 dispatch してしまう。「marker 削除と `ledger_write` を同一書込に統合して原子化する」不変条件を `clear` 経路にも一貫させ、この中間状態そのものを無くす)。
  - **`wait`**: 何もしない(marker を残したまま)。この step は**今 tick の実装役選別から除外**する(下記「選別(jq)」のガード参照)。
  - **`redispatch`**: **今 tick 内で即座には dispatch しない**。返った `retry_count` を保持したまま「実装役の再 dispatch 候補」として、下記「配車テーブル」節の**5 件上限を実装役の選別(jq)新規対象と共有する枠**へ合流させる(独自の無制限枠を持たせない)。この枠に収まった候補だけ、**引き継いだ `retry_count` を渡して**「developer(実装役)」手順 1 から再実行する(**marker の書込は手順 1 が単独で行う** — reconciliation 自身はここで `dispatchMarker` を書かない。手順 1 の marker 書込 `{"dispatched_tick": $TICK, "deadline_tick": $TICK + K, "retry_count": <0 か引き継いだ値>}` は新規 dispatch・redispatch のどちらでも同じ 1 箇所のみで行われ、reconciliation と手順 1 が同一 tick 内で同内容の marker を 2 回書く冗長書込を避ける)。**枠から溢れた候補は今 tick では marker を書き換えない**(`retry_count` を消費しない) — 次 tick も `current_tick > deadline_tick` が成立し続けるため、reconciliation が同じ候補として再び `redispatch` を返し、優先度が回れば後続 tick で処理される(取りこぼしではなく先送り)。
  - **`sink`**(`reason` が `retries_exhausted`(リトライ上限 N=2 到達)または `invalid_marker`(マーカーが壊れている/不整合・fail-closed)): outcome=**`timeout`** として判定器(role=implementer)を呼ぶ(`decide-orchestrator-route.py` の implementer/`timeout` 行。`ledger_write` は null — PR がまだ存在しない `ambiguous` と同型)。「失敗経路(単一の need for human review sink)」の**変則**として次のとおり扱う(通常の sink 共通手続きとの差分):
    - **ラベル付与は行わない**(PR が存在しないため `gh pr edit --add-label` の対象が無い。`ambiguous` と同じ制約)。
    - `PushNotification` を行う(内容: 「issue #<N> の実装役 dispatch が締切超過でリトライ上限(N=2)に到達した」または「issue #<N> の in-flight マーカーが不整合」)。**この通知と同じタイミングで、「ルーティング判定」節の「`notified` フラグの付与」手続きを実行する**(`dispatched_tick`/`deadline_tick`/`retry_count` の既存 3 キーは変更せず `notified: true` を追加のみ。`reconcile-dispatch-marker.py` の marker 妥当性検査はこの 3 キーの存在・型しか見ないため、追加の `notified` キーは判定に影響しない)。これにより次 tick 以降は上記「`notified` 済みマーカーの早期スキップ」に該当し、この sink は tick をまたいで**一度だけ**通知される(通知の無限反復を防ぐ)。
    - **`dispatchMarker` は消さず残す**(この持続状態自体が「無条件スキップ」の実装 — 次 tick 以降は `notified: true` により復旧検索・script 呼出そのものをスキップするため、無期限の GitHub 検索の繰り返しも止まる。ラベルが無くても選別ガードは marker の存在自体で恒久的にこの step をスキップする)。
    - **人間の解除手段**: ラベル解除に相当する操作は「対象 step の `dispatchMarker` を手動で削除する」(根本原因(issue 実装不能等)を先に解消してから削除するのが通常の流れ)。orchestrator 側に自動解除ロジックは持たない(既存の「ラベルの解除は人間が手動で行う」原則と同型)。

これにより `no_pr` の連続発生(P1 決定により timeout と同じカウンタに畳み込む)も真の締切超過(hang)も、**同じ `retry_count` で最大 N=2 回(初回 + 2 リトライ = 計 3 dispatch)まで有界リトライし、尽きたら sink する**(「有界停止の保証」節の唯一の例外だった `no_pr` はこれで解消)。dispatch call 自体がセッションを止めてしまう真の hang(`Agent` ツールにタイムアウト parameter が無い制約は変わらない)は、marker が dispatch 直前に書かれているため、**人間がセッションを再起動した次の tick**で `TICK > deadline_tick` として検知される(tick を跨いだ persistent state による回復。dispatch 中の hang をリアルタイムに検知する機構ではない — 「既知の制限・拡張ポイント」節参照)。

## 主観的エスカレーション(issue #31・A案)

**目的**: オーケストレーターで自動で回している時、委譲先のサブエージェント(実装役 / 対応役 / reviewer)が作業中に「これは人間の判断を仰ぎたい」と自分で判断しても、それを安全にエスカレーションする明示的な経路が無かった。既存の `escalate`(「ルーティング判定」節の reviewer 行)は round/blocker trend という**客観的**な停止条件でのみ発火する機構であり、委譲先自身の**主観的**な判断には対応していない。

**脅威モデル(issue #31 で確定)**: 「委譲先の自己申告を鵜呑みにしてよいか」という懸念に対し、この経路の唯一の力は「人間の注意を得る」ことのみ(fail-safe 方向)であることを確定させた。暴走した委譲先がこの経路を悪用しても、merge・台帳書込・越権実行はできない(「単一書込」節の capability 分離・単一書込主体・evidence gate が別途封鎖済み)。したがって悪用の実害は「人間が無駄に見る」注意コストに留まり、それに比例する解として**軽量な形式検証のみ**(下記)を採用し、独立検証エージェントの新設(過去 2 事故 — fork 入れ子暴走 / 台帳並行書込無音上書き — と異なり、この経路は実害に直結しないため過剰武装。「監視エージェントを新設しない」という issue #26 の確定原則とも整合)は採らない。

**3 role 共通の返り値契約**: 各ロールの dispatch prompt(下記「dispatch 先ごとの委譲方式」の各役割節)は、通常の返り値に加えて「人間の判断が必要と感じた場合は代わりに `{"escalate_to_human": {"reason": "<理由>"}}` を返してよい」という選択肢を明示する。3 ロールとも同じフィールド名・同じ形にする(発火機構の統一)。

**最小の形式検証(A 案)**: orchestrator prose が `escalate_to_human` を受けたら、**`reason` が存在し空でない文字列であることのみ**を確認する(ファイルパスや行番号の実在確認・意味的真偽の検証はしない)。この形式検証は `decide-orchestrator-route.py` の入力に `reason` 自体を含まない(script は `{role, outcome}` のみを受け取る)ため、**prose(orchestrator 自身の判断)側で行う** — reason 空チェックが script でなく prose に置かれる唯一の理由は、判定器の入力契約を `role`/`outcome` に絞り続けるため(この形式検証自体は L1 の防護線に留まり、machine-checked ではない。ただし脅威モデル上、破れても実害は注意コストのみなので L1 でも害に比例する)。`reason` が空・欠損・非文字列なら**形式不正として `escalate_to_human` を無視し**、通常の outcome 解決へフォールバックする(黙って握りつぶさず、tick 報告に「`escalate_to_human` 形式不正のため無視した」と 1 行残す)。

**新 outcome とルーティング**: `escalate_to_human.reason` が有効なら、各ロールは outcome=`subjective_escalate` として「ルーティング判定」節の判定器を呼ぶ(role はそのまま実装役/対応役/reviewer)。判定器の出力は「失敗経路(単一の need for human review sink)」の**既存 sink** に合流する(別 sink を新設しない):
- **実装役**(PR 未作成 = `pr.number` 未確定): `ledger_write=None`(進める PR が無いため書込なし)・`route=sink`。**`dispatchMarker` は削除せず永続させ `notified: true` を追加する**(`timeout` と同型。削除すると次 tick に即座に再 dispatch されてしまうため — 詳細は「developer(実装役)」手順 6/7)。
- **対応役 / reviewer**(PR が実在): `ledger_write={"pr.status": "need for human review"}`(escalate と同じく書いてから sink)・`route=sink`。

**実装役の複合ケースは v1 では扱わない**: 実装役が PR を作成した上で `escalate_to_human` も返す複合ケース(完了と申告の同時)は v1 のスコープ外(issue #31 set1 Implementation Scope 6 の決定)。実装役の dispatch prompt では「PR を作成した場合は通常どおり `{pr_number, proposed_status}` を返す。人間の判断が必要と感じた場合は PR を作らずに `{escalate_to_human: {reason}}` を返す(両方を返す必要がある状況は無い)」と明示し、二択であることを源流(dispatch prompt)で徹底する。万一両方が返された場合は `escalate_to_human` を優先して `subjective_escalate` に解決する(pr_number 側の追跡は行わない — 既知の限界として残す)。

**主観 vs 客観の区別**: `need for human review` ラベルは単一のまま(ラベル分割はしない)。人間が区別したい場合は、sink 共通手続きの `PushNotification` 本文に「主観的エスカレーション」の 1 語を添える(「失敗経路」節・sink 共通手続き手順 2 参照)。

**issue #26 との共有面(既知の制限)**: 本節が追加する `subjective_escalate` は `scripts/decide-orchestrator-route.py` の `DECISION_TABLE` と `tests/smoke/run-smoke.sh` [8] を、issue #26(dispatch した子の生存監視と失敗の有界化・別 PR)と共有する。#26 は `implementer` に `timeout` outcome を追加し、`no_pr` の連続発生をリトライカウンタ(`reconcile-dispatch-marker.py`)で有界化する改修を別途進めている。**両 PR が並行して `implementer` ブロックへ新エントリを追加するため、どちらかが先に merge された後にもう一方を rebase する際は `DECISION_TABLE`(本ファイル同名スクリプト)・行数ガード(smoke [8])・本節の周辺で軽微なテキスト競合が起こりうる**(意味的な衝突ではなく、同じ辞書リテラルへの追記が近接するだけ)。加えて、`subjective_escalate`(実装役・PR 未作成)の「PR 未作成 → 書込なしで sink」という扱いは、現状 `no_pr`/`ambiguous` と同型の空状態であることを根拠にしているが、**#26 の `no_pr` 有界化(`no_pr_count` によるリトライ集約)が着地した後は、その根拠(`ledger_write=None` の一致)が保たれるか改めて確認する**(`route` は `no_pr`=skip・`subjective_escalate`=sink で元々異なるため、ここでの「同型」は `ledger_write=None` の一点のみであることに注意)。

## 配車テーブル(v1・PR ライフサイクルのみ)

**`need for human review` ラベル付きの PR は無条件でスキップする**(ラベルの有無は各対象 step ごとに `gh pr view <n> --json labels` で確認)。**1 tick あたりの dispatch 上限は 5 件**(`commands/harness-review-pr.md` の暴走防止パターンを踏襲)。**この上限は「tick 冒頭 reconciliation」の `redispatch` 候補も含めた合計に適用する**(redispatch だけを上限の外に置くと、複数 step が同時に締切超過した場合に 1 tick で 5 件を大きく超える dispatch が起こりうるため。詳細は下記「選別(jq)」節参照)。

| 条件 | dispatch するロール | orchestrator が行うこと |
|---|---|---|
| `issue.status == "ready for implementation"` かつ `pr.number == null` かつ **in-flight マーカー無し(`wait` 対象外)** | developer(実装役) | tick 冒頭 reconciliation → (marker 無し/`redispatch`) → dispatch → 返答検証(復旧検索)→ evidence gate → outcome 解決 → 判定器 → git status ガード → route 実行(normal/skip/sink/timeout→sink) |
| `pr.status == "completed review"` | developer(対応役) | dispatch → 返答検証 → evidence gate → outcome 解決 → 判定器 → git status ガード → route 実行(normal/sink) |
| `pr.status in ("created pr", "waiting for review")` | pr reviewer | dispatch → 返答から outcome 解決(`invalid`/`escalate`/`clean_pass`/`blockers`)→ 判定器 → route + label_action 実行 |
| `pr.status == "ready for merge"` | なし | dispatch しない(終端は人間の専権) |
| `pr.status in ("merged pr")` / issue 終端(`closed issue`) | なし | 何もしない |

**注**: 終端は人間の専権だが、人間の明示指示がある場合のエージェントによる代行は例外として認められる — 詳細は `.harness/CLAUDE.harness.md`『終端の記録と merge 代行』節を参照。

issue サイドの走査は台帳の `issue.status` を読むだけ(追加の GitHub ポーリングは実装しない)。

### 選別(jq)

```
PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
REVIEW_MODE="${2:-code-review}"

# 実装役 dispatch 対象(新規 eligible のみ)。`dispatchMarker` が残っている step は、この jq 自身が
# `.dispatchMarker == null` で除外する(旧版は「reconciliation の結果を
# 読むだけで jq 自体は marker の有無を直接見ない」としていたが、`wait` 決着(締切未到達)の
# step は issue.status/pr.number が不変のままなのでこの guard が無いと選別に再度乗り、
# 同一 issue へ二重 dispatch(worktree/PR の競合)が起きる。marker が無い(eligible)か、
# reconciliation が `clear` して手順5以降(evidence gate)へ進み、手順7の原子書込で
# pr_number 確定・marker 削除まで完了した step だけがここへ来る。budget 内で redispatch が
# 実行されて新しい marker が書かれた場合も、この guard により
# 次 tick 以降の選別から除外され続ける — 有界化は reconciliation 側の締切・リトライ上限に委ねる)
#
# この jq の出力は「実装役枠」の候補の一部でしかない — もう一方は「tick 冒頭 reconciliation」
# 節が返す `redispatch` 候補(dispatchMarker が既にある既存 in-flight step)。両者を合算した
# ものが実装役枠の母集団になる(redispatch を合算せず jq 側だけで 5 件上限を
# 適用すると、redispatch が無制限に別枠で実行されてしまう)。
jq -c '[ .steps[]
  | select(.issue.status == "ready for implementation" and .pr.number == null and .dispatchMarker == null)
  | {id, issueNumber: .issue.number} ]' "$PLAN"

# 対応役 dispatch 対象
jq -c '[ .steps[]
  | select(.pr.number != null and .pr.githubState == "open")
  | select(.pr.status == "completed review")
  | {id, number: .pr.number} ]' "$PLAN"

# pr reviewer dispatch 対象
jq -c '[ .steps[]
  | select(.pr.number != null and .pr.githubState == "open")
  | select(.pr.status == "created pr" or .pr.status == "waiting for review")
  | {id, number: .pr.number} ] | unique_by(.number)' "$PLAN"
```

**実装役カテゴリの候補集合は、上記 jq が返す新規 eligible 対象と、「tick 冒頭 reconciliation」節が返す `redispatch` 候補(既存 in-flight step の再試行)を合算したもの**とする。3 カテゴリ(対応役 / pr reviewer / 実装役)を合算して **上限 5 件**に切り詰める(優先順は「対応役 > pr reviewer > 実装役」— 手戻り修正を優先し、新規 dispatch は余裕がある時だけ行う。実装役カテゴリ内では `redispatch` 候補(締切超過が古いもの優先)を新規 eligible 対象より先に数える — 既に in-flight で待たされている step を、まだ着手していない新規 step より優先する。この優先順位付け自体は機械的な tie-break であり、レビュー判断ではない)。実装役枠から溢れた `redispatch` 候補は「tick 冒頭 reconciliation」節のとおり marker を書き換えずに次 tick へ持ち越す。各対象を処理する前に `need for human review` ラベルの有無を確認しスキップする。

## dispatch 先ごとの委譲方式(転写しない)

各ロールは **dispatch → 状況を outcome トークンに解決 → 判定器(「ルーティング判定」節)→ route / label_action 実行**。dispatch prompt(委譲の中身)は転写せず参照させる方式を維持する。**ルーティング規則は判定器 script が正**なので、各ロール節は「どう outcome に解決するか」だけを書き、書込・sink・ラベルの規則は複製しない。

### developer(実装役)

**outcome 解決(判定器の implementer 行に渡すトークンを決める)**:

1. **in-flight マーカーを書く**(dispatch 直前・「tick 冒頭 reconciliation」節参照): 対象 step へ `{"dispatched_tick": $TICK, "deadline_tick": $TICK + K, "retry_count": <0 か reconciliation から引き継いだ値>}` を書いてから手順 2 の dispatch を行う(dispatch call 自体がセッションを止める真の hang でも、次 tick(人間がセッションを再起動した後)がこのマーカーを見て締切超過を検知できるようにするため)。この書込は「単一書込」節の git-status ガードにとっても orchestrator 自身の正当な書込であり、**PRE はこの書込が完了した直後・手順 2 の直前に再計測する**(「単一書込」節「PRE 計測タイミングの明確化」参照)。

2. **dispatch**(subagent には `Read, Skill, Bash, Grep, Glob` のみ渡す。`Write` は渡さない)し、返答から `pr_number` の取得を試みる(git-status ガードの PRE はここ、dispatch 直前に控える):

   > 「対象 issue #<N> の本文(Problem/Context/Alternatives/Implementation Scope/DoD)を `gh issue view <N>` で Read せよ。次に `creating-git-worktrees` skill を Skill ツールで起動し、その手順に従って worktree を作成せよ。issue の Implementation Scope に従って実装せよ。実装後、`creating-gh-prs` skill を Skill ツールで起動し、その手順に従って PR を作成せよ(base は main、`Closes #<N>` を本文に含める)。最後に `{pr_number, proposed_status}`(`proposed_status` は通常 `"created pr"`)を JSON で返せ。**人間の判断が必要と感じた場合(実装方針が確定できない・issue の指示が矛盾する等)は、PR を作らずに代わりに `{escalate_to_human: {reason}}` を返してよい(両方を返す必要がある状況は無い — issue #31・v1 は「完了 or 主観エスカレーション」の二択)。** 台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

3. **主観的エスカレーションの確認(issue #31・pr_number 解決より先に行う)**: 検出条件は「ルーティング判定」節の「3 role 共通の `subjective_escalate` の解決方法」を参照(ここでは複製しない)。該当すれば outcome=**`subjective_escalate`**(判定器は `ledger_write=None`・`route=sink` を返す。手順 4〜5 の pr_number 解決・evidence gate は行わず、手順 7 の判定器呼び出しへ進む)。形式不正で `escalate_to_human` を無視した場合は下記手順 4 へフォールバックする(tick 報告に 1 行残す)。

4. **`pr_number` の確定と outcome 解決**:
   - 返答が JSON として解釈でき、`pr_number` が `gh pr view <pr_number> --repo <repo>` で実在確認できた → その番号を採用し、手順 5 の evidence gate へ。
   - **`pr_number` が取得できない/不正**(subagent のクラッシュ・不正 JSON・実在確認失敗): 諦める前に、GitHub 側で実際に PR が作られていないか**復旧検索**する(dispatch prompt で PR 本文に `Closes #<N>` を含めるよう指示済みのため拾える)。**復旧検索の全 3 分岐を必ず定義する**。検索は **`Closes #<N>` のフレーズ厳密一致**で行う — 引用符が無いと GitHub 検索は語ごとの AND 一致になり、別 PR の「Closes #45. See also #<N> for context」のように `closes` と `#<N>` を偶然両方含む本文を誤検出しうる。フレーズ引用符は **GitHub 検索クエリ文字列側に埋め込む**(shell の外側引用符ではフレーズ化されない — GitHub へ渡る文字列自体に `"..."` を含める):
     ```
     # GitHub 検索クエリに埋め込んだ二重引用符でフレーズ一致を狙う(shell は外側を single quote で囲み、
     # 内側の二重引用符をそのまま GitHub へ渡す)。
     CANDIDATES=$(gh pr list --repo <repo> --search '"Closes #<N>" in:body' --state open --json number,body)
     # フォールバック再照合(効き目の保険): GitHub 検索はトークン化で `#` を落とし、フレーズ引用しても
     # `Closes #<N>` の厳密一致にならない可能性がある(効き目は手動 API 確認に回す。DoD 節)。効かなくても
     # 誤検出を除けるよう、取得した各候補の本文を `Closes #<N>`(大小無視・# 直後が対象番号ちょうど。
     # (?![0-9]) で #<N>0 のような部分一致を除外)の正規表現で再照合し、真に該当する PR だけを残す。
     MATCHED=$(printf '%s' "$CANDIDATES" | jq -c --arg n "<N>" \
       '[ .[] | select(.body | test("closes\\s+#" + $n + "(?![0-9])"; "i")) | {number} ]')
     ```
     再照合後の `MATCHED` の件数で分岐する(全 3 分岐を必ず定義する):
     - **0 件** → PR 未作成。outcome=**`no_pr`**(判定器は route=skip を返す。書込・副作用は無い。次 tick で `issue.status == "ready for implementation"` かつ `pr.number == null` かつ marker が `wait` でなければ再成立し再 dispatch される。**issue #26・P1 決定により、この `no_pr` はもはや無界ではない** — 手順 1 で書いた `dispatchMarker` が「tick 冒頭 reconciliation」節の機構で締切超過(K=2 tick)後にリトライ有界化(最大 N=2 回)され、尽きれば outcome=`timeout` として sink する。原因が持続的(issue 実装不能 / developer subagent の決定論的クラッシュ)でも、これで最終的に人間へ surface される)。
     - **複数件** → 曖昧(同一 issue を Closes する open PR が 2 本以上)。outcome=**`ambiguous`**(判定器は route=sink・書込なし。誤った番号を台帳に書かず人間が正しい PR を確定する)。
     - **1 件** → その番号を `pr_number` として採用し、手順 5 へ。

5. **evidence gate**(`pr_number` 確定後・書込より前に実行)。**subagent が dispatch 中に作った worktree は削除済みの可能性があり参照できないため、orchestrator 自身が独立して PR の head ブランチを取得し専用の一時 worktree を作って実行する**(`commands/harness-review-pr.md` 手順 4 の per-PR worktree パターンと同じ)。**`git worktree add` の exit code を必ず確認する** — 直前 tick が `git worktree remove` の前に中断していると同一パスに古い worktree が残り、`add` が exit 128(`... already exists`)になる。exit code を見ずに進むと残骸(古いコード)に対して evidence gate が走り、現在の PR head を黙って検証しなくなる。**worktree は成否に関わらず必ず後始末する**(`EVIDENCE_EXIT` の成否に関わらず末尾で `git worktree remove --force` し、worktree を残さない):
   ```
   HEAD_REF=$(gh pr view <pr_number> --repo <repo> --json headRefName --jq .headRefName)
   git fetch origin "$HEAD_REF" --quiet
   WORKTREE=".claude/worktrees/orchestrate-pr-<pr_number>"

   # 残骸掃除つき add。直前 tick が remove 前に中断すると同一パスに古い worktree が残り add が失敗する。
   # 失敗系の期待挙動(閉じた集合):
   #   (a) 既存が同一 head でも「再利用せず」常に最新 origin/<head> で作り直す(未 fetch の古いコミット・
   #       dirty な working tree で誤検証しないため、決定論的に「今の head を検証」を保証する)。
   #   (b) locked/dirty で remove --force 自体が失敗したら掃除不能 → evidence を実行せず fail 扱い(sink)。
   #   (c) admin record だけ残る(作業ディレクトリが消えている)場合は prune で解消してから再 add。
   CLEANUP_FAILED=0
   if ! git worktree add --detach "$WORKTREE" "origin/$HEAD_REF"; then
     git worktree remove --force "$WORKTREE"; REMOVE_EXIT=$?   # 残骸削除
     git worktree prune                                        # (c) admin record 除去
     if [ "$REMOVE_EXIT" -ne 0 ]; then
       CLEANUP_FAILED=1                                        # (b) locked/dirty で remove 失敗 → 掃除不能
     elif ! git worktree add --detach "$WORKTREE" "origin/$HEAD_REF"; then
       # 補助フォールバック: add --force で登録済みパスを上書き再利用(最新 head への確実な差し替えは
       # 保証されないため主手段にせず最後の手段のみ)。それも失敗なら掃除不能。
       git worktree add --force --detach "$WORKTREE" "origin/$HEAD_REF" || CLEANUP_FAILED=1
     fi
   fi

   if [ "$CLEANUP_FAILED" -eq 1 ]; then
     EVIDENCE_EXIT=1                                           # (b) 掃除失敗 → 検証せず fail(下記 outcome へ)
   else
     ( cd "$WORKTREE" && eval "$EVIDENCE_DONE" ); EVIDENCE_EXIT=$?
     git worktree remove --force "$WORKTREE"                   # 成否に関わらず後片付け
   fi
   ```
   (`$EVIDENCE_DONE` は台帳の `evidence.done`、無ければ `evidence.test` にフォールバック。)
   - **`EVIDENCE_EXIT == 0`** → outcome=**`pr_evidence_pass`**。
   - **`EVIDENCE_EXIT != 0`**(evidence 非 0 **または** 残骸掃除失敗 (b))→ outcome=**`pr_evidence_fail`**(route=sink・need for human review。古い残骸で誤って pass/fail を出すより停止が安全)。

6. **`dispatchMarker` の扱い(outcome ごとに 3 通りの決着を固定列挙する)**: 実装役の outcome(`no_pr` / `ambiguous` / `pr_evidence_pass` / `pr_evidence_fail` / `subjective_escalate`。**`timeout` はこの手順(1〜8)を通らず「tick 冒頭 reconciliation」節で独立に解決されるため、ここには含まれない** — 下記の `subjective_escalate` の扱いは timeout の変則をこの手順内で再現したものであり、timeout 自身がこの手順を通るわけではない)は、marker に対して次の 3 通りのいずれかで決着する。**固定列挙にするのは、「進める PR の有無が確定した」という性質だけで一括りにすると、新しい outcome がどちらの型に属すか誤分類しうるためである**(実際に起きた誤り: `subjective_escalate` をこの性質だけで判断して `marker 削除`型に分類したが、正しくは marker を永続させる `timeout` 型だった — 削除すると次 tick の選別 jq(`.dispatchMarker == null` かつ `.pr.number == null`)へ即座に再合致し、締切超過を待たず無条件・無制限に再 dispatch されてしまう)。**実装役に新しい outcome を追加する際は、この 3 分類のどれに属するかを明示的に決めてここへ追記すること**(性質ベースの一文で束ねて済ませない)。

   - **削除**(`ambiguous` / `pr_evidence_pass` / `pr_evidence_fail`): pr_number が確定した、または確定不能と判明したことで「進める PR の有無」がこの tick 内で解決し、marker を持ち越す理由が無い outcome。手順 7 で判定器を呼んだ後、その `$ROUTE` を「ルーティング判定」節の **`ledger_write` の適用**手続きへ `<clear_marker>`="true" として渡し、**同一の原子書込**で削除する(適用手続きの条件を `lw is not None or clear_marker == "true"` に一般化しているため、`ledger_write` が非 null(`pr_evidence_pass`/`pr_evidence_fail`)でも null(`ambiguous`)でも、この 1 つの手続きが扱える)。
   - **永続 + この場で `notified` を追加**(`subjective_escalate`): 委譲先が「人間の判断を仰ぎたい」と明示的に自己申告した outcome。marker を削除せず、`timeout` と同じく永続させたうえで、締切超過・リトライ上限到達を待たず**この場で即座に**「ルーティング判定」節の「`notified` フラグの付与」手続きを実行する(既存 3 キーは変更せず `notified: true` を追加するのみ)。これにより次 tick 以降は「notified 済みマーカーの早期スキップ」に該当し無条件スキップされる(詳細は手順 7)。
   - **完全に不可触**(`no_pr`): marker を書込も削除もしない。「tick 冒頭 reconciliation」節の機構(締切 K=2 tick・リトライ上限 N=2)による有界化に委ねる。

7. **判定器を呼び route を実行**(role=implementer。規則は判定器が正・下記は route の実行だけ):
   ```
   ROUTE=$(printf '{"role":"implementer","outcome":"<解決した outcome>"}' \
     | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/decide-orchestrator-route.py")
   ```
   - `pr_evidence_pass` / `pr_evidence_fail`: 判定器の `ledger_write`(`pr.number`=true / `pr.githubState`="open" / `pr.status`="created pr")を「ルーティング判定」節の **`ledger_write` の適用**手続きで**1 回のローカルファイル書込で書く**(`<pr_number>` に確定番号、`<clear_marker>`="true" を渡す — 手順 6 のとおり `dispatchMarker` の削除もこの同一書込に含める。**status リテラルは prose に複製せず `$ROUTE.ledger_write` から書く**)。evidence を書込より前に実行済みで、`ledger_write` の全キー(number/githubState/status)と `dispatchMarker` 削除を 1 回のファイル書込で適用するため、`pr.number` だけ書いて `pr.status` 未書込という中間状態や、marker だけ消えて `pr.number` 未書込という中間状態は生じない(非原子的多段書込を排除)。書込後は「書込方式」節に従いローカルファイル編集のみで完結させ(commit/push しない)、Statuses API 自己申告を行う。
     - `pr_evidence_pass` → route=normal。上記のローカル書込で完了。次 tick で pr reviewer に dispatch される。
     - `pr_evidence_fail` → route=sink。上記のローカル書込を行った**うえで**「失敗経路(単一の need for human review sink)」へ。書かれる `pr.status` は `ledger_write` のとおり `created pr`(`"completed review"` にはしない — reviewer が一度も走っていない PR には `# PR Reviewer` コメントが存在せず、対応役 dispatch しても直す finding が無い)。need for human review ラベル付与後は次 tick から無条件スキップされ安全に停止する。
   - `no_pr` → route=skip。書込なし。`dispatchMarker` は手順 6 のとおり残る(次 tick 以降「tick 冒頭 reconciliation」節が締切・リトライを判定する。**issue #26・P1 決定によりもはや無界ではない**)。
   - `ambiguous` → route=sink。`ledger_write` は null のため pr.number 等のフィールド書込は無いが、この判定器呼出の直後に同じ `ledger_write` の適用手続きを `<clear_marker>`="true" で呼び、`dispatchMarker` の削除だけを行う(この outcome の再 dispatch 挙動自体は issue #26 のスコープ外・変更しない)。
   - `subjective_escalate`(issue #31・手順 3 で解決済み)→ route=sink。`ledger_write` は null(進める PR が無い)。手順 6 のとおり `<clear_marker>` は渡さない(marker を削除しない) — 代わりに、判定器呼出の直後に「ルーティング判定」節の「`notified` フラグの付与」手続きを実行し、`dispatchMarker` へ `notified: true` を追加する(既存 3 キー(`dispatched_tick`/`deadline_tick`/`retry_count`)は変更せず追加のみ)。**この書込を怠ると(あるいは誤って marker を削除すると)、次 tick の選別 jq(`.dispatchMarker == null` かつ `.pr.number == null`)へ即座に再合致し、締切超過を待たず無条件・無制限に実装役が再 dispatch されてしまう**(marker を削除する誤りでも同じ実害になる — どちらの誤りでも「人間の判断を仰ぎたい」という明示的な意思表示が毎 tick 無視される)。`notified: true` の付与により、次 tick 以降は「notified 済みマーカーの早期スキップ」に該当しこの step は無条件スキップされる(解除は人間が `dispatchMarker` を手動削除するまで行われない — `timeout` と同じ解除手段)。「失敗経路(単一の need for human review sink)」の**変則**として、`timeout`/`ambiguous` と同じく PR が実在しないため次のとおり扱う: **ラベル付与は行わない**(`gh pr edit <n> --add-label` の対象となる PR 番号が無い)。`PushNotification` のみ行い、通知本文には「主観的エスカレーション」の 1 語と `reason` を含める(例: 「issue #<N> の実装役 dispatch が主観的エスカレーションを返した(PR 未作成・委譲先の自己申告: `<reason>`)」。sink 共通手続き手順 2 の通知例も参照)。

8. **orphan 防止は write-early ではなく復旧検索が担う(marker を永続させる outcome は書込前後を問わず安全)**: `ambiguous` / `pr_evidence_pass` / `pr_evidence_fail` は、手順 7 の原子書込(marker 削除 + (あれば) `ledger_write`)の**前**に tick が中断しても、marker が残ったままなので二重 dispatch は起きない(次 tick は `pr.number == null` のままなので手順 4 の復旧検索が既存 PR(`Closes #<N>`)を再発見して self-heal する)。`subjective_escalate` は手順 6 のとおり marker を削除しない(永続させる)ため、この保護は書込の前後を問わず一律に成立する — 手順 7 の `notified: true` 付与が tick 中断で未完了でも、`dispatchMarker` キー自体は残り続けるため選別 jq(`.dispatchMarker == null`)から除外され続け、二重 dispatch は起きない(次 tick は notified 未付与のまま reconciliation が通常どおり判定し、締切内なら `wait`、締切超過なら `redispatch`/`timeout` へ自然に合流する — 取りこぼしではなく先送り)。だから `pr.number` を先行して書き込む必要はなく、書込は手順 7 のとおり原子的にできる(先行書込 → evidence → 本書込 の 2 段書込は取らない。**`dispatchMarker` 自体は手順 1 で先行して書く点は変わらない** — こちらは `pr.number` ではなく hang 検知専用の別状態であり、この self-heal の議論とは独立)。

### developer(対応役)

**outcome 解決(判定器の responder 行に渡すトークンを決める)。実装役と対称で、evidence 失敗は必ず sink に到達し無界ループを残さない**:

1. **選別ガード**: 選別 jq に `.pr.githubState == "open"` を含める(GitHub 上で既に merged/closed の PR を対応役へ回さない)。

2. **dispatch**(ツール制限は実装役と同じ。`gh pr comment` 投稿は許可するが台帳・ラベルには触れさせない):

   > 「PR #<N> に投稿された最新の `# PR Reviewer` コメントを `gh pr view <N> --json comments` で読め。finding ごとに次の 4 分類で判定せよ:
   > 1. **採用**: 指摘を修正し commit する
   > 2. **却下**: 却下理由を明記する(誤検知・意図的な設計判断など)
   > 3. **保留(follow-up)**: merge 後の対応でよいと判断した場合(ただし最終判断は reviewer の責務であり、対応役はここで `ready for merge` を提案してはならない — `.harness/CLAUDE.harness.md` の doer ≠ judge 規約通り)
   > 4. **保留(解消不可)**: 環境依存の実測値が要る等、対応不能な場合(理由を明記)
   >
   > 対応内訳を PR コメントとして投稿し、`{proposed_status: "waiting for review"}` を JSON で返せ。**`ready for merge` を提案することは絶対に禁止**(採否に関わらず、対応後の提案は常に `waiting for review` 固定)。**人間の判断が必要と感じた場合(指摘の採否が判断できない・対応方針が確定できない等)は、代わりに `{escalate_to_human: {reason}}` を返してよい。** 台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

3. **主観的エスカレーションの確認(issue #31・返答検証より先に行う)**: 検出条件は「ルーティング判定」節の「3 role 共通の `subjective_escalate` の解決方法」を参照(ここでは複製しない)。該当すれば outcome=**`subjective_escalate`**(判定器は `ledger_write={"pr.status":"need for human review"}`・`route=sink` を返す。手順 5 の evidence gate は行わず、手順 6 の判定器呼び出しへ進む)。形式不正で `escalate_to_human` を無視した場合は下記手順 4 へフォールバックする(tick 報告に 1 行残す)。

4. **返答検証(越権の無効化)**: `proposed_status` が `"waiting for review"` 以外(特に `"ready for merge"`)でも**無視して先へ進む**(対応役の越権を orchestrator 側で機械的に無効化する — `.harness/CLAUDE.harness.md` の「対応側が `ready for merge` を立てるのは越権(例外なし)」を技術的に担保)。対応役の返答は outcome 解決に使わない — status は evidence gate だけで決まる。

5. **evidence gate**(実装役の手順 5 と同じ方法 — **`git worktree add` の exit code 確認 + 残骸掃除(remove --force → prune → 最新 head で再 add)を含む**。対象 PR は既に `pr.number` が確定しており subagent の dispatch 済み worktree の生死に依存しない。**worktree は成否に関わらず必ず後始末する**):
   ```
   HEAD_REF=$(gh pr view <n> --repo <repo> --json headRefName --jq .headRefName)
   git fetch origin "$HEAD_REF" --quiet
   WORKTREE=".claude/worktrees/orchestrate-pr-<n>"

   # 残骸掃除つき add(実装役 手順 5 と同一ロジック。失敗系 (a)(b)(c) の扱いも同じ)。
   CLEANUP_FAILED=0
   if ! git worktree add --detach "$WORKTREE" "origin/$HEAD_REF"; then
     git worktree remove --force "$WORKTREE"; REMOVE_EXIT=$?   # 残骸削除
     git worktree prune                                        # (c) admin record 除去
     if [ "$REMOVE_EXIT" -ne 0 ]; then
       CLEANUP_FAILED=1                                        # (b) locked/dirty で remove 失敗 → 掃除不能
     elif ! git worktree add --detach "$WORKTREE" "origin/$HEAD_REF"; then
       git worktree add --force --detach "$WORKTREE" "origin/$HEAD_REF" || CLEANUP_FAILED=1  # 補助フォールバック
     fi
   fi

   if [ "$CLEANUP_FAILED" -eq 1 ]; then
     EVIDENCE_EXIT=1                                           # (b) 掃除失敗 → 検証せず fail
   else
     ( cd "$WORKTREE" && eval "$EVIDENCE_DONE" ); EVIDENCE_EXIT=$?
     git worktree remove --force "$WORKTREE"                   # 成否に関わらず後片付け
   fi
   ```
   - **`EVIDENCE_EXIT == 0`** → outcome=**`evidence_pass`**。
   - **`EVIDENCE_EXIT != 0`**(evidence 非 0 **または** 残骸掃除失敗 (b))→ outcome=**`evidence_fail`**(route=sink。古い残骸で誤検証するより停止が安全)。

6. **判定器を呼び route を実行**(role=responder):
   - `evidence_pass` → 判定器の `ledger_write`(`pr.status`="waiting for review")を「ルーティング判定」節の **`ledger_write` の適用**手続きで書く(対応役は `pr.status` のみ・`<pr_number>` は空文字でよい。**status リテラルは prose に複製せず `$ROUTE.ledger_write` から書く**)・route=normal(次 tick で pr reviewer が再レビュー)。
   - `evidence_fail` → 書込なし・route=sink。**`pr.status` は `completed review` のまま**(事実: 未解決 blocker が残る)。これで対応役も有界停止になり実装役と対称になる — 「evidence が通らないまま `completed review` 固定で毎 tick 再 dispatch → reviewer が選別せず round カウンタが進まず永久に停止しない」旧・無界ループを根絶する。
   - `subjective_escalate`(issue #31・手順 3 で解決済み)→ 判定器の `ledger_write`(`pr.status`="need for human review")を **`ledger_write` の適用**手続きで書く(escalate と同じく書いてから sink)・route=sink。「失敗経路(単一の need for human review sink)」へ(通知本文には「主観的エスカレーション」の 1 語と `reason` を含める)。

**既知の限界(意図的・対応役の無作業検知は escalate backstop に委ねる)**: 対応役は outcome を evidence gate だけで決めるため、dispatch した subagent が **無作業/クラッシュでも test が元々緑なら `evidence_pass` → `waiting for review` へ進む**(偽の前進)。実装役(復旧検索)・reviewer(`invalid` 検知)が dispatch 結果失敗を即座に sink するのに対し、**対応役の無作業だけは即時検知しない**という latency の非対称が残る。ただし finding 未対応なら次 tick で reviewer が同じ blocker を再検出 → `completed review` へ戻す往復が続き、**escalate backstop(round≥5 / blocker trend)が最終的に人間へ surface する**。これは bounded(`has_blocker=true` 維持で `clean_pass`=不正 merge には至らない)であり、walking skeleton では検知機構を足さず backstop に委ねる(作者の意図的判断)。実害(無作業 dispatch が頻発)が観測されたら follow-up で対応役の作業有無(`# PR Review Worker` コメント / commit の有無)検証を足す(「既知の制限・拡張ポイント」節にも同旨を明記)。

### pr reviewer

対象 PR 番号と `$REVIEW_MODE` を渡し、次を Agent ツールで dispatch する(ツール制限は実装役と同じ。**`gh pr comment` 投稿は許可するが台帳・ラベルには触れさせない**):

> 「`commands/harness-review-pr.md` を Read し、そこに書かれた手順 4 〜 5.6(投稿である手順 5 を含む。5.5/5.6 は投稿より前に計算するが、投稿自体も実行対象に含む。review-mode=`$REVIEW_MODE`、停止条件判定込み)を PR #<N> に対してそのまま実行せよ。手順本体は転写しない — 必ずファイルを Read してから実行すること。判定ロジックは変更しない。手順 6 の台帳書込・ラベル管理・報告(手順 3 のマーカー投稿含む)は行わず、代わりに `{has_blocker, blocker_count, escalate, review_markdown}` を JSON で返せ(`review_markdown` は手順 5 で組み立てたコメント本文。投稿は行ってよい — 投稿そのものは pr reviewer の専権であり本コマンドの触らないものではない)。**レビュー中に人間の判断が必要と感じた場合(判定が付かない・専門知識が必要等)は、加えて `escalate_to_human: {reason}` を返してよい(他フィールドとの共存可 — 客観的な `escalate` とは独立のシグナル)。** 台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

**outcome 解決(判定器の reviewer 行に渡すトークンを決める。全 5 outcome を必ず解決する)**: 実装役の復旧検索・対応役の evidence gate と対称に、**reviewer にも「dispatch 結果失敗」分岐を持たせて単一 sink をすり抜けさせない**(「実装役は復旧検索、対応役は evidence gate で dispatch 失敗を捌けるが、reviewer だけ dispatch 結果失敗の分岐が無く単一 sink をすり抜ける」を、この `invalid` 分岐で塞ぐ)。判定順序は次のとおり(上から順に該当する最初の分岐を採用する):

1. **返答が JSON として解釈できない / `escalate` を読めない**(subagent クラッシュ・不正 JSON・個人 skill 欠落で `escalate` を組み立てられない等の **dispatch 結果失敗**)→ outcome=**`invalid`**(判定器は route=sink を返す)。
2. **(issue #31)検出条件は「ルーティング判定」節の「3 role 共通の `subjective_escalate` の解決方法」を参照(ここでは複製しない)**。該当する場合(客観的な `escalate` の値に関わらず優先) → outcome=**`subjective_escalate`**。形式不正で `escalate_to_human` を無視した場合は下記へフォールバックする(tick 報告に 1 行残す)。
3. **`escalate == true`**(round/trend 停止条件)→ outcome=**`escalate`**。
4. **`escalate == false` かつ `has_blocker == false`** → outcome=**`clean_pass`**。
5. **`escalate == false` かつ `has_blocker == true`** → outcome=**`blockers`**。

**判定器を呼び route / label_action を実行**(role=reviewer。evidence gate は reviewer 経路では不要 — reviewer 役に実装物は無い):
- `invalid`(dispatch 結果失敗)→ route=sink・書込なし・label_action=null。「失敗経路(単一の need for human review sink)」へ。台帳には一切書込まない(`pr.status` は dispatch 元の `created pr` / `waiting for review` のまま)。
- `subjective_escalate`(issue #31・上記手順 2 で解決済み)→ 判定器の `ledger_write`(`pr.status`="need for human review")を「ルーティング判定」節の **`ledger_write` の適用**手続きで書く(客観的な `escalate` と同じく書いてから sink)・route=sink・label_action=null。「失敗経路(単一の need for human review sink)」へ(通知本文には「主観的エスカレーション」の 1 語と `reason` を含める)。
- `escalate`(停止条件到達)→ 判定器の `ledger_write`(`pr.status`="need for human review")を「ルーティング判定」節の **`ledger_write` の適用**手続きで書く(reviewer は `pr.status` のみ・`<pr_number>` は空文字でよい)・route=sink・label_action=null。「失敗経路(単一の need for human review sink)」へ(sink 共通手続きが `need for human review` ラベル付与 + PushNotification を行う)。
- `clean_pass` → 判定器の `ledger_write`(`pr.status`="ready for merge")を「ルーティング判定」節の **`ledger_write` の適用**手続きで書く(reviewer は `pr.status` のみ・`<pr_number>` は空文字でよい。**status リテラルは prose に複製せず `$ROUTE.ledger_write` から書く**)・route=normal・label_action=`add_ready_for_merge`。
- `blockers` → 判定器の `ledger_write`(`pr.status`="completed review")を同手続きで書く・route=normal・label_action=`remove_ready_for_merge`。

label_action(`ready for merge` ラベル同期)の実コマンドは「ルーティング判定」節の `label_action の実行` を参照する(prose に複製しない)。

## evidence gate(対称モデル)

evidence gate は orchestrator 自身が独立した一時 worktree を用意して `evidence.done`(台帳 `.harness/plan-progress.json` の `evidence.done`、無ければ `evidence.test` にフォールバック)を実行する共通機構(具体的な worktree の作り方は「developer(実装役)」節の手順 5 参照)。**実装役・対応役いずれも、evidence gate 失敗時は判定器が `route=sink` を返し、単一の need for human review sink に到達する(対称)**:

- **developer(実装役)**: `pr_number` が確定した(PR は実在する)場合、失敗 outcome=`pr_evidence_fail` → `pr.status="created pr"` を 1 回のローカル書込で書き込んだうえで sink。PR 未作成(復旧検索 0 件)は outcome=`no_pr` → route=skip で書込まず次 tick 再 dispatch(副作用が無いので暴走しない。**issue #26(P1 決定)により、原因が持続的(issue 実装不能 / developer subagent の決定論的クラッシュ)でも「tick 冒頭 reconciliation」節の in-flight マーカーが締切 K=2 tick・リトライ上限 N=2 で有界化し、尽きれば outcome=`timeout` として sink する — もはや無界ではない(詳細は「tick 冒頭 reconciliation」節・「既知の制限・拡張ポイント」節参照)**)。復旧検索が複数一致(曖昧)は outcome=`ambiguous` → route=sink・書込なし。
- **developer(対応役)**: 対象 PR は既に存在し `pr.number` も書込済み。失敗 outcome=`evidence_fail` → 書込なし(`pr.status="completed review"` のまま = 未解決 blocker が残る事実)で sink。**旧版の「書込まずスキップ + 再試行」は取らない** — `completed review` は reviewer が選別しないため round カウンタが進まず、round≥5 の停止条件に永久に到達しない無界ループになるため。

これで「どのロールの evidence 失敗も need for human review に到達し、無界ループを残さない」という対称性が、判定器の `route=sink` として一元化される(失敗経路の一元化)。

## 書込方式

`commands/harness-review-pr.md` の手順 3/6 と同じく、台帳 (`.harness/plan-progress.json`) は git にコミットしないローカル台帳として扱う(issue #11 F案)。状態遷移は「`ledger_write` の適用」手続きによる **ローカルファイル編集だけで完結させ、`git add` / `git commit` / `git push` は行わない**(main への直接 push を禁止するポリシーのリポジトリでもそのまま動く)。作業ツリー上で台帳が「変更あり」になるのは正常。

**台帳検証の自己申告(Statuses API)**: 状態遷移をローカルに書いたら、ローカル validator の実行結果を **対象 PR の head SHA** に対して Statuses API で報告する(「commit されない台帳」の機械検証の代わり。GitHub ホスト CI は commit されない台帳を検証できないため)。branch protection の required check はこの context(`harness-gate`)を指定する。Check Run 作成(Checks API)は GitHub App 認証専用で個人 `gh auth`(PAT/OAuth)では作れないため使わず、必ず **Statuses API**(`POST /repos/{owner}/{repo}/statuses/{sha}`)を使う。**この自己申告は独立検証ゲートではなく便宜シグナル(convenience signal)である**(spoof 可能・独立ランナー不在の受容コスト。詳細と限界は `.harness/CLAUDE.harness.md`「台帳の書込経路」節)。

schema/drift のローカル実行 → Statuses API への post は **`scripts/report-ledger-status.sh` に抽出済み**(`commands/harness-review-pr.md` 手順 3/6 と共有する単一の実体。報告ロジックを散文に複製しない — `scripts/*.py` と同じ「規則は script が正」の境界)。スクリプト内で `ROOT="$(git rev-parse --show-toplevel)"` から `PLAN` / validator を**すべて絶対パス**で解決するため、CWD が repo ルート以外でも失敗しない:

```
# <head_sha> は対象 PR の head SHA (gh pr view <n> --repo <repo> --json headRefOid --jq .headRefOid)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/report-ledger-status.sh" "<repo>" "<head_sha>"
# 引数: $1=<owner/repo> $2=<head_sha> [$3=context(省略時 harness-gate)]
# schema/drift をローカル実行し、結果(success/failure)を対象 SHA へ Statuses API で post する
```

## 既知のリスク(明示)

**issue #11(台帳の git 非依存化・main push 禁止ポリシー)の F案は実装済み**(本節が旧 v1 で「既知の負債」として予見していた自己無効化)。orchestrator の単一書込は、旧方式(main 直接コミット + push)から **ローカルファイル編集 + Statuses API 自己申告**(上記「書込方式」節)へ追従済み。台帳が commit されなくなったことに伴い、git-status ガードは「clean 比較」ではなくスナップショット比較へ調整済み(「単一書込」節・「既知の制限・拡張ポイント」節 (b))。

## 報告

`commands/harness-review-pr.md` 手順 8 に倣い、tick サマリを分かりやすく出す:

````markdown
## 🚦 Orchestrator tick 報告

**実施: HH:MM**(local time)

### 📊 dispatch サマリ(N 件、上限 5)

| step | ロール | 遷移前 → outcome → 書込結果 | evidence gate | 失敗 sink |
|---|---|---|---|---|
| P8 | developer(実装役) | null → pr_evidence_pass → **書込済み(#N)** | ✅ exit 0 | — |
| P9 | developer(実装役) | null → pr_evidence_fail → **書込済み(#M)** | ❌ 非 0 | 🛑 need for human review 付与 + 通知済み |
| P13 | pr reviewer | created pr → clean_pass → **ready for merge** | — | — |
| P11 | pr reviewer | waiting for review → escalate → **need for human review へ書込済み** | — | 🛑 need for human review 付与 + 通知済み |
| P10 | pr reviewer | created pr → invalid(dispatch 失敗)→ **書込なし** | — | ⚠️ ラベル付与失敗(手動付与が必要) |
| P12 | developer(対応役) | completed review → evidence_fail → **書込なし** | ❌ 非 0 | 🛑 need for human review 付与 + 通知済み |
| P14 | developer(実装役) | ready for implementation → subjective_escalate(issue #31) → **書込なし(marker 永続 + notified 付与)** | — | 🔔 通知済み(ラベル対象 PR なし・主観的エスカレーション) |

**失敗 sink 列は無条件に「付与 + 通知済み」と書かない**(報告虚偽の防止)。sink 共通手続き手順 1 の `LABEL_OK` と通知の成否を**実際に反映**する: 付与成功時のみ「🛑 need for human review 付与 + 通知済み」、`add-label` 失敗時は「⚠️ ラベル付与失敗(手動付与が必要)」と正直に書く(上表 P10 が失敗例)。**PR が実在せずラベル付与そのものを行わない変則(`timeout`・実装役 `subjective_escalate`)は、「🛑 付与」/「⚠️ 失敗」のいずれでもなく「🔔 通知済み(ラベル対象 PR なし)」と書く**(上表 P14 が例。この行が「🛑 付与 + 通知済み」になっていると、実際には付与していないラベルを付与済みと報告する虚偽になる)。

### ⏭️ スキップ(あれば)
- #M は `need for human review` ラベル付きのため無条件スキップ
- #K は復旧検索 0 件(`no_pr`・PR 未作成)のため書込せずスキップ(次 tick 再試行。`dispatchMarker` の締切 K=2 tick・リトライ上限 N=2 で有界化済み — issue #26)

### 🛑 失敗 sink 到達(あれば)
- #N: 理由(`escalate` 停止条件: round 上限到達 / blocker 傾向未改善 / reviewer dispatch 失敗(`invalid`・不正応答)/ 実装役 evidence 失敗(`pr_evidence_fail`)/ 対応役 evidence 失敗(`evidence_fail`)/ git status ガード検知 / `Closes #N` 復旧検索が複数一致(`ambiguous`)/ 実装役 dispatch が締切超過・リトライ上限到達またはマーカー不整合(`timeout`・issue #26。PR 未作成のためラベル付与なし・`dispatchMarker` の永続で無条件スキップ)/ 主観的エスカレーション(`subjective_escalate`・委譲先の自己申告。issue #31))

### ↩️ 誤判定の巻き戻し方
台帳の書込はローカルファイル編集のため、誤りがあれば手動で `pr.status` / `issue.status` を巻き戻し、`need for human review` ラベルを外して、次 tick で再評価させる。
````

0 件 tick の場合は「dispatch 対象なし」の 1 行報告に簡略化する。

## loop での回し方

- 試行: `/loop 15m /harness-orchestrate`(review-mode=code-review 既定、15 分間隔)。
- review-mode を明示したい場合: `/loop 15m /harness-orchestrate owner/repo multi-angle`。
- `/loop` は起動時の引数をそのまま毎 tick 再実行するため、review-mode は起動時の引数が毎 tick 引き継がれる。追加の状態保持は不要。

## 既知の制限・拡張ポイント

- **真の無人化はまだできない**: `/loop` はセッションが開いている間だけ定期実行できる方式であり無人ではない。GitHub Actions `on: schedule` / `/schedule` クラウド routine による真の無人化は、判定 skill(`reviewing-multi-angle` 等)の kit 同梱が前提になるため別途対応が必要(現行は個人 skill 依存または `/code-review` 単体のみ)。
- **issue #11 の F案は実装済み**: 上記「既知のリスク」節参照。orchestrator の単一書込は ローカルファイル編集 + Statuses API 自己申告へ追従済み(main への直接 commit/push はしない)。
- **issue サイド(issue reviewer / issue review worker)の自動化は対象外**: v1 は PR ライフサイクルのみ。issue フェーズの配車は別 issue の範囲。
- **git-status ガードの限界と設計境界(部分的バックストップ・正直な明記)**: 台帳保護には次の点がある。
  - **(a) subagent の worktree 編集は捕捉できない**: 実装役 subagent は自前の worktree で作業するため、その `.harness/` 編集は orchestrator 自身の checkout で走る `git status` からは**見えない**。したがってこのガードは **orchestrator 自身の checkout 内の編集しか捕捉できない部分的バックストップ**に過ぎない。**台帳保護の主たる防御は「subagent に `Write` を渡さない」ツール制限**であって、git-status ガードはその補完(検知したら失敗 sink へ)。`Bash` 経由の編集は完全には防げず、hook 等による L3 相当の強制ではない。
  - **(b) 自身の書込の誤検知を避ける(ローカル編集方式)**: ローカル編集方式(F案)では orchestrator 自身の書込は commit されず作業ツリーに残り続ける(`.harness/plan-progress.json` は常に dirty)。この自分の書込を subagent の変更と**誤検知しない**よう、ガードは `git status` の dirty 判定ではなく、`plan-progress.json` については **orchestrator が最後に書いた内容のスナップショットと照合**し、`.harness/` のそれ以外のファイルのみ `git status` で HEAD 一致を確認する。orchestrator は自身の各書込の直後にスナップショットを更新する(「dirty = subagent の意図しない変更」と短絡しない — 誤検知で無関係 step を spurious に sink 隔離するのを防ぐ)。
  - **(c) git-status ガードだけが decision script を通らない唯一の失敗経路(設計境界・意図的)**: 他の全失敗面は「ルーティング判定」節の decision script が `route=sink` として決めるが、git-status ガードの drift 検知 → sink だけは script を経由しない。これは意図的である — **git-guard trip は「(role, outcome) に紐づくルーティング判断」ではなく、全ロール横断(cross-cutting)の pre-write 前提チェックであり、その帰結は自明に sink(分岐する判断ロジックが無い)ため decision script の対象外とする**(decision script はルーティング「判断」を集約するものであって、判断の無い自明な guard→sink はその対象ではない、という設計境界)。無理に決定表へ押し込まない。
- **dispatch 上限 5 件のトレードオフ**: 1 tick で処理しきれない場合は次 tick へ持ち越される(dedup は各ロールの status 遷移が担う)。**「tick 冒頭 reconciliation」の `redispatch` 候補もこの上限の対象**(「選別(jq)」節参照)であり、枠から溢れた候補は marker を書き換えずに持ち越されるため retry_count は消費されない。
- **ルーティングは tested decision script**: (role, outcome) → (ledger_write, route, label_action) を `scripts/decide-orchestrator-route.py` が決定論的に解決し、`tests/smoke/run-smoke.sh` [8] が全 (role × outcome) 14 行を網羅検証する(reviewer の `invalid` 分岐 / implementer の `timeout` 分岐(issue #26)/ 3 role 共通の `subjective_escalate`(issue #31)を含む)。散文分岐の取りこぼしを構造的に防ぐのが目的で、規則は script が正・prose は「outcome への解決」と「route の実行」だけを持つ。
- **`dispatchMarker` のライフサイクル(削除 / 永続 / 永続+`notified`)は machine-enforce されていない(既知のギャップ)**: 上記の decision script が検証するのは `(ledger_write, route, label_action)` の 3 つだけで、実装役の各 outcome が marker をどう扱うか(手順 6 の 3 分類)は `DECISION_TABLE` にも `tests/smoke/run-smoke.sh` にも反映されておらず、手順 6 の固定列挙(prose)だけが正である。これは意図的な現状維持であり、次の理由による: (i) `dispatchMarker` は issue #26 の決定により schema 非宣言・transient なフィールドであり、`validate-plan-progress.py` の対象外(marker の**存在確認・妥当性**は `reconcile-dispatch-marker.py` が既に smoke [9] で網羅検証しているが、これは「marker が有効か」の判定であって「outcome ごとにどう処理すべきか」の判定ではない — 後者を machine-enforce するには decision script の出力契約(`ledger_write`/`route`/`label_action`)を拡張する必要があり、これは 1 フィールド追加では済まず、`decide-orchestrator-route.py` の 14 行・smoke [8] の `assert_route` 全件・「ルーティング判定」節の適用手続き・reconciliation の timeout 分岐(現状 decision script を経由しない別経路)を横断する変更になる。(ii) issue #31 は「主観的エスカレーション経路の追加」がスコープであり、marker ライフサイクルの machine-enforce 化はそれ自体別の改善提案として independently 評価すべき設計変更である。手順 6 を固定列挙(性質ベースの一文ではなく `no_pr`/`ambiguous`/`pr_evidence_pass`/`pr_evidence_fail`/`subjective_escalate` の個別列挙 + 新 outcome 追加時の追記指示)に変更したことが、今回のスコープで取れる現実的な緩和策である。**同種の欠落(散文の一般化が実際の分類を誤る)が今後も観測される場合は、decision script の出力契約への `marker_disposition` 相当フィールド追加を検討する。**
- **issue #26 との共有面(既知の drift リスク)**: `scripts/decide-orchestrator-route.py` の `DECISION_TABLE` と `tests/smoke/run-smoke.sh` [8] は issue #26(dispatch した子の生存監視と失敗の有界化)とも共有ファイルであり、両 issue が独立に `implementer` 行へ新エントリを追加する。詳細と rebase 時の注意点は「主観的エスカレーション(issue #31)」節の「issue #26 との共有面」を参照。
- **失敗経路は単一 sink に集約(重要)**: 実装役・対応役・reviewer のどの経路でも「前進不能 = need for human review sink 到達」で対称に扱う。reviewer も `escalate`(停止条件)に加え `invalid`(dispatch 結果失敗)を持ち、単一 sink をすり抜けない。個別ロールに独自の失敗処理(片方だけ有界停止・片方は無界ループ)を持たせない。書き込む事実 status だけがトリガーごとに異なる(「失敗経路(単一の need for human review sink)」節の一覧表を参照)。**実装役の `no_pr` はこの対称性の唯一の例外だったが、issue #26(P1 決定)で解消済み**(下記「実装役の `no_pr` の有界化(issue #26)」参照)。
- **対応役の無作業検知は escalate backstop に委ねる(意図的な既知の限界)**: 対応役だけは dispatch 結果失敗の即時検知分岐を持たない(最後の非対称)。subagent が **無作業/クラッシュでも test が元々緑なら `evidence_pass` → `waiting for review`** へ進む(偽の前進)。実装役(復旧検索)・reviewer(`invalid` 検知)が dispatch 失敗を即座に sink するのに対し、対応役の無作業だけ検知が **~3 round 遅延する**という latency の非対称が残る。ただし finding 未対応なら reviewer が同じ blocker を再検出 → `completed review` へ戻す往復が続き、**escalate backstop(round≥5 / blocker trend)が最終的に人間へ surface する**。これは bounded(`has_blocker=true` 維持で `clean_pass`=不正 merge には至らない)であり、walking skeleton では検知機構を足さず backstop に委ねる(作者の意図的判断)。実害(無作業 dispatch が頻発)が観測されたら follow-up で対応役の作業有無(`# PR Review Worker` コメント / commit の有無)検証を足す(対応役 flow の該当箇所にも同旨を明記済み)。
- **実装役の `no_pr` の有界化(issue #26・P1 決定で解消済み)**: 実装役 dispatch 後に PR が未作成(返答不正 + `Closes #N` 復旧検索 0 件)なら outcome=`no_pr` → route=skip で書込・副作用なく次 tick 再 dispatch される点は変わらないが、**issue #26 の「tick 冒頭 reconciliation」節の in-flight マーカー機構(締切 K=2 tick・リトライ上限 N=2)がこれを有界化する**。P1 決定(所有者判断・2026-07-14)により「無状態 tick では『完了して no_pr』と『まだ処理中』を区別できない」ため、`no_pr` は独立カウンタ(`no_pr_count`)を持たず、**締切超過(timeout・真の hang)と同じ `retry_count` に畳み込んで数える**。持続的な原因(issue が実装不能 / developer subagent が決定論的にクラッシュ)でも、最大 N=2 回のリトライ(計 3 dispatch)後は outcome=`timeout` として sink へ到達する。**本コマンドが掲げる「無界ループを残さない / 失敗経路を対称に扱う」不変条件の唯一の(文書化された)例外はこれで解消された**(旧版はこの段落で `no_pr` を無界の既知の限界と明記していたが、issue #26 の実装後は該当しない)。
  - **残る限界(issue #26 v1 のスコープ・意図的)**: (i) dispatch call 自体がセッションを止める**真の hang**は、`Agent` ツールにタイムアウト parameter が無い制約が変わらないため、リアルタイムには検知できない(marker が dispatch 直前に書かれているため、**人間がセッションを再起動した次の tick**で `TICK > deadline_tick` として事後検知される — tick を跨いだ persistent state による回復であり、hang 中のリアルタイム検知ではない)。(ii) `dispatchMarker`(`dispatched_tick`/`deadline_tick`/`retry_count`、および sink 通過後に追加される任意キー `notified`)は transient フィールドで schema に宣言せず、`validate-plan-progress.py` の `--schema`/`--drift`・`tests/smoke/run-smoke.sh` の複製一致検査のいずれも検査対象にしない(壊れた/不整合なマーカーへの fail-closed 判定は `reconcile-dispatch-marker.py` 自身の責務であり、この判定ロジック自体は smoke `[9]` で網羅検証している。`notified` は script が読まない prose 専用の帳簿フィールドであり script の妥当性検査の対象外)。(iii) implementer/`timeout` の sink は PR が存在しないため `need for human review` ラベルを付与できず(`ambiguous` と同じ制約)、「無条件スキップ」は永続する `dispatchMarker` 自体が実装する — 人間の解除手段はラベル解除ではなく `dispatchMarker` の手動削除(「tick 冒頭 reconciliation」節参照)。(iv) `ambiguous` outcome 自体の再 dispatch 有界化は本 issue のスコープ外(手順 7 の原子書込で `dispatchMarker` を削除し、marker による有界化の対象外にする — 挙動は issue #26 以前と変わらない)。(v) K=2 tick / N=2 の値は校正根拠の無い best-effort(loop 間隔が実装役の想定所要より十分長い前提)であり、観測に応じた見直しは follow-up。
- **sink の出口を人間の意図と結線(issue #12 で実装済み)**: 「失敗経路(単一の need for human review sink)」節の**「sink の出口を人間の意図と結線」**を参照。reviewer/`escalate` は `pr.status="need for human review"` を書いてから sink するため、ラベル解除だけでは再 dispatch されない(status も人為的に戻す必要がある)。この結線の恩恵は `escalate` 経路のみで、`invalid`(dispatch 結果失敗)は引き続き無書込のまま(書ける確定事実が無いため)。
- **ラベル同期ロジックの複製(drift リスク)**: 本コマンドのラベル同期ロジック(「ルーティング判定」節の `label_action の実行`)は `commands/harness-review-pr.md` 手順 6 の内容を単一書込の都合上複製している。将来どちらかの label 定義(色・説明・名称)を変更する場合は両ファイルを同時に更新すること(自動で同期されない、既知の drift リスク)。
