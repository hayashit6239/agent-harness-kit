---
description: レビュー候補収集(角度別 finder)への dispatch prompt 本体。review-mode=code-review の候補収集フェーズで、finder を「このファイルの実行者自身」の直接の子として起動するための指示(issue #49)。`commands/harness-orchestrate.md`「pr reviewer」節(orchestrator 自身が実行)から Read されて実行される機構ファイルであり、単体で直接呼び出すことは想定しない(issue #63 で `roles/review-finders.md` から `collectors/strategy.md` へ移設・角度定義を `collectors/angles/*.md` へ分解。issue #65 でユーザーが `.harness/collectors/angles/` に観点を追加できるように拡張可能にした)。
allowed-tools: [Read, Skill, Bash, Agent, Grep, Glob, Write]
---

# 収集(collector)機構 — 角度別 finder の起動 dispatch prompt

`commands/harness-orchestrate.md`「pr reviewer」節が review-mode=code-review の候補収集で Read して実行する指示本体。**転写しない** — 必ずこのファイルを Read してから、以下をそのまま実行すること。

**review-mode との関係**: この収集機構は `review-mode=code-review`(既定)の**下位**の差し替え点であり、`review-mode=multi-angle` には適用しない(multi-angle は収集+判定一体で pr reviewer が内部で fan-out する現状維持・issue #63 スコープ外)。

**このファイルを実行している主体自身が、finder の直接の親になる**(issue #49 の核心)。orchestrator が `review-mode=code-review` の候補収集フェーズでこのファイルを実行するため、finder は orchestrator の直接の子になる(orchestrator から見て「孫」、または誰からも観測できない世代にはならない)。対象 PR 番号 `<N>` / リポジトリ `<repo>` / 出力先ディレクトリ `<OUT_DIR>` は呼出元(orchestrator)から渡される(`<OUT_DIR>` 省略時は `mktemp -d` 等で一時ディレクトリを自分で用意してよい)。

**候補の出力形式は `contracts/findings.schema.json` を正とする**(`{file, line, summary, failure_scenario}` の配列。severity・sources 等の判定用フィールドは持たせない — doer≠judge の境界を形式でも守る。issue #64)。**角度(observation point)定義の frontmatter 形式は `contracts/collector-angle.schema.json` を正とする**(`id` / `label` / `skill?` / `enabled?`。新規角度を追加するときの雛形は `contracts/collector-angle.template.md`)。

**★最重要★ 手順を読む前に頭に入れておくこと**:

**全ロール共通コア(issue #52 Phase B・症状1)** — 下記 5 項目は全 dispatch ファイル(実装役 / 対応役 / pr reviewer / collectors)で**文言一致**の単一コア。単一ソースは `tests/smoke/run-smoke.sh` の `CANONICAL_CORE` 配列であり、同 script が各 dispatch ファイル冒頭ブロックへの presence を機械検査する(逐語部分一致)。**文言を変えるときは単一ソースと全 dispatch ファイルを一括更新すること**(1 箇所だけ直すと drift 検査で落ちる):

1. **fork を使うな(fan-out は `general-purpose`)**: 作業中に subagent を fan-out する場面では `subagent_type: "general-purpose"` で起動せよ(`fork` は呼出元の会話文脈を丸ごと継承し、狭い directive を無視して呼出元の最上位タスクを再実行する)。文脈は各 subagent に自己完結する形で渡す。
2. **`SendMessage` を使うな**: 結果は最終メッセージで直接返せ(`SendMessage` は宛先解決に失敗して結果が消失する)。
3. **`gh auth switch` を実行するな**: active アカウントを変えると orchestrator 自身の `gh` 操作が壊れる。
4. **台帳(`.harness/plan-progress.json`)に触れるな**: Read も編集もするな。`git stash` / `git checkout` / `git reset` で戻そうともするな(作業ツリー上で dirty なのは F案の正常な状態)。
5. **観測していないことを書くな**: 『エラー』と『処理中』を区別せよ。分からないことは未観測と書け。

**collectors(候補収集)固有**:

- **各 finder への指示にも共通コア 1・2(fork 禁止・`SendMessage` 禁止)を必ず明示せよ**: finder は起動主体から見て孫になりうるため、finder 自身への指示にも二重に釘を刺す(実測: `SendMessage` で返す finder は宛先解決に失敗して結果を失い、最終メッセージで直接出力した finder は 100% 到達した / `fork` は 6/6 逸脱・1 件も findings を返せなかった)。
- **角度ごとに 1 メッセージ内で並列起動する**(担当領域が排他な独立タスクなので、順番に 1 体ずつ起動しない)。
- **収集は機械的**(角度は下記手順 2 の解決ロジックで確定し、以降は選択の余地なし)。ここでは判定(severity 付与・CONFIRMED/PLAUSIBLE/REFUTED の検証・集計・投稿)を行わない — それは呼出元(pr reviewer)の独立検証の役目であり、finder が担うのは候補の列挙だけ(doer ≠ judge を壊さないための境界)。
- **判定を伴う skill を角度の `skill:` に指定させない**(下記手順 2 参照。観点の frontmatter は収集専任のみを許す — issue #65)。

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
   - **kit デフォルト**: `${CLAUDE_PLUGIN_ROOT}/collectors/angles/*.md`(kit 同梱のデフォルト角度群。角度の追加・削除に伴う本ファイルの更新は不要 — 一覧はこのディレクトリの `*.md` 自体を単一の正とする)
   - **導入先追加**: `<repo>/.harness/collectors/angles/*.md`(ユーザーが独自観点を追加する置き場。無くてもよい)

   解決ロジック(ファイル名基準の union + override。実行例):
   ```
   python3 - "${CLAUDE_PLUGIN_ROOT}/collectors/angles" "<repo の絶対パス>/.harness/collectors/angles" <<'PY'
   import glob, os, re, sys, json

   MAX_ANGLES = 20  # 暴走防止の上限(超過分は fail-open で切り詰める。既存の dispatch 上限パターンに倣った目安値)

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

   # 必須項目・enabled 既定値は contracts/collector-angle.schema.json を実行時に読んで取得する
   # (schema 側の変更にここが追随する。読み込みに失敗した場合のみ fail-open でハードコード値へフォールバック)
   required_fields, enabled_default = ["id", "label"], True
   try:
       schema_path = os.path.join(os.path.dirname(os.path.dirname(kit_dir)), "contracts", "collector-angle.schema.json")
       with open(schema_path, encoding="utf-8") as f:
           schema = json.load(f)
       required_fields = schema.get("required", required_fields)
       enabled_default = schema.get("properties", {}).get("enabled", {}).get("default", enabled_default)
   except Exception as e:
       print(f"WARNING: schema 読込に失敗しハードコード値へフォールバック: {e}", file=sys.stderr)
   # id/label 必須は下の membership 判定(required_fields)一本で保証する。schema 側の "required" が
   # 将来 id/label を含まない形に変わってもここで union して不変条件を守る(round3 finding 2:
   # 直後の membership 判定と後段の .get() 明示チェックの二重検査を解消)。
   required_fields = list(set(required_fields) | {"id", "label"})

   resolved = {}  # basename -> (path, frontmatter, source)
   for d, src in [(kit_dir, "kit"), (target_dir, "target")]:
       if not d or not os.path.isdir(d):
           continue
       for path in sorted(glob.glob(os.path.join(d, "*.md"))):
           fm = parse_frontmatter(path)
           if fm is None or any(k not in fm for k in required_fields):
               continue  # frontmatter 不正な角度ファイルは fail-open で無視(収集を止めない)
           resolved[os.path.basename(path)] = (path, fm, src)  # target が後で回るため kit を上書き

   angles = []
   for base, (path, fm, src) in sorted(resolved.items()):
       enabled_str = fm.get("enabled", "true" if enabled_default else "false")
       if enabled_str.lower() == "false":
           continue
       # id/label の必須は上の required_fields union + membership 判定(`any(k not in fm ...)`)で
       # 保証済みのため、ここでの再チェックはしない(直接アクセスで KeyError にならない。round3 finding 2)
       angles.append({"path": path, "id": fm["id"], "label": fm["label"], "skill": fm.get("skill"), "source": src})

   if len(angles) > MAX_ANGLES:
       dropped = [a["id"] for a in angles[MAX_ANGLES:]]
       angles = angles[:MAX_ANGLES]
       print(f"WARNING: 角度数が上限({MAX_ANGLES})を超過。省略した角度: {dropped}", file=sys.stderr)

   print(json.dumps(angles, ensure_ascii=False, indent=2))
   PY
   ```
   - `id` の全角度(kit + 導入先)を通したユニーク性は、この収集フェーズでは強制検証しない(fail-open。詳細は下記「既知の制限・拡張ポイント」参照)。
   - 角度が 1 件も解決できなかった場合(kit デフォルトの読み込みにも失敗)は候補収集を中止し、呼出元へ「角度を 1 件も解決できなかった」と報告する(0 件を偽って返さない)。
   - 解決した角度数が `MAX_ANGLES`(既定 20)を超える場合、超過分は fail-open で切り詰める(角度数だけ並列 finder が増えコストが膨らむのを防ぐ。1 tick あたりの dispatch 上限 5 件など、本コマンド群が他の fan-out に課す暴走防止パターンに倣った目安値)。切り詰めが発生すると標準エラー出力に警告が出るので、手順 7 の返り値に「角度数上限により省略した角度: `<id>` 一覧」として含める。

3. **解決した角度ごとに finder を起動する**。各 finder には次を**自己完結する形で**渡す(`general-purpose` は呼出元の文脈を継承しないため): 対象 worktree の絶対パス・diff の見方(`cd <worktree> && git diff "origin/$BASE_REF"...HEAD`)・角度の frontmatter 外の本文(その角度が探すものの指示)・出力形式(`contracts/findings.schema.json`)・出力先ファイルパス・「SendMessage 禁止・直接返せ」の指示。

   各 finder の dispatch prompt テンプレート(`<id>` / `<label>` / `<body>` を手順 2 で解決した角度の値で埋め、解決した角度の数だけこのテンプレートで起動する。**`skill` が設定されている角度は、プロンプト先頭に skill 起動の指示を織り込む**(issue #65)):

   > (`skill` が設定されている場合のみ先頭に追加)「まず `Skill` ツールで `<skill>` を起動して従い、」
   >
   > 「あなたは PR #<N> の diff を **`<id>`(<label>)** の観点だけでレビューする finder だ。他の観点は担当しない・判定(severity 付与や採否)も行わない。作業ディレクトリ: `<worktree の絶対パス>`。diff は `cd <worktree> && git diff "origin/<BASE_REF>"...HEAD` で見よ(必要なら worktree 内の他ファイルも Read/Grep して文脈を補ってよい)。この観点が探すもの: `<body>`。見つけた候補を `contracts/findings.schema.json` が定める形(`{file, line, summary, failure_scenario}`)の JSON 配列として **Write ツールで** `<OUT_DIR>/<id>.json` に書け(該当なしなら空配列 `[]` を書く。何であれ必ずファイルを書くこと — 未応答扱いを防ぐため)。**`SendMessage` は使うな。** 書き終えたら、最終メッセージとして `<id>: N 件書いた` とだけ直接返せ(findings 本文を最終メッセージに含めない — 呼出元の context を圧迫しないため)。`.harness/plan-progress.json` には一切触れるな。」

   `skill:` が指す skill が見つからない・起動に失敗した場合、その finder は当該角度を候補 0 件として扱ってよい(fail-open。判定は不要な収集専任のため、skill 欠落で候補収集全体を止めない)。

4. **全 finder の完了を待ち、出力ファイルの存在を確認する**。Write していない角度(クラッシュ・タイムアウト等)があれば、その角度は候補 0 件として扱う(fail-open)。**ただし「0 件」と「未応答」を混同しない** — 未応答の角度があれば、後段(呼出元の報告)に「`<id>` 未応答」と 1 行残せるよう、未応答一覧を手順 7 の返り値に含める。

5. **統合 findings ファイルを組み立てる**(角度ごとの個別ファイルは残したまま、統合版を追加で書く。**呼出元の context には個々の findings 本文を持ち込まない** — 統合は `jq` のファイル操作で行い、LLM が読んで転記しない):
   ```
   jq -s '[.[][]]' <OUT_DIR>/<id1>.json <OUT_DIR>/<id2>.json ... > <OUT_DIR>/findings.json
   ```
   (手順 2 で解決した角度の `id` すべてを列挙する。未応答でファイルが存在しない角度がある場合は、その角度のパスを `jq -s` の引数から除外する。1 件も書けなかった場合は `<OUT_DIR>/findings.json` に `[]` を書く。)

6. **worktree を後片付けする**(成否に関わらず):
   ```
   git worktree remove --force "$WORKTREE"
   ```

7. **呼出元へ返す**: 統合ファイルのパス `<OUT_DIR>/findings.json` と、未応答の角度があればその一覧(手順 4)・角度数上限により省略した角度があればその一覧(手順 2)を返す。**findings の中身そのものを呼出元へ再掲しない**(呼出元(orchestrator)は必要になったときにファイルを Read する — findings 本文をここで自分の応答に含めて context に載せない)。この後 orchestrator が dispatch する pr reviewer(`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md`)がこのパスを使って独立検証(候補ごとの CONFIRMED/PLAUSIBLE/REFUTED 判定 + severity 付与。手順は同ファイル手順 4-b 参照)を行う — **その検証はこのファイルの範囲外**(finder は候補を機械的に集めるだけで判定しない)。

## 既知の制限・拡張ポイント(issue #65)

- **`id` の全域ユニーク性は未検証(fail-open)**: 手順 2 は同名 `id` が kit デフォルトと導入先追加(または導入先内の複数ファイル)で衝突しても収集を止めない。衝突すると `findings.json` 上で角度の由来が曖昧になりうるが、悪化が観測されたら validator 側(follow-up)で検証を追加する。
- **`enabled: false` の対象**: 現状は kit デフォルト・導入先追加のどちらのファイルにも書ける(frontmatter 単位の無効化。config ファイルでの一括無効化は本 issue のスコープ外)。
- **skill 委譲は収集専任のみ**: `contracts/collector-angle.schema.json` の `skill` フィールドの説明どおり、判定(severity・合否)を行う skill を角度に割り当ててはいけない。この制約は形式(schema)では強制できない(自然文の skill 名から判定を伴うかどうかは機械判定できないため)ため、運用(角度を追加するユーザー自身の遵守)に委ねる。kit 同梱のデフォルト角度自身もこの制約を守り、`skill:` を使わず本文の指示のみで収集する。
- **角度数の上限(`MAX_ANGLES=20`・fail-open)**: 手順 2 は解決した角度数が上限を超えると超過分を切り詰める。値は kit デフォルト(9)に導入先追加分の余裕を見込んだ目安であり、実運用で不足/過剰が観測されたら見直す。
