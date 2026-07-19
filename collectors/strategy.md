---
description: レビュー候補収集(角度別 finder)への dispatch prompt 本体。review-mode=code-review の候補収集フェーズで、finder を「このファイルの実行者自身」の直接の子として起動するための指示(issue #49)。`commands/harness-orchestrate.md`「pr reviewer」節(orchestrator 自身が実行)から Read されて実行される機構ファイルであり、単体で直接呼び出すことは想定しない(issue #63 で `roles/review-finders.md` から `collectors/strategy.md` へ移設・角度定義を `collectors/angles/*.md` へ分解。issue #65 でユーザーが `.harness/collectors/angles/` に観点を追加できるようにプラガブル化)。
allowed-tools: [Read, Skill, Bash, Agent, Grep, Glob, Write]
---

# 収集(collector)機構 — 角度別 finder の起動 dispatch prompt

`commands/harness-orchestrate.md`「pr reviewer」節が review-mode=code-review の候補収集で Read して実行する指示本体。**転写しない** — 必ずこのファイルを Read してから、以下をそのまま実行すること。

**review-mode との関係**: この収集機構は `review-mode=code-review`(既定)の**下位**の差し替え点であり、`review-mode=multi-angle` には適用しない(multi-angle は収集+判定一体で pr reviewer が内部で fan-out する現状維持・issue #63 スコープ外)。

**このファイルを実行している主体自身が、finder の直接の親になる**(issue #49 の核心)。orchestrator が `review-mode=code-review` の候補収集フェーズでこのファイルを実行するため、finder は orchestrator の直接の子になる(orchestrator から見て「孫」、または誰からも観測できない世代にはならない)。対象 PR 番号 `<N>` / リポジトリ `<repo>` / 出力先ディレクトリ `<OUT_DIR>` は呼出元(orchestrator)から渡される(`<OUT_DIR>` 省略時は `mktemp -d` 等で一時ディレクトリを自分で用意してよい)。

**候補の出力形式は `contracts/findings.schema.json` を正とする**(`{file, line, summary, failure_scenario}` の配列。severity・sources 等の判定用フィールドは持たせない — doer≠judge の境界を形式でも守る。issue #64)。**角度(observation point)定義の frontmatter 形式は `contracts/collector-angle.schema.json` を正とする**(`id` / `label` / `skill?` / `enabled?`。新規角度を追加するときの雛形は `contracts/collector-angle.template.md`)。

**★最重要★ 手順を読む前に頭に入れておくこと(issue #49・PR #40/#41 の実測に基づく対策)**:

1. すべての finder は `subagent_type: "general-purpose"` で起動せよ(**`fork` を禁止**。fork は呼出元の会話文脈を丸ごと継承する設計のため、finder が「この角度だけ見ろ」という狭い directive を無視し、継承した文脈から呼出元の最上位タスクを再実行する — 実測で 6/6 逸脱・1 件も findings を返せなかった)。
2. 各 finder への指示に **「`SendMessage` を使うな。結果は最終メッセージとして直接出力せよ」を必ず明示する**(実測で生死を分けた対策 — `SendMessage` で返す finder は宛先解決に失敗して結果を失うが、最終メッセージで直接出力した finder は 100% 到達した)。
3. `gh auth switch` を実行するな(active アカウントを変えると呼出元の `gh` 操作が壊れる)。
4. 角度ごとに担当領域が排他な独立タスクなので、可能な限り 1 メッセージ内で並列起動する(順番に 1 体ずつ起動しない)。
5. **収集は機械的**(角度は下記手順 2 の解決ロジックで確定し、以降は選択の余地なし)。ここでは判定(severity 付与・CONFIRMED/PLAUSIBLE/REFUTED の検証・集計・投稿)を行わない — それは呼出元(pr reviewer)の独立検証の役目であり、finder が担うのは候補の列挙だけ(doer ≠ judge を壊さないための境界)。
6. **判定を伴う skill を角度の `skill:` に指定させない**(下記手順 2 参照。観点の frontmatter は収集専任のみを許す — issue #65)。

---

## 手順

1. **対象 PR の diff を見られる worktree を用意する**(finder に文脈を自己完結させて渡すため。`.harness/plan-progress.json` には一切触れない):
   ```
   REFS=$(gh pr view <N> --repo <repo> --json headRefName,baseRefName --jq '[.headRefName, .baseRefName] | @tsv')
   HEAD_REF=$(printf '%s' "$REFS" | cut -f1)
   BASE_REF=$(printf '%s' "$REFS" | cut -f2)
   git fetch origin "$HEAD_REF" "$BASE_REF" --quiet
   WORKTREE=".claude/worktrees/collectors-pr<N>"
   git worktree add --detach "$WORKTREE" "origin/$HEAD_REF"
   ```
   `add` が残骸で失敗したら `git worktree remove --force "$WORKTREE"` → `git worktree prune` → 再度 `add` を試みる(`scripts/run-orchestrator-evidence-gate.sh` の残骸掃除パターンと同型)。それでも失敗したら候補収集を中止し、呼出元へ「worktree 作成に失敗した」と報告する(0 件を偽って返さない)。

2. **角度(observation point)を解決する(issue #65・kit デフォルト ∪ 導入先追加のユニオン)**。角度は `collectors/angles/*.md` の frontmatter(`contracts/collector-angle.schema.json` 準拠)で定義される。2 つの置き場を突き合わせ、**同名ファイルは導入先が kit を上書き**、**`enabled: false` の角度は除外**、判定を伴う `skill:` を混入させない(角度は収集専任のみ):
   - **kit デフォルト**: `${CLAUDE_PLUGIN_ROOT}/collectors/angles/*.md`(kit 同梱の 9 角度 — line-scan / removed-behavior / cross-file / reuse / simplify / efficiency / altitude / conventions / architecture)
   - **導入先追加**: `<repo>/.harness/collectors/angles/*.md`(ユーザーが独自観点を追加する置き場。無くてもよい)

   解決ロジック(ファイル名基準の union + override。実行例):
   ```
   python3 - "${CLAUDE_PLUGIN_ROOT}/collectors/angles" "<repo の絶対パス>/.harness/collectors/angles" <<'PY'
   import glob, os, re, sys, json

   def parse_frontmatter(path):
       text = open(path, encoding="utf-8").read()
       m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
       if not m:
           return None
       fm = {}
       for line in m.group(1).splitlines():
           line = line.strip()
           if not line or line.startswith("#") or ":" not in line:
               continue
           k, v = line.split(":", 1)
           fm[k.strip()] = v.strip()
       return fm

   kit_dir, target_dir = sys.argv[1], sys.argv[2]
   resolved = {}  # basename -> (path, frontmatter, source)
   for d, src in [(kit_dir, "kit"), (target_dir, "target")]:
       if not d or not os.path.isdir(d):
           continue
       for path in sorted(glob.glob(os.path.join(d, "*.md"))):
           fm = parse_frontmatter(path)
           if fm is None or "id" not in fm or "label" not in fm:
               continue  # frontmatter 不正な角度ファイルは fail-open で無視(収集を止めない)
           resolved[os.path.basename(path)] = (path, fm, src)  # target が後で回るため kit を上書き

   angles = []
   for base, (path, fm, src) in sorted(resolved.items()):
       if fm.get("enabled", "true").lower() == "false":
           continue
       angles.append({"path": path, "id": fm["id"], "label": fm["label"], "skill": fm.get("skill"), "source": src})
   print(json.dumps(angles, ensure_ascii=False, indent=2))
   PY
   ```
   - `id` が全角度(kit + 導入先)を通してユニークであること自体は `contracts/collector-angle.schema.json` の規約であり、この収集フェーズでは強制検証しない(issue #64 のスコープ外 = 検証の強制は follow-up)。重複 `id` があっても収集は止めない(fail-open)。
   - 角度が 1 件も解決できなかった場合(kit デフォルトの読み込みにも失敗)は候補収集を中止し、呼出元へ「角度を 1 件も解決できなかった」と報告する(0 件を偽って返さない)。

3. **解決した角度ごとに finder を起動する**。各 finder には次を**自己完結する形で**渡す(`general-purpose` は呼出元の文脈を継承しないため): 対象 worktree の絶対パス・diff の見方(`cd <worktree> && git diff "origin/$BASE_REF"...HEAD`)・角度の frontmatter 外の本文(その角度が探すものの指示)・出力形式(`contracts/findings.schema.json`)・出力先ファイルパス・「SendMessage 禁止・直接返せ」の指示。

   各 finder の dispatch prompt テンプレート(`<id>` / `<label>` / `<body>` を手順 2 で解決した角度の値で埋め、解決した角度の数だけこのテンプレートで起動する。**`skill` が設定されている角度は、プロンプト先頭に skill 起動の指示を織り込む**(issue #65)):

   > (`skill` が設定されている場合のみ先頭に追加)「まず `Skill` ツールで `<skill>` を起動して従い、」
   >
   > 「あなたは PR #<N> の diff を **`<id>`(<label>)** の観点だけでレビューする finder だ。他の観点は担当しない・判定(severity 付与や採否)も行わない。作業ディレクトリ: `<worktree の絶対パス>`。diff は `cd <worktree> && git diff "origin/<BASE_REF>"...HEAD` で見よ(必要なら worktree 内の他ファイルも Read/Grep して文脈を補ってよい)。この観点が探すもの: `<body>`。見つけた候補を `contracts/findings.schema.json` が定める形(`{file, line, summary, failure_scenario}`)の JSON 配列として **Write ツールで** `<OUT_DIR>/<id>.json` に書け(該当なしなら空配列 `[]` を書く。何であれ必ずファイルを書くこと — 未応答扱いを防ぐため)。**`SendMessage` は使うな。** 書き終えたら、最終メッセージとして `<id>: N 件書いた` とだけ直接返せ(findings 本文を最終メッセージに含めない — 呼出元の context を圧迫しないため)。`.harness/plan-progress.json` には一切触れるな。」

   `skill:` が指す skill が見つからない・起動に失敗した場合、その finder は当該角度を候補 0 件として扱ってよい(fail-open。判定は不要な収集専任のため、skill 欠落で候補収集全体を止めない)。

4. **全 finder の完了を待ち、出力ファイルの存在を確認する**。Write していない角度(クラッシュ・タイムアウト等)があれば、その角度は候補 0 件として扱う(fail-open)。**ただし「0 件」と「未応答」を混同しない** — 未応答の角度があれば、後段(呼出元の報告)に「`<id>` 未応答」と 1 行残せるよう、未応答一覧を手順 6 の返り値に含める。

5. **統合 findings ファイルを組み立てる**(角度ごとの個別ファイルは残したまま、統合版を追加で書く。**呼出元の context には個々の findings 本文を持ち込まない** — 統合は `jq` のファイル操作で行い、LLM が読んで転記しない):
   ```
   jq -s '[.[][]]' <OUT_DIR>/<id1>.json <OUT_DIR>/<id2>.json ... > <OUT_DIR>/findings.json
   ```
   (手順 2 で解決した角度の `id` すべてを列挙する。未応答でファイルが存在しない角度がある場合は、その角度のパスを `jq -s` の引数から除外する。1 件も書けなかった場合は `<OUT_DIR>/findings.json` に `[]` を書く。)

6. **worktree を後片付けする**(成否に関わらず):
   ```
   git worktree remove --force "$WORKTREE"
   ```

7. **呼出元へ返す**: 統合ファイルのパス `<OUT_DIR>/findings.json` と、未応答の角度があればその一覧(手順 4)を返す。**findings の中身そのものを呼出元へ再掲しない**(呼出元(orchestrator)は必要になったときにファイルを Read する — findings 本文をここで自分の応答に含めて context に載せない)。この後 orchestrator が dispatch する pr reviewer(`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md`)がこのパスを使って独立検証(候補ごとの CONFIRMED/PLAUSIBLE/REFUTED 判定 + severity 付与。手順は同ファイル手順 4-b 参照)を行う — **その検証はこのファイルの範囲外**(finder は候補を機械的に集めるだけで判定しない)。

## 既知の制限・拡張ポイント(issue #65)

- **`id` の全域ユニーク性は未検証(fail-open)**: 手順 2 は同名 `id` が kit デフォルトと導入先追加(または導入先内の複数ファイル)で衝突しても収集を止めない。衝突すると `findings.json` 上で角度の由来が曖昧になりうるが、悪化が観測されたら validator 側(follow-up)で検証を追加する。
- **`enabled: false` の対象**: 現状は kit デフォルト・導入先追加のどちらのファイルにも書ける(frontmatter 単位の無効化。config ファイルでの一括無効化は本 issue のスコープ外)。
- **skill 委譲は収集専任のみ**: `contracts/collector-angle.schema.json` の `skill` フィールドの説明どおり、判定(severity・合否)を行う skill を角度に割り当ててはいけない。この制約は形式(schema)では強制できない(自然文の skill 名から判定を伴うかどうかは機械判定できないため)ため、運用(角度を追加するユーザー自身の遵守)に委ねる。
