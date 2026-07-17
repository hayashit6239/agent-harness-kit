---
description: レビュー候補収集(8 角度 finder)への dispatch prompt 本体。review-mode=code-review の候補収集フェーズで、finder を「このファイルの実行者自身」の直接の子として起動するための指示(issue #49)。`commands/harness-orchestrate.md`「pr reviewer」節(orchestrator モードでは orchestrator 自身が実行)、および `commands/harness-review-pr.md` 手順 4-b(orchestrator 未経由の単体起動では pr reviewer セッション自身が実行)から Read されて実行される内部フラグメントであり、単体で `/harness-dispatch-review-finders` として直接呼び出すことは想定しない(既存 `commands/harness-dispatch-implementer.md` / `commands/harness-dispatch-responder.md` と対称の配置・命名)。
allowed-tools: [Read, Skill, Bash, Agent, Grep, Glob, Write]
---

# レビュー候補収集(8 角度 finder)dispatch prompt

`commands/harness-orchestrate.md`「pr reviewer」節、または `commands/harness-review-pr.md` 手順 4-b が review-mode=code-review の候補収集で Read して実行する指示本体。**転写しない** — 必ずこのファイルを Read してから、以下をそのまま実行すること。

**このファイルを実行している主体自身が、finder の直接の親になる**(issue #49 の核心)。orchestrator モードでは orchestrator 自身がこのファイルを実行するため finder は orchestrator の直接の子になる。単体起動(orchestrator 未経由・手動 / `/loop` 直接実行)では pr reviewer セッション自身がこのファイルを実行するため finder はそのセッションの直接の子になる。**どちらの経路でも finder が「孫」(orchestrator から見て孫、または誰からも観測できない世代)にならない**。対象 PR 番号 `<N>` / リポジトリ `<repo>` / 出力先ディレクトリ `<OUT_DIR>` は呼出元(orchestrator または pr reviewer 手順 4-b)から渡される(`<OUT_DIR>` 省略時は `mktemp -d` 等で一時ディレクトリを自分で用意してよい)。

**★最重要★ 手順を読む前に頭に入れておくこと(issue #49・PR #40/#41 の実測に基づく対策)**:

1. 8 角度の finder はすべて `subagent_type: "general-purpose"` で起動せよ(**`fork` を禁止**。fork は呼出元の会話文脈を丸ごと継承する設計のため、finder が「この角度だけ見ろ」という狭い directive を無視し、継承した文脈から呼出元の最上位タスクを再実行する — 実測で 6/6 逸脱・1 件も findings を返せなかった)。
2. 各 finder への指示に **「`SendMessage` を使うな。結果は最終メッセージとして直接出力せよ」を必ず明示する**(実測で生死を分けた対策 — `SendMessage` で返す finder は宛先解決に失敗して結果を失うが、最終メッセージで直接出力した finder は 100% 到達した)。
3. `gh auth switch` を実行するな(active アカウントを変えると呼出元の `gh` 操作が壊れる)。
4. 8 体は角度ごとに担当領域が排他な独立タスクなので、可能な限り 1 メッセージ内で並列起動する(順番に 1 体ずつ起動しない)。
5. **収集は機械的**(8 角度固定・選択の余地なし)。ここでは判定(severity 付与・CONFIRMED/PLAUSIBLE/REFUTED の検証・集計・投稿)を行わない — それは呼出元(pr reviewer)の独立検証の役目であり、finder が担うのは候補の列挙だけ(doer ≠ judge を壊さないための境界)。

---

## 手順

1. **対象 PR の diff を見られる worktree を用意する**(finder に文脈を自己完結させて渡すため。`.harness/plan-progress.json` には一切触れない):
   ```
   REFS=$(gh pr view <N> --repo <repo> --json headRefName,baseRefName --jq '[.headRefName, .baseRefName] | @tsv')
   HEAD_REF=$(printf '%s' "$REFS" | cut -f1)
   BASE_REF=$(printf '%s' "$REFS" | cut -f2)
   git fetch origin "$HEAD_REF" "$BASE_REF" --quiet
   WORKTREE=".claude/worktrees/review-finders-pr<N>"
   git worktree add --detach "$WORKTREE" "origin/$HEAD_REF"
   ```
   `add` が残骸で失敗したら `git worktree remove --force "$WORKTREE"` → `git worktree prune` → 再度 `add` を試みる(`scripts/run-orchestrator-evidence-gate.sh` の残骸掃除パターンと同型)。それでも失敗したら候補収集を中止し、呼出元へ「worktree 作成に失敗した」と報告する(0 件を偽って返さない)。

2. **8 角度分の finder を起動する**。各 finder には次を**自己完結する形で**渡す(`general-purpose` は呼出元の文脈を継承しないため): 対象 worktree の絶対パス・diff の見方(`cd <worktree> && git diff "origin/$BASE_REF"...HEAD`)・その角度が探すもの・出力形式・出力先ファイルパス・「SendMessage 禁止・直接返せ」の指示。

   角度と担当領域(既存 Claude Code 組込 `/code-review` の 8 角度分けに倣うが、**プロンプト文面は本 repo が独自に定義する** — Anthropic 非公開実装の逐語コピーではない。シャドー保守コストを避けるため、各行は 1〜2 文の軽量な指示に留める):

   | 角度 id | 担当領域 |
   |---|---|
   | `line-scan` | 行単位の correctness(ロジック誤り・off-by-one・null/undefined 処理漏れ・境界条件・型の誤り等) |
   | `removed-behavior` | diff で削除・変更された既存の挙動が意図せず失われていないか |
   | `cross-file` | diff の変更が、diff に含まれない他ファイルの呼び出し元・契約・前提と食い違っていないか |
   | `reuse` | 既存のユーティリティ・関数と重複した再実装をしていないか |
   | `simplify` | 過剰に複雑な実装を単純化できないか |
   | `efficiency` | 不要な計算量・重複処理・無駄な I/O が無いか |
   | `altitude` | 抽象度・責務の置き場所が適切か(層違いの実装をしていないか) |
   | `conventions` | 本 repo の命名・スタイル・既存パターンからの逸脱 |

   各 finder の dispatch prompt テンプレート(`<angle>` / `<focus>` を上表の値で埋め、8 体分をこのテンプレートで起動する):

   > 「あなたは PR #<N> の diff を **`<angle>`(<focus>)** の観点だけでレビューする finder だ。他の観点は担当しない・判定(severity 付与や採否)も行わない。作業ディレクトリ: `<worktree の絶対パス>`。diff は `cd <worktree> && git diff "origin/<BASE_REF>"...HEAD` で見よ(必要なら worktree 内の他ファイルも Read/Grep して文脈を補ってよい)。見つけた候補を `{file, line, summary, failure_scenario}` の JSON 配列として **Write ツールで** `<OUT_DIR>/<angle>.json` に書け(該当なしなら空配列 `[]` を書く。何であれ必ずファイルを書くこと — 未応答扱いを防ぐため)。**`SendMessage` は使うな。** 書き終えたら、最終メッセージとして `<angle>: N 件書いた` とだけ直接返せ(findings 本文を最終メッセージに含めない — 呼出元の context を圧迫しないため)。`.harness/plan-progress.json` には一切触れるな。」

3. **8 体の完了を待ち、出力ファイルの存在を確認する**。Write していない角度(クラッシュ・タイムアウト等)があれば、その角度は候補 0 件として扱う(fail-open)。**ただし「0 件」と「未応答」を混同しない** — 未応答の角度があれば、後段(呼出元の報告)に「`<angle>` 未応答」と 1 行残せるよう、未応答一覧を手順 6 の返り値に含める。

4. **統合 findings ファイルを組み立てる**(8 個の個別ファイルは残したまま、統合版を追加で書く。**呼出元の context には個々の findings 本文を持ち込まない** — 統合は `jq` のファイル操作で行い、LLM が読んで転記しない):
   ```
   jq -s '[.[][]]' <OUT_DIR>/line-scan.json <OUT_DIR>/removed-behavior.json \
     <OUT_DIR>/cross-file.json <OUT_DIR>/reuse.json <OUT_DIR>/simplify.json \
     <OUT_DIR>/efficiency.json <OUT_DIR>/altitude.json <OUT_DIR>/conventions.json \
     > <OUT_DIR>/findings.json
   ```
   (未応答でファイルが存在しない角度がある場合は、その角度のパスを `jq -s` の引数から除外する。8 個中 0 個しか書けなかった場合は `<OUT_DIR>/findings.json` に `[]` を書く。)

5. **worktree を後片付けする**(成否に関わらず):
   ```
   git worktree remove --force "$WORKTREE"
   ```

6. **呼出元へ返す**: 統合ファイルのパス `<OUT_DIR>/findings.json` と、未応答の角度があればその一覧(手順 3)を返す。**findings の中身そのものを呼出元へ再掲しない**(呼出元は必要になったときにファイルを Read する — このファイルの実行者が orchestrator の場合、findings 本文をここで自分の応答に含めて context に載せない)。呼出元(orchestrator または pr reviewer)はこのパスを使って独立検証(候補ごとの CONFIRMED/PLAUSIBLE/REFUTED 判定 + severity 付与。手順は `commands/harness-review-pr.md` 手順 4-b 参照)を行う — **その検証はこのファイルの範囲外**(finder は候補を機械的に集めるだけで判定しない)。
