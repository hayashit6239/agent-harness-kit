---
description: 対象 repo の .harness/plan-progress.json を単一の書込主体として、developer(実装役・対応役)と pr reviewer の 2 ロールを配車する orchestrator(v1 walking skeleton・PR ライフサイクルのみ)。判断ロジックは一切持たず、既存の判定 skill/command(`/code-review` または `reviewing-multi-angle` 経由の `commands/harness-review-pr.md`)に委譲し、返答を検証してから台帳へ書き込む。前進できない状況は原因を問わず単一の失敗経路(needs-human sink)に集約する。ルーティング(台帳書込・sink・ラベル操作)は各ロールが状況を outcome トークンに解決したうえで tested decision script(`scripts/decide-orchestrator-route.py`)で決定論的に解決し、規則を散文に複製しない。
argument-hint: "[owner/repo] [review-mode]  省略時: CWD の origin から自動判定 / code-review(opt-in: multi-angle)"
allowed-tools: [Bash, Agent, PushNotification, Skill, Read]
---

# /harness-orchestrate — developer / pr reviewer を配車する orchestrator(v1 walking skeleton)

これは **運用(policy)** の層であり、minimal 構成の上に乗る **orchestrator ロール**(Phase 2 の中核機構の最初の増分)。対象は **developer(実装役・対応役)と pr reviewer の 2 ロール、PR ライフサイクルのみ**(issue reviewer 側の自動化は対象外)。

## orchestrator の性質(判断を持たない調整層)

**本コマンドは判定ロジックを一切持たない。** レビュー当否・実装内容の良し悪しを判断するのは常に dispatch 先の subagent(pr reviewer / developer)であり、orchestrator はその**提案を検証し、台帳へ書き込むかどうかを機械的なゲート(evidence gate / git status ガード)でのみ判定する**。orchestrator が持つ責務は次の 5 つだけ:

1. 配車判断(下記の配車テーブルに従い、どの step にどのロールを dispatch するか決める)
2. dispatch 先 subagent への委譲(判定・実装ロジックは転写せず、参照すべき command/skill を読ませて実行させる)
3. 返答の検証(evidence gate・git status ガード)
4. 台帳への単一書込
5. 前進できない状況の集約(下記「失敗経路(単一の needs-human sink)」へルーティングする)

## 単一書込

**台帳(`.harness/plan-progress.json`)への書込は本コマンドだけが行う。** dispatch する subagent には台帳の書込ツールを渡さない:

- **実装手段**: `Agent` ツールで subagent を起動する際、渡すツールを `Read, Skill, Bash, Grep, Glob` に絞り、**`Write` を渡さない**(subagent が台帳ファイルを直接 Write できないようにする)。
- **限界を正直に明記する**: `Bash` を渡す以上(`gh` コマンド実行・`reaggregate-has-blocker.py` 実行に必要)、subagent が `Bash` 経由で `.harness/plan-progress.json` を編集すること自体は**技術的に完全には防げない**(この repo の他の「触らないものを厳守」規約と同様、L1 policy 相当の制約であり L3 hook 相当の強制ではない)。
- **技術的バックストップ(git status ガード)**: dispatch から subagent の返答を受け取った後、**台帳へ書き込む前に必ず** `git status --short -- .harness/` を実行し、**tick 開始時にクリーンだと確認したベースラインと比較する**(orchestrator 自身の書込は `mv` 後・commit 前に一時的に dirty になりうるため、この既知の書込を除外して評価し、mid-tick 残渣を subagent の変更と**誤検知しない**)。ベースラインから外れる変更があれば(= subagent が dispatch 中に orchestrator の checkout 内の `.harness/` へ意図しない変更を加えた形跡)、その提案を採用せず、当該 step を下記「失敗経路(単一の needs-human sink)」へルーティングする(`git checkout -- .harness/` 等の破壊的な巻き戻しは行わず、状態を報告して人間の判断を待つ)。**このガードの限界(subagent の worktree 編集は見えない=部分的バックストップに過ぎず、主たる防御は「Write を渡さない」ツール制限であること)は「既知の制限・拡張ポイント」節に正直に明記する**。

## 失敗経路(単一の needs-human sink)

**原則: orchestrator が step を安全に前進させられない状況は、原因を問わず単一の失敗経路に集約する。** すなわち **`needs-human` ラベル付与 + `PushNotification` + 事実に即した台帳書込(あれば)→ 以後その step は人間がラベルを外すまで配車テーブルで無条件スキップ**。実装役・対応役・reviewer 経路すべてで**対称に**扱う(どのロールでも「前進不能 = この sink に到達」であり、片方だけ有界停止・片方は無界ループ、という非対称を作らない)。**どの状況が sink に落ちるかは「ルーティング判定」節の decision script が `route=sink` として決める**(下表はその sink 経路を人間向けに列挙したもので、規則そのものは script が正)。

### この sink にルーティングされるトリガー(全経路の一覧)

| トリガー(状況) | role/outcome(判定器トークン) | この sink で書き込む事実 status |
|---|---|---|
| reviewer dispatch が `escalate=true` を返した(round/trend 停止条件) | reviewer/`escalate` | 書込なし(`pr.status` は dispatch 元の `created pr` / `waiting for review` のまま) |
| reviewer dispatch の返答が JSON でない / `escalate` を読めない(dispatch 結果失敗) | reviewer/`invalid` | 書込なし(dispatch 失敗のため状態を変えない。`pr.status` は dispatch 元のまま) |
| 実装役 dispatch 後の evidence gate 失敗 | implementer/`pr_evidence_fail` | `pr.number` + `pr.githubState="open"` + `pr.status="created pr"`(PR は実在するという事実。単一コミット後に sink) |
| 対応役 dispatch 後の evidence gate 失敗 | responder/`evidence_fail` | 書込なし(`pr.status` は `completed review` のまま。未解決の review blocker が残っているという事実) |
| 実装役の `pr_number` 復旧検索(`Closes #N`)が複数一致(曖昧) | implementer/`ambiguous` | 書込なし(誤った番号を書かない) |
| git-status ガードが `.harness/` への意図しない変更を検知 | (判定器の外・単一書込ガード) | 書込なし(提案を破棄する) |

**注**: 上表の「書き込む事実 status」列は decision script の `ledger_write` 出力を人間向けに説明するものであり、status リテラルの唯一の正は decision script。実行時は各ロール節が `$ROUTE.ledger_write` を台帳へ書く(適用手続きは「ルーティング判定」節の **`ledger_write` の適用**参照)。表内の status 文字列は表示・説明用途に留まり、実行される書込は script 出力から来る。**最終行の git-status ガードだけは decision script を通らない**(role/outcome 列が「判定器の外」と示すとおり)— その扱いは「既知の制限・拡張ポイント」節 (c) を参照。

**書き込む事実 status がトリガーごとに異なる**のは、「その時点で GitHub 上に確定している事実」を写すため:
- **reviewer/`escalate`・reviewer/`invalid`**: reviewer は選別 jq 上 `created pr` / `waiting for review` からしか dispatch されないため、無書込なら status は**その dispatch 元のまま**(reviewer に実装物は無く status を進める根拠が無い)。旧記述の「`completed review` のまま」は誤りだった(reviewer が `completed review` を選別することはない)。
- **対応役 evidence 失敗**: `completed review` のまま(未解決 blocker が残る事実)。
- **実装役 evidence 失敗**: `created pr`(PR 実在の事実)。

`escalate` や「停止条件」そのものは台帳に一切書かない(needs-human ラベルと PushNotification のみがエスカレーションの記録)。

**既知の限界(#12/P14 で解消予定・深い修正)**: reviewer/`escalate`(および reviewer/`invalid`)の sink は台帳を書き換えないため、**人間が `needs-human` ラベルを外すと status は `created pr` / `waiting for review` のままで reviewer へ再 dispatch され、原因が未解消なら再び escalate に逆戻りする**(sink の出口が人間の想定意図と結線されていない)。この再 escalate ループは、停止条件到達時に `pr.status` を新 enum `need for human review` へ遷移させる **issue #12 の follow-up 要件(台帳 P14 で tracking 済み)で解消予定**。本 PR は schema 変更を伴うためスコープ外(#14 merge 後の follow-up)であり、**この PR で新 enum 値 `need for human review` を実装してはならない**。現状は既知の限界として明示する。

### sink の共通手続き

事実に即した台帳書込(上表・あれば)を行った**うえで**、次を実行する:

1. `needs-human` ラベルを PR に付与する。**必ず create(fallback・冪等)を先、add を後の順で実行し、`add-label` の exit code を確認する**(`gh` はラベル未存在の状態で `add-label` するとエラーになるため。同ファイル内「ルーティング判定」節の `ready for merge` ラベル操作と同じ順序に揃える。色・説明は `commands/harness-review-pr.md` 手順 6 の `ready for merge` ラベル作成パターンに倣う):
   ```
   gh label create "needs-human" --color "d93f0b" --description "orchestrator が人間の判断を要求した PR" --force
   if gh pr edit <n> --repo <repo> --add-label "needs-human"; then LABEL_OK=1; else LABEL_OK=0; fi
   ```
   `LABEL_OK` は手順 4 の報告に反映する(**成否を検証せず無条件に「付与済み」と報告しない** — 報告虚偽の防止)。
2. `PushNotification` ツールで人間に通知する(離席中でも気づけるように)。内容にトリガー(上表のどれか)と PR 番号を明記する — 例: 「PR #<n> が停止条件に到達した」「PR #<n> の reviewer dispatch が失敗した(不正応答)」「PR #<n> の evidence gate が失敗した(実装役 / 対応役)」「PR #<n> の dispatch 中に台帳への意図しない変更を検知した」「issue #<N> を Closes する open PR が複数見つかった(曖昧)」等。通知の成否も確認する(離席中の唯一の気づき経路のため)。
3. **以後その step は無条件スキップ**: 次 tick 以降、配車テーブルの選別より前で `needs-human` ラベルの有無を確認し、付いていればどのロールにも dispatch しない。**ラベルの解除は人間が手動で行う**(orchestrator 側で自動解除ロジックは持たない)。
4. **報告への反映(虚偽防止)**: tick 報告の「失敗 sink」列は `LABEL_OK` と通知の成否を**実際に反映する**。付与成功時のみ「🛑 needs-human 付与 + 通知済み」と書き、`add-label` 失敗時は「⚠️ ラベル付与失敗(手動付与が必要)」と正直に書く(無条件に「付与 + 通知済み」と書かない)。

**有界停止の保証**: この sink に入った step は「人間がラベルを外す」以外に配車対象へ戻る経路が無い。したがって、どのロール(実装役・対応役・reviewer)から入っても、evidence が通らない/停止条件に達した/dispatch 結果が失敗した step が無限に再 dispatch され続けることはない(無界ループは残さない)。ただし上記「既知の限界」のとおり、人間がラベルを外した後の再 escalate ループは #12/P14 の follow-up で解消する。

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
  - **implementer**: `no_pr`(返答不正 かつ 復旧検索 0 件)/ `ambiguous`(復旧検索 複数件)/ `pr_evidence_pass`(pr_number 確定 かつ evidence exit 0)/ `pr_evidence_fail`(pr_number 確定 かつ evidence 非 0)
  - **responder**: `evidence_pass` / `evidence_fail`
  - **reviewer**: `invalid`(返答が JSON でない・`escalate` を読めない=dispatch 結果失敗)/ `escalate`(escalate=true)/ `clean_pass`(escalate=false かつ has_blocker=false)/ `blockers`(escalate=false かつ has_blocker=true)

  script が exit 2(role enum 外 / outcome が role に対応しない / 必須キー欠損)なら、その step の処理を止め状態を報告する(黙って散文判定に切り替えない — `reaggregate-has-blocker.py` の扱いと同じ)。

- **`ledger_write` の適用(status リテラルは decision script が唯一の正)**: decision script の出力(`$ROUTE`)から `ledger_write` を取り出し、**非 null ならその中のキーだけを台帳へ書く**(script が返したフィールドのみ・**prose 側で status 文字列をハードコードしない**)。`null` なら台帳書込なし。ロールごとに書くフィールドが異なる(実装役=number+githubState+status / 対応役・reviewer=status のみ)ため、**`ledger_write` のキー集合に応じて書込を動的に組み立てる**。キーの解釈は 2 通りだけ:
  - `"pr.number": true` → orchestrator が保持する実 `pr_number` を書く(script は番号を知らないので真偽フラグ。この 1 点だけ prose が実値を供給する)
  - `"pr.githubState"` / `"pr.status"` → script が返したリテラル値をそのまま書く

  抽出と適用は次の 1 手続きで行う(`<step id>` は対象 step、`<pr_number>` は orchestrator が保持する確定番号。`pr.number` を含まない経路では空文字でよい)。`ledger_write` の全キーを 1 回のファイル書込で適用するため原子的(`pr.number` だけ書いて `pr.status` 未書込という中間状態を作らない):
  ```
  PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
  python3 - "$PLAN" "<step id>" "$ROUTE" "<pr_number>" <<'PY'
  import datetime, json, os, sys
  plan_path, step_id, route_json, pr_number = sys.argv[1:5]
  lw = json.loads(route_json)["ledger_write"]  # decision script の出力を消費 (唯一の正)
  if lw is not None:
      with open(plan_path, encoding="utf-8") as f:
          plan = json.load(f)
      step = next(s for s in plan["steps"] if s["id"] == step_id)
      for key, val in lw.items():             # script が返したキーだけを書く (動的)
          section, field = key.split(".", 1)  # "pr.status" -> ("pr","status")
          if key == "pr.number" and val is True:
              val = int(pr_number)            # script は真偽フラグ。実値は orchestrator が供給
          step[section][field] = val          # status 等は script の返値をそのまま (prose で複製しない)
      plan["updatedAt"] = datetime.date.today().isoformat()
      with open(plan_path + ".tmp", "w", encoding="utf-8") as f:
          json.dump(plan, f, ensure_ascii=False, indent=2)
      os.replace(plan_path + ".tmp", plan_path)  # 原子的な置換
  PY
  ```
  これで**実行される書込は decision script の `ledger_write` から来る**(prose に status リテラルを複製しない)。書込後は「書込方式」節に従い main へ単一コミット + push する。

- **`route` の実行**:
  - **`normal`**: `ledger_write`(あれば)を書いて完了。sink・ラベル以外の副作用なし。
  - **`skip`**: 書込なし・副作用なし。次 tick で条件が再成立すれば再 dispatch される(副作用が無いので暴走しない)。
  - **`sink`**: 「失敗経路(単一の needs-human sink)」へ。`ledger_write` が非 null なら**先に書いてから** sink 共通手続きを実行する(例: 実装役 evidence 失敗は「PR は実在する」事実を書いた上で sink)。

- **`label_action` の実行**(reviewer 経路のみ非 null。`ready for merge` ラベルの同期。単一書込の設計上 pr reviewer subagent はラベルに触らせないため orchestrator が実コマンドとして持つ — `commands/harness-review-pr.md` 手順 6 と同内容):
  - **`add_ready_for_merge`**:
    - ラベル作成 fallback(冪等): `gh label create "ready for merge" --color "0e8a16" --description "reviewer が merge 可能と判定した PR" --force`
    - `gh pr edit <n> --repo <repo> --add-label "ready for merge"`(冪等)
    - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(無ければ警告のみで実害なし)
  - **`remove_ready_for_merge`**:
    - `gh pr edit <n> --repo <repo> --remove-label "ready for merge"`(付いていなければ警告のみで実害なし)
    - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(無ければ警告のみで実害なし)
  - **`null`**: ラベル操作なし。

## 配車テーブル(v1・PR ライフサイクルのみ)

**`needs-human` ラベル付きの PR は無条件でスキップする**(ラベルの有無は各対象 step ごとに `gh pr view <n> --json labels` で確認)。**1 tick あたりの dispatch 上限は 5 件**(`commands/harness-review-pr.md` の暴走防止パターンを踏襲)。

| 条件 | dispatch するロール | orchestrator が行うこと |
|---|---|---|
| `issue.status == "ready for implementation"` かつ `pr.number == null` | developer(実装役) | dispatch → 返答検証(復旧検索)→ evidence gate → outcome 解決 → 判定器 → git status ガード → route 実行(normal/skip/sink) |
| `pr.status == "completed review"` | developer(対応役) | dispatch → 返答検証 → evidence gate → outcome 解決 → 判定器 → git status ガード → route 実行(normal/sink) |
| `pr.status in ("created pr", "waiting for review")` | pr reviewer | dispatch → 返答から outcome 解決(`invalid`/`escalate`/`clean_pass`/`blockers`)→ 判定器 → route + label_action 実行 |
| `pr.status == "ready for merge"` | なし | dispatch しない(終端は人間の専権) |
| `pr.status in ("merged pr")` / issue 終端(`closed issue`) | なし | 何もしない |

issue サイドの走査は台帳の `issue.status` を読むだけ(追加の GitHub ポーリングは実装しない)。

### 選別(jq)

```
PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
REVIEW_MODE="${2:-code-review}"

# 実装役 dispatch 対象
jq -c '[ .steps[]
  | select(.issue.status == "ready for implementation" and .pr.number == null)
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

3 カテゴリを合算して **上限 5 件**に切り詰める(優先順は「対応役 > pr reviewer > 実装役」— 手戻り修正を優先し、新規 dispatch は余裕がある時だけ行う。この優先順位付け自体は機械的な tie-break であり、レビュー判断ではない)。各対象を処理する前に `needs-human` ラベルの有無を確認しスキップする。

## dispatch 先ごとの委譲方式(転写しない)

各ロールは **dispatch → 状況を outcome トークンに解決 → 判定器(「ルーティング判定」節)→ route / label_action 実行**。dispatch prompt(委譲の中身)は転写せず参照させる方式を維持する。**ルーティング規則は判定器 script が正**なので、各ロール節は「どう outcome に解決するか」だけを書き、書込・sink・ラベルの規則は複製しない。

### developer(実装役)

**outcome 解決(判定器の implementer 行に渡すトークンを決める)**:

1. **dispatch**(subagent には `Read, Skill, Bash, Grep, Glob` のみ渡す。`Write` は渡さない)し、返答から `pr_number` の取得を試みる:

   > 「対象 issue #<N> の本文(Problem/Context/Alternatives/Implementation Scope/DoD)を `gh issue view <N>` で Read せよ。次に `creating-git-worktrees` skill を Skill ツールで起動し、その手順に従って worktree を作成せよ。issue の Implementation Scope に従って実装せよ。実装後、`creating-gh-prs` skill を Skill ツールで起動し、その手順に従って PR を作成せよ(base は main、`Closes #<N>` を本文に含める)。最後に `{pr_number, proposed_status}`(`proposed_status` は通常 `"created pr"`)を JSON で返せ。台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

2. **`pr_number` の確定と outcome 解決**:
   - 返答が JSON として解釈でき、`pr_number` が `gh pr view <pr_number> --repo <repo>` で実在確認できた → その番号を採用し、手順 3 の evidence gate へ。
   - **`pr_number` が取得できない/不正**(subagent のクラッシュ・不正 JSON・実在確認失敗): 諦める前に、GitHub 側で実際に PR が作られていないか**復旧検索**する(dispatch prompt で PR 本文に `Closes #<N>` を含めるよう指示済みのため拾える)。**復旧検索の全 3 分岐を必ず定義する**:
     ```
     gh pr list --repo <repo> --search "Closes #<N> in:body" --state open --json number
     ```
     - **0 件** → PR 未作成。outcome=**`no_pr`**(判定器は route=skip を返す。次 tick で `issue.status == "ready for implementation"` かつ `pr.number == null` が再成立すれば再 dispatch。**副作用が無いので暴走しない**)。
     - **複数件** → 曖昧(同一 issue を Closes する open PR が 2 本以上)。outcome=**`ambiguous`**(判定器は route=sink・書込なし。誤った番号を台帳に書かず人間が正しい PR を確定する)。
     - **1 件** → その番号を `pr_number` として採用し、手順 3 へ。

3. **evidence gate**(`pr_number` 確定後・書込より前に実行)。**subagent が dispatch 中に作った worktree は削除済みの可能性があり参照できないため、orchestrator 自身が独立して PR の head ブランチを取得し専用の一時 worktree を作って実行する**(`commands/harness-review-pr.md` 手順 4 の per-PR worktree パターンと同じ)。**worktree は `EVIDENCE_EXIT` の成否に関わらず必ず `git worktree remove --force` する**(失敗経路でも後片付けを行い worktree を残さない):
   ```
   HEAD_REF=$(gh pr view <pr_number> --repo <repo> --json headRefName --jq .headRefName)
   git fetch origin "$HEAD_REF" --quiet
   WORKTREE=".claude/worktrees/orchestrate-pr-<pr_number>"
   git worktree add --detach "$WORKTREE" "origin/$HEAD_REF"
   ( cd "$WORKTREE" && eval "$EVIDENCE_DONE" ); EVIDENCE_EXIT=$?
   git worktree remove --force "$WORKTREE"
   ```
   (`$EVIDENCE_DONE` は台帳の `evidence.done`、無ければ `evidence.test` にフォールバック。)
   - **`EVIDENCE_EXIT == 0`** → outcome=**`pr_evidence_pass`**。
   - **`EVIDENCE_EXIT != 0`** → outcome=**`pr_evidence_fail`**。

4. **判定器を呼び route を実行**(role=implementer。規則は判定器が正・下記は route の実行だけ):
   ```
   ROUTE=$(printf '{"role":"implementer","outcome":"<解決した outcome>"}' \
     | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/decide-orchestrator-route.py")
   ```
   - `pr_evidence_pass` / `pr_evidence_fail`: 判定器の `ledger_write`(`pr.number`=true / `pr.githubState`="open" / `pr.status`="created pr")を「ルーティング判定」節の **`ledger_write` の適用**手続きで**単一コミットで書く**(`<pr_number>` に確定番号を渡す。**status リテラルは prose に複製せず `$ROUTE.ledger_write` から書く**)。evidence を書込より前に実行済みで、`ledger_write` の全キー(number/githubState/status)を 1 回のファイル書込で適用するため、`pr.number` だけ書いて `pr.status` 未書込という中間状態は生じない(非原子的多段書込を排除)。書込後は「書込方式」節に従い main へ直接コミット + push(1 コミット。例: `chore(harness): <step> pr.status -> created pr`)。
     - `pr_evidence_pass` → route=normal。上記単一コミットで完了。次 tick で pr reviewer に dispatch される。
     - `pr_evidence_fail` → route=sink。上記単一コミットを書き込んだ**うえで**「失敗経路(単一の needs-human sink)」へ。書かれる `pr.status` は `ledger_write` のとおり `created pr`(`"completed review"` にはしない — reviewer が一度も走っていない PR には `# PR Reviewer` コメントが存在せず、対応役 dispatch しても直す finding が無い)。needs-human ラベル付与後は次 tick から無条件スキップされ安全に停止する。
   - `no_pr` → route=skip。書込なし。
   - `ambiguous` → route=sink。書込なし。

5. **orphan 防止は write-early ではなく復旧検索が担う**: 手順 3〜4 の途中で tick が中断しても、次 tick は `pr.number == null` のままなので手順 2 の復旧検索が既存 PR(`Closes #<N>`)を再発見して self-heal する。だから `pr.number` を先行コミットする必要はなく、書込は手順 4 のとおり原子的にできる(先行コミット → evidence → 本コミット の 2 段書込は取らない)。

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
   > 対応内訳を PR コメントとして投稿し、`{proposed_status: "waiting for review"}` を JSON で返せ。**`ready for merge` を提案することは絶対に禁止**(採否に関わらず、対応後の提案は常に `waiting for review` 固定)。台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

3. **返答検証(越権の無効化)**: `proposed_status` が `"waiting for review"` 以外(特に `"ready for merge"`)でも**無視して先へ進む**(対応役の越権を orchestrator 側で機械的に無効化する — `.harness/CLAUDE.harness.md` の「対応側が `ready for merge` を立てるのは越権(例外なし)」を技術的に担保)。対応役の返答は outcome 解決に使わない — status は evidence gate だけで決まる。

4. **evidence gate**(実装役の手順 3 と同じ方法。対象 PR は既に `pr.number` が確定しており subagent の dispatch 済み worktree の生死に依存しない。**worktree は `EVIDENCE_EXIT` の成否に関わらず必ず `git worktree remove --force` する**):
   ```
   HEAD_REF=$(gh pr view <n> --repo <repo> --json headRefName --jq .headRefName)
   git fetch origin "$HEAD_REF" --quiet
   WORKTREE=".claude/worktrees/orchestrate-pr-<n>"
   git worktree add --detach "$WORKTREE" "origin/$HEAD_REF"
   ( cd "$WORKTREE" && eval "$EVIDENCE_DONE" ); EVIDENCE_EXIT=$?
   git worktree remove --force "$WORKTREE"
   ```
   - **`EVIDENCE_EXIT == 0`** → outcome=**`evidence_pass`**。
   - **`EVIDENCE_EXIT != 0`** → outcome=**`evidence_fail`**。

5. **判定器を呼び route を実行**(role=responder):
   - `evidence_pass` → 判定器の `ledger_write`(`pr.status`="waiting for review")を「ルーティング判定」節の **`ledger_write` の適用**手続きで書く(対応役は `pr.status` のみ・`<pr_number>` は空文字でよい。**status リテラルは prose に複製せず `$ROUTE.ledger_write` から書く**)・route=normal(次 tick で pr reviewer が再レビュー)。
   - `evidence_fail` → 書込なし・route=sink。**`pr.status` は `completed review` のまま**(事実: 未解決 blocker が残る)。これで対応役も有界停止になり実装役と対称になる — 「evidence が通らないまま `completed review` 固定で毎 tick 再 dispatch → reviewer が選別せず round カウンタが進まず永久に停止しない」旧・無界ループを根絶する。

**既知の限界(意図的・対応役の無作業検知は escalate backstop に委ねる)**: 対応役は outcome を evidence gate だけで決めるため、dispatch した subagent が **無作業/クラッシュでも test が元々緑なら `evidence_pass` → `waiting for review` へ進む**(偽の前進)。実装役(復旧検索)・reviewer(`invalid` 検知)が dispatch 結果失敗を即座に sink するのに対し、**対応役の無作業だけは即時検知しない**という latency の非対称が残る。ただし finding 未対応なら次 tick で reviewer が同じ blocker を再検出 → `completed review` へ戻す往復が続き、**escalate backstop(round≥5 / blocker trend)が最終的に人間へ surface する**。これは bounded(`has_blocker=true` 維持で `clean_pass`=不正 merge には至らない)であり、walking skeleton では検知機構を足さず backstop に委ねる(作者の意図的判断)。実害(無作業 dispatch が頻発)が観測されたら follow-up で対応役の作業有無(`# PR Review Worker` コメント / commit の有無)検証を足す(「既知の制限・拡張ポイント」節にも同旨を明記)。

### pr reviewer

対象 PR 番号と `$REVIEW_MODE` を渡し、次を Agent ツールで dispatch する(ツール制限は実装役と同じ。**`gh pr comment` 投稿は許可するが台帳・ラベルには触れさせない**):

> 「`commands/harness-review-pr.md` を Read し、そこに書かれた手順 4 〜 5.6(投稿である手順 5 を含む。5.5/5.6 は投稿より前に計算するが、投稿自体も実行対象に含む。review-mode=`$REVIEW_MODE`、停止条件判定込み)を PR #<N> に対してそのまま実行せよ。手順本体は転写しない — 必ずファイルを Read してから実行すること。判定ロジックは変更しない。手順 6 の台帳書込・ラベル管理・報告(手順 3 のマーカー投稿含む)は行わず、代わりに `{has_blocker, blocker_count, escalate, review_markdown}` を JSON で返せ(`review_markdown` は手順 5 で組み立てたコメント本文。投稿は行ってよい — 投稿そのものは pr reviewer の専権であり本コマンドの触らないものではない)。台帳ファイル(`.harness/plan-progress.json`)には一切触れるな。」

**outcome 解決(判定器の reviewer 行に渡すトークンを決める。全 4 outcome を必ず解決する)**: 実装役の復旧検索・対応役の evidence gate と対称に、**reviewer にも「dispatch 結果失敗」分岐を持たせて単一 sink をすり抜けさせない**(round 4 指摘 🔴#1 の要点。「実装役は復旧検索、対応役は evidence gate で dispatch 失敗を捌けるが、reviewer だけ dispatch 結果失敗の分岐が無く単一 sink をすり抜ける」を、この `invalid` 分岐で塞ぐ):

- **返答が JSON として解釈できない / `escalate` を読めない**(subagent クラッシュ・不正 JSON・個人 skill 欠落で `escalate` を組み立てられない等の **dispatch 結果失敗**)→ outcome=**`invalid`**(判定器は route=sink を返す)。
- **`escalate == true`**(round/trend 停止条件)→ outcome=**`escalate`**。
- **`escalate == false` かつ `has_blocker == false`** → outcome=**`clean_pass`**。
- **`escalate == false` かつ `has_blocker == true`** → outcome=**`blockers`**。

**判定器を呼び route / label_action を実行**(role=reviewer。evidence gate は reviewer 経路では不要 — reviewer 役に実装物は無い):
- `invalid` / `escalate` → route=sink・書込なし・label_action=null。「失敗経路(単一の needs-human sink)」へ(`invalid` のトリガー: reviewer dispatch の返答不正 / `escalate` のトリガー: 停止条件到達)。台帳には一切書込まない(`pr.status` は dispatch 元の `created pr` / `waiting for review` のまま)。
- `clean_pass` → 判定器の `ledger_write`(`pr.status`="ready for merge")を「ルーティング判定」節の **`ledger_write` の適用**手続きで書く(reviewer は `pr.status` のみ・`<pr_number>` は空文字でよい。**status リテラルは prose に複製せず `$ROUTE.ledger_write` から書く**)・route=normal・label_action=`add_ready_for_merge`。
- `blockers` → 判定器の `ledger_write`(`pr.status`="completed review")を同手続きで書く・route=normal・label_action=`remove_ready_for_merge`。

label_action(`ready for merge` ラベル同期)の実コマンドは「ルーティング判定」節の `label_action の実行` を参照する(prose に複製しない)。

## evidence gate(対称モデル)

evidence gate は orchestrator 自身が独立した一時 worktree を用意して `evidence.done`(台帳 `.harness/plan-progress.json` の `evidence.done`、無ければ `evidence.test` にフォールバック)を実行する共通機構(具体的な worktree の作り方は「developer(実装役)」節の手順 3 参照)。**実装役・対応役いずれも、evidence gate 失敗時は判定器が `route=sink` を返し、単一の needs-human sink に到達する(対称)**:

- **developer(実装役)**: `pr_number` が確定した(PR は実在する)場合、失敗 outcome=`pr_evidence_fail` → `pr.status="created pr"` を単一コミットで書き込んだうえで sink。PR 未作成(復旧検索 0 件)は outcome=`no_pr` → route=skip で書込まず次 tick 再 dispatch(副作用が無いので暴走しない)。復旧検索が複数一致(曖昧)は outcome=`ambiguous` → route=sink・書込なし。
- **developer(対応役)**: 対象 PR は既に存在し `pr.number` も書込済み。失敗 outcome=`evidence_fail` → 書込なし(`pr.status="completed review"` のまま = 未解決 blocker が残る事実)で sink。**旧版の「書込まずスキップ + 再試行」は取らない** — `completed review` は reviewer が選別しないため round カウンタが進まず、round≥5 の停止条件に永久に到達しない無界ループになるため。

これで「どのロールの evidence 失敗も needs-human に到達し、無界ループを残さない」という対称性が、判定器の `route=sink` として一元化される(失敗経路の一元化)。

## 書込方式

`commands/harness-review-pr.md` の手順 3/6 と同じ jq パターンを踏襲する: main 上で `.harness/plan-progress.json` だけを含む小コミットを作り push する。push が拒否された場合(doer と同時書込)は `git pull --ff-only` してからやり直す。コミットメッセージ規約は `chore(harness): <step id> <issue|pr>.status -> <新 status>`(例: `chore(harness): P8 pr.status -> created pr`)。

```
git add .harness/plan-progress.json
git commit -m "chore(harness): <step> <issue|pr>.status -> <new>"
git push origin main
```

## 既知のリスク(明示)

**orchestrator の単一書込は現行方式(main 直接コミット + push)を前提にしている。** issue #11(台帳の git 非依存化・main push 禁止ポリシー)が実装されると、この前提が崩れる。皮肉なことに、issue #11 自体が本 orchestrator 最初の実仕事の対象(配車テーブル該当 step)であり、orchestrator 自身がこの変更を実装した後、orchestrator の書込ロジックへの追従修正が別途必要になる。v1 ではこれを解消せず、既知の負債として明示するに留める。

## 報告

`commands/harness-review-pr.md` 手順 8 に倣い、tick サマリを分かりやすく出す:

````markdown
## 🚦 Orchestrator tick 報告

**実施: HH:MM**(local time)

### 📊 dispatch サマリ(N 件、上限 5)

| step | ロール | 遷移前 → outcome → 書込結果 | evidence gate | 失敗 sink |
|---|---|---|---|---|
| P8 | developer(実装役) | null → pr_evidence_pass → **書込済み(#N)** | ✅ exit 0 | — |
| P9 | developer(実装役) | null → pr_evidence_fail → **書込済み(#M)** | ❌ 非 0 | 🛑 needs-human 付与 + 通知済み |
| P13 | pr reviewer | created pr → clean_pass → **ready for merge** | — | — |
| P11 | pr reviewer | waiting for review → escalate → **書込なし** | — | 🛑 needs-human 付与 + 通知済み |
| P10 | pr reviewer | created pr → invalid(dispatch 失敗)→ **書込なし** | — | ⚠️ ラベル付与失敗(手動付与が必要) |
| P12 | developer(対応役) | completed review → evidence_fail → **書込なし** | ❌ 非 0 | 🛑 needs-human 付与 + 通知済み |

**失敗 sink 列は無条件に「付与 + 通知済み」と書かない**(報告虚偽の防止 — 実装 C)。sink 共通手続き手順 1 の `LABEL_OK` と通知の成否を**実際に反映**する: 付与成功時のみ「🛑 needs-human 付与 + 通知済み」、`add-label` 失敗時は「⚠️ ラベル付与失敗(手動付与が必要)」と正直に書く(上表 P10 が失敗例)。

### ⏭️ スキップ(あれば)
- #M は `needs-human` ラベル付きのため無条件スキップ
- #K は復旧検索 0 件(`no_pr`・PR 未作成)のため書込せずスキップ(次 tick 再試行)

### 🛑 失敗 sink 到達(あれば)
- #N: 理由(`escalate` 停止条件: round 上限到達 / blocker 傾向未改善 / reviewer dispatch 失敗(`invalid`・不正応答)/ 実装役 evidence 失敗(`pr_evidence_fail`)/ 対応役 evidence 失敗(`evidence_fail`)/ git status ガード検知 / `Closes #N` 復旧検索が複数一致(`ambiguous`))

### ↩️ 誤判定の巻き戻し方
台帳の書込は main への直接コミットのため、誤りがあれば手動で `pr.status` / `issue.status` を巻き戻し、`needs-human` ラベルを外して、次 tick で再評価させる。
````

0 件 tick の場合は「dispatch 対象なし」の 1 行報告に簡略化する。

## loop での回し方

- 試行: `/loop 15m /harness-orchestrate`(review-mode=code-review 既定、15 分間隔)。
- review-mode を明示したい場合: `/loop 15m /harness-orchestrate owner/repo multi-angle`。
- `/loop` は起動時の引数をそのまま毎 tick 再実行するため、review-mode は起動時の引数が毎 tick 引き継がれる。追加の状態保持は不要。

## 既知の制限・拡張ポイント

- **真の無人化はまだできない**: `/loop` はセッションが開いている間だけ定期実行できる方式であり無人ではない。GitHub Actions `on: schedule` / `/schedule` クラウド routine による真の無人化は、判定 skill(`reviewing-multi-angle` 等)の kit 同梱が前提になるため別途対応が必要(現行は個人 skill 依存または `/code-review` 単体のみ)。
- **issue #11 との既知のリスク**: 上記「既知のリスク」節参照。orchestrator の単一書込は main 直接コミット + push が前提。
- **issue サイド(issue reviewer / issue review worker)の自動化は対象外**: v1 は PR ライフサイクルのみ。issue フェーズの配車は別 issue の範囲。
- **git-status ガードの限界と設計境界(部分的バックストップ・正直な明記)**: 台帳保護には次の点がある。
  - **(a) subagent の worktree 編集は捕捉できない**: 実装役 subagent は自前の worktree で作業するため、その `.harness/` 編集は orchestrator 自身の checkout で走る `git status` からは**見えない**。したがってこのガードは **orchestrator 自身の checkout 内の編集しか捕捉できない部分的バックストップ**に過ぎない。**台帳保護の主たる防御は「subagent に `Write` を渡さない」ツール制限**であって、git-status ガードはその補完(検知したら失敗 sink へ)。`Bash` 経由の編集は完全には防げず、hook 等による L3 相当の強制ではない。
  - **(b) mid-tick 残渣の誤検知を避ける**: orchestrator 自身の書込は `.harness/plan-progress.json` の書換後・commit 前に一時的に dirty になる。この残渣を subagent の変更と**誤検知しない**よう、ガードは **tick 開始時にクリーンだと確認したベースラインと比較**し、orchestrator 自身の既知の書込は除外して評価する(「dirty = subagent の意図しない変更」と短絡しない — 誤検知で無関係 step を spurious に sink 隔離するのを防ぐ)。
  - **(c) git-status ガードだけが decision script を通らない唯一の失敗経路(設計境界・意図的)**: 他の全失敗面は「ルーティング判定」節の decision script が `route=sink` として決めるが、git-status ガードの drift 検知 → sink だけは script を経由しない。これは意図的である — **git-guard trip は「(role, outcome) に紐づくルーティング判断」ではなく、全ロール横断(cross-cutting)の pre-write 前提チェックであり、その帰結は自明に sink(分岐する判断ロジックが無い)ため decision script の対象外とする**(decision script はルーティング「判断」を集約するものであって、判断の無い自明な guard→sink はその対象ではない、という設計境界)。無理に決定表へ押し込まない。
- **dispatch 上限 5 件のトレードオフ**: 1 tick で処理しきれない場合は次 tick へ持ち越される(dedup は各ロールの status 遷移が担う)。
- **ルーティングは tested decision script**: (role, outcome) → (ledger_write, route, label_action) を `scripts/decide-orchestrator-route.py` が決定論的に解決し、`tests/smoke/run-smoke.sh` [8] が全 (role × outcome) 10 行を網羅検証する(reviewer の `invalid` 分岐を含む)。散文分岐の取りこぼしを構造的に防ぐのが目的で、規則は script が正・prose は「outcome への解決」と「route の実行」だけを持つ。
- **失敗経路は単一 sink に集約(重要)**: 実装役・対応役・reviewer のどの経路でも「前進不能 = needs-human sink 到達」で対称に扱う。reviewer も `escalate`(停止条件)に加え `invalid`(dispatch 結果失敗)を持ち、単一 sink をすり抜けない。個別ロールに独自の失敗処理(片方だけ有界停止・片方は無界ループ)を持たせない。書き込む事実 status だけがトリガーごとに異なる(「失敗経路(単一の needs-human sink)」節の一覧表を参照)。
- **対応役の無作業検知は escalate backstop に委ねる(意図的な既知の限界)**: 対応役だけは dispatch 結果失敗の即時検知分岐を持たない(最後の非対称)。subagent が **無作業/クラッシュでも test が元々緑なら `evidence_pass` → `waiting for review`** へ進む(偽の前進)。実装役(復旧検索)・reviewer(`invalid` 検知)が dispatch 失敗を即座に sink するのに対し、対応役の無作業だけ検知が **~3 round 遅延する**という latency の非対称が残る。ただし finding 未対応なら reviewer が同じ blocker を再検出 → `completed review` へ戻す往復が続き、**escalate backstop(round≥5 / blocker trend)が最終的に人間へ surface する**。これは bounded(`has_blocker=true` 維持で `clean_pass`=不正 merge には至らない)であり、walking skeleton では検知機構を足さず backstop に委ねる(作者の意図的判断)。実害(無作業 dispatch が頻発)が観測されたら follow-up で対応役の作業有無(`# PR Review Worker` コメント / commit の有無)検証を足す(対応役 flow の該当箇所にも同旨を明記済み)。
- **sink の出口が人間の意図と未結線(#12/P14 で解消予定)**: reviewer の `escalate` / `invalid` sink は台帳無書込のため、人間が `needs-human` ラベルを外すと status は dispatch 元のままで再 dispatch され、原因未解消なら再 escalate ループに戻る。停止条件到達時に `pr.status` を新 enum `need for human review` へ遷移させる issue #12 の follow-up 要件(台帳 P14 で tracking 済み)で解消予定。本 PR は schema 変更を伴うためスコープ外(#14 merge 後の follow-up)で、新 enum 値は実装しない。
- **ラベル同期ロジックの複製(drift リスク)**: 本コマンドのラベル同期ロジック(「ルーティング判定」節の `label_action の実行`)は `commands/harness-review-pr.md` 手順 6 の内容を単一書込の都合上複製している。将来どちらかの label 定義(色・説明・名称)を変更する場合は両ファイルを同時に更新すること(自動で同期されない、既知の drift リスク)。
