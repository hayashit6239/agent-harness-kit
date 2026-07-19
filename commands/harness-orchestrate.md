---
description: 対象 repo の .harness/plan-progress.json を単一の書込主体として、developer(実装役・対応役)と pr reviewer の 2 ロールを配車する orchestrator(v1 walking skeleton・PR ライフサイクルのみ)。判断ロジックは一切持たず、既存の判定 skill/command(`/code-review` または `reviewing-multi-angle` 経由の `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md`)に委譲し、返答を検証してから台帳へ書き込む。前進できない状況は原因を問わず単一の失敗経路(need for human review sink)に集約する。ルーティング(台帳書込・sink・ラベル操作)は各ロールが状況を outcome トークンに解決したうえで tested decision script(`scripts/decide-orchestrator-route.py`)で決定論的に解決し、規則を散文に複製しない。委譲先ロール(実装役・対応役・pr reviewer)の作業レポート(`reports[]`)も、単一 writer 原則(`.harness/CLAUDE.harness.md`)に従い本コマンドが代筆する(issue #52 症状2)。**第 3 引数にゴール文言を渡すと、本コマンドの手順書内容を context にロード済みの状態で、失敗経路の 10 トリガーを反映した `/goal <文言>` コマンド文字列を組み立てて提示する(issue #60)。`/goal` の実行そのものは技術的制約により本コマンドから起動できないため、提示のみに留まる**。
argument-hint: "[owner/repo] [review-mode] [ゴール文言]  省略時: CWD の origin から自動判定 / code-review(opt-in: multi-angle) / 通常 tick 実行。ゴール文言(第3引数)指定時は /goal 起動文字列の組み立てのみを行う(review-mode を既定のままにしたい場合は $2 に \"\" を渡す)"
allowed-tools: [Bash, Agent, PushNotification, Skill, Read]
---

# /harness-orchestrate — developer / pr reviewer を配車する orchestrator(v1 walking skeleton)

これは **運用(policy)** の層であり、minimal 構成の上に乗る **orchestrator ロール**(Phase 1 の中核機構の最初の増分)。対象は **developer(実装役・対応役)と pr reviewer の 2 ロール、PR ライフサイクルのみ**(issue reviewer 側の自動化は対象外)。

## `/goal` 起動文字列の組み立て(issue #60)

実運用では、本コマンドの定期実行を `/loop` に任せるのではなく、Claude Code CLI の `/goal`(Stop hook 機構。各ターン終了時に小さい高速モデルがゴール条件の充足を判定し、未充足ならブロックして続行を強制する仕組み。https://code.claude.com/docs/en/goal )に「本コマンドの手順書を読み込んで停止条件つきで繰り返し実行する」文言を手打ちする運用へ実質移行している。この手打ちは (a) 本コマンドの手順書ロード指示と (b) 停止条件の列挙、の 2 手を毎回繰り返す無駄があり、かつ (b) は下記「失敗経路(単一の need for human review sink)」節がすでに持つ包括的なトリガー一覧の narrow な re-implementation になりがちで drift しやすい。本コマンドは第 3 引数にゴール文言を渡すことでこの 2 手を 1 手(組み立て結果のコピー&ペースト)へ縮める。

**技術的制約(正直な明記)**: 本コマンドは `/goal` を完全にはラップできない。skill/command の実行は 1 ラウンドで完結し、そこから hook 設定を動的に書き換えてターン継続を強制する公式な経路が無い(claude-code-guide エージェントが公式ドキュメントを参照して確認済みの制約)。したがって本コマンドが行えるのは「`/goal` に渡す文字列の組み立てと提示」までであり、**`/goal` の実行そのものは引き続きユーザーの手操作を要する**(2 手が 1 手になるだけで 0 手にはならない)。

**引数**: `$1`=owner/repo(省略時 CWD の origin から自動判定)、`$2`=review-mode(省略時 `code-review`)、`$3`=ゴール文言。bash の位置引数は途中を省略できないため、review-mode を既定のまま `$3` だけ渡したい場合は `$2` に空文字を明示する(例: `/harness-orchestrate owner/repo "" "issue #42 を ready for implementation になるまでレビュー・対応を繰り返して"`)。空文字であれば「配車テーブル」節の既存展開 `REVIEW_MODE="${2:-code-review}"` がそのまま既定値にフォールバックするため、既存の展開ロジックの変更は不要。

**`$3` が与えられた場合**: 本コマンドは通常の tick(下記「配車テーブル」以降の手順)を実行**しない**。代わりに次を行う:

1. 本ファイル(このコマンドの手順書)は、このコマンド自体の実行によって既に context にロード済みである。追加のファイル読込は不要。
2. 下記「失敗経路(単一の need for human review sink)」節の**この sink にルーティングされるトリガー**表(decision script 経由の sink 9 種 + git-status ガード 1 種 = 合計 10 種)を、簡潔な自然文の停止条件へ変換する。表の `role/outcome` トークンや書込 status 列はそのまま `/goal` 文字列へ転記しない — 表の「トリガー(状況)」列の文言を平易な日本語で言い換える。
3. `$3` のゴール文言と、変換した 10 個の停止条件を、次のサンプルと同じ構造で 1 つの `/goal` コマンド文字列に組み立てる:

   ```
   /goal 「issue #42 を ready for implementation になるまでレビュー・対応を繰り返して。次のいずれかに該当したら停止して人間に報告して: reviewer dispatch が escalate=true を返した(round/trend 停止条件)/ reviewer dispatch の返答が JSON でない(dispatch 結果失敗)/ 実装役 dispatch 後の evidence gate 失敗 / 対応役 dispatch 後の evidence gate 失敗 / 実装役の pr_number 復旧検索が複数一致(曖昧)/ 実装役の in-flight マーカーが締切超過でリトライ上限到達(timeout)/ 実装役・対応役・reviewer いずれかが主観的エスカレーションを返した / git-status ガードが .harness/ への意図しない変更を検知した」
   ```

   サンプルの「issue #42 を ready for implementation になるまでレビュー・対応を繰り返して」の部分を `$3` の内容に差し替え、停止条件の並びはサンプルの粒度(10 トリガーを 8 文で言い換えた簡潔な自然文の列挙 — `subjective_escalate` は実装役・対応役・reviewer の 3 経路をまとめて 1 文にできる)に揃える。
4. 組み立てた `/goal <文言>` をそのままコピー&ペーストできる形で提示して終了する。**このコマンド自身は `/goal` を実行しない**(実行はユーザーの操作)。

**`$3` が省略された場合**: 従来どおり、本コマンドは 1 回の orchestrator tick を実行する(以下の手順)。

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
- **限界を正直に明記する(理由の framing を実態に合わせる。issue #37・欠落 9)**: `Write` を渡さないこと自体は**隔離にならない**。「`Agent` ツールは `subagent_type` しか指定できずツールを絞れない」という理由付けは不正確 — `.claude/agents/*.md` 定義でツール集合を絞った custom subagent_type は作れる(ただし ad-hoc per-call では絞れない)。本質は、subagent には `gh` コマンド実行・`reaggregate-has-blocker.py` 実行のため **`Bash` が必須**であり、**`Bash` を持つ子は `jq` / python 等 `Bash` 経由で台帳ファイルを直接編集できる**ため、`Write` を除外しても台帳保護の隔離にはならない点にある。したがって台帳保護の実質は下記「技術的バックストップ(git status ガード)」(部分的バックストップ)と、各ロール委譲プロンプト**冒頭**の禁止文言(L1)のみに依存する。追加の構造防御(hook 等の L3 相当の強制)は `Agent` ツールに環境隔離が入るまで別 issue とし、主防御の不在をここで正直に受容する(「既知の制限・拡張ポイント」節にも同旨を明記)。
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

  **同時配車(issue #51)下での一般化(dispatch 単位ではなく「各書込の直前直後」で運用する)**: 「実行ループ(同時配車)」節のとおり同一 tick 内で複数候補の手順 1〜8 が独立に進む場合、PRE/POST ガードは**候補ごとに個別**に運用する。tick 冒頭で 1 度だけ控えた PRE、あるいは他候補向けに控えた PRE を同一 tick 内の複数候補で使い回さない — 使い回すと、後述のとおり台帳書込自体は候補間で逐次実行されるため、**別候補の正当な書込(その候補自身の手順 1 の marker 書込や手順 7 の `ledger_write` 適用)が自分の PRE→POST 間に挟まり、それを subagent の改変と誤検知してしまう**。適用する原則は 1 件処理時と同一(「その候補自身の直前の正当な書込が完了した直後に PRE を控え直す」)であり、これを**候補ごとに個別**に行うだけである: 各候補について、その候補自身の手順 1(marker 書込)が完了した直後にその候補専用の PRE を控え、その候補自身の手順 6/7(marker 削除・`ledger_write` の適用)の直前に POST を照合する。台帳書込そのものを候補間でどう逐次化するかは「実行ループ(同時配車)」節を参照(規則の重複を避けるため、ここでは PRE/POST ガードの運用細則のみを扱う)。

## 失敗経路(単一の need for human review sink)

**原則: orchestrator が step を安全に前進させられない状況は、原因を問わず単一の失敗経路に集約する。** すなわち **`need for human review` ラベル付与 + `PushNotification` + 事実に即した台帳書込(あれば)→ 以後その step は人間がラベルを外すまで配車テーブルで無条件スキップ**。実装役・対応役・reviewer 経路すべてで**対称に**扱う(どのロールでも「前進不能 = この sink に到達」であり、片方だけ有界停止・片方は無界ループ、という非対称を作らない)。**どの状況が sink に落ちるかは「ルーティング判定」節の decision script が `route=sink` として決める**(下表はその sink 経路を人間向けに列挙したもので、規則そのものは script が正)。

### この sink にルーティングされるトリガー(全経路の一覧)

| トリガー(状況) | role/outcome(判定器トークン) | この sink で書き込む事実 status |
|---|---|---|
| reviewer dispatch が `escalate=true` を返した(round/trend 停止条件) | reviewer/`escalate` | `pr.status="need for human review"`(停止条件到達の事実。1 回のローカル書込後に sink) |
| reviewer dispatch の返答が JSON でない / `escalate` を読めない(dispatch 結果失敗) | reviewer/`invalid` | `pr.status` への書込なし(dispatch 失敗のため状態を変えない。dispatch 元のまま)。ただし dispatch 直前に書いた `reviewLock`(issue #37)は解除する |
| 実装役 dispatch 後の evidence gate 失敗 | implementer/`pr_evidence_fail` | `pr.number` + `pr.githubState="open"` + `pr.status="created pr"`(PR は実在するという事実。1 回のローカル書込後に sink) |
| 対応役 dispatch 後の evidence gate 失敗 | responder/`evidence_fail` | `pr.status` への書込なし(`completed review` のまま。未解決の review blocker が残っているという事実)。ただし dispatch 直前に書いた `reviewLock`(issue #37)は解除する |
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

1. `need for human review` ラベルを PR に付与する。**必ず create(fallback・冪等)を先、add を後の順で実行し、`add-label` の exit code を確認する**(`gh` はラベル未存在の状態で `add-label` するとエラーになるため。同ファイル内「ルーティング判定」節の `ready for merge` ラベル操作と同じ順序に揃える。色・説明は `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` 手順 6 の `ready for merge` ラベル作成パターンに倣う):
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

各ロール節の post-dispatch 処理は、**状況を outcome トークンに解決 → `${CLAUDE_PLUGIN_ROOT}/scripts/decide-orchestrator-route.py` を呼ぶ → 返った `{ledger_write, route, label_action}` を実行**、という構造に統一する。**ルーティング規則(どの (role, outcome) がどう書くか・どの route か・ラベルをどう操作するか)は script が唯一の正**であり、prose に決定表を複製しない(`evaluate-stop-condition.py` / `reaggregate-has-blocker.py` と同じ「規則は script・prose は I/O」境界)。prose が担うのは (1) 状況を outcome へ解決する方法(各ロール節)と (2) 返った route / label_action の**実行方法**(本節)だけ。**この I/O の形(入力 `{role, outcome, observation?}` / 出力 `{ledger_write, route, label_action}`)の型/形の正は `contracts/orchestrator-route.schema.json`**(issue #68 で抽出。ルーティング規則そのもの = どの outcome がどう解決するかは引き続き script の `DECISION_TABLE` が正で、schema は形のみを規定する)。

- **呼び方(`observation` を含む。issue #50 A1)**: 解決した outcome の route が `sink` になる(下記 outcome トークン一覧のうち sink 系 — 各ロール節で個別に列挙する)場合、判定入力に `observation`(観測した事実: 実行したコマンド・終了コード・出力要約)を必須で添える。**無いと判定器は exit 2 で拒否する(fail-closed)** — 詳細・spoof 可能性の正直な明記は `scripts/decide-orchestrator-route.py` のモジュール docstring「観測必須フィールド (A1)」を参照(規則はそちらが正・ここに複製しない)。sink でない outcome には `observation` は不要(渡さない)。呼び方はロール共通で次の 1 手続きに統一する。

  **`<command>`/`<summary>` はシェル変数へ heredoc 経由で代入してから渡す(issue #59 round1 🔴1)**: `<command>`(例: `gh pr list --search '"Closes #<N>" in:body' ...` のような二重引用符入りの値)・`<summary>` は自由文であり、任意の引用符を含みうる。これを下の呼出テンプレートの引数位置へ**文字列として直接書き込む**(例: `"gh pr list --search '"Closes #<N>" in:body' ..."` とテンプレートの `"<command か空文字>"` を置換する)と、値の中の `"` がテンプレート側の外側引用符を早期に閉じてしまい、(1) `python3 -c` の argv 分解が壊れて `ValueError` で例外終了する、または (2) bash 変数代入位置で埋め込むと構文が壊れ値が無言で切り詰められる(いずれも実測済み)。**これを避けるため、`<command>`/`<summary>` は先に quoted heredoc でシェル変数へ代入し、呼出には `"$OBS_CMD"` / `"$OBS_SUMMARY"`(変数展開)だけを使う** — heredoc の delimiter を単一引用符で囲む(`<<'OBS_CMD_EOF'`)と本文中の `$` `` ` `` `"` `'` はすべて非展開のリテラル文字として扱われるため、値に何が入っていてもエスケープ不要になる(`"$VAR"` 展開自体は bash の基本動作として、変数の中身をどんな文字が入っていても単一の引数としてそのまま渡す — 壊れるのは値をテンプレートへ literal に書き写す手順の側であって、変数展開そのものではない)。`<role>`/`<outcome>` は固定トークン(`implementer`/`ambiguous` 等)、`<exit_code>` は整数のみなので、引用符を含まずこの保護は不要 — 従来どおりテンプレートへ直接書いてよい。sink でない outcome を解決したときは `<command>` が空文字なので heredoc は使わず `OBS_CMD=""` `OBS_SUMMARY=""` と直接代入すればよい(空文字に引用符崩壊のリスクは無い):
  ```
  # sink 系 outcome を解決したときだけ実行する(sink でなければ OBS_CMD="" / OBS_SUMMARY="" でよい)
  OBS_CMD=$(cat <<'OBS_CMD_EOF'
  <command か空文字>
  OBS_CMD_EOF
  )
  OBS_SUMMARY=$(cat <<'OBS_SUMMARY_EOF'
  <summary か空文字>
  OBS_SUMMARY_EOF
  )
  ROUTE=$(python3 -c '
  import json, sys
  role, outcome, cmd, code, summary = sys.argv[1:6]
  payload = {"role": role, "outcome": outcome}
  if cmd:
      payload["observation"] = {"command": cmd, "exit_code": int(code), "summary": summary}
  print(json.dumps(payload))
  ' "<role>" "<outcome>" "$OBS_CMD" "<exit_code か 0>" "$OBS_SUMMARY" \
    | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/decide-orchestrator-route.py")
  # -> {"ledger_write": <null|{...}>, "route": "normal|skip|sink",
  #     "label_action": "null|add_ready_for_merge|remove_ready_for_merge"}
  ```
  **各ロール節が定義するのは `<command>/<exit_code>/<summary>` に何を渡すかだけ**(sink 系 outcome ごとに、その outcome を解決した手順で既に確定している値を使う — この判定のために新たに何かを実行観測する必要は無い)。**この呼び方(heredoc → `OBS_CMD`/`OBS_SUMMARY` → `"$OBS_CMD"`/`"$OBS_SUMMARY"` 展開)はロール共通の唯一の正であり、各ロール節(実装役手順 7 を含む)はこれを複製せずここを参照する。** script が exit 2(`observation` 欠落・不備を含む)を返した場合の扱いは下記のとおり。

  outcome トークン(role ごと。全網羅は `tests/smoke/run-smoke.sh` [8] が決定論検証):
  - **implementer**: `no_pr`(返答不正 かつ 復旧検索 0 件)/ `ambiguous`(復旧検索 複数件)/ `pr_evidence_pass`(pr_number 確定 かつ evidence exit 0)/ `pr_evidence_fail`(pr_number 確定 かつ evidence 非 0)/ `timeout`(issue #26: 「tick 冒頭 reconciliation」節の in-flight マーカーが締切超過でリトライ上限 N=2 に到達、またはマーカーが壊れている/不整合)/ `subjective_escalate`(issue #31・PR 未作成のまま `escalate_to_human` を返した)
  - **responder**: `evidence_pass` / `evidence_fail` / `subjective_escalate`(issue #31)
  - **reviewer**: `invalid`(返答が JSON でない・`escalate` を読めない=dispatch 結果失敗)/ `escalate`(escalate=true)/ `clean_pass`(escalate=false かつ has_blocker=false)/ `blockers`(escalate=false かつ has_blocker=true)/ `subjective_escalate`(issue #31・客観的な `escalate` とは別に `escalate_to_human` を返した)

  **3 role 共通の `subjective_escalate` の解決方法(issue #31・詳細は「主観的エスカレーション」節)**: 各ロールの dispatch 応答が `escalate_to_human: {reason}`(`reason` は空でない文字列)を含む場合、その他の分岐より**先に** outcome=`subjective_escalate` へ解決する。**この検出条件(JSON として解釈できるか・`escalate_to_human.reason` の有無)の唯一の正はここに置き、各ロール節(実装役手順 3・対応役手順 3・reviewer 手順 2)では複製せずここを参照する**(役割ごとに異なるのは「他の分岐より先に判定する」という優先順位の適用箇所と「解決後にどの手順へ進むか」だけで、検出条件自体は共通)。`reason` の形式検証(空・欠損・非文字列なら無視してフォールバック)は「主観的エスカレーション」節の「最小の形式検証(A案)」を参照(判定ロジックの唯一の正はそちらに置き、ここでは複製しない)。

  script が exit 2(role enum 外 / outcome が role に対応しない / 必須キー欠損 / **sink 系 outcome で `observation` が欠落・不備(issue #50 A1)**)なら、その step の処理を止め状態を報告する(黙って散文判定に切り替えない — `reaggregate-has-blocker.py` の扱いと同じ)。

- **`ledger_write` の適用(status リテラルは decision script が唯一の正)**: decision script の出力(`$ROUTE`)から `ledger_write` を取り出し、**非 null ならその中のキーだけを台帳へ書く**(script が返したフィールドのみ・**prose 側で status 文字列をハードコードしない**)。`null` かつ `<clear_marker>` も `false`(既定)なら台帳書込なし。**`null` でも `<clear_marker>`="true" が渡された場合は marker の削除だけを行う**(実装役の `ambiguous` outcome、および pr reviewer/対応役の `reviewLock` 解除がこれに該当。詳細は下記手続き参照)。ロールごとに書くフィールドが異なる(実装役=number+githubState+status / 対応役・reviewer=status のみ)ため、**`ledger_write` のキー集合に応じて書込を動的に組み立てる**。キーの解釈は 2 通りだけ:
  - `"pr.number": true` → orchestrator が保持する実 `pr_number` を書く(script は番号を知らないので真偽フラグ。この 1 点だけ prose が実値を供給する)
  - `"pr.githubState"` / `"pr.status"` → script が返したリテラル値をそのまま書く

  抽出と適用は次の 1 手続きで行う(`<step id>` は対象 step、`<pr_number>` は orchestrator が保持する確定番号。`pr.number` を含まない経路では空文字でよい。`<clear_marker>` は省略可・既定 `false` — `true` を渡すと同じ書込内で marker キーも削除する。`<marker_field>` は省略可・既定 `"dispatchMarker"`(issue #37 で追加した 6 番目の引数 — pr reviewer / developer(対応役)が `reviewLock` を解除する際に `"reviewLock"` を渡す。実装役の既存呼出は省略のままで挙動不変)。実装役の `pr_evidence_pass`/`pr_evidence_fail`/`ambiguous` がこれを `<clear_marker>`="true" で呼ぶ理由は「developer(実装役)」手順 6 参照 — `ambiguous` は `ledger_write` が無い(=null)ため、他のフィールド書込を伴わない marker 単独削除としてこの同じ手続きで扱われる。**`subjective_escalate` はこの手続きを呼ばない**(marker を削除せず永続させるため。代わりに上記「`notified` フラグの付与」の手続きを使う — 詳細は「developer(実装役)」手順 6/7)。pr reviewer / developer(対応役)は全 outcome でこれを `<clear_marker>`="true" `<marker_field>`="reviewLock" で呼ぶ(「reviewer / 対応役の in-flight ロック」節参照)。`ledger_write` の全キー(と、渡された場合は marker 削除)を 1 回のファイル書込で適用するため原子的(`pr.number` だけ書いて `pr.status` 未書込という中間状態や、marker だけ消えて `pr.number` 未書込という中間状態を作らない):
  ```
  PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
  python3 - "$PLAN" "<step id>" "$ROUTE" "<pr_number>" "<clear_marker>" "<marker_field>" <<'PY'
  import datetime, json, os, sys
  argv = sys.argv[1:]
  if len(argv) > 6:
      # 決め打ちパースへの将来のパラメータ追加が黙って切り捨てられるのを防ぐ。
      print(f"::error:: ledger_write 適用: 引数が6個を超えている ({len(argv)}個)。"
            "この決め打ちパースにパラメータを追加した場合は本ブロックの更新が必要。", file=sys.stderr)
      sys.exit(2)
  argv = argv + ["false", "dispatchMarker"][len(argv) - 4:]  # <clear_marker>/<marker_field> 省略時の既定
  plan_path, step_id, route_json, pr_number, clear_marker, marker_field = argv[:6]
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
          step.pop(marker_field, None)        # marker 削除を ledger_write と同一書込で原子化 (issue #37: フィールド名を汎化)
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

- **`label_action` の実行**(reviewer 経路のみ非 null。`ready for merge` ラベルの同期。単一書込の設計上 pr reviewer subagent はラベルに触らせないため orchestrator が実コマンドとして持つ — `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` 手順 6 と同内容):
  - **`add_ready_for_merge`**:
    - ラベル作成 fallback(冪等): `gh label create "ready for merge" --color "0e8a16" --description "reviewer が merge 可能と判定した PR" --force`
    - `gh pr edit <n> --repo <repo> --add-label "ready for merge"`(冪等)
    - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(無ければ警告のみで実害なし)
  - **`remove_ready_for_merge`**:
    - `gh pr edit <n> --repo <repo> --remove-label "ready for merge"`(付いていなければ警告のみで実害なし)
    - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(無ければ警告のみで実害なし)
  - **`null`**: ラベル操作なし。

## tick 開始時の前提整備(issue #37・選別より前)

各 tick の選別(jq)より前に、次を 1 回実行する:

1. **`git fetch origin --quiet`**: `origin/main` のリモート追跡参照を最新化する。実装役 dispatch(「developer(実装役)」節手順 2)は `creating-git-worktrees` skill 経由で worktree を作成し、同 skill は既定(`worktree.baseRef=fresh`)で `origin/<default-branch>` から新しい branch を切る。この fetch を怠ると `origin/main` のローカル参照が古いままになり、そこから分岐した worktree も古い main を基点にしてしまう(実測: PR #36 が古い main(`3b38c55`)から分岐した)。fetch は取得のみで、常時 dirty な `.harness/plan-progress.json` を含むローカル main checkout には触れない — `git pull` / `git merge` / `git checkout` は行わない。
2. **freshness の確認は報告に留め、tick を止めない**: `git rev-list --count HEAD..origin/main` 等でローカル main checkout が `origin/main` からどれだけ遅れているかを把握し、遅れがあれば tick 報告に 1 行 surface する。**tick 全体は停止させない** — F案の台帳は常時 uncommitted-dirty で main 前進のたびに hard-stop すると `/loop` 運用で頻繁に停止するため。欠落 2 の根本対処は 1. の fetch により worktree 側が常に fresh になることで足りており、ローカル main checkout 自体を前進させる必要は無い。
3. **`git worktree prune`**: `.claude/worktrees/` の admin record 残骸を掃除する(欠落 8。前 tick の異常終了等で登録だけ残った worktree を除去)。実体ディレクトリがまだ残っている場合(`git worktree remove` 前に中断した等)は各ロール節の evidence gate 手順(手順 5)が同一パスへの `add` 失敗時に個別掃除するため、ここでの `prune` は admin record のみを対象とする軽量な前提整備に留める。

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
- **形の正は schema・検査対象外は維持**(issue #68 で issue #26 の「schema 非宣言」から変更): このマーカーの型/形は `plan-progress.schema.json` の `definitions.dispatchMarker`(`step.properties.dispatchMarker` から `$ref`)を単一の正とする(ここでは二重定義しない)。宣言は **optional**(`step.required` に含めない)で、`step` の `additionalProperties` も制限しないため、issue #26 決定「transient なフィールドは validator/drift/smoke の検査対象外に留める」の実効はそのまま維持される(この宣言を足しても `--schema` / `--drift` / smoke の検査挙動は不変)。
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
  - **`sink`**(`reason` が `retries_exhausted`(リトライ上限 N=2 到達)または `invalid_marker`(マーカーが壊れている/不整合・fail-closed)): outcome=**`timeout`** として判定器(role=implementer)を呼ぶ(`decide-orchestrator-route.py` の implementer/`timeout` 行。`ledger_write` は null — PR がまだ存在しない `ambiguous` と同型)。**`observation`(issue #50 A1)**: `timeout` も sink 系のため観測必須。`<command>`="reconcile-dispatch-marker.py の判定"・`<exit_code>`=0(script 自体は正常終了している)・`<summary>`=`$reason`(`retries_exhausted` または `invalid_marker`。「ルーティング判定」節「呼び方」の共通手続きに従う)を渡す。**この観測は新たな独立検査ではなく、`reconcile-dispatch-marker.py` が既に下した判定(有界リトライ機構そのもの)を記録するに留まる** — timeout の真偽(hang か否か)は無状態 tick では原理的に観測不能(issue #26 P1 決定)なため、A1 が timeout に対して上げるのは「sink 判断の根拠を必ず記録させる」捏造コストのみで、それ以上の独立性は持たない(正直な限界の明記)。「失敗経路(単一の need for human review sink)」の**変則**として次のとおり扱う(通常の sink 共通手続きとの差分):
    - **ラベル付与は行わない**(PR が存在しないため `gh pr edit --add-label` の対象が無い。`ambiguous` と同じ制約)。
    - `PushNotification` を行う(内容: 「issue #<N> の実装役 dispatch が締切超過でリトライ上限(N=2)に到達した」または「issue #<N> の in-flight マーカーが不整合」)。**この通知と同じタイミングで、「ルーティング判定」節の「`notified` フラグの付与」手続きを実行する**(`dispatched_tick`/`deadline_tick`/`retry_count` の既存 3 キーは変更せず `notified: true` を追加のみ。`reconcile-dispatch-marker.py` の marker 妥当性検査はこの 3 キーの存在・型しか見ないため、追加の `notified` キーは判定に影響しない)。これにより次 tick 以降は上記「`notified` 済みマーカーの早期スキップ」に該当し、この sink は tick をまたいで**一度だけ**通知される(通知の無限反復を防ぐ)。
    - **`dispatchMarker` は消さず残す**(この持続状態自体が「無条件スキップ」の実装 — 次 tick 以降は `notified: true` により復旧検索・script 呼出そのものをスキップするため、無期限の GitHub 検索の繰り返しも止まる。ラベルが無くても選別ガードは marker の存在自体で恒久的にこの step をスキップする)。
    - **人間の解除手段**: ラベル解除に相当する操作は「対象 step の `dispatchMarker` を手動で削除する」(根本原因(issue 実装不能等)を先に解消してから削除するのが通常の流れ)。orchestrator 側に自動解除ロジックは持たない(既存の「ラベルの解除は人間が手動で行う」原則と同型)。

これにより `no_pr` の連続発生(P1 決定により timeout と同じカウンタに畳み込む)も真の締切超過(hang)も、**同じ `retry_count` で最大 N=2 回(初回 + 2 リトライ = 計 3 dispatch)まで有界リトライし、尽きたら sink する**(「有界停止の保証」節の唯一の例外だった `no_pr` はこれで解消)。dispatch call 自体がセッションを止めてしまう真の hang(`Agent` ツールにタイムアウト parameter が無い制約は変わらない)は、marker が dispatch 直前に書かれているため、**人間がセッションを再起動した次の tick**で `TICK > deadline_tick` として検知される(tick を跨いだ persistent state による回復。dispatch 中の hang をリアルタイムに検知する機構ではない — 「既知の制限・拡張ポイント」節参照)。

## reviewer / 対応役の in-flight ロック(lock-only・issue #37)

**目的**: pr reviewer / developer(対応役)の dispatch にも、実装役の `dispatchMarker`(issue #26)と同じ「重複配車防止」が要る(欠落 1)。ただし目的は選別排他ロックのみで、実装役が持つ締切・有界リトライ(`deadline_tick`/`retry_count`)は要らない — reviewer/対応役には `no_pr` 相当の無界駆動因(dispatch 後の完了未確認状態が跨 tick で残る)が無く、dispatch は `Agent` ツールの blocking call として同一 tick 内で outcome まで解決するため、liveness/timeout の機構を持ち込むと over-engineering になる。実装役の `dispatchMarker` をそのまま転用しない理由もここにある。

**`reviewLock`(transient・型の正は `plan-progress.schema.json` の `definitions.reviewLock`。issue #68 で optional 宣言に変更・検査対象外は維持)**: pr reviewer / developer(対応役)が dispatch する直前に、対象 step へ次を書く(実装役の `dispatchMarker` とは**別フィールド**で持つ — 「tick 冒頭 reconciliation」節の reconciliation はこのフィールドを走査しない。同一フィールドを共有すると `deadline_tick` を必須とする `marker_is_valid()` に `invalid_marker` として拾われ sink されてしまうため):
```json
{"dispatched_tick": <TICK>}
```
`deadline_tick` / `retry_count` は持たない(lock-only)。`$TICK` は「tick 冒頭 reconciliation」節の `orchestratorTick` を共有する。書込は次の 1 手続きで行う(`<step id>` は対象 step):
```
PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
python3 - "$PLAN" "<step id>" "$TICK" <<'PY'
import datetime, json, os, sys
plan_path, step_id, tick = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(plan_path, encoding="utf-8") as f:
    plan = json.load(f)
step = next(s for s in plan["steps"] if s["id"] == step_id)
step["reviewLock"] = {"dispatched_tick": tick}
plan["updatedAt"] = datetime.date.today().isoformat()
with open(plan_path + ".tmp", "w", encoding="utf-8") as f:
    json.dump(plan, f, ensure_ascii=False, indent=2)
os.replace(plan_path + ".tmp", plan_path)
PY
```

**選別ガード**: 「選別(jq)」節の対応役・pr reviewer ブロックに `.reviewLock == null` を追加し、既に in-flight な step を選別から除外する(実装役の `.dispatchMarker == null` ガードと同型)。

**解除(必ず同一 tick 内・全 outcome で)**: pr reviewer / 対応役はどちらも dispatch が同一 tick 内で outcome まで同期完結するため、判定器呼出後の原子書込(「ルーティング判定」節『`ledger_write` の適用』)で **全 outcome について** `reviewLock` を削除する(route が normal/sink いずれでも、`ledger_write` が null の outcome(reviewer/`invalid`・対応役/`evidence_fail`)でも解除する — 解除しないと次 tick 以降この step が永久に選別から外れたままになる)。適用手続きは既存の `<clear_marker>` 引数に加え、削除対象のフィールド名を汎化した `<marker_field>`(省略時の既定 `dispatchMarker`)を渡す — 実装役の既存呼出は省略のまま(挙動不変)、pr reviewer / 対応役は `"reviewLock"` を渡す。詳細は「ルーティング判定」節『`ledger_write` の適用』を参照(手続き本体はそちらが正・ここでは複製しない)。

**既知の限界(正直な明記・独立機構は足さない)**: dispatch call 自体がセッションを止める真の hang が起きた場合、`reviewLock` は書かれたまま残り、それを跨 tick でタイムアウトさせる主体は無い(「tick 冒頭 reconciliation」節の reconciliation は `deadline_tick` 必須かつ `dispatchMarker` フィールドのみを走査するため、`reviewLock` を看取れない)。この残留は issue #26 自身の残余限界(真の hang はリアルタイム検知できず、人間がセッションを再起動しても `reviewLock` は自動では解除されない)と同型で、**`pr.status` は resting のまま変化しないため、復旧は人間が対象 step の `reviewLock` を手動削除するだけでよい**(status の復元は不要 — 実装役の `dispatchMarker` のような専用ラベル・`notified` 通知の仕組みは持たない)。頻度が低い残留経路のため、独立の timeout/retry 機構を追加するのは v1 では over-engineering と判断する。実運用で高頻度に観測されたら follow-up で issue #26 の reconciliation を「ロール非依存・deadline 任意」へ一般化する対応を検討する(v1 では採らない・観測駆動)。

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

**`need for human review` ラベル付きの PR は無条件でスキップする**(ラベルの有無は各対象 step ごとに `gh pr view <n> --json labels` で確認)。**1 tick あたりの dispatch 上限は 5 件**(`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` の暴走防止パターンを踏襲)。**この上限は「tick 冒頭 reconciliation」の `redispatch` 候補も含めた合計に適用する**(redispatch だけを上限の外に置くと、複数 step が同時に締切超過した場合に 1 tick で 5 件を大きく超える dispatch が起こりうるため。詳細は下記「選別(jq)」節参照)。

| 条件 | dispatch するロール | orchestrator が行うこと |
|---|---|---|
| `issue.status == "ready for implementation"` かつ `pr.number == null` かつ **in-flight マーカー無し(`wait` 対象外)** | developer(実装役) | tick 冒頭 reconciliation → (marker 無し/`redispatch`) → **ファイル衝突検知(下記)** → dispatch → 返答検証(復旧検索)→ evidence gate → outcome 解決 → 判定器 → git status ガード → route 実行(normal/skip/sink/timeout→sink) |
| `pr.status == "completed review"` かつ **`reviewLock` 無し** | developer(対応役) | `reviewLock` 書込 → dispatch → 返答検証 → evidence gate → outcome 解決 → 判定器 → git status ガード → route 実行(normal/sink)→ `reviewLock` 解除 |
| `pr.status in ("created pr", "waiting for review")` かつ **`reviewLock` 無し** | pr reviewer | `reviewLock` 書込 → dispatch → 返答から outcome 解決(`invalid`/`escalate`/`clean_pass`/`blockers`/`subjective_escalate`)→ 判定器 → route + label_action 実行 → `reviewLock` 解除 |
| `pr.status == "ready for merge"` | なし | dispatch しない(終端は人間の専権) |
| `pr.status in ("merged pr")` / issue 終端(`closed issue`) | なし | 何もしない |

**注**: 終端は人間の専権だが、人間の明示指示がある場合のエージェントによる代行は例外として認められる — 詳細は `.harness/CLAUDE.harness.md`『終端の記録と merge 代行』節を参照。`reviewLock` の書込・解除の詳細は「reviewer / 対応役の in-flight ロック」節を参照。

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
#
# dependsOn ガード(issue #51・スループット): `dependsOn` の全要素が終端(`issue.status ==
# "closed issue"` の step。PR の有無は問わない — discuss 型 step は PR を持たず直接この状態に
# 至る)である step だけを候補にする。空配列/欠損は「依存なし」として常に eligible(後方互換・
# `(.dependsOn // [])` が `[]` になり `all` は空配列に対し恒真)。存在しない step id を指す要素は
# $terminal 集合に含まれえないため、自動的に fail-closed で未解決として除外される
# (`.harness/plan-progress.schema.json` の整合規則が authoring-time に同じ違反を検知する
# 2 段目の安全網 — この jq は selection-time の安全網)。
jq -c '
  ( [ .steps[] | select(.issue.status == "closed issue") | .id ] ) as $terminal
  | [ .steps[]
      | select(.issue.status == "ready for implementation" and .pr.number == null and .dispatchMarker == null)
      | select((.dependsOn // []) | all(. as $d | $terminal | index($d) != null))
      | {id, issueNumber: .issue.number} ]
' "$PLAN"

# 対応役 dispatch 対象(issue #37: `.reviewLock == null` で in-flight な step を除外。
# 実装役の `.dispatchMarker == null` ガードと同型 — 無いと重複配車が起きる)
jq -c '[ .steps[]
  | select(.pr.number != null and .pr.githubState == "open")
  | select(.pr.status == "completed review" and .reviewLock == null)
  | {id, number: .pr.number} ]' "$PLAN"

# pr reviewer dispatch 対象(issue #37: 同じく `.reviewLock == null` で除外)
jq -c '[ .steps[]
  | select(.pr.number != null and .pr.githubState == "open")
  | select((.pr.status == "created pr" or .pr.status == "waiting for review") and .reviewLock == null)
  | {id, number: .pr.number} ] | unique_by(.number)' "$PLAN"
```

**実装役カテゴリの候補集合は、上記 jq が返す新規 eligible 対象と、「tick 冒頭 reconciliation」節が返す `redispatch` 候補(既存 in-flight step の再試行)を合算したもの**とする(dependsOn ガード(issue #51)は上記 jq 自身が新規 eligible 対象に既に適用済み — 依存未解決の候補はここに含まれない。`redispatch` 候補は元々 eligible 判定を経て dispatch 済みだった step の再試行であり、dependsOn ガードを再適用しない)。

**ファイル衝突検知(issue #37・欠落 3)**: dependsOn ガードとは直交する 2 段目のフィルタ(依存順序ではなくファイル単位の衝突を見る)。実装役カテゴリの候補が 1 件以上ある場合、各候補の対象 issue の Implementation Scope から対象ファイルを抽出する(バッククォートで囲まれたファイルパスのみを対象ファイルとして収集し、地の文中の通りすがり言及(例:「`decide-orchestrator-route.py` と同型」)は除外する — この抽出規則自体は script が判定しないため prose 側の責務。Implementation Scope の記載が無い/抽出 0 件なら `files: []` とする)。集めた `[{id, files}]` を `scripts/detect-dispatch-collision.py` へ渡す:
```
COLLISION=$(printf '%s' "$CANDIDATES_JSON" | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/detect-dispatch-collision.py")
# -> {"groups": [["<id>", ...], ...], "safe": ["<id>", ...]}
```
返る `safe` の候補だけを今 tick の実装役枠の母集団として残す。`groups`(ファイルが衝突する組、および対象ファイル抽出 0 件で fail-closed 判定された候補)は**今 tick では dispatch せず**、marker を書き換えずに次 tick へ持ち越す(取りこぼしではなく先送り — 次 tick には候補の組合せが変わりうるため、同じ衝突が起き続けるとは限らない)。

3 カテゴリ(対応役 / pr reviewer / 実装役)を合算して **上限 5 件**に切り詰める(優先順は「対応役 > pr reviewer > 実装役」— 手戻り修正を優先し、新規 dispatch は余裕がある時だけ行う。実装役カテゴリ内では `redispatch` 候補(締切超過が古いもの優先)を新規 eligible 対象より先に数える — 既に in-flight で待たされている step を、まだ着手していない新規 step より優先する。この優先順位付け自体は機械的な tie-break であり、レビュー判断ではない)。実装役枠から溢れた `redispatch` 候補は「tick 冒頭 reconciliation」節のとおり marker を書き換えずに次 tick へ持ち越す。各対象を処理する前に `need for human review` ラベルの有無を確認しスキップする。

## dispatch 先ごとの委譲方式(転写しない)

各ロールは **dispatch → 状況を outcome トークンに解決 → 判定器(「ルーティング判定」節)→ route / label_action 実行**。dispatch prompt(委譲の中身)は転写せず参照させる方式を維持する。**ルーティング規則は判定器 script が正**なので、各ロール節は「どう outcome に解決するか」だけを書き、書込・sink・ラベルの規則は複製しない。

### developer(実装役)

**実行ループ(同時配車。issue #51)**: 下記の手順 1〜8 は **1 候補ぶんの outcome 解決を記述している**。「選別(jq)」節の実装役 dispatch 対象(dependsOn ガード通過済みの新規 eligible + `redispatch` 候補、上限 5 件切り詰め後)が 2 件以上ある場合、orchestrator は **同一 tick 内で候補ごとに手順 1〜8 を独立に(並列に)実行する** — 候補を 1 件ずつ逐次処理しない。候補が 1 件以下の tick では従来どおり単体で実行する(挙動不変)。

「同時配車」の定義はこの実行ループの挙動そのものを指す — 選別 jq の出力サイズ(何件 eligible か)と、実行時に何件の `Agent` 呼出を同一 tick で発行するか、の**両方**が揃って初めて成立する。選別だけを直しても実行ループが逐次のままなら同時配車は成立しない。この 2 つの性質は検証手段の性質が異なる:
- **選別 jq の出力サイズ**: 決定論的な jq の入出力であり、`tests/smoke/run-smoke.sh` で機械検証できる(DoD (ii-a)。「選別(jq) 実装役の dependsOn ガード」ブロック参照)。
- **実行時の並列 `Agent` 呼出**: orchestrator セッションの実行時ふるまいであり、bash の smoke script では原理的に検証できない(DoD (ii-b)。実運用の `/goal` 実行観測でのみ確認できる — 本 repo が既に「自己申告は便宜シグナル」「reports は best-effort で機械強制されない」と検証手段の限界を正直に書いている前例に倣う)。

**台帳書込(marker 書込・`ledger_write` の適用)は並列化しない(issue #51・PR #57 round 1 レビュー対応)**: 同時配車で並列に実行されるのは手順 2 の `Agent` 呼出(dispatch call = subagent の実行そのもの)だけである。台帳(`.harness/plan-progress.json`)への書込主体は orchestrator という単一プロセスのままであり、書込そのものは本質的に逐次にしかなり得ない。したがって手順 1(in-flight マーカー書込)・手順 6/7(`dispatchMarker` の削除・`ledger_write` の適用)は、複数候補が同一 tick で処理されていても**候補ごとに 1 件ずつ逐次実行し、2 候補分の書込を同時に(重ねて)行わない**。複数候補の `Agent` 呼出が並列に走っている間に subagent の返答が interleave して戻ってきても、ある候補の返答を受けて台帳へ書き込む処理は、別候補の書込処理が進行中であればその完了を待ってから行う(実装上は「1 候補ぶんの書込処理をひとまとめの直列区間として扱い、この区間だけは複数候補間で重ねない」と読み替えてよい — 区間の外側(dispatch call の待ち時間や evidence gate の実行)は引き続き並列でよい)。**PRE/POST ガードをこの逐次書込に沿って候補ごとに個別運用する具体手順は「単一書込」節『PRE 計測タイミングの明確化』の同時配車向け一般化を参照**(規則の重複を避けるため、ここでは繰り返さない)。

これは `.harness/CLAUDE.harness.md`『developer / reviewer は同一マシンの同一ローカル台帳ファイルを共有する。書込主体をモードごとに単一に保つことで、ローカルファイルへの競合書込を避ける』という規約と矛盾しない — 同規約が禁じるのは「複数の書込主体(モード)が同じ台帳へ競合して書くこと」であり、本節が定める「単一の書込主体(orchestrator)の内部で、複数候補ぶんの書込を時間的に直列化する」こととは水準が異なる。書込主体はこの並列化の前後で orchestrator のまま変わらず、並列化されるのは書込そのものではなく dispatch call の実行時間だけである。

**outcome 解決(判定器の implementer 行に渡すトークンを決める)**:

1. **in-flight マーカーを書く**(dispatch 直前・「tick 冒頭 reconciliation」節参照): 対象 step へ `{"dispatched_tick": $TICK, "deadline_tick": $TICK + K, "retry_count": <0 か reconciliation から引き継いだ値>}` を書いてから手順 2 の dispatch を行う(dispatch call 自体がセッションを止める真の hang でも、次 tick(人間がセッションを再起動した後)がこのマーカーを見て締切超過を検知できるようにするため)。この書込は「単一書込」節の git-status ガードにとっても orchestrator 自身の正当な書込であり、**PRE はこの書込が完了した直後・手順 2 の直前に再計測する**(「単一書込」節「PRE 計測タイミングの明確化」参照)。

2. **dispatch**(subagent には `Read, Skill, Bash, Grep, Glob` のみ渡す。`Write` は渡さない)し、返答から `pr_number` の取得を試みる(git-status ガードの PRE はここ、dispatch 直前に控える)。**dispatch prompt 本文は `${CLAUDE_PLUGIN_ROOT}/roles/developer-implementer.md` へ外出し済み**(issue #38・毎 tick の実効トークン削減。pr reviewer 節が `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` を参照するのと同型)。この参照ファイルは **dispatch する subagent 自身が(自分の Read ツールで)読む** — orchestrator 自身は読まない。したがって実装役 dispatch が 0 件の tick では、orchestrator はもとより誰もこのファイルを読まない(DoD (ii) の分岐はこの構造そのもので満たされる。「if 分岐」を prose に追加で持つ必要はない):

   > 「`${CLAUDE_PLUGIN_ROOT}/roles/developer-implementer.md` を Read し、そこに書かれた指示をそのまま実行せよ(対象 issue は #<N>)。手順本体は転写しない — 必ずファイルを Read してから実行すること。」

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

5. **evidence gate**(`pr_number` 確定後・書込より前に実行)。**subagent が dispatch 中に作った worktree は削除済みの可能性があり参照できないため、orchestrator 自身が独立して PR の head ブランチを取得し専用の一時 worktree を作って実行する**(`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` 手順 4 の per-PR worktree パターンと同じ)。worktree の作成・残骸掃除(`git worktree add` の exit code 確認 + remove/prune/再 add のフォールバック)・実行の手続きは **`scripts/run-orchestrator-evidence-gate.sh` へ抽出済み**(issue #38。対応役 手順 5 と重複していたロジックを dedup した単一の実体):
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-orchestrator-evidence-gate.sh" "<repo>" "<pr_number>"
   EVIDENCE_EXIT=$?
   ```
   - **`EVIDENCE_EXIT == 0`** → outcome=**`pr_evidence_pass`**。
   - **`EVIDENCE_EXIT != 0`**(evidence 非 0 **または** worktree 残骸掃除失敗)→ outcome=**`pr_evidence_fail`**(route=sink・need for human review。古い残骸で誤って pass/fail を出すより停止が安全)。

6. **`dispatchMarker` の扱い(outcome ごとに 3 通りの決着を固定列挙する)**: 実装役の outcome(`no_pr` / `ambiguous` / `pr_evidence_pass` / `pr_evidence_fail` / `subjective_escalate`。**`timeout` はこの手順(1〜8)を通らず「tick 冒頭 reconciliation」節で独立に解決されるため、ここには含まれない** — 下記の `subjective_escalate` の扱いは timeout の変則をこの手順内で再現したものであり、timeout 自身がこの手順を通るわけではない)は、marker に対して次の 3 通りのいずれかで決着する。**固定列挙にするのは、「進める PR の有無が確定した」という性質だけで一括りにすると、新しい outcome がどちらの型に属すか誤分類しうるためである**(実際に起きた誤り: `subjective_escalate` をこの性質だけで判断して `marker 削除`型に分類したが、正しくは marker を永続させる `timeout` 型だった — 削除すると次 tick の選別 jq(`.dispatchMarker == null` かつ `.pr.number == null`)へ即座に再合致し、締切超過を待たず無条件・無制限に再 dispatch されてしまう)。**実装役に新しい outcome を追加する際は、この 3 分類のどれに属するかを明示的に決めてここへ追記すること**(性質ベースの一文で束ねて済ませない)。

   - **削除**(`ambiguous` / `pr_evidence_pass` / `pr_evidence_fail`): pr_number が確定した、または確定不能と判明したことで「進める PR の有無」がこの tick 内で解決し、marker を持ち越す理由が無い outcome。手順 7 で判定器を呼んだ後、その `$ROUTE` を「ルーティング判定」節の **`ledger_write` の適用**手続きへ `<clear_marker>`="true" として渡し、**同一の原子書込**で削除する(適用手続きの条件を `lw is not None or clear_marker == "true"` に一般化しているため、`ledger_write` が非 null(`pr_evidence_pass`/`pr_evidence_fail`)でも null(`ambiguous`)でも、この 1 つの手続きが扱える)。
   - **永続 + この場で `notified` を追加**(`subjective_escalate`): 委譲先が「人間の判断を仰ぎたい」と明示的に自己申告した outcome。marker を削除せず、`timeout` と同じく永続させたうえで、締切超過・リトライ上限到達を待たず**この場で即座に**「ルーティング判定」節の「`notified` フラグの付与」手続きを実行する(既存 3 キーは変更せず `notified: true` を追加するのみ)。これにより次 tick 以降は「notified 済みマーカーの早期スキップ」に該当し無条件スキップされる(詳細は手順 7)。
   - **完全に不可触**(`no_pr`): marker を書込も削除もしない。「tick 冒頭 reconciliation」節の機構(締切 K=2 tick・リトライ上限 N=2)による有界化に委ねる。

7. **判定器を呼び route を実行**(role=implementer。規則は判定器が正・下記は route の実行だけ)。**`observation`(issue #50 A1・「ルーティング判定」節「呼び方」の共通手続きに従う)**: `ambiguous`/`pr_evidence_fail`/`subjective_escalate`(sink 系)を解決したときは `<command>/<exit_code>/<summary>` に次を渡す(いずれもここまでの手順で既に確定している値 — 新たに何かを実行観測する必要は無い):
   - `ambiguous`: `<command>`=手順 4 の復旧検索コマンド(`gh pr list --search '"Closes #<N>" in:body' ...`)/ `<exit_code>`=0(検索コマンド自体は成功している)/ `<summary>`=再照合後の一致件数(例:「2 件一致」)。
   - `pr_evidence_fail`: `<command>`=手順 5 で呼んだ `run-orchestrator-evidence-gate.sh` の呼出文字列 / `<exit_code>`=`$EVIDENCE_EXIT` / `<summary>`=evidence gate 失敗の要約(1 行)。
   - `subjective_escalate`: `<command>`="dispatch 応答の escalate_to_human 検出" / `<exit_code>`=0 / `<summary>`=委譲先が返した `reason` をそのまま。
   `no_pr` / `pr_evidence_pass`(sink でない)は `<command>` を空文字で渡し `observation` を省略する。`timeout` はこの手順を通らない(「tick 冒頭 reconciliation」節で別途解決・後述)。**呼出し自体(heredoc → `OBS_CMD`/`OBS_SUMMARY` → `"$OBS_CMD"`/`"$OBS_SUMMARY"` 展開)は「ルーティング判定」節「呼び方」の共通手続きをそのまま使う(ここでは複製しない)** — `<role>`="implementer"、`<outcome>`=上記で解決した outcome、`<command>/<exit_code>/<summary>` は上記の値を渡す。
   - `pr_evidence_pass` / `pr_evidence_fail`: 判定器の `ledger_write`(`pr.number`=true / `pr.githubState`="open" / `pr.status`="created pr")を「ルーティング判定」節の **`ledger_write` の適用**手続きで**1 回のローカルファイル書込で書く**(`<pr_number>` に確定番号、`<clear_marker>`="true" を渡す — 手順 6 のとおり `dispatchMarker` の削除もこの同一書込に含める。**status リテラルは prose に複製せず `$ROUTE.ledger_write` から書く**)。evidence を書込より前に実行済みで、`ledger_write` の全キー(number/githubState/status)と `dispatchMarker` 削除を 1 回のファイル書込で適用するため、`pr.number` だけ書いて `pr.status` 未書込という中間状態や、marker だけ消えて `pr.number` 未書込という中間状態は生じない(非原子的多段書込を排除)。書込後、「作業レポートの代筆」節の共通手続きで対象 step の `reports[]` へ 1 件追記する(`author`="main developer (実装役)"・`role`="developer")。続けて「書込方式」節に従いローカルファイル編集のみで完結させ(commit/push しない)、Statuses API 自己申告を行う。
     - `pr_evidence_pass` → route=normal。上記のローカル書込で完了。次 tick で pr reviewer に dispatch される。
     - `pr_evidence_fail` → route=sink。上記のローカル書込を行った**うえで**「失敗経路(単一の need for human review sink)」へ。書かれる `pr.status` は `ledger_write` のとおり `created pr`(`"completed review"` にはしない — reviewer が一度も走っていない PR には `# PR Reviewer` コメントが存在せず、対応役 dispatch しても直す finding が無い)。need for human review ラベル付与後は次 tick から無条件スキップされ安全に停止する。
   - `no_pr` → route=skip。書込なし。`dispatchMarker` は手順 6 のとおり残る(次 tick 以降「tick 冒頭 reconciliation」節が締切・リトライを判定する。**issue #26・P1 決定によりもはや無界ではない**)。
   - `ambiguous` → route=sink。`ledger_write` は null のため pr.number 等のフィールド書込は無いが、この判定器呼出の直後に同じ `ledger_write` の適用手続きを `<clear_marker>`="true" で呼び、`dispatchMarker` の削除だけを行う(この outcome の再 dispatch 挙動自体は issue #26 のスコープ外・変更しない)。
   - `subjective_escalate`(issue #31・手順 3 で解決済み)→ route=sink。`ledger_write` は null(進める PR が無い)。手順 6 のとおり `<clear_marker>` は渡さない(marker を削除しない) — 代わりに、判定器呼出の直後に「ルーティング判定」節の「`notified` フラグの付与」手続きを実行し、`dispatchMarker` へ `notified: true` を追加する(既存 3 キー(`dispatched_tick`/`deadline_tick`/`retry_count`)は変更せず追加のみ)。**この書込を怠ると(あるいは誤って marker を削除すると)、次 tick の選別 jq(`.dispatchMarker == null` かつ `.pr.number == null`)へ即座に再合致し、締切超過を待たず無条件・無制限に実装役が再 dispatch されてしまう**(marker を削除する誤りでも同じ実害になる — どちらの誤りでも「人間の判断を仰ぎたい」という明示的な意思表示が毎 tick 無視される)。`notified: true` の付与により、次 tick 以降は「notified 済みマーカーの早期スキップ」に該当しこの step は無条件スキップされる(解除は人間が `dispatchMarker` を手動削除するまで行われない — `timeout` と同じ解除手段)。「失敗経路(単一の need for human review sink)」の**変則**として、`timeout`/`ambiguous` と同じく PR が実在しないため次のとおり扱う: **ラベル付与は行わない**(`gh pr edit <n> --add-label` の対象となる PR 番号が無い)。`PushNotification` のみ行い、通知本文には「主観的エスカレーション」の 1 語と `reason` を含める(例: 「issue #<N> の実装役 dispatch が主観的エスカレーションを返した(PR 未作成・委譲先の自己申告: `<reason>`)」。sink 共通手続き手順 2 の通知例も参照)。

8. **orphan 防止は write-early ではなく復旧検索が担う(marker を永続させる outcome は書込前後を問わず安全)**: `ambiguous` / `pr_evidence_pass` / `pr_evidence_fail` は、手順 7 の原子書込(marker 削除 + (あれば) `ledger_write`)の**前**に tick が中断しても、marker が残ったままなので二重 dispatch は起きない(次 tick は `pr.number == null` のままなので手順 4 の復旧検索が既存 PR(`Closes #<N>`)を再発見して self-heal する)。`subjective_escalate` は手順 6 のとおり marker を削除しない(永続させる)ため、この保護は書込の前後を問わず一律に成立する — 手順 7 の `notified: true` 付与が tick 中断で未完了でも、`dispatchMarker` キー自体は残り続けるため選別 jq(`.dispatchMarker == null`)から除外され続け、二重 dispatch は起きない(次 tick は notified 未付与のまま reconciliation が通常どおり判定し、締切内なら `wait`、締切超過なら `redispatch`/`timeout` へ自然に合流する — 取りこぼしではなく先送り)。だから `pr.number` を先行して書き込む必要はなく、書込は手順 7 のとおり原子的にできる(先行書込 → evidence → 本書込 の 2 段書込は取らない。**`dispatchMarker` 自体は手順 1 で先行して書く点は変わらない** — こちらは `pr.number` ではなく hang 検知専用の別状態であり、この self-heal の議論とは独立)。

### developer(対応役)

**outcome 解決(判定器の responder 行に渡すトークンを決める)。実装役と対称で、evidence 失敗は必ず sink に到達し無界ループを残さない**:

1. **選別ガードと `reviewLock` 書込**: 選別 jq に `.pr.githubState == "open"` と `.reviewLock == null` を含める(GitHub 上で既に merged/closed の PR を対応役へ回さない・in-flight な step への重複配車を防ぐ。詳細は「reviewer / 対応役の in-flight ロック」節)。dispatch する直前に、対象 step へ同節の書込手続きで `reviewLock` を書く。

2. **dispatch**(ツール制限は実装役と同じ。`gh pr comment` 投稿は許可するが台帳・ラベルには触れさせない)。**dispatch prompt 本文は `${CLAUDE_PLUGIN_ROOT}/roles/developer-responder.md` へ外出し済み**(issue #38・毎 tick の実効トークン削減。実装役節と同型)。この参照ファイルは **dispatch する subagent 自身が読む** — orchestrator 自身は読まない。したがって対応役 dispatch が 0 件の tick では、orchestrator はもとより誰もこのファイルを読まない(DoD (ii) の分岐はこの構造そのもので満たされる):

   > 「`${CLAUDE_PLUGIN_ROOT}/roles/developer-responder.md` を Read し、そこに書かれた指示をそのまま実行せよ(対象 PR は #<N>)。手順本体は転写しない — 必ずファイルを Read してから実行すること。」

3. **主観的エスカレーションの確認(issue #31・返答検証より先に行う)**: 検出条件は「ルーティング判定」節の「3 role 共通の `subjective_escalate` の解決方法」を参照(ここでは複製しない)。該当すれば outcome=**`subjective_escalate`**(判定器は `ledger_write={"pr.status":"need for human review"}`・`route=sink` を返す。手順 5 の evidence gate は行わず、手順 6 の判定器呼び出しへ進む)。形式不正で `escalate_to_human` を無視した場合は下記手順 4 へフォールバックする(tick 報告に 1 行残す)。

4. **返答検証(越権の無効化)**: `proposed_status` が `"waiting for review"` 以外(特に `"ready for merge"`)でも**無視して先へ進む**(対応役の越権を orchestrator 側で機械的に無効化する — `.harness/CLAUDE.harness.md` の「対応側が `ready for merge` を立てるのは越権(例外なし)」を技術的に担保)。対応役の返答は outcome 解決に使わない — status は evidence gate だけで決まる。

5. **evidence gate**(実装役の手順 5 と同じ `scripts/run-orchestrator-evidence-gate.sh` を呼ぶ — worktree 作成・残骸掃除ロジックは同スクリプトへ dedup 済み。issue #38。対象 PR は既に `pr.number` が確定しており subagent の dispatch 済み worktree の生死に依存しない):
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-orchestrator-evidence-gate.sh" "<repo>" "<n>"
   EVIDENCE_EXIT=$?
   ```
   - **`EVIDENCE_EXIT == 0`** → outcome=**`evidence_pass`**。
   - **`EVIDENCE_EXIT != 0`**(evidence 非 0 **または** worktree 残骸掃除失敗)→ outcome=**`evidence_fail`**(route=sink。古い残骸で誤検証するより停止が安全)。

6. **判定器を呼び route を実行**(role=responder。**全 outcome で `<clear_marker>`="true" `<marker_field>`="reviewLock" を渡し、手順 1 で書いた `reviewLock` を同一の原子書込で解除する**(issue #37。解除しないと次 tick 以降この step が選別から永久に外れる)。**`observation`(issue #50 A1・「ルーティング判定」節「呼び方」の共通手続きに従う)**: sink 系(`evidence_fail`/`subjective_escalate`)を解決したときは `<command>/<exit_code>/<summary>` に次を渡す — `evidence_fail`: `<command>`=手順 5 で呼んだ `run-orchestrator-evidence-gate.sh` の呼出文字列 / `<exit_code>`=`$EVIDENCE_EXIT` / `<summary>`=evidence gate 失敗の要約。`subjective_escalate`: `<command>`="dispatch 応答の escalate_to_human 検出" / `<exit_code>`=0 / `<summary>`=`reason` をそのまま。`evidence_pass`(sink でない)は `<command>` を空文字で渡す):
   - `evidence_pass` → 判定器の `ledger_write`(`pr.status`="waiting for review")を「ルーティング判定」節の **`ledger_write` の適用**手続きで書く(対応役は `pr.status` のみ・`<pr_number>` は空文字でよい。**status リテラルは prose に複製せず `$ROUTE.ledger_write` から書く**)・route=normal(次 tick で pr reviewer が再レビュー)。
   - `evidence_fail` → `ledger_write` は null。**`pr.status` は `completed review` のまま**(事実: 未解決 blocker が残る)。ただし `reviewLock` は解除する必要があるため、同じ適用手続きを `<clear_marker>`="true" `<marker_field>`="reviewLock" で呼ぶ(`ledger_write=null` のため他フィールドは書き換わらない — marker 単独削除)・route=sink。これで対応役も有界停止になり実装役と対称になる — 「evidence が通らないまま `completed review` 固定で毎 tick 再 dispatch → reviewer が選別せず round カウンタが進まず永久に停止しない」旧・無界ループを根絶する。
   - `subjective_escalate`(issue #31・手順 3 で解決済み)→ 判定器の `ledger_write`(`pr.status`="need for human review")を **`ledger_write` の適用**手続きで書く(escalate と同じく書いてから sink)・route=sink。「失敗経路(単一の need for human review sink)」へ(通知本文には「主観的エスカレーション」の 1 語と `reason` を含める)。

   `evidence_pass` / `evidence_fail` はいずれも対応役が実際に作業した事実(採用/却下の判断・修正試行)を伴うため、上記の `ledger_write` 適用の直後に「作業レポートの代筆」節の共通手続きで対象 step の `reports[]` へ 1 件追記する(`author`="main developer (対応役)"・`role`="developer"。`subjective_escalate` は対応未完了のため追記しない)。

**既知の限界(意図的・対応役の無作業検知は escalate backstop に委ねる)**: 対応役は outcome を evidence gate だけで決めるため、dispatch した subagent が **無作業/クラッシュでも test が元々緑なら `evidence_pass` → `waiting for review` へ進む**(偽の前進)。実装役(復旧検索)・reviewer(`invalid` 検知)が dispatch 結果失敗を即座に sink するのに対し、**対応役の無作業だけは即時検知しない**という latency の非対称が残る。ただし finding 未対応なら次 tick で reviewer が同じ blocker を再検出 → `completed review` へ戻す往復が続き、**escalate backstop(round≥5 / blocker trend)が最終的に人間へ surface する**。これは bounded(`has_blocker=true` 維持で `clean_pass`=不正 merge には至らない)であり、walking skeleton では検知機構を足さず backstop に委ねる(作者の意図的判断)。実害(無作業 dispatch が頻発)が観測されたら follow-up で対応役の作業有無(`# PR Review Worker` コメント / commit の有無)検証を足す(「既知の制限・拡張ポイント」節にも同旨を明記)。

### pr reviewer

**候補収集(review-mode=code-review のときのみ・issue #49・reviewLock 書込より前に行う)**: `$REVIEW_MODE == "code-review"`(既定)の場合、pr reviewer を dispatch する**前**に、**orchestrator 自身**が `${CLAUDE_PLUGIN_ROOT}/collectors/strategy.md` を Read し、そこに書かれた指示をそのまま実行する(対象 PR は #<N>、出力先ディレクトリは orchestrator が用意する一時ディレクトリ、effort は `$EFFORT` を目安として渡す)。手順本体は転写しない。この実行により角度別 finder(kit デフォルト角度 ∪ 導入先 `.harness/collectors/angles/` の追加観点 — `collectors/strategy.md` 手順 2 が解決。issue #63・#65)が **orchestrator 自身の直接の子**として起動する(pr reviewer の子にしない — これが issue #49 の核心。orchestrator から見た「孫」を構造的に無くす)。finder は各自の findings をファイルへ直接 Write し、orchestrator へは短い確認メッセージしか返さないため、**findings 本文は orchestrator の context に載らない**。収集完了後に返る統合ファイルのパスを `$FINDINGS_PATH` として控える(未応答の角度があれば tick 報告に 1 行残す)。`$REVIEW_MODE == "multi-angle"` のときはこの手順を**行わない**(4-a 経路は本 issue のスコープ外・pr reviewer が引き続き内部で fan-out する現状維持)。

**dispatch 直前の `reviewLock` 書込**: 対象 step へ「reviewer / 対応役の in-flight ロック」節の書込手続きで `reviewLock` を書く(選別 jq は既に `.reviewLock == null` で除外済み)。

対象 PR 番号と `$REVIEW_MODE`(code-review の場合は加えて `$FINDINGS_PATH`)を渡し、次を Agent ツールで dispatch する(ツール制限は実装役と同じ。**`gh pr comment` 投稿は許可するが台帳・ラベルには触れさせない**):

> 「**★最重要★ 手順を読む前に頭に入れておくこと(issue #37・#49)**: (1) `review-mode=multi-angle` の場合、`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` 経由で `reviewing-multi-angle` を実行する際、内部の finder / verifier は `subagent_type: "general-purpose"` で起動せよ(`fork` を使うな)。fork は呼出元の会話文脈を丸ごと継承する設計のため、finder が「この角度だけ見ろ」という狭い directive を無視し、継承した文脈から呼出元の最上位タスクを再実行する(別 schema での応答・呼出元が使用中の worktree の無断削除を実測)。`general-purpose` は文脈を継承しないためこの逸脱が起きない。文脈は各 finder / verifier に自己完結する形で渡す。**`review-mode=code-review` の場合、あなた自身は finder を起動しない**(候補は orchestrator が事前に収集済み — 下記参照)。(2) `gh auth switch` を実行するな(active アカウントを変えると orchestrator 自身の `gh` 操作が壊れる)。(3) 観測していないことを書くな。『エラー』と『処理中』を区別せよ。分からないことは未観測と書け。 --- `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` を Read し、そこに書かれた手順 4 〜 5.6(投稿である手順 5 を含む。5.5/5.6 は投稿より前に計算するが、投稿自体も実行対象に含む。review-mode=`$REVIEW_MODE`、停止条件判定込み)を PR #<N> に対してそのまま実行せよ。**review-mode=code-review の場合、手順 4-b の候補収集済みファイルのパスは `$FINDINGS_PATH` である(このファイルを Read せよ。finder は起動するな)。** 手順本体は転写しない — 必ずファイルを Read してから実行すること。判定ロジックは変更しない。手順 6 の台帳書込・ラベル管理・報告(手順 3 のマーカー投稿含む)は行わず、代わりに `contracts/reviewer-return.schema.json` が規定する形(`{has_blocker, blocker_count, escalate, review_markdown}`)を JSON で返せ(`review_markdown` は手順 5 で組み立てたコメント本文。投稿は行ってよい — 投稿そのものは pr reviewer の専権であり本コマンドの触らないものではない)。**レビュー中に人間の判断が必要と感じた場合(判定が付かない・専門知識が必要等)の返り値の形は `${CLAUDE_PLUGIN_ROOT}/rules/escalate-to-human.md` の契約に従う(pr reviewer 固有の使い分け: 加えて `escalate_to_human: {reason}` を返してよい — 他フィールドとの共存可・客観的な `escalate` とは独立のシグナル。issue #61 で集約)。** 台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

**outcome 解決(判定器の reviewer 行に渡すトークンを決める。全 5 outcome を必ず解決する)**: 実装役の復旧検索・対応役の evidence gate と対称に、**reviewer にも「dispatch 結果失敗」分岐を持たせて単一 sink をすり抜けさせない**(「実装役は復旧検索、対応役は evidence gate で dispatch 失敗を捌けるが、reviewer だけ dispatch 結果失敗の分岐が無く単一 sink をすり抜ける」を、この `invalid` 分岐で塞ぐ)。判定順序は次のとおり(上から順に該当する最初の分岐を採用する):

1. **返答が JSON として解釈できない / `escalate` を読めない**(subagent クラッシュ・不正 JSON・個人 skill 欠落で `escalate` を組み立てられない等の **dispatch 結果失敗**)→ outcome=**`invalid`**(判定器は route=sink を返す)。
2. **(issue #31)検出条件は「ルーティング判定」節の「3 role 共通の `subjective_escalate` の解決方法」を参照(ここでは複製しない)**。該当する場合(客観的な `escalate` の値に関わらず優先) → outcome=**`subjective_escalate`**。形式不正で `escalate_to_human` を無視した場合は下記へフォールバックする(tick 報告に 1 行残す)。
3. **`escalate == true`**(round/trend 停止条件)→ outcome=**`escalate`**。
4. **`escalate == false` かつ `has_blocker == false`** → outcome=**`clean_pass`**。
5. **`escalate == false` かつ `has_blocker == true`** → outcome=**`blockers`**。

**判定器を呼び route / label_action を実行**(role=reviewer。evidence gate は reviewer 経路では不要 — reviewer 役に実装物は無い。**全 outcome で `<clear_marker>`="true" `<marker_field>`="reviewLock" を渡し、dispatch 直前に書いた `reviewLock` を同一の原子書込で解除する**(issue #37。解除しないと次 tick 以降この step が選別から永久に外れる)。**`observation`(issue #50 A1・「ルーティング判定」節「呼び方」の共通手続きに従う)**: sink 系(`invalid`/`escalate`/`subjective_escalate`)を解決したときは `<command>/<exit_code>/<summary>` に次を渡す — `invalid`: `<command>`="reviewer dispatch 応答の解析" / `<exit_code>`=1(dispatch 結果失敗を表す) / `<summary>`=不正の内容(例:「JSON として解釈できない」「escalate キーを読めない」)。`escalate`: `<command>`="evaluate-stop-condition.py" / `<exit_code>`=0 / `<summary>`=`$ESCALATE_REASON`(`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` 手順 5.6 の停止条件理由)。`subjective_escalate`: `<command>`="dispatch 応答の escalate_to_human 検出" / `<exit_code>`=0 / `<summary>`=`reason` をそのまま。`clean_pass`/`blockers`(sink でない)は `<command>` を空文字で渡す):
- `invalid`(dispatch 結果失敗)→ `ledger_write` は null(`pr.status` は dispatch 元の `created pr` / `waiting for review` のまま変更しない)。ただし `reviewLock` は解除する必要があるため、適用手続きを `<clear_marker>`="true" `<marker_field>`="reviewLock" で呼ぶ(marker 単独削除)・route=sink・label_action=null。「失敗経路(単一の need for human review sink)」へ。
- `subjective_escalate`(issue #31・上記手順 2 で解決済み)→ 判定器の `ledger_write`(`pr.status`="need for human review")を「ルーティング判定」節の **`ledger_write` の適用**手続きで書く(客観的な `escalate` と同じく書いてから sink)・route=sink・label_action=null。「失敗経路(単一の need for human review sink)」へ(通知本文には「主観的エスカレーション」の 1 語と `reason` を含める)。
- `escalate`(停止条件到達)→ 判定器の `ledger_write`(`pr.status`="need for human review")を「ルーティング判定」節の **`ledger_write` の適用**手続きで書く(reviewer は `pr.status` のみ・`<pr_number>` は空文字でよい)・route=sink・label_action=null。「失敗経路(単一の need for human review sink)」へ(sink 共通手続きが `need for human review` ラベル付与 + PushNotification を行う)。
- `clean_pass` → 判定器の `ledger_write`(`pr.status`="ready for merge")を「ルーティング判定」節の **`ledger_write` の適用**手続きで書く(reviewer は `pr.status` のみ・`<pr_number>` は空文字でよい。**status リテラルは prose に複製せず `$ROUTE.ledger_write` から書く**)・route=normal・label_action=`add_ready_for_merge`。
- `blockers` → 判定器の `ledger_write`(`pr.status`="completed review")を同手続きで書く・route=normal・label_action=`remove_ready_for_merge`。

`subjective_escalate` / `escalate` / `clean_pass` / `blockers` の 4 分岐はいずれも判定が確定し `pr.status` が遷移するため、上記の `ledger_write` 適用の直後に「作業レポートの代筆」節の共通手続きで対象 step の `reports[]` へ 1 件追記する(`author`="pr reviewer"・`role`="reviewer"。`invalid` は dispatch 結果失敗で判定物が無いため追記しない)。

label_action(`ready for merge` ラベル同期)の実コマンドは「ルーティング判定」節の `label_action の実行` を参照する(prose に複製しない)。

## evidence gate(対称モデル)

evidence gate は orchestrator 自身が独立した一時 worktree を用意して `evidence.done`(台帳 `.harness/plan-progress.json` の `evidence.done`、無ければ `evidence.test` にフォールバック)を実行する共通機構(具体的な worktree の作り方は「developer(実装役)」節の手順 5 参照)。**実装役・対応役いずれも、evidence gate 失敗時は判定器が `route=sink` を返し、単一の need for human review sink に到達する(対称)**:

- **developer(実装役)**: `pr_number` が確定した(PR は実在する)場合、失敗 outcome=`pr_evidence_fail` → `pr.status="created pr"` を 1 回のローカル書込で書き込んだうえで sink。PR 未作成(復旧検索 0 件)は outcome=`no_pr` → route=skip で書込まず次 tick 再 dispatch(副作用が無いので暴走しない。**issue #26(P1 決定)により、原因が持続的(issue 実装不能 / developer subagent の決定論的クラッシュ)でも「tick 冒頭 reconciliation」節の in-flight マーカーが締切 K=2 tick・リトライ上限 N=2 で有界化し、尽きれば outcome=`timeout` として sink する — もはや無界ではない(詳細は「tick 冒頭 reconciliation」節・「既知の制限・拡張ポイント」節参照)**)。復旧検索が複数一致(曖昧)は outcome=`ambiguous` → route=sink・書込なし。
- **developer(対応役)**: 対象 PR は既に存在し `pr.number` も書込済み。失敗 outcome=`evidence_fail` → 書込なし(`pr.status="completed review"` のまま = 未解決 blocker が残る事実)で sink。**旧版の「書込まずスキップ + 再試行」は取らない** — `completed review` は reviewer が選別しないため round カウンタが進まず、round≥5 の停止条件に永久に到達しない無界ループになるため。

これで「どのロールの evidence 失敗も need for human review に到達し、無界ループを残さない」という対称性が、判定器の `route=sink` として一元化される(失敗経路の一元化)。

## 書込方式

`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` の手順 3/6 と同じく、台帳 (`.harness/plan-progress.json`) は git にコミットしないローカル台帳として扱う(issue #11 F案)。状態遷移は「`ledger_write` の適用」手続きによる **ローカルファイル編集だけで完結させ、`git add` / `git commit` / `git push` は行わない**(main への直接 push を禁止するポリシーのリポジトリでもそのまま動く)。作業ツリー上で台帳が「変更あり」になるのは正常。

**台帳検証の自己申告(Statuses API)**: 状態遷移をローカルに書いたら、ローカル validator の実行結果を **対象 PR の head SHA** に対して Statuses API で報告する(「commit されない台帳」の機械検証の代わり。GitHub ホスト CI は commit されない台帳を検証できないため)。branch protection の required check はこの context(`harness-gate`)を指定する。Check Run 作成(Checks API)は GitHub App 認証専用で個人 `gh auth`(PAT/OAuth)では作れないため使わず、必ず **Statuses API**(`POST /repos/{owner}/{repo}/statuses/{sha}`)を使う。**この自己申告は独立検証ゲートではなく便宜シグナル(convenience signal)である**(spoof 可能・独立ランナー不在の受容コスト。詳細と限界は `.harness/CLAUDE.harness.md`「台帳の書込経路」節)。

schema/drift のローカル実行 → Statuses API への post は **`scripts/report-ledger-status.sh` に抽出済み**(`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` 手順 3/6 と共有する単一の実体。報告ロジックを散文に複製しない — `scripts/*.py` と同じ「規則は script が正」の境界)。スクリプト内で `ROOT="$(git rev-parse --show-toplevel)"` から `PLAN` / validator を**すべて絶対パス**で解決するため、CWD が repo ルート以外でも失敗しない:

```
# <head_sha> は対象 PR の head SHA (gh pr view <n> --repo <repo> --json headRefOid --jq .headRefOid)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/report-ledger-status.sh" "<repo>" "<head_sha>"
# 引数: $1=<owner/repo> $2=<head_sha> [$3=context(省略時 harness-gate)]
# schema/drift をローカル実行し、結果(success/failure)を対象 SHA へ Statuses API で post する
```

### Statuses post 失敗の surface と global halt(issue #37・欠落 5)

`report-ledger-status.sh` が STATE=`success`/`failure` のいずれかを **post できた**場合(スクリプト自体が exit 0)、それは台帳の schema/drift 状態を正しく報告できているので追加対応は不要(STATE=`failure` は台帳側の問題であり別途「台帳の書込経路」節の drift 照合が扱う)。ここで扱うのは、**post という行為そのものが失敗するケース**(`gh api` 呼出の失敗 = `report-ledger-status.sh` 自体が非 0 で終了する。原因は欠落 4 の `gh auth switch` 事故・token 失効・network・rate limit 等)。この失敗は元々 tick に何も表面化させず、`required check`(`harness-gate`)が付かない PR が無言で残る実害があった(実測)。

- **カウンタ(`statusesPostFailCount`・transient・schema 非宣言)**: 台帳 top-level に整数フィールドを持つ(`orchestratorTick` と同型・キー無しは 0 扱い)。`report-ledger-status.sh` を呼ぶたびに終了コードを見る: **非 0 なら 1 加算**、**0(post 成功。STATE の値によらない)なら 0 にリセット**する。
- **tick 報告への surface(常時)**: 呼ぶたびに成否を tick 報告(下記「報告」節の dispatch サマリ表)へ 1 列として記載する。これは post が失敗しても成功しても毎回行う(全 step を横断するため症状に合う)。
- **global halt(連続失敗が閾値に達したら)**: `statusesPostFailCount` が **3 回**(校正根拠の無い best-effort 値。他所の `K`/`N=2` より 1 大きいのは、単発の network flake で即 halt しないための余裕)に達したら、**その時点で処理中の tick の残り候補への dispatch を打ち切る**(既に完了した step のローカル書込は取り消さない — 台帳への書込は post 試行より前に完了しているため、halt は post の失敗そのものへの対応であり、ローカル状態を巻き戻す話ではない)。`PushNotification` で人間に auth/network の復旧を促し、tick 報告に `🛑 global halt` を明記する。**counter はリセットしない**(次 tick も引き継ぐ)。**tick 全体を将来にわたって停止する仕組みは持たない** — 次 tick は通常どおり選別・dispatch を試み、最初の step の post 結果が自然な回復確認(probe)になる。成功すればそこで counter が 0 にリセットされ通常運転に戻る。失敗すれば(counter は既に閾値以上のため)その step の処理後ただちに再度 halt する。
- **per-step sink にしない理由**: Statuses post 失敗の主因(`gh auth switch` 事故・token 失効・network・rate limit)は **session 全体で起きる global 障害**であり、特定 step の品質問題ではない。特定 step だけを `need for human review` へ sink しても、他 step の post は同じ障害で失敗し続け実害(required check が付かない PR が無言で残る)が他 step で再発する。かつ、作業自体は正しい step を infra 障害で誤って blocker 化してしまう。global halt はこの mis-target を避ける。
- **閾値ロジックを prose に置く理由(既知の位置づけ)**: 「連続 N 回失敗で halt」という閾値つき判定は、本来は `evaluate-stop-condition.py` と同型の decision script に載せる方が「規則は script が正」の設計境界と一貫する(衝突検知(欠落 3)を script 化した判断と対称)。v1 では counter の読み書きが 1 行の比較で足り、prose のまま置いても取りこぼしのリスクが低いため script 化を見送る(over-engineering 回避)。実運用で counter 判定の分岐が増えたら script への切り出しを検討する(follow-up・今すぐ決める必要はない)。

## 作業レポートの代筆(`reports[]`・issue #52 症状2)

**目的**: `.harness/CLAUDE.harness.md`「作業レポートの書込」節が定める単一 writer 原則により、委譲先の子ロールは `reports[]` を直接書かない — 単一 writer(本コマンド)がそのロールを `author`/`role` に記録して代筆する。同節は本コマンドへの配線を「#26(単一 writer・in-flight マーカー)着地後の follow-up」と明記していたが、#26 は着地済みのため本節で配線する(issue #52 Phase A)。

**best-effort のまま(機械強制はしない)**: `reports[]` の妥当性(件数・timestamp 形式・必須キー)は引き続き `validate-plan-progress.py --schema` の検査対象外(`.harness/CLAUDE.harness.md` 同節)。本節が足すのは「orchestrator が動く限り書き忘れない」経路であって、書込自体を machine-enforce するものではない。

**共通の書込手続き**(`ledger_write` の適用手続きと同型・別ファイル書込で行う。1 tick 内で複数 step を処理する場合、この手続きは step ごとに個別実行する): 各ロール節が outcome を解決し `ledger_write` を適用した**直後**、対象 step の `reports[]` へ 1 件追記する。追記は「書込方式」節の Statuses API 自己申告より**前**に行う(`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` 手順 6 の「追記は上の status 書込に隣接させ、下記『台帳検証の自己申告』より前に行う」と同じ順序)。`<step id>` は対象 step、`<author>`/`<role>` は下表の値、`<body>` は各ロール節が組み立てた 1〜数文のサマリ。timestamp は UTC・`Z` 終端で生成する(`.harness/CLAUDE.harness.md` が明記する `date -u +%Y-%m-%dT%H:%M:%SZ` と同じ形式を python 側で生成する — macOS/BSD の `date +%z` はコロン無しオフセットを返し schema の timestamp pattern に不一致になるため使わない):

```
PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
python3 - "$PLAN" "<step id>" "<author>" "<role>" "<body>" <<'PY'
import datetime, json, os, sys
plan_path, step_id, author, role, body = sys.argv[1:6]
with open(plan_path, encoding="utf-8") as f:
    plan = json.load(f)
step = next(s for s in plan["steps"] if s["id"] == step_id)
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
report = {"author": author, "role": role, "timestamp": ts, "body": body}
step["reports"] = ((step.get("reports") or []) + [report])[-10:]  # FIFO trim (schema maxItems:10 は超過を拒否するだけで自動削除しないため、append と trim を一体で行う)
plan["updatedAt"] = datetime.date.today().isoformat()
with open(plan_path + ".tmp", "w", encoding="utf-8") as f:
    json.dump(plan, f, ensure_ascii=False, indent=2)
os.replace(plan_path + ".tmp", plan_path)
PY
```

**7 ロールの配線点(名指し。`.harness/CLAUDE.harness.md`「作業レポートの書込」節の表と対応させる — DoD (iv') が要求する「7 ロール各々の代筆点が名指しされていること」を満たす)**:

| 作業ロール(`author` / `role`) | 配線点(outcome) | 本ファイルでの位置 |
|---|---|---|
| `main developer (実装役)` / `developer` | `pr_evidence_pass` または `pr_evidence_fail`(いずれも PR は実在するため対象。`no_pr`/`ambiguous`/`subjective_escalate`/`timeout` は PR 未実在・作業未完のため対象外) | 「developer(実装役)」手順 7 |
| `main developer (対応役)` / `developer` | `evidence_pass` または `evidence_fail`(いずれも対応作業(採用/却下の判断・修正試行)が実際に行われた事実を伴うため対象。`subjective_escalate` は対応未完了のため対象外) | 「developer(対応役)」手順 6 |
| `pr reviewer` / `reviewer` | `clean_pass` / `blockers` / `escalate` / `subjective_escalate`(いずれも判定が確定し `pr.status` が遷移するため対象。`invalid` は dispatch 結果失敗で判定物が無いため対象外) | 「pr reviewer」outcome 実行部 |
| `issue reviewer` / `issue review worker` | 対象外(v1・PR ライフサイクルのみ。issue フェーズの自動化は「orchestrator の性質」節冒頭・「既知の制限・拡張ポイント」節で明記済みのスコープ外 — 本コマンドはこれらのロールを dispatch しない) | — |
| `pr review worker` | 対象外(本コマンドが dispatch しないロール。`developer(対応役)` と機能は近いが、本コマンド経由ではなく個人 skill `working-triaged-pr-for-loop` 経由で手動 / loop 起動される独立ロールであり、本ファイルの配線対象ではない) | — |
| `orchestrator` | 対象外(上記 3 ロール分の代筆行為そのものが単一 writer = 本コマンドの実行として行われるため、別途 `author="orchestrator"` の重複 report は持たない) | — |

**`<body>` の組み立て方(ロールごと)**:
- 実装役: dispatch 応答(`${CLAUDE_PLUGIN_ROOT}/roles/developer-implementer.md` の返り値)に含まれる `summary`(実装内容の 1〜2 文要約)をそのまま使う。空・欠損なら `"issue #<N> の実装(PR #<pr_number>)"` にフォールバックする(observed-fact のみを書く原則により、無い情報を捏造しない)。
- 対応役: dispatch 応答(`${CLAUDE_PLUGIN_ROOT}/roles/developer-responder.md` の返り値)に含まれる `summary`(対応内訳の 1〜2 文要約)をそのまま使う。空・欠損なら `"PR #<n> のレビュー指摘対応"` にフォールバックする。
- pr reviewer: 手順内で既に取得済みの判定結果(`ledger_write` が書く遷移先 `pr.status`)と、dispatch 応答の `has_blocker` / `blocker_count` から組み立てる(例: `"判定 <遷移先 status> / has_blocker=<has_blocker> / blocker_count=<blocker_count>"`)。追加の `gh` 呼出は不要 — `blocker_count` は集計済みの blocker 件数であり finding 総数ではない点に注意(正直な明記。finding 総数を取りたければ `review_markdown` の解析が要るが、v1 では行わない)。

## 既知のリスク(明示)

**issue #11(台帳の git 非依存化・main push 禁止ポリシー)の F案は実装済み**(本節が旧 v1 で「既知の負債」として予見していた自己無効化)。orchestrator の単一書込は、旧方式(main 直接コミット + push)から **ローカルファイル編集 + Statuses API 自己申告**(上記「書込方式」節)へ追従済み。台帳が commit されなくなったことに伴い、git-status ガードは「clean 比較」ではなくスナップショット比較へ調整済み(「単一書込」節・「既知の制限・拡張ポイント」節 (b))。

## 報告

`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` 手順 8 に倣い、tick サマリを分かりやすく出す:

````markdown
## 🚦 Orchestrator tick 報告

**実施: HH:MM**(local time)

### 🧹 tick 開始時の前提整備
- `git fetch origin` OK。ローカル main は `origin/main` から 0 commit 遅れ(遅れがあれば件数を明記。tick は止めない)
- `git worktree prune` 実行済み(除去した admin record: 0 件)

### 📊 dispatch サマリ(N 件、上限 5)

| step | ロール | 遷移前 → outcome → 書込結果 | evidence gate | Statuses post | 失敗 sink |
|---|---|---|---|---|---|
| P8 | developer(実装役) | null → pr_evidence_pass → **書込済み(#N)** | ✅ exit 0 | ✅ | — |
| P9 | developer(実装役) | null → pr_evidence_fail → **書込済み(#M)** | ❌ 非 0 | ✅ | 🛑 need for human review 付与 + 通知済み |
| P13 | pr reviewer | created pr → clean_pass → **ready for merge** | — | ✅ | — |
| P11 | pr reviewer | waiting for review → escalate → **need for human review へ書込済み** | — | ✅ | 🛑 need for human review 付与 + 通知済み |
| P10 | pr reviewer | created pr → invalid(dispatch 失敗)→ **`reviewLock` のみ解除** | — | ✅ | ⚠️ ラベル付与失敗(手動付与が必要) |
| P12 | developer(対応役) | completed review → evidence_fail → **`reviewLock` のみ解除** | ❌ 非 0 | ❌(`gh api` 失敗) | 🛑 need for human review 付与 + 通知済み |
| P14 | developer(実装役) | ready for implementation → subjective_escalate(issue #31) → **書込なし(marker 永続 + notified 付与)** | — | ✅ | 🔔 通知済み(ラベル対象 PR なし・主観的エスカレーション) |

**失敗 sink 列は無条件に「付与 + 通知済み」と書かない**(報告虚偽の防止)。sink 共通手続き手順 1 の `LABEL_OK` と通知の成否を**実際に反映**する: 付与成功時のみ「🛑 need for human review 付与 + 通知済み」、`add-label` 失敗時は「⚠️ ラベル付与失敗(手動付与が必要)」と正直に書く(上表 P10 が失敗例)。**PR が実在せずラベル付与そのものを行わない変則(`timeout`・実装役 `subjective_escalate`)は、「🛑 付与」/「⚠️ 失敗」のいずれでもなく「🔔 通知済み(ラベル対象 PR なし)」と書く**(上表 P14 が例。この行が「🛑 付与 + 通知済み」になっていると、実際には付与していないラベルを付与済みと報告する虚偽になる)。**Statuses post 列も実際の `report-ledger-status.sh` 終了コードを反映する**(issue #37・欠落 5。上表 P12 が失敗例 — `gh api` 呼出の失敗であり、台帳の schema/drift とは別の障害)。

### ⏭️ スキップ(あれば)
- #M は `need for human review` ラベル付きのため無条件スキップ
- #K は復旧検索 0 件(`no_pr`・PR 未作成)のため書込せずスキップ(次 tick 再試行。`dispatchMarker` の締切 K=2 tick・リトライ上限 N=2 で有界化済み — issue #26)
- #L はファイル衝突検知(`detect-dispatch-collision.py`)で他候補と同一 group と判定され、marker を書き換えずに次 tick へ持ち越し(issue #37・欠落 3)

### 🛑 失敗 sink 到達(あれば)
- #N: 理由(`escalate` 停止条件: round 上限到達 / blocker 傾向未改善 / reviewer dispatch 失敗(`invalid`・不正応答)/ 実装役 evidence 失敗(`pr_evidence_fail`)/ 対応役 evidence 失敗(`evidence_fail`)/ git status ガード検知 / `Closes #N` 復旧検索が複数一致(`ambiguous`)/ 実装役 dispatch が締切超過・リトライ上限到達またはマーカー不整合(`timeout`・issue #26。PR 未作成のためラベル付与なし・`dispatchMarker` の永続で無条件スキップ)/ 主観的エスカレーション(`subjective_escalate`・委譲先の自己申告。issue #31))

### 🌐 Statuses post 連続失敗(global halt。あれば)
- `statusesPostFailCount`=3 に到達したため、残り候補(#P, #Q)の dispatch をこの tick では見送った。`PushNotification` 済み。次 tick の最初の post が成功すれば counter は 0 にリセットされ通常運転に戻る(issue #37・欠落 5。詳細は「書込方式」節『Statuses post 失敗の surface と global halt』参照)。

### ↩️ 誤判定の巻き戻し方
台帳の書込はローカルファイル編集のため、誤りがあれば手動で `pr.status` / `issue.status` を巻き戻し、`need for human review` ラベルを外して、次 tick で再評価させる。
````

0 件 tick の場合は「dispatch 対象なし」の 1 行報告に簡略化する。

## loop での回し方

- 試行: `/loop 15m /harness-orchestrate`(review-mode=code-review 既定、15 分間隔)。
- review-mode を明示したい場合: `/loop 15m /harness-orchestrate owner/repo multi-angle`。
- `/loop` は起動時の引数をそのまま毎 tick 再実行するため、review-mode は起動時の引数が毎 tick 引き継がれる。追加の状態保持は不要。
- **ゴール文言(`$3`)を渡すモードは `/loop` と併用しない**: `/loop` は起動時の引数をそのまま毎 tick 再実行するため、`$3` 付きで `/loop` に渡すと「`/goal` 文字列を組み立てて提示するだけ」の処理(通常 tick を実行しない)が毎 tick 繰り返され、実質的に何も進まない。`$3` 付き起動は 1 回限りの単発呼出として使い、提示された `/goal <文言>` をユーザーが実行することで初めて継続実行が始まる(上記「`/goal` 起動文字列の組み立て」節参照)。

## 既知の制限・拡張ポイント

- **真の無人化はまだできない**: `/loop` はセッションが開いている間だけ定期実行できる方式であり無人ではない。GitHub Actions `on: schedule` / `/schedule` クラウド routine による真の無人化は、判定 skill(`reviewing-multi-angle` 等・review-mode=multi-angle のみ)の kit 同梱が前提になるため別途対応が必要(review-mode=code-review(既定)は issue #49 以降 `${CLAUDE_PLUGIN_ROOT}/collectors/strategy.md`(kit 同梱・個人 skill 不要)による角度別 finder 収集のみに依存する。導入先が `.harness/collectors/angles/` に `skill:` 付き角度を追加した場合はその skill にも依存する)。
- **issue #11 の F案は実装済み**: 上記「既知のリスク」節参照。orchestrator の単一書込は ローカルファイル編集 + Statuses API 自己申告へ追従済み(main への直接 commit/push はしない)。
- **issue サイド(issue reviewer / issue review worker)の自動化は対象外**: v1 は PR ライフサイクルのみ。issue フェーズの配車は別 issue の範囲。
- **git-status ガードの限界と設計境界(部分的バックストップ・正直な明記)**: 台帳保護には次の点がある。
  - **(a) subagent の worktree 編集は捕捉できない**: 実装役 subagent は自前の worktree で作業するため、その `.harness/` 編集は orchestrator 自身の checkout で走る `git status` からは**見えない**。したがってこのガードは **orchestrator 自身の checkout 内の編集しか捕捉できない部分的バックストップ**に過ぎない。**「subagent に `Write` を渡さない」ツール制限は台帳保護の隔離にならない(issue #37・欠落 9。理由は「単一書込」節参照 — `Bash` を持つ子は `Bash` 経由で台帳を編集でき、実装役は `Bash` が必須)**。したがって台帳保護の実質はこの git-status ガード(部分的バックストップ)と各ロール委譲プロンプト冒頭の禁止文言(L1)のみに依存する。`Bash` 経由の編集は完全には防げず、hook 等による L3 相当の強制ではない。追加の構造防御は `Agent` ツールに環境隔離が入るまで別 issue とし、主防御の不在を正直に受容する。
  - **(b) 自身の書込の誤検知を避ける(ローカル編集方式)**: ローカル編集方式(F案)では orchestrator 自身の書込は commit されず作業ツリーに残り続ける(`.harness/plan-progress.json` は常に dirty)。この自分の書込を subagent の変更と**誤検知しない**よう、ガードは `git status` の dirty 判定ではなく、`plan-progress.json` については **orchestrator が最後に書いた内容のスナップショットと照合**し、`.harness/` のそれ以外のファイルのみ `git status` で HEAD 一致を確認する。orchestrator は自身の各書込の直後にスナップショットを更新する(「dirty = subagent の意図しない変更」と短絡しない — 誤検知で無関係 step を spurious に sink 隔離するのを防ぐ)。
  - **(c) git-status ガードだけが decision script を通らない唯一の失敗経路(設計境界・意図的)**: 他の全失敗面は「ルーティング判定」節の decision script が `route=sink` として決めるが、git-status ガードの drift 検知 → sink だけは script を経由しない。これは意図的である — **git-guard trip は「(role, outcome) に紐づくルーティング判断」ではなく、全ロール横断(cross-cutting)の pre-write 前提チェックであり、その帰結は自明に sink(分岐する判断ロジックが無い)ため decision script の対象外とする**(decision script はルーティング「判断」を集約するものであって、判断の無い自明な guard→sink はその対象ではない、という設計境界)。無理に決定表へ押し込まない。
- **dispatch 上限 5 件のトレードオフ**: 1 tick で処理しきれない場合は次 tick へ持ち越される(dedup は各ロールの status 遷移が担う)。**「tick 冒頭 reconciliation」の `redispatch` 候補もこの上限の対象**(「選別(jq)」節参照)であり、枠から溢れた候補は marker を書き換えずに持ち越されるため retry_count は消費されない。
- **ファイル衝突検知(`scripts/detect-dispatch-collision.py`)の抽出規則は machine-enforce されていない(既知のギャップ・issue #37・欠落 3)**: script が受け取る `files` は issue 本文の Implementation Scope から prose が抽出したものであり、抽出規則(バッククォート内のパスのみを対象ファイルとし、通りすがり言及を除外する)自体は script の対象外(pure-function 境界を守るため。「衝突判定(グラフの連結成分)」だけが script 側の正)。抽出漏れ・誤抽出は smoke では検出できず、fail-closed(`files: []`)側に倒すことで実害を「衝突不明な step を保守的に別 tick へ回す」に留めている。
- **ルーティングは tested decision script**: (role, outcome) → (ledger_write, route, label_action) を `scripts/decide-orchestrator-route.py` が決定論的に解決し、`tests/smoke/run-smoke.sh` [8] が全 (role × outcome) 14 行を網羅検証する(reviewer の `invalid` 分岐 / implementer の `timeout` 分岐(issue #26)/ 3 role 共通の `subjective_escalate`(issue #31)を含む)。散文分岐の取りこぼしを構造的に防ぐのが目的で、規則は script が正・prose は「outcome への解決」と「route の実行」だけを持つ。
- **A1(sink 系 outcome の観測必須フィールド)は独立検証ではなく自己規律の強化に留まる(issue #50 owner 決定 (b)・正直な明記)**: `route=sink` への解決に `observation`(コマンド + 終了コード + 出力要約)を必須化する A1(「ルーティング判定」節「呼び方」・`decide-orchestrator-route.py` モジュール docstring 参照)は、orchestrator 自身の 2 日間の自動運転で「観測できないもの」を「失敗」と 7 回誤断した実害(issue #50)への対策として導入した。**ただしこの検証は `observation` の存在・型のみを確認し、内容の真偽は検証しない** — orchestrator prose(判定を下す当人)が虚偽の観測を書けばそのまま通る(spoof 可能)。issue #50 の owner は「症状1(orchestrator/doer 自身の sink 判断)の常用経路は独立検証ゼロを正直に受容する」と決定した(選択肢 (b)。#17 round2 の Statuses API 自己申告「security boundary ではなく便宜シグナル」と同じ流儀)。**症状2(doer による DoD の独断書き換え)とは非対称**: そちらは PR reviewer という独立読み手(別セッション)が `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` の DoD 照合手順(issue #50 B2)で機械的に塞ぐが、症状1(orchestrator が sink へ倒す判断そのもの)には対称の独立読み手が存在しない。この非対称は本 issue の対応(Worker 権限)では解消できないと判断され保留された構造的な限界であり、(a) sink 倒し込み側にも独立検証の主体を配線する、という選択肢は #21(完全無人化)を本気で進める段階の前提として別途 issue 化する想定(issue #50 本文「レビュー反映 — 決定事項(round1/round2)」+ owner 決定コメント参照)。
- **`dispatchMarker` のライフサイクル(削除 / 永続 / 永続+`notified`)は machine-enforce されていない(既知のギャップ)**: 上記の decision script が検証するのは `(ledger_write, route, label_action)` の 3 つだけで、実装役の各 outcome が marker をどう扱うか(手順 6 の 3 分類)は `DECISION_TABLE` にも `tests/smoke/run-smoke.sh` にも反映されておらず、手順 6 の固定列挙(prose)だけが正である。これは意図的な現状維持であり、次の理由による: (i) `dispatchMarker` は issue #26 の決定により schema 非宣言・transient なフィールドであり、`validate-plan-progress.py` の対象外(marker の**存在確認・妥当性**は `reconcile-dispatch-marker.py` が既に smoke [9] で網羅検証しているが、これは「marker が有効か」の判定であって「outcome ごとにどう処理すべきか」の判定ではない — 後者を machine-enforce するには decision script の出力契約(`ledger_write`/`route`/`label_action`)を拡張する必要があり、これは 1 フィールド追加では済まず、`decide-orchestrator-route.py` の 14 行・smoke [8] の `assert_route` 全件・「ルーティング判定」節の適用手続き・reconciliation の timeout 分岐(現状 decision script を経由しない別経路)を横断する変更になる。(ii) issue #31 は「主観的エスカレーション経路の追加」がスコープであり、marker ライフサイクルの machine-enforce 化はそれ自体別の改善提案として independently 評価すべき設計変更である。手順 6 を固定列挙(性質ベースの一文ではなく `no_pr`/`ambiguous`/`pr_evidence_pass`/`pr_evidence_fail`/`subjective_escalate` の個別列挙 + 新 outcome 追加時の追記指示)に変更したことが、今回のスコープで取れる現実的な緩和策である。**同種の欠落(散文の一般化が実際の分類を誤る)が今後も観測される場合は、decision script の出力契約への `marker_disposition` 相当フィールド追加を検討する。**
- **issue #26 との共有面(既知の drift リスク)**: `scripts/decide-orchestrator-route.py` の `DECISION_TABLE` と `tests/smoke/run-smoke.sh` [8] は issue #26(dispatch した子の生存監視と失敗の有界化)とも共有ファイルであり、両 issue が独立に `implementer` 行へ新エントリを追加する。詳細と rebase 時の注意点は「主観的エスカレーション(issue #31)」節の「issue #26 との共有面」を参照。
- **失敗経路は単一 sink に集約(重要)**: 実装役・対応役・reviewer のどの経路でも「前進不能 = need for human review sink 到達」で対称に扱う。reviewer も `escalate`(停止条件)に加え `invalid`(dispatch 結果失敗)を持ち、単一 sink をすり抜けない。個別ロールに独自の失敗処理(片方だけ有界停止・片方は無界ループ)を持たせない。書き込む事実 status だけがトリガーごとに異なる(「失敗経路(単一の need for human review sink)」節の一覧表を参照)。**実装役の `no_pr` はこの対称性の唯一の例外だったが、issue #26(P1 決定)で解消済み**(下記「実装役の `no_pr` の有界化(issue #26)」参照)。
- **対応役の無作業検知は escalate backstop に委ねる(意図的な既知の限界)**: 対応役だけは dispatch 結果失敗の即時検知分岐を持たない(最後の非対称)。subagent が **無作業/クラッシュでも test が元々緑なら `evidence_pass` → `waiting for review`** へ進む(偽の前進)。実装役(復旧検索)・reviewer(`invalid` 検知)が dispatch 失敗を即座に sink するのに対し、対応役の無作業だけ検知が **~3 round 遅延する**という latency の非対称が残る。ただし finding 未対応なら reviewer が同じ blocker を再検出 → `completed review` へ戻す往復が続き、**escalate backstop(round≥5 / blocker trend)が最終的に人間へ surface する**。これは bounded(`has_blocker=true` 維持で `clean_pass`=不正 merge には至らない)であり、walking skeleton では検知機構を足さず backstop に委ねる(作者の意図的判断)。実害(無作業 dispatch が頻発)が観測されたら follow-up で対応役の作業有無(`# PR Review Worker` コメント / commit の有無)検証を足す(対応役 flow の該当箇所にも同旨を明記済み)。
- **実装役の `no_pr` の有界化(issue #26・P1 決定で解消済み)**: 実装役 dispatch 後に PR が未作成(返答不正 + `Closes #N` 復旧検索 0 件)なら outcome=`no_pr` → route=skip で書込・副作用なく次 tick 再 dispatch される点は変わらないが、**issue #26 の「tick 冒頭 reconciliation」節の in-flight マーカー機構(締切 K=2 tick・リトライ上限 N=2)がこれを有界化する**。P1 決定(所有者判断・2026-07-14)により「無状態 tick では『完了して no_pr』と『まだ処理中』を区別できない」ため、`no_pr` は独立カウンタ(`no_pr_count`)を持たず、**締切超過(timeout・真の hang)と同じ `retry_count` に畳み込んで数える**。持続的な原因(issue が実装不能 / developer subagent が決定論的にクラッシュ)でも、最大 N=2 回のリトライ(計 3 dispatch)後は outcome=`timeout` として sink へ到達する。**本コマンドが掲げる「無界ループを残さない / 失敗経路を対称に扱う」不変条件の唯一の(文書化された)例外はこれで解消された**(旧版はこの段落で `no_pr` を無界の既知の限界と明記していたが、issue #26 の実装後は該当しない)。
  - **残る限界(issue #26 v1 のスコープ・意図的)**: (i) dispatch call 自体がセッションを止める**真の hang**は、`Agent` ツールにタイムアウト parameter が無い制約が変わらないため、リアルタイムには検知できない(marker が dispatch 直前に書かれているため、**人間がセッションを再起動した次の tick**で `TICK > deadline_tick` として事後検知される — tick を跨いだ persistent state による回復であり、hang 中のリアルタイム検知ではない)。(ii) `dispatchMarker`(`dispatched_tick`/`deadline_tick`/`retry_count`、および sink 通過後に追加される任意キー `notified`)は transient フィールドで schema に宣言せず、`validate-plan-progress.py` の `--schema`/`--drift`・`tests/smoke/run-smoke.sh` の複製一致検査のいずれも検査対象にしない(壊れた/不整合なマーカーへの fail-closed 判定は `reconcile-dispatch-marker.py` 自身の責務であり、この判定ロジック自体は smoke `[9]` で網羅検証している。`notified` は script が読まない prose 専用の帳簿フィールドであり script の妥当性検査の対象外)。(iii) implementer/`timeout` の sink は PR が存在しないため `need for human review` ラベルを付与できず(`ambiguous` と同じ制約)、「無条件スキップ」は永続する `dispatchMarker` 自体が実装する — 人間の解除手段はラベル解除ではなく `dispatchMarker` の手動削除(「tick 冒頭 reconciliation」節参照)。(iv) `ambiguous` outcome 自体の再 dispatch 有界化は本 issue のスコープ外(手順 7 の原子書込で `dispatchMarker` を削除し、marker による有界化の対象外にする — 挙動は issue #26 以前と変わらない)。(v) K=2 tick / N=2 の値は校正根拠の無い best-effort(loop 間隔が実装役の想定所要より十分長い前提)であり、観測に応じた見直しは follow-up。
- **sink の出口を人間の意図と結線(issue #12 で実装済み)**: 「失敗経路(単一の need for human review sink)」節の**「sink の出口を人間の意図と結線」**を参照。reviewer/`escalate` は `pr.status="need for human review"` を書いてから sink するため、ラベル解除だけでは再 dispatch されない(status も人為的に戻す必要がある)。この結線の恩恵は `escalate` 経路のみで、`invalid`(dispatch 結果失敗)は引き続き無書込のまま(書ける確定事実が無いため)。
- **ラベル同期ロジックの複製(drift リスク)**: 本コマンドのラベル同期ロジック(「ルーティング判定」節の `label_action の実行`)は `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` 手順 6 の内容を単一書込の都合上複製している。将来どちらかの label 定義(色・説明・名称)を変更する場合は両ファイルを同時に更新すること(自動で同期されない、既知の drift リスク)。
- **developer(実装役・対応役)の dispatch prompt 外出し(issue #38・毎 tick の実効トークン削減)**: 両ロールの dispatch prompt 本文(旧版で本ファイルへ直接埋め込まれていた `> 「...」` の巨大な引用ブロック)を `${CLAUDE_PLUGIN_ROOT}/roles/developer-implementer.md` / `${CLAUDE_PLUGIN_ROOT}/roles/developer-responder.md` へ抽出した(pr reviewer 節が `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` を参照する既存パターンと同型)。抽出後は複製ではなく単一ソース化(旧「ラベル同期ロジックの複製」のような drift リスクは生じない)。**この参照ファイルは dispatch された subagent 自身が(自分の Read ツールで)読む設計であり、orchestrator 自身は読まない** — したがって当該ロールの dispatch が 0 件の tick では orchestrator はもとより誰もこれらのファイルを読まず、毎 tick の実効トークンが無条件に(dispatch の有無を判定する分岐無しで)削減される。実装役・対応役それぞれの evidence gate worktree 手続き(`git worktree add` の残骸掃除・実行・後始末)も、両ロールでほぼ同一だったロジックを `scripts/run-orchestrator-evidence-gate.sh` へ dedup 抽出した(こちらは全 tick で無条件に本体の行数を下げる。「developer(実装役)」節 手順 5・「developer(対応役)」節 手順 5 参照)。
- **委譲先の返り値は独立検証できない(正直な明記・意図的に塞がない。issue #37・欠落 7)**: pr reviewer の `has_blocker` / `escalate`、および 3 role 共通の `escalate_to_human` は、いずれも委譲先 subagent の自己申告であり、orchestrator 側で機械的に裏取りする手段が無い。evidence gate(`evidence.done` の独立再実行)は実装役・対応役の**作業結果**を独立検証しているが、reviewer の**判定そのもの**(diff を実際に見て finding を出したか)は検証できない — 捏造する reviewer が `clean_pass` を返せば `ready for merge` まで進んでしまう。緩和策は各ロール委譲プロンプト**冒頭**の「観測していないことを書くな。『エラー』と『処理中』を区別せよ。分からないことは未観測と書け」という L1 文言のみで(「dispatch 先ごとの委譲方式」節 各ロールの冒頭注記を参照)、実測では捏造後に自己訂正が起きたことはあるが、これは検証の代替ではない。`.harness/CLAUDE.harness.md` が明記する「doer ≠ judge の実質はほぼ別セッションの PR reviewer が実際の diff/状態を初見で読むこと単独に依存する」という設計は、その reviewer 自身のレイヤでは担保されないまま残る既知の限界であり、現時点で構造的な解決策は無い(塞げないものを塞いだことにしない)。
- **作業レポート代筆(`reports[]`)は machine-enforce されていない(既知のギャップ・issue #52 症状2)**: 「作業レポートの代筆」節の配線は、実装役 / 対応役 / pr reviewer の 3 ロールについて `ledger_write` 適用直後に `reports[]` へ追記する経路を追加するが、これは `tests/smoke/run-smoke.sh` の検証対象ではない(schema/drift 検証の対象外という `.harness/CLAUDE.harness.md` の既存の best-effort 方針をそのまま引き継ぐ)。したがって配線コード自体に typo や欠落があっても smoke は緑のまま通りうる — 発見は目視レビューか、ダッシュボードの `WorkFeed` で report が欠落していることの事後観測に依存する。issue reviewer / issue review worker / pr review worker / orchestrator 自身の 4 ロールは、本コマンドが dispatch しない(issue フェーズは v1 スコープ外・`pr review worker` は独立 skill)ため配線対象外であることを「作業レポートの代筆」節の表で明示した(DoD (iv') が要求する「7 ロール各々の代筆点の名指し」は、この「対象外である」という明記も含めて満たす)。
