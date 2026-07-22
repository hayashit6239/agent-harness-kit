---
description: 対象 repo の .harness/plan-progress.json を単一の書込主体として、developer(実装役・対応役)/ pr reviewer に加え、issue フェーズの issue reviewer / issue review worker(issue #88)を配車する orchestrator(v1 walking skeleton)。判断ロジックは一切持たず、既存の判定 skill/command(`/code-review` または `reviewing-multi-angle` 経由の `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md`)に委譲し、返答を検証してから台帳へ書き込む。前進できない状況は原因を問わず単一の失敗経路(need for human review sink)に集約する。ルーティング(台帳書込・sink・ラベル操作)は各ロールが状況を outcome トークンに解決したうえで tested decision script(`scripts/decide-orchestrator-route.py`)で決定論的に解決し、規則を散文に複製しない。委譲先ロール(実装役・対応役・pr reviewer)の作業レポート(`reports[]`)も、単一 writer 原則(`.harness/CLAUDE.harness.md`)に従い本コマンドが代筆する(issue #52 症状2)。**第 1 引数にゴール文言を渡すと、本コマンドの手順書内容を context にロード済みの状態で、失敗経路のトリガーを反映した `/goal <文言>` コマンド文字列を組み立てて提示する(issue #60)。issue #89 で第 1 引数に `'pr <N>'` / `'issue <N>'` の構造化対象指定を渡すと、凍結雛形から verbatim(LLM パラフレーズ無し)で `/goal` 文字列を組み立てるモードを追加した。`/goal` の実行そのものは技術的制約により本コマンドから起動できないため、提示のみに留まる**。
argument-hint: "[ゴール文言|'pr <N>'|'issue <N>'] [review-mode] [owner/repo]  省略時: 通常 tick 実行 / code-review(opt-in: multi-angle) / CWD の origin から自動判定。第1引数指定時は /goal 起動文字列の組み立てのみを行う(構造化指定=pr/issue モードは凍結雛形から組み立て)"
allowed-tools: [Bash, Agent, PushNotification, Skill, Read]
---

# /harness-orchestrate — developer / pr reviewer を配車する orchestrator(v1 walking skeleton)

これは **運用(policy)** の層であり、minimal 構成の上に乗る **orchestrator ロール**(Phase 1 の中核機構の最初の増分)。対象は **PR ライフサイクルの 3 ロール(developer 実装役・対応役 / pr reviewer)+ issue フェーズの 2 ロール(issue reviewer / issue review worker)**(issue #88 で issue フェーズを PR フェーズと対称に配線した)。**issue フェーズの非対称(正直な明記・issue #88 / #93)**: 「A＝PR と対称」は **1 点(evidence gate)を除いて成立する** — (i) issue フェーズには実行して落とせる証拠(test)が構造的に無く **evidence gate 相当が無い**(本 issue でも残存)。**(ii) issue reviewer の判定エンジンの可搬性は issue #93 で解消した** — 既定 `ISSUE_REVIEW_MODE=spec` は kit 同梱 spec `roles/issue-reviewer.md`(8 観点 / 3 ファミリー rubric を parity 深さで inline)を Read して実行し、他 repo は skill 無しで動く(個人 skill `reviewing-github-issues` は opt-in `ISSUE_REVIEW_MODE=skill` へ後退・PR 既定 `code-review` / opt-in `multi-angle` と対称)。残る受容コストは **kit 版 spec ⇔ 個人 skill の rubric drift が機械検知不可・best-effort 手動同期**(個人 skill は repo 外にあり smoke から読めない)である点のみ。

## `/goal` 起動文字列の組み立て(issue #60)

> **⚠ 下流 fresh session(`$1` 無し)向けの道標(issue #112 round1 🔴1)**: 本節「`/goal` 起動文字列の組み立て」全体は、`$1` を伴う起動(`/harness-orchestrate <ゴール文言|pr <N>|issue <N>>`)でのみ発火する**組み立てモード**の説明である。生成 goal 文の要件 (b)(下記)に従い本手順書を「正」として Read しただけで `$1` を持たない下流 session は、本節を適用しない — `$1` 省略時の唯一の正は下記「`$1` が省略された場合」で、そこが指す orchestrator tick 手順(「orchestrator の性質」節以降)を実行する。本節の雛形・組み立て散文を「正の手順」として follow し `/goal` 文字列を提示するだけで終わると tick が一度も回らず PR が前進しない(harness の cardinal sin = 静かな非前進)ため、この道標で明示的に塞ぐ。要件 (b) の literal 文言そのもの(「手順は手順書 `commands/harness-orchestrate.md` を正として参照して進めて」)は issue #110 で確定済みの固定値のため書き換えず、本道標を手順書側へ足すことで残余経路を閉じる。

実運用では、本コマンドの定期実行を `/loop` に任せるのではなく、Claude Code CLI の `/goal`(Stop hook 機構。各ターン終了時に小さい高速モデルがゴール条件の充足を判定し、未充足ならブロックして続行を強制する仕組み。https://code.claude.com/docs/en/goal )に「本コマンドの手順書を読み込んで停止条件つきで繰り返し実行する」文言を手打ちする運用へ実質移行している。この手打ちは (a) 本コマンドの手順書ロード指示と (b) 停止条件の列挙、の 2 手を毎回繰り返す無駄があり、かつ (b) は下記「失敗経路(単一の need for human review sink)」節がすでに持つ包括的なトリガー一覧の限定的な再実装になりがちで drift しやすい。本コマンドは第 1 引数にゴール文言を渡すことでこの 2 手を 1 手(組み立て結果のコピー&ペースト)へ縮める。

**技術的制約(正直な明記)**: 本コマンドは `/goal` を完全にはラップできない。skill/command の実行は 1 ラウンドで完結し、そこから hook 設定を動的に書き換えてターン継続を強制する公式な経路が無い(claude-code-guide エージェントが公式ドキュメントを参照して確認済みの制約)。したがって本コマンドが行えるのは「`/goal` に渡す文字列の組み立てと提示」までであり、**`/goal` の実行そのものは引き続きユーザーの手操作を要する**(2 手が 1 手になるだけで 0 手にはならない)。

**引数**: `$1`=第 1 引数(省略時=通常 tick を実行 / 指定時=`/goal` 文言を組み立てて提示するモード。自由文ゴール文言、または issue #89 の構造化対象指定 `'pr <N>'` / `'issue <N>'` を単一引用で載せる)、`$2`=review-mode(省略時 `code-review`)、`$3`=owner/repo(省略時 CWD の origin から自動判定)。bash の位置引数は途中を省略できないため、repo(`$3`)を明示したい場合は先行する `$1`・`$2`(review-mode)を空文字で埋める必要がある(例: `/harness-orchestrate "" "" owner/repo`)。空文字であれば「配車テーブル」節の既存展開 `REVIEW_MODE="${2:-code-review}"` がそのまま既定値にフォールバックするため、既存の展開ロジックの変更は不要。**構造化対象指定は既存の位置引数レイアウトを変えず単一引用の `$1` に載せる**(例: `/harness-orchestrate 'pr 36'`)ため、`$2`/`$3` の意味は不変。

**`$1` の解釈は 3 分岐**(issue #89・軸 3 = 併存・後方互換): `$1` をまず下記「モード判定マニフェスト」の strict 正規表現へ照合し、(1) **構造化モード**(`pr <N>` / `issue <N>` に完全一致)なら凍結雛形から `/goal` 文字列を組み立てる / (2) **near-miss**(引用符欠落・二重空白等)なら警告を添えて自由文フォールバック / (3) いずれでもなければ従来どおり**自由文モード**(#60)として扱う。判定順は「構造化を先に照合 → 非一致は自由文フォールバック」。

### モード判定(issue #89)

`$1` を次のマニフェスト(strict 受理 / near-miss 判定の**単一ソース**。値は bash `[[ ... =~ ... ]]` の ERE。smoke `[14]` が `[8]`/`[13]` 同型で単体テストする)へ照合する:

<!-- MODE-DETECTION-MANIFEST:BEGIN -->
```
MODE-PR = ^pr [0-9]+$
MODE-ISSUE = ^issue [0-9]+$
NEAR-BARE = ^(pr|issue)$
NEAR-LOOSE = ^(pr|issue)[[:space:]]+[0-9]+[[:space:]]*$
```
<!-- MODE-DETECTION-MANIFEST:END -->

- **構造化モード**: `$1` が `MODE-PR` / `MODE-ISSUE` のいずれかに**完全一致**したら、その `<N>`(番号)を凍結雛形へ literal 置換して `/goal` 文字列を組み立てる(下記「構造化モードの雛形」)。**対象 PR/issue の実在は検証しない**(#60 と同じ「提示のみ」姿勢。`pr 99999` でも組み立てる。`issue abc` は `MODE-ISSUE` 不一致で自由文へ)。
- **near-miss(警告 + 自由文フォールバック・hard error にしない)**: `$1` が strict のいずれにも一致せず、かつ `NEAR-BARE`(裸キーワードのみ = 引用符欠落で番号が `$2` へ流れた兆候)または `NEAR-LOOSE`(キーワード + 空白 + 番号だが単一空白でない = 二重空白・タブ・末尾空白)に一致したら、次の 1 行警告を提示に添えたうえで**自由文として扱う**(非破壊):
  > 構造化モードの near-miss を検出しました(`$1`='…')。構造化モードは `'pr <N>'` / `'issue <N>'`(単一引用・単一空白・裸の番号)を厳密に要求します。今回は自由文ゴールとして扱いました — 構造化モードのつもりなら正しい形で再実行してください。

  hard error にしないのは、本コマンドが `/goal` 文字列を提示するだけで破壊的作用が無く、人間が提示を読んで誤りに気付けるため + 後方互換(自由文ゴール)を壊さないため。
- **自由文モード(#60・後方互換)**: 上記いずれにも該当しなければ、`$1` を従来どおり自由文ゴール文言として扱う(下記「自由文モード」)。現行の自由文例 `issue #42 を…` は `#42`(裸の数字でない)+ 番号後の助詞・文により strict にも near-miss にも一致せず、**警告を誤発火しない**。

### 構造化モードの雛形(issue #89・verbatim 単一ソース・LLM パラフレーズ禁止)

構造化モードでは、下記の凍結雛形から `<N>` を**文字列置換するだけ**で `/goal` 文字列を組み立てる。**#60 の自由文モードのような「平易な日本語で言い換える」パラフレーズ手順は構造化モードでは一切行わない**(同一入力 → 同一出力を構造的に担保する = DoD-1 決定性)。

**生成される goal 文のテンプレート要件 (a)(b)(issue #110)**: 両モード雛形が生成する `/goal` 文は次の 2 要件を満たす。**(a) コマンド名のスラッシュ起動を指示しない** — `/harness-orchestrate` のスラッシュ起動を goal 文へ書くと、引数あり分岐(= `/goal` 文字列の組み立てモード)へ誤入し「goal 文が goal 文の生成を指示する」再帰になるため。下記凍結雛形はいずれもコマンド名のスラッシュ起動を含まず、この要件を満たす。**(b) 手順書ファイルを正として参照する literal 文言を含める** — 生成 goal 文へ「手順は手順書 `commands/harness-orchestrate.md` を正として参照して進めて」の一文を差し込む(下記雛形に焼き込み済み)。これは*生成される goal 文*が下流の fresh session でも手順書を辿れるようにする自己参照責務であり、**自由文モード(#60)の item-1「本ファイルは既に context にロード済み・追加読込不要」(=*組み立てセッション自身*の context の話) とはレイヤが別**である — item-1 は組み立てセッションに無用な再読込を強いないための記述であって (b) を骨抜きにするものではない(両者を混同して item-1 を書き換えない)。

停止条件は次の「凍結停止条件マニフェスト」を単一ソースとする。**このマニフェストの 18 個の outcome トークンは `scripts/decide-orchestrator-route.py` の `route=="sink"` outcome(PR フェーズ 11 + issue フェーズ 6 = 17。issue #88)+ `git-status-guard`(decision script 外・1)= 18 にアンカーし、smoke `[14]` が集合一致を機械検証する**(散文表の行数ではなく decision script が単一の正)。人間可読な `/goal` 文字列はこのトークン付きソースからの literal 連結で組み立てる — その際 `subjective_escalate`(PR ×3 / issue ×2)と reviewLock / issueReviewLock `timeout`(PR ×2 / issue ×2)は雛形側で各フェーズ 1 文へ畳み込み済み(18 トークン → 13 文)であり、**組み立て時に LLM で畳み直さない**(畳み込みは凍結ソースに焼き込む):

<!-- FROZEN-STOP-CONDITIONS:BEGIN -->
```
implementer/ambiguous | 実装役の pr_number 復旧検索が複数一致(曖昧)
implementer/pr_evidence_fail | 実装役 dispatch 後の evidence gate 失敗
implementer/timeout | 実装役の in-flight マーカーが締切超過でリトライ上限到達
implementer/subjective_escalate | 実装役 dispatch が主観的エスカレーションを返した(PR 未作成)
responder/evidence_fail | 対応役 dispatch 後の evidence gate 失敗
responder/timeout | 対応役の reviewLock が締切超過(dispatch の hang)
responder/subjective_escalate | 対応役 dispatch が主観的エスカレーションを返した
reviewer/invalid | reviewer dispatch の返答が JSON でない(dispatch 結果失敗)
reviewer/escalate | reviewer dispatch が escalate=true を返した(round/trend 停止条件)
reviewer/timeout | reviewer の reviewLock が締切超過(dispatch の hang)
reviewer/subjective_escalate | reviewer dispatch が主観的エスカレーションを返した
issue-reviewer/invalid | issue reviewer dispatch の返答が JSON でない(dispatch 結果失敗)
issue-reviewer/escalate | issue reviewer dispatch が escalate=true を返した(round/trend 停止条件)
issue-reviewer/subjective_escalate | issue reviewer dispatch が主観的エスカレーションを返した
issue-reviewer/timeout | issue reviewer の issueReviewLock が締切超過(dispatch の hang)
issue-review-worker/subjective_escalate | issue review worker dispatch が主観的エスカレーションを返した
issue-review-worker/timeout | issue review worker の issueReviewLock が締切超過(dispatch の hang)
git-status-guard | git-status ガードが .harness/ への意図しない変更を検知(decision script 外)
```
<!-- FROZEN-STOP-CONDITIONS:END -->

上の 18 トークンを 13 文へ畳んだ**停止条件の並び(凍結・verbatim・両モード共通)** `<STOP>`:

> reviewer dispatch が escalate=true を返した(round/trend 停止条件)/ reviewer dispatch の返答が JSON でない(dispatch 結果失敗)/ 実装役 dispatch 後の evidence gate 失敗 / 対応役 dispatch 後の evidence gate 失敗 / 実装役の pr_number 復旧検索が複数一致(曖昧)/ 実装役の in-flight マーカーが締切超過でリトライ上限到達(timeout)/ reviewer・対応役の reviewLock が締切超過(dispatch の hang・timeout)/ 実装役・対応役・reviewer いずれかが主観的エスカレーションを返した / issue reviewer dispatch が escalate=true を返した(round/trend 停止条件)/ issue reviewer dispatch の返答が JSON でない(dispatch 結果失敗)/ issue reviewer・issue review worker いずれかが主観的エスカレーションを返した / issue reviewer・issue review worker の issueReviewLock が締切超過(dispatch の hang・timeout)/ git-status ガードが .harness/ への意図しない変更を検知した

**PR モード雛形**(`$1` = `pr <N>`。`<N>` を番号へ・`<STOP>` を上の 13 文へ literal 置換する):

```
/goal 「PR #<N> を ready for merge になるまでレビュー・対応を繰り返して。手順は手順書 `commands/harness-orchestrate.md` を正として参照して進めて。次のいずれかに該当したら停止して人間に報告して: <STOP>。人間のタッチポイントは (i) この /goal 実行の承認 (ii) 停止条件到達(sink)時 (iii) ready for merge 到達後の merge 代行判断、の 3 点のみで、それ以外の途中の人間確認は無い。ready for merge に到達したら、規約『終端の記録と merge 代行』節に従い人間が merge を代行してよい — この /goal 文言(委譲条項が見える状態)を人間が読んで実行した行為が同節の言う"明示指示"に相当する。merge 前提確認(status=ready for merge かつ CI 緑、外れたら拒否・エスカレーション)は同節が定める人間の手動ゲートであり、この goal ループの停止条件ではない(自動ループの到達点は ready for merge 止まり)。」
```

**issue モード雛形**(`$1` = `issue <N>`。一気通貫・v1):

```
/goal 「issue #<N> を issue レビュー → ready for implementation → PR 作成 → PR レビュー・対応 → ready for merge まで一気通貫で進めて。手順は手順書 `commands/harness-orchestrate.md` を正として参照して進めて。次のいずれかに該当したら停止して人間に報告して: <STOP>。人間のタッチポイントは (i) この /goal 実行の承認 (ii) 停止条件到達(sink)時 (iii) ready for merge 到達後の merge 代行判断、の 3 点のみで、それ以外の途中の人間確認は無い。ready for merge に到達したら、規約『終端の記録と merge 代行』節に従い人間が merge を代行してよい(提示された本文言を読んで実行した行為が同節の"明示指示"に相当。precheck: status=ready for merge かつ CI 緑・外れたら拒否)。なお本雛形が凍結する停止条件 `<STOP>` は上記 13 文(18 トークン)で issue 相・PR 相の両フェーズを覆う — issue #88 で issue フェーズの sink outcome(issue reviewer の escalate(round 上限 / blocker trend)・dispatch 結果失敗・主観的エスカレーション・issueReviewLock の hang / issue review worker の主観的エスカレーション・issueReviewLock の hang)を decision script に成文化したため、issue 相にもレビューが収束しない失敗モードを自動 halt する停止条件が備わり、本雛形はそれらを含めて組み立てる。」
```

**Phase 3(#85)再利用の境界(1 行制約)**: この「構造化対象指定 → verbatim goal 文字列」の展開部品は、入出力境界(入力 = `pr <N>` / `issue <N>` の構造化指定 / 出力 = 上記 verbatim goal 文字列)を、Phase 3(#85)の無人トリガーが人間の `/goal` 実行を置き換える際にそのまま食える形に保つ(この境界を崩す拡張をしない)。

### 自由文モード(#60・後方互換)

**`$1` が自由文の場合**(構造化モードにも near-miss にも該当しない。例: `/harness-orchestrate "issue #42 を ready for implementation になるまでレビュー・対応を繰り返して"`): 本コマンドは通常の tick(下記「配車テーブル」以降の手順)を実行**しない**。代わりに次を行う:

1. 本ファイル(このコマンドの手順書)は、このコマンド自体の実行によって既に context にロード済みである。追加のファイル読込は不要。
2. 下記「失敗経路(単一の need for human review sink)」節の**この sink にルーティングされるトリガー**表(decision script 経由の sink 17 種 = PR フェーズ 11 種 + issue フェーズ 6 種(issue #88)+ git-status ガード 1 種 = 合計 18 種)を、簡潔な自然文の停止条件へ変換する。うち `timeout` 系 5 種(実装役 `dispatchMarker` の hang + reviewer / 対応役 `reviewLock` の hang + issue reviewer / issue review worker `issueReviewLock` の hang。issue #26 / #71 / #88)は下表の行ではなく「tick 冒頭 reconciliation」節が検知する変則 sink だが、停止条件としては下記サンプルに含める。表の `role/outcome` トークンや書込 status 列はそのまま `/goal` 文字列へ転記しない — 表の「トリガー(状況)」列の文言を平易な日本語で言い換える。**ゴールが issue フェーズのみ(例: `created issue → ready for implementation`)なら issue フェーズの停止条件だけを、PR フェーズのみなら PR フェーズの停止条件だけを選んでよい**(ゴールに無関係なフェーズの停止条件は省ける)。
3. `$1` のゴール文言と、変換した停止条件を、次のサンプルと同じ構造で 1 つの `/goal` コマンド文字列に組み立てる:

   ```
   /goal 「issue #42 を ready for implementation になるまでレビュー・対応を繰り返して。手順は手順書 `commands/harness-orchestrate.md` を正として参照して進めて。次のいずれかに該当したら停止して人間に報告して: issue reviewer dispatch が escalate=true を返した(round/trend 停止条件)/ issue reviewer dispatch の返答が JSON でない(dispatch 結果失敗)/ issue reviewer・issue review worker いずれかが主観的エスカレーションを返した / issue reviewer・issue review worker の issueReviewLock が締切超過(dispatch の hang・timeout)/ git-status ガードが .harness/ への意図しない変更を検知した」
   ```

   サンプルの「issue #42 を ready for implementation になるまでレビュー・対応を繰り返して」の部分を `$1` の内容に差し替える。**サンプル中の「手順は手順書 `commands/harness-orchestrate.md` を正として参照して進めて」の一文は要件 (b)(issue #110)であり、`$1` の内容に差し替えず必ず残す** — これは*生成される goal 文*が下流の fresh session でも手順書を辿れるようにする自己参照責務であり、上記 item-1(*組み立てセッション自身*は既に手順書を context ロード済み・追加読込不要)とはレイヤが別である(item-1 と混同して (b) を落とさない)。また要件 (a) として、組み立てる goal 文にコマンド名のスラッシュ起動(`/harness-orchestrate ...`)を書かない(組み立てモードへの再帰誤入を封じる)。**上記サンプルは issue フェーズのゴール向けに issue フェーズの停止条件のみを選んだ例**(issue #88)。PR フェーズまで回すゴールなら PR フェーズの停止条件(reviewer/実装役/対応役の escalate・dispatch 失敗・evidence gate 失敗・ambiguous・reviewLock hang・subjective_escalate)も同じ粒度で列挙する(`subjective_escalate` は同フェーズ複数ロールを 1 文に、`timeout` 系も同種を 1 文にまとめてよい)。
4. 組み立てた `/goal <文言>` をそのままコピー&ペーストできる形で提示して終了する。**このコマンド自身は `/goal` を実行しない**(実行はユーザーの操作)。

**`$1` が省略された場合**: 従来どおり、本コマンドは 1 回の orchestrator tick を実行する(以下の手順)。

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
| **issue reviewer** dispatch が `escalate=true` を返した(round/trend 停止条件。issue #88) | issue-reviewer/`escalate` | `issue.status="need for human review"`(停止条件到達の事実。1 回のローカル書込後に sink) |
| **issue reviewer** dispatch の返答が JSON でない / `escalate` を読めない(dispatch 結果失敗。issue #88) | issue-reviewer/`invalid` | `issue.status` への書込なし(dispatch 失敗のため状態を変えない。dispatch 元のまま)。ただし dispatch 直前に書いた `issueReviewLock` は解除する |
| **issue reviewer** dispatch が主観的エスカレーション(`escalate_to_human`)を返した(issue #88) | issue-reviewer/`subjective_escalate` | `issue.status="need for human review"`(1 回のローカル書込後に sink) |
| **issue reviewer** の `issueReviewLock` が締切超過(dispatch の hang。issue #88) | issue-reviewer/`timeout` | `issue.status` への書込なし(hang は検証不能なので状態を捏造しない)。`issueReviewLock` は削除せず永続させ `notified: true` を追加する |
| **issue review worker** dispatch が主観的エスカレーション(`escalate_to_human`)を返した(issue #88) | issue-review-worker/`subjective_escalate` | `issue.status="need for human review"`(1 回のローカル書込後に sink) |
| **issue review worker** の `issueReviewLock` が締切超過(dispatch の hang。issue #88) | issue-review-worker/`timeout` | `issue.status` への書込なし(hang は検証不能)。`issueReviewLock` は削除せず永続させ `notified: true` を追加する |
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

**issue フェーズの sink の差分(issue #88)**: issue reviewer / issue review worker が sink に落ちるときも上記共通手続きに従うが、PR が無いため 2 点だけ変える(round1 🟡4 決定):
- **手順 1 のラベルは issue に付ける**: `gh pr edit` の代わりに `gh issue edit <N> --repo <repo> --add-label "need for human review"`(`gh label create` の冪等 fallback は同じ)。
- **手順 3 の無条件スキップは台帳ベースで足りる**: 選別 jq は `issue.status` を読むため、sink が `issue.status="need for human review"` を書けば以降の選別(`created issue` / `waiting for review` / `completed review` のみ対象)から自動的に外れる(status 自身がスキップを兼ねる)。PR フェーズの `gh pr view --json labels` によるラベルベース無条件スキップより単純。ただし `timeout`(`issueReviewLock` hang)は status を書かず `issueReviewLock` を永続させるため、無条件スキップは `dispatchMarker` の `notified` と同型に **`issueReviewLock.notified` が担う**(「tick 冒頭 reconciliation」節「issueReviewLock の reconciliation」参照)。

**有界停止の保証**: この sink に入った step は「人間がラベルを外す」以外に配車対象へ戻る経路が無い。したがって、どのロール(実装役・対応役・reviewer)から入っても、evidence が通らない/停止条件に達した/dispatch 結果が失敗した step が無限に再 dispatch され続けることはない(無界ループは残さない)。**実装役の `no_pr`(dispatch 後 PR 未作成 + 復旧検索 0 件)は、issue #26(P1 決定)により「tick 冒頭 reconciliation」節の in-flight マーカー機構(締切 K=2 tick・リトライ上限 N=2)で有界化された** — `no_pr` は sink には入らず route=skip のまま毎 tick 即時再 dispatch されるが、原因が持続的なら最大 N=2 回のリトライで outcome=`timeout` に解決し sink(この sink はラベルではなく永続する `dispatchMarker` 自体が「無条件スキップ」を実装する変則形 — 詳細は「tick 冒頭 reconciliation」節参照)。これで本コマンドが掲げる「無界ループを残さない」不変条件に唯一残っていた例外が解消された(旧版はこの段落で `no_pr` を唯一の例外と明記していたが、issue #26 で解消済み)。加えて、reviewer/`escalate` は `pr.status="need for human review"` を書いてから sink するため(上記「sink の出口を人間の意図と結線」参照)、人間がラベルを外しただけでは再 dispatch されず、この経路での再 escalate ループは構造的に防がれる(`invalid` 経路は書込が無いため対象外)。**reviewer / 対応役の `reviewLock` hang も issue #71 の締切機構(reviewLock reconciliation・N=0)で有界化された** — 次 tick で締切超過を検知し reviewer/`timeout` または responder/`timeout` として単一 sink に落ちる(「tick 冒頭 reconciliation」節「reviewLock の reconciliation」参照)。

**この有界性は tick 数ベースであり実時間ベースではない(B2・issue #71)**: 上記の「無限に再 dispatch され続けない」保証は、**tick を単位とした有界性**(実装役は最大 N=2 リトライ、reviewLock hang は次 tick で即 sink 等)である。`/loop` 運用では tick 間隔がおおむね一定なため**近似的に実時間の有界性にもなる**が、**手動代行モード(orchestrator を `/loop` ではなくルートエージェントが都度手動起動する運用。「既知の制限・拡張ポイント」節参照)では tick 間の実時間間隔(cadence)が不定期**であり、次 tick を人間がいつ起動するかに実時間の有界性が依存する — 締切機構が保証するのは「何 tick で sink へ到達するか」であって「何分/何時間で」ではない。`dispatchMarker` の `K=2` / `reviewLock` の `K_review=0` はいずれも tick 数の値であり、実時間の締切ではない(締切を tick ベースから時刻ベースへ変える案 = #53 の B3 は本 issue のスコープ外・owner 判断待ち)。

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
  #     "label_action": "null|add_ready_for_merge|remove_ready_for_merge|
  #                      add_ready_for_implementation|remove_ready_for_implementation"}
  ```
  **各ロール節が定義するのは `<command>/<exit_code>/<summary>` に何を渡すかだけ**(sink 系 outcome ごとに、その outcome を解決した手順で既に確定している値を使う — この判定のために新たに何かを実行観測する必要は無い)。**この呼び方(heredoc → `OBS_CMD`/`OBS_SUMMARY` → `"$OBS_CMD"`/`"$OBS_SUMMARY"` 展開)はロール共通の唯一の正であり、各ロール節(実装役手順 7 を含む)はこれを複製せずここを参照する。** script が exit 2(`observation` 欠落・不備を含む)を返した場合の扱いは下記のとおり。

  outcome トークン(role ごと。全網羅は `tests/smoke/run-smoke.sh` [8] が決定論検証):
  - **implementer**: `no_pr`(返答不正 かつ 復旧検索 0 件)/ `ambiguous`(復旧検索 複数件)/ `pr_evidence_pass`(pr_number 確定 かつ evidence exit 0)/ `pr_evidence_fail`(pr_number 確定 かつ evidence 非 0)/ `timeout`(issue #26: 「tick 冒頭 reconciliation」節の in-flight マーカーが締切超過でリトライ上限 N=2 に到達、またはマーカーが壊れている/不整合)/ `subjective_escalate`(issue #31・PR 未作成のまま `escalate_to_human` を返した)
  - **responder**: `evidence_pass` / `evidence_fail` / `timeout`(issue #71: 「tick 冒頭 reconciliation」節の reviewLock reconciliation が締切超過 = hang と判定した。reconciliation 側が解決)/ `subjective_escalate`(issue #31)
  - **reviewer**: `invalid`(返答が JSON でない・`escalate` を読めない=dispatch 結果失敗)/ `escalate`(escalate=true)/ `clean_pass`(escalate=false かつ has_blocker=false)/ `blockers`(escalate=false かつ has_blocker=true)/ `timeout`(issue #71: reviewLock が締切超過 = hang。`invalid` とは別事象で reconciliation 側が解決)/ `subjective_escalate`(issue #31・客観的な `escalate` とは別に `escalate_to_human` を返した)
  - **issue-reviewer**(issue #88・reviewer を issue フェーズへ写す): `invalid` / `escalate`(escalate=true)/ `clean_pass`(escalate=false かつ has_blocker=false → `issue.status="ready for implementation"` + issue の `ready for implementation` ラベル付与)/ `blockers`(escalate=false かつ has_blocker=true → `issue.status="completed review"` + ラベル除去)/ `timeout`(`issueReviewLock` が締切超過 = hang)/ `subjective_escalate`(issue #31)。`ledger_write` は `pr.status` ではなく **`issue.status`** を書く(下記「`ledger_write` の適用」の issue キー参照)
  - **issue-review-worker**(issue #88・responder を issue フェーズへ写すが evidence gate を持てない): `done`(指摘対応が済んだ → `issue.status="waiting for review"`)/ `subjective_escalate`(issue #31)/ `timeout`(`issueReviewLock` が締切超過 = hang)。**責め返す evidence gate が無いため responder の `evidence_pass`/`evidence_fail` 二分岐は無く、前進 outcome は単一の `done` のみ**。`ready for implementation` は worker からは書けない(= issue-reviewer の `clean_pass` 経由でのみ到達する doer≠judge の構造担保)

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
  argv = argv + ["false", "dispatchMarker"][len(argv) - 4:]  # <clear_marker>/<marker_field> 省略時の既定 (この pad は tests/smoke/run-smoke.sh の APPLY_LW に意図的ミラーあり — 変える時は両方揃える・issue #54)
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

- **`label_action` の実行**(reviewer / issue-reviewer 経路のみ非 null。PR は `ready for merge`・issue は `ready for implementation` ラベルの同期。単一書込の設計上 reviewer subagent はラベルに触らせないため orchestrator が実コマンドとして持つ — PR は `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` 手順 6 と同内容・issue は `roles/issue-reviewer-dispatch.md`「ラベル操作は orchestrator 専権」が委ねる先。**この節が全 label_action トークンの唯一の執行 home であり、decision script(`scripts/decide-orchestrator-route.py`)が emit しうる非 null トークンはすべてここにレシピを持つ**(`tests/smoke/run-smoke.sh` [8] が presence を機械照合する — 執行部にレシピが無いと add-label が存在しないラベルへ実行され無音 drift する故障クラスを塞ぐ・round2 🔴1)):
  - **`add_ready_for_merge`**(PR reviewer 経路・`clean_pass`):
    - ラベル作成 fallback(冪等): `gh label create "ready for merge" --color "0e8a16" --description "reviewer が merge 可能と判定した PR" --force`
    - `gh pr edit <n> --repo <repo> --add-label "ready for merge"`(冪等)
    - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(無ければ警告のみで実害なし)
  - **`remove_ready_for_merge`**(PR reviewer 経路・`blockers`):
    - `gh pr edit <n> --repo <repo> --remove-label "ready for merge"`(付いていなければ警告のみで実害なし)
    - 旧名ラベルの掃除: `gh pr edit <n> --repo <repo> --remove-label "merge ready"`(無ければ警告のみで実害なし)
  - **`add_ready_for_implementation`**(issue-reviewer 経路・`clean_pass`・issue #88。issue の `ready for implementation` ラベルの同期。PR の `add_ready_for_merge` と対称。`ready for merge`(色 `0e8a16`)とはラベル名が異なるため read-map では色・説明を導けず、冪等 create fallback を明記する):
    - ラベル作成 fallback(冪等): `gh label create "ready for implementation" --color "1d76db" --description "issue reviewer が実装着手可能と判定した issue" --force`(色・説明は `/harness-init` の仕上げ節が作る同ラベルと**必ず揃える** — `--force` は既存の色・説明も上書きするため、片側だけ変えるともう一方の実行で旧定義へ戻り変更が定着しない。PR 側 `ready for merge` の drift 注意(`roles/pr-reviewer.md`)と同種)
    - `gh issue edit <N> --repo <repo> --add-label "ready for implementation"`(冪等。`<N>` は対象 issue 番号)
  - **`remove_ready_for_implementation`**(issue-reviewer 経路・`blockers`):
    - `gh issue edit <N> --repo <repo> --remove-label "ready for implementation"`(付いていなければ警告のみで実害なし)
  - **`null`**: ラベル操作なし。

## tick 開始時の前提整備(issue #37・選別より前)

各 tick の選別(jq)より前に、次を 1 回実行する:

1. **`git fetch origin --quiet`**: `origin/main` のリモート追跡参照を最新化する。実装役 dispatch(「developer(実装役)」節手順 2)は `creating-git-worktrees` skill 経由で worktree を作成し、同 skill は既定(`worktree.baseRef=fresh`)で `origin/<default-branch>` から新しい branch を切る。この fetch を怠ると `origin/main` のローカル参照が古いままになり、そこから分岐した worktree も古い main を基点にしてしまう(実測: PR #36 が古い main(`3b38c55`)から分岐した)。fetch は取得のみで、常時 dirty な `.harness/plan-progress.json` を含むローカル main checkout には触れない — `git pull` / `git merge` / `git checkout` は行わない。
2. **freshness の確認は報告に留め、tick を止めない**: `git rev-list --count HEAD..origin/main` 等でローカル main checkout が `origin/main` からどれだけ遅れているかを把握し、遅れがあれば tick 報告に 1 行 surface する。**tick 全体は停止させない** — F案の台帳は常時 uncommitted-dirty で main 前進のたびに hard-stop すると `/loop` 運用で頻繁に停止するため。欠落 2 の根本対処は 1. の fetch により worktree 側が常に fresh になることで足りており、ローカル main checkout 自体を前進させる必要は無い。
3. **`git worktree prune`**: `.claude/worktrees/` の admin record 残骸を掃除する(欠落 8。前 tick の異常終了等で登録だけ残った worktree を除去)。実体ディレクトリがまだ残っている場合(`git worktree remove` 前に中断した等)は各ロール節の evidence gate 手順(手順 5)が同一パスへの `add` 失敗時に個別掃除するため、ここでの `prune` は admin record のみを対象とする軽量な前提整備に留める。**⚠ 実体ディレクトリ掃除への拡張は挙動変化ありとして慎重に spec 化する(issue #54)**: `prune` を実ディレクトリ削除(`git worktree remove` / `rm -rf`)へ広げるなら、**削除対象を「merge 済み PR の worktree のみ」に限定するガードが必須**。判定根拠は `orchestrate-pr-<N>` の `<N>` を PR 番号として解決し `gh pr view <N> --json state,mergedAt` で **merged を確認できた場合に限り削除する**。**merge 済みと確定できない worktree(状態取得失敗 / open・draft / 番号を解決できない / 手動代行・別セッションが使用中の可能性)は消さない側に倒す(fail-safe)** — 進行中の worktree を消すと稼働中の作業を壊す事故になる。現状の admin record 限定は意図的にこの安全側へ倒してあり、実体掃除のコード実装自体は follow-up とする(本項目は削除条件と fail-safe を spec として固定するに留める)。

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
  - **`redispatch`**: **今 tick 内で即座には dispatch しない**。返った `retry_count` を保持したまま「実装役の再 dispatch 候補」として、下記「配車テーブル」節の**5 件上限を実装役の選別(jq)新規対象と共有する枠**へ合流させる(独自の無制限枠を持たせない)。**この 5 件枠へ入る前に、redispatch 候補も新規 eligible 候補と同じく「ファイル衝突検知 + 代表選出」ゲート(下記「ファイル衝突検知」節・issue #55)を通る** — 同一ファイルに live wait 占有者を共有する redispatch や、占有者ゼロ衝突 group で代表選出に負けた redispatch は、そのゲートで marker 非書換のまま持ち越される(5 件枠への合流は衝突フィルタ後の集合に対して行う)。この枠に収まった候補だけ、**引き継いだ `retry_count` を渡して**「developer(実装役)」手順 1 から再実行する(**marker の書込は手順 1 が単独で行う** — reconciliation 自身はここで `dispatchMarker` を書かない。手順 1 の marker 書込 `{"dispatched_tick": $TICK, "deadline_tick": $TICK + K, "retry_count": <0 か引き継いだ値>}` は新規 dispatch・redispatch のどちらでも同じ 1 箇所のみで行われ、reconciliation と手順 1 が同一 tick 内で同内容の marker を 2 回書く冗長書込を避ける)。**枠から溢れた候補は今 tick では marker を書き換えない**(`retry_count` を消費しない) — 次 tick も `current_tick > deadline_tick` が成立し続けるため、reconciliation が同じ候補として再び `redispatch` を返し、優先度が回れば後続 tick で処理される(取りこぼしではなく先送り)。
  - **`sink`**(`reason` が `retries_exhausted`(リトライ上限 N=2 到達)または `invalid_marker`(マーカーが壊れている/不整合・fail-closed)): outcome=**`timeout`** として判定器(role=implementer)を呼ぶ(`decide-orchestrator-route.py` の implementer/`timeout` 行。`ledger_write` は null — PR がまだ存在しない `ambiguous` と同型)。**`observation`(issue #50 A1)**: `timeout` も sink 系のため観測必須。`<command>`="reconcile-dispatch-marker.py の判定"・`<exit_code>`=0(script 自体は正常終了している)・`<summary>`=`$reason`(`retries_exhausted` または `invalid_marker`。「ルーティング判定」節「呼び方」の共通手続きに従う)を渡す。**この観測は新たな独立検査ではなく、`reconcile-dispatch-marker.py` が既に下した判定(有界リトライ機構そのもの)を記録するに留まる** — timeout の真偽(hang か否か)は無状態 tick では原理的に観測不能(issue #26 P1 決定)なため、A1 が timeout に対して上げるのは「sink 判断の根拠を必ず記録させる」捏造コストのみで、それ以上の独立性は持たない(正直な限界の明記)。「失敗経路(単一の need for human review sink)」の**変則**として次のとおり扱う(通常の sink 共通手続きとの差分):
    - **ラベル付与は行わない**(PR が存在しないため `gh pr edit --add-label` の対象が無い。`ambiguous` と同じ制約)。
    - `PushNotification` を行う(内容: 「issue #<N> の実装役 dispatch が締切超過でリトライ上限(N=2)に到達した」または「issue #<N> の in-flight マーカーが不整合」)。**この通知と同じタイミングで、「ルーティング判定」節の「`notified` フラグの付与」手続きを実行する**(`dispatched_tick`/`deadline_tick`/`retry_count` の既存 3 キーは変更せず `notified: true` を追加のみ。`reconcile-dispatch-marker.py` の marker 妥当性検査はこの 3 キーの存在・型しか見ないため、追加の `notified` キーは判定に影響しない)。これにより次 tick 以降は上記「`notified` 済みマーカーの早期スキップ」に該当し、この sink は tick をまたいで**一度だけ**通知される(通知の無限反復を防ぐ)。
    - **`dispatchMarker` は消さず残す**(この持続状態自体が「無条件スキップ」の実装 — 次 tick 以降は `notified: true` により復旧検索・script 呼出そのものをスキップするため、無期限の GitHub 検索の繰り返しも止まる。ラベルが無くても選別ガードは marker の存在自体で恒久的にこの step をスキップする)。
    - **人間の解除手段**: ラベル解除に相当する操作は「対象 step の `dispatchMarker` を手動で削除する」(根本原因(issue 実装不能等)を先に解消してから削除するのが通常の流れ)。orchestrator 側に自動解除ロジックは持たない(既存の「ラベルの解除は人間が手動で行う」原則と同型)。

これにより `no_pr` の連続発生(P1 決定により timeout と同じカウンタに畳み込む)も真の締切超過(hang)も、**同じ `retry_count` で最大 N=2 回(初回 + 2 リトライ = 計 3 dispatch)まで有界リトライし、尽きたら sink する**(「有界停止の保証」節の唯一の例外だった `no_pr` はこれで解消)。dispatch call 自体がセッションを止めてしまう真の hang(`Agent` ツールにタイムアウト parameter が無い制約は変わらない)は、marker が dispatch 直前に書かれているため、**人間がセッションを再起動した次の tick**で `TICK > deadline_tick` として検知される(tick を跨いだ persistent state による回復。dispatch 中の hang をリアルタイムに検知する機構ではない — 「既知の制限・拡張ポイント」節参照)。

**reviewLock の reconciliation(issue #71・`dispatchMarker` の走査と並置)**: 上の `dispatchMarker` の走査と**並置**して、`reviewLock` を持つ全 step も各 tick(選別より前)に reconcile する。目的は reviewer / 対応役の dispatch が真の hang(dispatch call がセッションを止めた)で `reviewLock` が解除されないまま次 tick 以降まで残った場合に、有界に sink へ落とすこと。`dispatchMarker` と同じ `reconcile-dispatch-marker.py`(**ロール非依存**)を使い、次の 2 点だけを変える:

- **`progressed` は常に false**: reviewLock には実装役の `Closes #<N>` 復旧検索に相当する跨 tick 進捗シグナルが構造的に無く、残留 = hang である以上「前進したか」を確定する手段が無いため、保守側に倒して常に false を渡す(`clear` へは決して解決しない)。
- **`max_retries: 0` を渡す**(N=0)。reviewLock の締切は `K_review=0`(`deadline_tick == dispatched_tick`。「reviewer / 対応役の in-flight ロック」節)なので、正常時に同一 tick 内で削除された reviewLock は reconciliation の走査に乗らない。次 tick 以降まで残った reviewLock は `current_tick > deadline_tick` で締切超過と判定され、`max_retries: 0` により **redispatch を経ず初回で即 `sink`(`retries_exhausted`)** に落ちる(redispatch を持たせないのは、対応役の再 dispatch が修正の二重適用になりうるため — 冪等性を別機構で担保せず設計で回避する)。

**`notified` 済みの早期スキップ**: `reviewLock.notified == true` の step は、`dispatchMarker` の「`notified` 済みマーカーの早期スキップ」と同型に、reconcile 呼出そのものをスキップする(この step は既に下記 sink を通過済みで、選別 jq からも `reviewLock` の存在自体で除外されている — 再判定は重複通知を生むだけ)。`notified` が無い(または false の)step だけ、以下を行う:

```
ROUTE_MARKER=$(printf '{"marker":<reviewLock か null>,"current_tick":%d,"progressed":false,"max_retries":0}' "$TICK" \
  | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/reconcile-dispatch-marker.py")
```
返る `action` は実質 `wait` か `sink` のいずれか(`eligible` は reviewLock 不在時のみ・`clear`/`redispatch` は上記のとおり構造的に発生しない):

- **`wait`**(締切未到達 = `K_review=0` では通常起こらない): 何もしない(reviewLock を残す。選別 jq は `.reviewLock == null` で既に除外している)。
- **`sink`**(`retries_exhausted` または `invalid_marker`(fail-closed)): 対象 step の `pr.status` から役割を解決し(`completed review` → **responder**、`created pr` / `waiting for review` → **reviewer**。dispatch が hang したなら status は dispatch 前の値のまま変化していない)、outcome=**`timeout`** として判定器を呼ぶ(`decide-orchestrator-route.py` の reviewer/`timeout` または responder/`timeout` 行。いずれも `ledger_write=null`(hang は無状態 tick では検証不能なので status を捏造しない)・`route=sink`)。**`observation`(issue #50 A1)**: `<command>`="reconcile-dispatch-marker.py の判定(reviewLock)"・`<exit_code>`=0・`<summary>`=`$reason`(`retries_exhausted` または `invalid_marker`。「ルーティング判定」節「呼び方」の共通手続きに従う)。**sink の出口**は、実装役 `timeout`(PR 不在でラベル付与しない変則)とは異なり **PR が実在するため「sink の共通手続き」をそのまま実行し `need for human review` ラベル + `PushNotification` を出す**。ただし `dispatchMarker` の timeout sink と同型に、**`reviewLock` は削除せず残したまま `notified: true` を付与する**(「ルーティング判定」節『`notified` フラグの付与』の手続きを、`dispatchMarker` の代わりに `reviewLock` に対して行う — 既存 3 キーは変更せず `notified` を追加。reviewLock を削除すると `.reviewLock == null` ガードで次 tick に再選別=再 dispatch されるため、削除してはならない)。人間の復旧手段は `need for human review` ラベル除去 + 対象 step の `reviewLock` 手動削除の 2 つ。

**走査の独立性**: 1 step が `dispatchMarker` と `reviewLock` を同時に持つ場合、reconciliation は各フィールドを**独立に**走査する(dispatchMarker は N=2・redispatch あり、reviewLock は N=0・即 sink)。通常は実装役 dispatch と reviewer/対応役 dispatch はライフサイクル上の別フェーズで、1 step が両方を同時に持つことは無い。

**issueReviewLock の reconciliation(issue #88・`reviewLock` の issue 版)**: 上の 2 走査と**並置**して、`issueReviewLock` を持つ全 step も各 tick(選別より前)に reconcile する。目的は issue reviewer / issue review worker の dispatch が真の hang で `issueReviewLock` が解除されないまま残った場合に、有界に sink へ落とすこと。`reviewLock` の reconciliation と**同一**で(`reconcile-dispatch-marker.py` をロール非依存に流用・`progressed: false`・`max_retries: 0`)、変えるのは **sink 時の役割解決を `pr.status` ではなく `issue.status` から引く**点だけ:

```
ROUTE_MARKER=$(printf '{"marker":<issueReviewLock か null>,"current_tick":%d,"progressed":false,"max_retries":0}' "$TICK" \
  | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/reconcile-dispatch-marker.py")
```

- **`notified` 済みの早期スキップ**: `issueReviewLock.notified == true` の step は reconcile 呼出そのものをスキップする(reviewLock と同型)。
- **`sink`**(`retries_exhausted` または `invalid_marker`): 対象 step の `issue.status` から役割を解決し(`created issue` / `waiting for review` → **issue-reviewer**、`completed review` → **issue-review-worker**。dispatch が hang したなら status は dispatch 前の値のまま変化していない)、outcome=**`timeout`** として判定器を呼ぶ(`decide-orchestrator-route.py` の issue-reviewer/`timeout` または issue-review-worker/`timeout` 行。いずれも `ledger_write=null`・`route=sink`)。**`observation`(issue #50 A1)**: `<command>`="reconcile-dispatch-marker.py の判定(issueReviewLock)"・`<exit_code>`=0・`<summary>`=`$reason`。**sink の出口**は「sink の共通手続き」+「issue フェーズの sink の差分」(ラベルは **issue に** 付与)を実行し、**`issueReviewLock` は削除せず残したまま `notified: true` を付与する**(「ルーティング判定」節『`notified` フラグの付与』を `issueReviewLock` に対して行う。削除すると `.issueReviewLock == null` ガードで次 tick に再選別=再 dispatch されるため削除してはならない)。人間の復旧手段は `need for human review` ラベル除去 + 対象 step の `issueReviewLock` 手動削除の 2 つ。

`reviewLock`(`pr.status` 由来)と `issueReviewLock`(`issue.status` 由来)を別フィールドにするのは、issue フェーズには `pr.status` が無く reviewLock の役割解決(`completed review`→responder 等)が壊れるため(round1 🟡3 決定)。issue と PR はライフサイクル上分離するので時間的衝突は無いが、役割解決の結合を避けるため別フィールドに保つ。

## reviewer / 対応役の in-flight ロック(issue #37、issue #71 で締切機構を追加)

**目的**: pr reviewer / developer(対応役)の dispatch にも、実装役の `dispatchMarker`(issue #26)と同じ「重複配車防止」が要る(欠落 1)。加えて、dispatch call 自体がセッションを止める**真の hang** で `reviewLock` が解除されないまま残るケースを、有界に sink へ落とす締切機構を持たせる(issue #71。issue #37 時点ではこの残留を検知する主体が無く、人間が手動削除するまで永久に選別から外れたままだった)。ただし reviewLock は実装役の `dispatchMarker`(N=2・締切超過で redispatch)とは**プロファイルが異なる** — reviewer/対応役の dispatch は `Agent` ツールの blocking call として**同一 tick 内で outcome まで解決**し、正常時は同じ tick 内で reviewLock を削除するため、`no_pr` 相当の無界駆動因は無い。したがって締切は `K_review=0`(下記)、リトライは **N=0(redispatch なし・初回の締切超過で即 sink)** とする。**対応役の再 dispatch は修正の二重適用**になりうるため redispatch 経路を持たせず、冪等性を別機構で担保せず設計で回避する(#37 節が述べた「独立 timeout/retry 機構の追加は over-engineering」とも整合 — 実装役の締切機構 `reconcile-dispatch-marker.py` を**ロール非依存**に流用し、`max_retries: 0` を渡すだけで実現する)。

**`reviewLock`(transient・型の正は `plan-progress.schema.json` の `definitions.reviewLock`。issue #68 で optional 宣言・issue #71 で `dispatchMarker` 同型へ拡張・検査対象外は維持)**: pr reviewer / developer(対応役)が dispatch する直前に、対象 step へ次を書く(実装役の `dispatchMarker` とは**別フィールド**で持つ — 「tick 冒頭 reconciliation」節の reconciliation は両フィールドを**独立に**走査する。同一フィールドを共有すると、dispatchMarker 用の N=2・redispatch プロファイルと reviewLock 用の N=0・即 sink プロファイルが混ざり、対応役の二重 dispatch を招くため別フィールドに保つ):
```json
{"dispatched_tick": <TICK>, "deadline_tick": <TICK>, "retry_count": 0}
```
`deadline_tick = dispatched_tick + K_review`(**`K_review = 0`** のため通常 `dispatched_tick` と一致・下記)、`retry_count` は初回 0 固定(reviewLock は N=0 で redispatch しないため常に 0)。`$TICK` は「tick 冒頭 reconciliation」節の `orchestratorTick` を共有する。書込は次の 1 手続きで行う(`<step id>` は対象 step):
```
PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
python3 - "$PLAN" "<step id>" "$TICK" <<'PY'
import datetime, json, os, sys
plan_path, step_id, tick = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(plan_path, encoding="utf-8") as f:
    plan = json.load(f)
step = next(s for s in plan["steps"] if s["id"] == step_id)
# K_review=0 のため deadline_tick == dispatched_tick、retry_count は初回 0 固定 (N=0・issue #71)
step["reviewLock"] = {"dispatched_tick": tick, "deadline_tick": tick, "retry_count": 0}
plan["updatedAt"] = datetime.date.today().isoformat()
with open(plan_path + ".tmp", "w", encoding="utf-8") as f:
    json.dump(plan, f, ensure_ascii=False, indent=2)
os.replace(plan_path + ".tmp", plan_path)
PY
```

**`K_review = 0`(tick)と定義する**: reviewer/対応役の dispatch は同一 tick 内で outcome まで解決し、正常時は reviewLock を書いた同じ tick 内で削除される(下記「解除」)。したがって reviewLock が次 tick 以降まで残ること自体が「dispatch 中にセッションが死んだ(真の hang)」の定義的シグナルであり、`dispatched_tick` より後の tick で reviewLock を観測した時点で sink してよい。`K_review=0` は **mode 非依存の構造的確定値**である — multi-angle の内部 fan-out は単一 blocking call の**内部(同一 tick 内)**で起きるため tick 単位の締切 K には影響しない(code-review モード対 multi-angle モードの所要差は wall-clock 差であり tick 数差ではない)。dispatchMarker の `K=2`(校正根拠なし best-effort)とは対照的に、reviewLock の `K=0` は同一 tick 解決という構造的事実から導かれるため校正不要。締切超過の判定と sink 手続きは「tick 冒頭 reconciliation」節の**「reviewLock の reconciliation」**が担う(ここでは書込のみ・複製しない)。

**選別ガード**: 「選別(jq)」節の対応役・pr reviewer ブロックに `.reviewLock == null` を追加し、既に in-flight な step を選別から除外する(実装役の `.dispatchMarker == null` ガードと同型)。

**解除(必ず同一 tick 内・全 outcome で)**: pr reviewer / 対応役はどちらも dispatch が同一 tick 内で outcome まで同期完結するため、判定器呼出後の原子書込(「ルーティング判定」節『`ledger_write` の適用』)で **全 outcome について** `reviewLock` を削除する(route が normal/sink いずれでも、`ledger_write` が null の outcome(reviewer/`invalid`・対応役/`evidence_fail`)でも解除する — 解除しないと次 tick 以降この step が永久に選別から外れたままになる)。適用手続きは既存の `<clear_marker>` 引数に加え、削除対象のフィールド名を汎化した `<marker_field>`(省略時の既定 `dispatchMarker`)を渡す — 実装役の既存呼出は省略のまま(挙動不変)、pr reviewer / 対応役は `"reviewLock"` を渡す。詳細は「ルーティング判定」節『`ledger_write` の適用』を参照(手続き本体はそちらが正・ここでは複製しない)。

**hang 検知の到達点(issue #71 で締切機構を追加)**: dispatch call 自体がセッションを止める真の hang が起きた場合、`reviewLock` は書かれたまま残るが、**「tick 冒頭 reconciliation」節の「reviewLock の reconciliation」(`max_retries: 0`・`progressed: false`)が次 tick 以降にこれを締切超過(`current_tick > deadline_tick`)として検知し、初回で即 `sink`(reviewer/`timeout` または responder/`timeout`)に落とす**。これは issue #26 の実装役 hang 検知と同型の「tick を跨いだ persistent state による事後回復」であり、dispatch 中の hang をリアルタイムに検知する機構ではない(`Agent` ツールにタイムアウト parameter が無い制約は変わらない)。sink 到達時は `need for human review` ラベル付与(reviewer/対応役は PR が実在するため実装役 `timeout` の変則(ラベル無し)とは異なる)+ `reviewLock` 残置 + `notified: true` 付与で以後の tick を早期スキップさせる(重複通知防止)。人間の復旧手段は `need for human review` ラベル除去 + 対象 step の `reviewLock` 手動削除の 2 つ。issue #37 が「follow-up で issue #26 の reconciliation をロール非依存・deadline 任意へ一般化する」と留保していた対応が、本 issue #71 で実現された(`reconcile-dispatch-marker.py` は元からロール非依存で、`max_retries` の任意入力化だけで reviewLock の N=0 プロファイルを賄えたため、role 分岐の追加は不要だった)。

## issue reviewer / issue review worker の in-flight ロック(issue #88)

**目的**: issue フェーズ dispatch にも PR フェーズと同じ重複配車防止 + hang 検知を配線する。PR フェーズは `reviewLock` **単独**でこの両方を担う — dispatch 前に `reviewLock` **だけ**を書き `pr.status` は書き換えず(選別 jq の `.reviewLock == null` ガードが dedup、reconciliation が hang 検知)。issue フェーズも対称に、`issueReviewLock`(reviewLock の issue 版)**単独**で両方を担わせる。**dispatch 前に `issue.status` を書き換えてはならない(round1 🔴1・🔴2)** — status を書き換えると「dispatch が hang したなら status は dispatch 前の値のまま」という reconciliation の役割解決の前提(上記「issueReviewLock の reconciliation」の役割解決マップが依存する不変条件)が壊れる。`issueReviewLock` が既に dedup を担うため、in-flight status マーカー(`starting review` / `starting review work`)の追加書込は**冗長かつ有害**であり、書かない(PR フェーズが dispatch 前に `pr.status` を書かないのと対称)。

**`issueReviewLock`(重複配車防止 + hang 検知・transient・型の正は `plan-progress.schema.json` の `definitions.issueReviewLock`)**: issue reviewer / issue review worker が dispatch する直前に、対象 step へ `reviewLock` と同型に書く(`K_review = 0`・`retry_count = 0` 固定)。`reviewLock` とは**別フィールド**で持つ(役割解決を `issue.status` から引くため — 上記「issueReviewLock の reconciliation」)。書込手続きは reviewLock の書込(「reviewer / 対応役の in-flight ロック」節)と同一で、フィールド名を `issueReviewLock` に変えるだけ:
```
step["issueReviewLock"] = {"dispatched_tick": tick, "deadline_tick": tick, "retry_count": 0}
```
**選別ガード**: 「選別(jq)」節の issue reviewer / issue review worker ブロックに `.issueReviewLock == null` を追加し、既に in-flight な step を選別から除外する(実装役の `.dispatchMarker == null`・対応役の `.reviewLock == null` ガードと同型)。**dispatch 前に `issue.status` を書き換えないため、hang しても status は dispatch 前の値のまま**であり、「issueReviewLock の reconciliation」の役割解決マップ({`created issue` / `waiting for review` → issue-reviewer, `completed review` → issue-review-worker})が sink 時に正しく役割を解決できる(PR reviewLock reconciliation が `pr.status` から役割解決するのと対称。もし dispatch 前に `starting review` 系へ書き換えると、hang 残留時に status がマップに無い値になり役割解決が undefined になる — これが round1 🔴1 の根因だった)。

**解除(必ず同一 tick 内・全 outcome で)**: issue reviewer / issue review worker はどちらも dispatch が同一 tick 内で outcome まで同期完結するため、判定器呼出後の原子書込で **全 outcome について** `issueReviewLock` を削除する(`ledger_write` が null の outcome(issue-reviewer/`invalid`)でも解除する)。適用は「ルーティング判定」節『`ledger_write` の適用』の `<marker_field>` に `"issueReviewLock"` を渡す(手続き本体はそちらが正・ここでは複製しない)。ただし `timeout`(hang)は上記 reconciliation が `issueReviewLock` を残置 + `notified` 付与する変則で、この解除経路は通らない。

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

## discover→enqueue フェーズ(issue #78・#21 能力3 v1=A)

**目的**: 「人間が台帳に step を足す」を「機械が発見して enqueue する」に置き換える(#21 能力3・オーナーが 2026-07-21 に v1=A を明示承認)。v1 の射程は **明示 opt-in ラベル方式(A)= enqueue の自動化**に限る — 発見源はラベル付き open issue のみで、真の discover 自動化(B: CI 失敗 / doc 乖離 / 監査 → 自動起票。LLM を伴う)は **Phase 3 epic #85 傘下の #102 へ切り出し済み**で本フェーズでは扱わない。

**起動点(round2 🔴1)= tick-prep 領域の別レーン**。実行順は **「tick 冒頭 reconciliation」(全マーカーの reconcile 完了)の後・下記「配車テーブル」の選別(jq)の前**。これは step 駆動の配車テーブルとは**別レーン**であり、配車テーブルは従来どおり `issue.status` を読むだけで変えない(下記「配車テーブル」節末尾の (1) 不変)。discover が選別の**上流**で step を作るため、生成した step(`issue.status="created issue"`)は**同一 tick の選別(jq)から見える**ようになり、鶏卵問題(step を*作る* discover を step 駆動テーブルで選別できない)は配置で構造的に解消する — 配車テーブルが「step を作る step」を選ぶ必要がそもそも無い。enqueue された step は同一 tick の issue reviewer 選別に乗るが、1 tick 5 件上限を全カテゴリと共有し(issue reviewer は最低優先)、溢れれば次 tick へ持ち越す(step は台帳に残るため取りこぼしではない)。

**主体(round2 🔴2)= 純関数 script + bounded label クエリ(LLM subagent ではない)**。v1=A は B(LLM を伴う自動起票)を #102 へ切り出し済みのため discover に LLM 判断が構造的に無く、「発見役」独立 subagent・dispatch prompt・`issueReviewLock` 同型の in-flight ロックは**不要**(discover は subagent dispatch ではなく tick 内の同期 script 呼出)。構成は 3 層:

1. **network discover(orchestrator の I/O・散文・smoke 対象外=手動確認)**: 次を 1 回実行し、opt-in ラベル `discover` が付いた open issue の候補を、**epic 判定材料(epic ラベル / `epic:` prefix)を添えた `{number, isEpic}` オブジェクト配列**として得る(epic 除外 fail-safe の入力・issue #107・D1):
   ```
   gh issue list --repo <owner/repo> --label discover --state open --json number,labels,title \
     --jq '[.[] | {number, isEpic: ((.labels | map(.name) | index("epic") != null) or (.title | test("^epic(\\(.*\\))?!?:")))}]'
   ```
   - **epic 判定は 2 シグナルの OR(round2 🟢3)**: `epic` **ラベル**を持つ、または **タイトルが `epic` prefix**(Conventional Commits 形 `epic:` / `epic(scope):` / `epic!:`)で始まる、のいずれかで `isEpic=true`。**ラベル単一シグナルだと `epic` ラベルの無い prefix-only epic を取りこぼす**ため、`--json` に `title` を含めて prefix も判定する(層意味論の正は `rules/issue-tree.md` §1-§2)。判定を epic 側へ寄せる fail-safe なので、稀な誤判定は「除外側に倒れる」= 安全側。
   - **クエリ失敗時は fail-soft(round3 🟡 L6)**: このクエリ自体が失敗(network 断 / auth 失効 / rate limit)したら、**その tick の discover は no-op で続行し、失敗を tick 報告に 1 行 surface する**(tick 全体は止めない)。これは「tick 開始時の前提整備」節の `git fetch`(「失敗は報告に留め tick を止めない」)と**同型の受容**。空結果(候補 0 件・クエリ成功)の no-op とは**別の失敗モード**であることに注意 — 空結果は下記 script に `candidates: []` として渡り no-op になるが、クエリ失敗はそもそも script に入力すら渡さず、この分岐で no-op に倒す。network 層のため smoke 対象外(手動確認境界)だが、fail-soft を実装裁量に落とさず本行で明記する。
2. **純 enqueue/dedup/epic 除外(script・smoke 対象)**: 得た候補オブジェクト配列と現台帳 steps を `scripts/decide-enqueue-steps.py` へ渡し、追加すべき step 群を得る(既存 `reconcile-dispatch-marker.py` / `decide-orchestrator-route.py` と同型の pure decision script・stdin JSON → stdout・network 非依存・決定論):
   ```
   PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
   ENQUEUE=$(jq -cn --argjson cand "<候補オブジェクト配列(上記 discover の出力・{number,isEpic})>" --slurpfile plan "$PLAN" \
     '{candidates: $cand, steps: $plan[0].steps}' \
     | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/decide-enqueue-steps.py")
   # -> {"enqueue": [<追加 step>, ...]}   (空配列 = no-op)
   ```
   入出力契約 = `{候補 (裸 int | {number, isEpic, ...}) リスト, 現台帳 steps} → {追加 step 群 / no-op}`。この script が **epic 除外 fail-safe(`isEpic:true` の候補を dedup/採番の前段で決定論的に drop・id 番号を消費しない・issue #107・D1。epic は最下層の実装単位でなく PR で close できないため、誤って `discover` ラベルが付いても台帳 step 化しない)/ dedup(dedup key=`issue.number` 一致・突合範囲=全 step(終端 `closed issue` / `merged pr` を含む)・終端後の再ラベル=no-op・round1 🔴2)/ batch 採番(同一 tick で複数候補を enqueue する際は max+1, max+2, … と逐次加算・round2 🟡2。固定値 DoD「1 件追加」は単一対象 happy-path として不変)/ step 雛形生成(`id`=既存台帳の形式に追随した max+1 の string(`P<n>` 台帳なら `P<max+1>`・純数値台帳なら `<max+1>`・issue #78 round1 🔴) / `issue={number:<N>, status:"created issue", githubState:"open"}` / `pr={number:null,...}` / `dependsOn` 省略・round1 🟡1)** をすべて決定論的に担う。空入力(候補 0 件)= no-op(round1 🟡2)。**候補要素は後方互換で裸の `issue.number`(int)も受理する**が、epic 除外を効かせるには上記のとおり `{number, isEpic}` を渡す(裸 int は `isEpic=false` 扱い = 除外しない)。**下流 #111 との共有契約**: 同じ `candidates` 要素へ #111 が `dependsOn`(`Depends-on: #N` の parse 結果)を後から追加する予定で、script は dict の**未知キーを無視する**ため #107 の `{number, isEpic}` を壊さず載る(着地順 = #107 先行 → #111 追随・round2 🟡1)。
3. **台帳書込(orchestrator・単一 writer)**: orchestrator が script の返す `enqueue` 配列の各 step を**台帳の `steps` へ append する**(発見役は候補報告のみ・enqueue の台帳書込は orchestrator tick に集約する単一 writer 不変条件・round1 🔴3。discover subagent が直接台帳を書く経路は禁止)。append はローカル台帳の直接編集(F案・`git add`/`commit` はしない)。`enqueue` が空なら書込なし(no-op)。書込後、追加 step は同一 tick の選別(jq)から見える。

**opt-in ラベル `discover` の provisioning(round1 🟢2 / round2 🟢)**: このラベルは `commands/harness-init.md` 手順 5 の `gh label create --force` 対象に含める(導入先 repo での移植性のため人作業にしない)。**`discover` ラベルは人間が issue に付ける*入力*ラベル**であり、orchestrator が付与/除去する status ラベル(`need for human review` / `ready for implementation` 等)とは別種のため、**「label_action の実行」節への create fallback は不要**(orchestrator は `discover` ラベルの存在だけを要求し付与/除去はしないので、label_action の同期対象は増えない)。

**tree 規約への参照(issue #109)**: 発見される issue の層・帰属・prefix 意味論は kit の `${CLAUDE_PLUGIN_ROOT}/rules/issue-tree.md`(role 横断の tree 文法)が定義する。discover→enqueue はこの文法の消費者の 1 つ(round1 🔴1(b) の 4 消費者)。**epic を実装 step として enqueue しない epic 除外 fail-safe**(構造層 = `epic` prefix / `epic` ラベルの issue は最下層の実装単位ではない・`rules/issue-tree.md` §1-§2)は **issue #107 が所有し実装済み**(所有権を #107 に一意確定・D1。旧記述「本 v1 のスコープ外(#107 / #78 follow-up 側の論点)」が #107 と相互に送り返していた**循環参照を解消**した)。実装位置は上記 2. の script 側(`decide-enqueue-steps.py` が `isEpic:true` を決定論的に drop・smoke 閉ループ)で、判定材料(epic ラベル / `epic:` prefix)の取得は上記 1. の network prose が担う。文法の正は `rules/issue-tree.md` 側に一元化する(discover 側で層意味論を再定義しない)。

**「配車テーブル」節末尾との関係 = 狭い supersede(round2 🔴3)**: 下記「配車テーブル」節末尾は 2 つを主張する — (1) 配車テーブルの issue サイド選別は台帳 `issue.status` を読むだけ、(2) 追加の GitHub ポーリングは実装しない。**(1) は不変**(discover フェーズは選別の上流の別レーンで、配車テーブル自体は従来どおり `issue.status` のみ読む)。#78 が supersede するのは **(2) のみ・かつ discover フェーズについてのみ**であり、これは #78 の承認済みの目的(「機械が発見して enqueue する」)の直接の帰結で新規のアーキ判断ではない。**頻度・コストの有界性**: discover は毎 tick 1 回の bounded な `gh issue list`(候補 number のみ返す 1 往復)。これは (a) tick-prep の毎 tick `git fetch origin --quiet`、(b) #11 の `--drift` 頻度増、と同型の**受容されたコスト**。間引き(N tick に 1 回)は follow-up の最適化で v1 要件ではない(v1 は git-fetch と同じ毎 tick で回す)。

**テスト境界(round2 🟡1)**: network discover(label クエリ + epic 判定材料の取得・上記 1.)は smoke 対象外=手動の最小動作確認。純 enqueue/dedup/epic 除外 script(上記 2.)は smoke 対象で、`tests/smoke/run-smoke.sh` が既存の pure decision script([7]/[8]/[9])と同型に決定論検証する(dedup / batch 採番 / 空入力 / 終端突合 / step 雛形 / **epic 除外(`isEpic:true` を drop・id 番号を消費しない)/ 拡張 candidate 契約(裸 int | {number,isEpic,...} の受理・未知キー無視)** の境界 + 不正入力 exit 2)。**epic 除外が閉ループ(fail-safe が決定論テストに乗る)**なのは判定 drop を script 側に置いたためで、prose 側(epic 判定材料の取得)は smoke 対象外に残る(round2 🟢3 の受容境界)。

## 配車テーブル(PR ライフサイクル + issue フェーズ・issue #88)

**`need for human review` ラベル付きの PR は無条件でスキップする**(ラベルの有無は各対象 step ごとに `gh pr view <n> --json labels` で確認)。**1 tick あたりの dispatch 上限は 5 件**(`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` の暴走防止パターンを踏襲)。**この上限は「tick 冒頭 reconciliation」の `redispatch` 候補も含めた合計に適用する**(redispatch だけを上限の外に置くと、複数 step が同時に締切超過した場合に 1 tick で 5 件を大きく超える dispatch が起こりうるため。詳細は下記「選別(jq)」節参照)。

| 条件 | dispatch するロール | orchestrator が行うこと |
|---|---|---|
| `issue.status == "ready for implementation"` かつ `pr.number == null` かつ **in-flight マーカー無し(`wait` 対象外)** | developer(実装役) | tick 冒頭 reconciliation → (marker 無し/`redispatch`) → **ファイル衝突検知 + 代表選出(wait 占有者 inject・1 group から高々 1 件・下記)** → dispatch → 返答検証(復旧検索)→ evidence gate → outcome 解決 → 判定器 → git status ガード → route 実行(normal/skip/sink/timeout→sink) |
| `pr.status == "completed review"` かつ **`reviewLock` 無し** | developer(対応役) | `reviewLock` 書込 → dispatch → 返答検証 → evidence gate → outcome 解決 → 判定器 → git status ガード → route 実行(normal/sink)→ `reviewLock` 解除 |
| `pr.status in ("created pr", "waiting for review")` かつ **`reviewLock` 無し** | pr reviewer | `reviewLock` 書込 → dispatch → 返答から outcome 解決(`invalid`/`escalate`/`clean_pass`/`blockers`/`subjective_escalate`)→ 判定器 → route + label_action 実行 → `reviewLock` 解除 |
| `issue.status in ("created issue", "waiting for review")` かつ **`issueReviewLock` 無し**(issue #88) | issue reviewer | `issueReviewLock` 書込(`issue.status` は書き換えない・round1 🔴1/🔴2)→ dispatch → 返答から outcome 解決(`invalid`/`escalate`/`clean_pass`/`blockers`/`subjective_escalate`)→ 判定器 → route + label_action 実行 → `issueReviewLock` 解除 |
| `issue.status == "completed review"` かつ **`issueReviewLock` 無し**(issue #88) | issue review worker | `issueReviewLock` 書込(`issue.status` は書き換えない・round1 🔴1/🔴2)→ dispatch → 返答から outcome 解決(`done`/`subjective_escalate`)→ 判定器 → route 実行 → `issueReviewLock` 解除 |
| `issue.status == "ready for implementation"`(issue reviewer の天井) | なし(PR フェーズへ) | issue フェーズ側では dispatch しない(実装役は PR フェーズの配車が拾う) |
| `pr.status == "ready for merge"` | なし | dispatch しない(終端は人間の専権) |
| `pr.status in ("merged pr")` / issue 終端(`closed issue`) | なし | 何もしない |
| `issue.status == "need for human review"` / `pr.status == "need for human review"` | なし | dispatch しない(sink・人間の判断待ち) |

**注**: 終端は人間の専権だが、人間の明示指示がある場合のエージェントによる代行は例外として認められる — 詳細は `.harness/CLAUDE.harness.md`『終端の記録と merge 代行』節を参照。`reviewLock` の書込・解除の詳細は「reviewer / 対応役の in-flight ロック」節を参照。

issue サイドの走査は台帳の `issue.status` を読むだけ(追加の GitHub ポーリングは実装しない)。**(#78)** 上記「discover→enqueue フェーズ」がこの主張の **(2)「追加の GitHub ポーリングは実装しない」を、discover フェーズに限って狭く supersede する**(毎 tick 1 回の bounded な `gh issue list --label discover`。git fetch / `--drift` と同型の受容コスト)。**(1)「配車テーブルの選別は `issue.status` を読むだけ」は不変** — discover は選別の上流の別レーンで、配車テーブル自体は追加ポーリングしない。

### 選別(jq)

```
PLAN="$(git rev-parse --show-toplevel)/.harness/plan-progress.json"
REVIEW_MODE="${2:-code-review}"
# issue reviewer 判定モード(issue #93): 既定 spec=kit 同梱 判定 spec (roles/issue-reviewer.md) を Read して実行 / opt-in skill=個人 skill reviewing-github-issues へ委譲。PR 側 $REVIEW_MODE (code-review/multi-angle) と対称だが、既定語が食い違う(PR は code-review・issue は spec)ため literal 共有せず別変数を新設する(round2 🟡 L6/L7)。orchestrator の起動環境から受け取り、未指定なら kit 既定 spec に倒す。
ISSUE_REVIEW_MODE="${ISSUE_REVIEW_MODE:-spec}"

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

# issue reviewer dispatch 対象(issue #88: `.issueReviewLock == null` で in-flight を除外。
# dedup は `.issueReviewLock == null` ガード単独が担う(PR フェーズの `.reviewLock == null` と対称。
# dispatch 前に `issue.status` を書き換えないため in-flight status マーカーは無い・round1 🔴1/🔴2)。
# `.issue.number != null and .issue.githubState == "open"` ガード(round1 🔴3)は PR 側
# (`.pr.number != null and .pr.githubState == "open"`)と対称 — GitHub 上で close 済みの issue へ
# 台帳の遅延で誤 dispatch するのを防ぐ。`.pr.number == null` の cross-phase 相互排他ガード
# (round2 🟡3)は実装役選別(下記 `.pr.number == null`)と対称 — 台帳 drift 時(手動編集 / PR 実在中の
# issue 再オープン再レビュー / 部分書込)に issue reviewer と pr reviewer が同一 step へ二重 dispatch
# するのを防ぐ defense-in-depth(happy path では issue.status は PR 作成前に ready for implementation へ
# 抜けるため到達不能・正常系の正しさには影響しない)。dependsOn ガード(issue #51・round1 🟡5)も適用する)
jq -c '
  ( [ .steps[] | select(.issue.status == "closed issue") | .id ] ) as $terminal
  | [ .steps[]
      | select(.issue.number != null and .issue.githubState == "open")
      | select((.issue.status == "created issue" or .issue.status == "waiting for review") and .issueReviewLock == null and .pr.number == null)
      | select((.dependsOn // []) | all(. as $d | $terminal | index($d) != null))
      | {id, number: .issue.number} ]
' "$PLAN"

# issue review worker dispatch 対象(issue #88: 同じく `.issueReviewLock == null` で除外。
# `.issue.number != null and .issue.githubState == "open"` ガード(round1 🔴3)も PR 側と対称に課す。
# `.pr.number == null` の cross-phase 相互排他ガード(round2 🟡3)も issue reviewer と同型に課す
# (実装役選別 `.pr.number == null` と対称・二重 dispatch 防止の defense-in-depth))
jq -c '
  ( [ .steps[] | select(.issue.status == "closed issue") | .id ] ) as $terminal
  | [ .steps[]
      | select(.issue.number != null and .issue.githubState == "open")
      | select(.issue.status == "completed review" and .issueReviewLock == null and .pr.number == null)
      | select((.dependsOn // []) | all(. as $d | $terminal | index($d) != null))
      | {id, number: .issue.number} ]
' "$PLAN"
```

**実装役カテゴリの候補集合は、上記 jq が返す新規 eligible 対象と、「tick 冒頭 reconciliation」節が返す `redispatch` 候補(既存 in-flight step の再試行)を合算したもの**とする(dependsOn ガード(issue #51)は上記 jq 自身が新規 eligible 対象に既に適用済み — 依存未解決の候補はここに含まれない。`redispatch` 候補は元々 eligible 判定を経て dispatch 済みだった step の再試行であり、dependsOn ガードを再適用しない)。

**ファイル衝突検知(issue #37・欠落 3。issue #55 で恒久衝突ペアの直列化を追加)**: dependsOn ガードとは直交する 2 段目のフィルタ(依存順序ではなくファイル単位の衝突を見る)。

**入力母集団(issue #55・round2/round3 で確定)**: 衝突判定へ渡すのは次の 3 種の和集合とする(既存の marker / reconciliation 機構を再利用し独立実装しない):
- **新規 eligible 候補**(上記選別(jq)が返す `dispatchMarker == null` の実装役対象)
- **redispatch 候補**(reconciliation action == `redispatch` = 締切超過・再試行。marker 保持。「tick 冒頭 reconciliation」節が返す)
- **wait 占有者**(reconciliation action == `wait` = `dispatchMarker != null` かつ `pr.number == null` かつ `current_tick <= deadline_tick`・締切未到達 = 真に in-flight の step)を **inject する**

wait 占有者と redispatch 候補は `reconcile-dispatch-marker.py` の `current_tick > deadline_tick` 分岐でのみ割れる(両者とも `marker != null ∧ pr.number == null` を満たすため締切でしか区別できない・round2 🔴1)。**dispatch 対象候補は「新規 eligible ∪ redispatch」**であり、**wait 占有者は inject 専用で dispatch 対象ではない**(選別 jq の `.dispatchMarker == null` ガード + reconciliation の `wait` で今 tick の選別から既に除外済み)— 「1 件目が in-flight の間、同一ファイルを触る 2 件目を出さない」を成立させるためだけに files ごと衝突判定へ注入する。

各候補(wait 占有者を含む)の対象ファイルは、その step の対象 issue の Implementation Scope から**同じ抽出規則で**抽出する(バッククォートで囲まれたファイルパスのみを対象ファイルとして収集し、地の文中の通りすがり言及(例:「`decide-orchestrator-route.py` と同型」)は除外する — この抽出規則自体は script が判定しないため prose 側の責務。Implementation Scope の記載が無い/抽出 0 件なら `files: []` とする)。集めた `[{id, files}]` を `scripts/detect-dispatch-collision.py` へ渡す。**script は pure な Union-Find grouping に徹し(占有者除外・代表選出は行わない)、`[{id, files}]` → `{groups, safe}` の連結成分分割だけを返す**(占有者判定は台帳 state(`dispatchMarker`/`pr.number`)を要するため下記 prose 側の責務・🟡4 決定。issue #55 で script は不変):
```
COLLISION=$(printf '%s' "$CANDIDATES_JSON" | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/detect-dispatch-collision.py")
# -> {"groups": [["<id>", ...], ...], "safe": ["<id>", ...]}
```
**代表選出述語(issue #55・round3 で規則X/Y を一本化。issue #87 で decision script へ抽出)**: `detect-dispatch-collision.py` が返す `groups` / `safe` の**下流**で、**各候補の kind を prose 側で解決**したうえで `scripts/select-dispatch-representatives.py` へ渡し、返る `dispatch` 集合を今 tick の実装役枠の dispatch 対象とする。**代表選出規則の適用は script が唯一の正**(既存 decision script と同じ設計境界 —「状況を kind トークンへ解決するのは prose / 規則の適用は script で決定論」。issue #87)。以下の述語はその script が符号化する規則の spec であり、**人間が prose↔script の一致を目視確認する**(挙動不変の operational 定義・#37 前例・機械的な before/after 等価検証は不可能)。**不変条件は「1 つの衝突 group から今 tick に dispatch されるのは常に高々 1 件。live wait 占有者が居る group からは 0 件」**:
```
# $COLLISION の groups/safe に、各候補の kind を付した candidates を添えて代表選出判定器へ渡す
REPS=$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/select-dispatch-representatives.py" <<JSON
{"groups": <$COLLISION の groups>, "safe": <$COLLISION の safe>,
 "candidates": {"<id>": {"kind": "<new_eligible|redispatch|wait_occupant>"}, ...}}
JSON
)
# -> {"dispatch": ["<id>", ...], "carry_over": ["<id>", ...], "injected_only": ["<id>", ...]}
```
kind は prose が解決する(状況→トークンの解決 seam は prose 側に残る・🟡4): **選別(jq)が返した新規 eligible = `new_eligible` / reconciliation action==`redispatch` = `redispatch` / action==`wait` の live 占有者 = `wait_occupant`(inject 専用)**。判定器の出力を次のとおり使う — `dispatch` を今 tick の実装役枠へ載せ、`carry_over` は **marker 非書換で次 tick へ持ち越す**(下記「持ち越しが sink を殺さない」)、`injected_only`(wait 占有者)は dispatch しない。下記の述語はこの判定器が返す `dispatch` / `carry_over` / `injected_only` の内訳を規則として記述したものである:
- **`safe`**(単独連結成分・非空 files): そのうち **dispatch 対象候補(新規 eligible ∪ redispatch)だけ**を今 tick の実装役枠の母集団として残す。inject した wait 占有者が(共有ファイルを持たず)単独で `safe` に現れた場合は **除外する**(inject 専用で dispatch しない)。
- **`groups`** は group ごとに、まず **fail-closed 単独候補(size==1 かつ `files=[]`・対象ファイル抽出 0 件)** か **size≥2 の恒久衝突組** かで分岐する(`detect-dispatch-collision.py` は両者をともに `groups` に入れるが、prose の扱いは分ける):
  - **fail-closed 単独候補(`files=[]`)** → **占有者の有無・代表選出によらず常に持ち越す**(#55 以前の fail-closed 挙動を保存)。対象ファイル不明のため in-flight 占有者と同一ファイルを触るか判定できず、dispatch すると衝突を検知できないまま同一ファイル 2 件同時 in-flight になりうる(DoD (ii) 違反)ため **決して dispatch しない**。**下の「占有者ゼロの group → 代表 1 件 dispatch」は size≥2 の恒久衝突組にのみ適用し、この単独候補には適用しない** — script が `empty_ids` 分岐で `files=[]` を単独 group として `groups` に入れるのは「占有者ゼロの衝突 group」ではなく「fail-closed 持ち越し」として扱う(size==1 の group を代表選出の母集団に含めない)。これは「既知の制限・拡張ポイント」節の『ファイル衝突検知…の抽出規則は machine-enforce されていない』項(抽出規則が `files: []` へ倒す fail-closed)および `detect-dispatch-collision.py` docstring の『`files` が空配列の候補は…group ごと今 tick では dispatch せず marker を書き換えずに次 tick へ持ち越す』と整合する(旧 round では代表選出述語がこの単独候補も無差別に 1 件 dispatch し、fail-closed の『常に持ち越す』保守挙動を反転させていた・round2 🔴1)。
  - **size≥2 の恒久衝突組**は占有者判定でさらに分岐する:
    - **live wait 占有者が 1 人でも居る group** → **今 tick は何も dispatch しない**(新規 eligible も、同一ファイルを共有する redispatch も持ち越す)。
    - **占有者ゼロの group** → dispatch 対象候補(新規 eligible ∪ redispatch)から **決定論 tie-break = step id 昇順の完全順序で代表 1 件だけ dispatch** し、残りは持ち越す。

いずれの持ち越しも **marker を書き換えない**(下記「持ち越しが sink を殺さない」)。この group 内の代表決定(step id 昇順)は、下記 5 件枠の「redispatch を新規 eligible より先に数える」優先順位付けとは**直交する**(前者は衝突 group 内の代表決定、後者は衝突フィルタ後の safe/代表集合を 5 枠へ詰める順序)。

**redispatch の扱い(規則Y・round3 で限定)**: redispatch 候補は原則 #26/#71 機構どおり dispatch 経路に残す(占有者述語で**無条件に**止めると retry_count が消費されず締切 sink が殺されるため)。ただし round3 で **「同一ファイルに live wait 占有者を共有しない redispatch に限る」へ限定**した — 同一ファイルに live wait 占有者が居る redispatch は、上記「占有者が居る group からは 0 件」により**占有者が clear(PR 作成)/ sink するまで marker 非書換で持ち越す**。この持ち越しは、上記 group 持ち越し(代表選出で負けた候補の marker 非書換持ち越し)/「配車テーブル」節が定める「実装役枠から溢れた redispatch の marker 非書換持ち越し」が既に定める「持ち越し = marker 非書換で次 tick」操作の再利用で、新機構は足さない。この限定 + 規則X/Y 一本化により、2 件同時 in-flight に到達しうる 2 経路(占有者不在で redispatch × 新規 eligible が代表枠を争う経路 A / live wait 占有者 × 同一ファイル redispatch の経路 B)がいずれも「高々 1 件」に畳まれ decidable になった(round2/round3 でこの 2 経路を検出・修正した往復の経緯は PR #96 / issue #55 のレビュー履歴を参照 — merge-commit で保全される)。

**持ち越しが sink を殺さない(実コード整合)**: 持ち越し = marker 非書換なので `reconcile-dispatch-marker.py` の `new_retry = marker["retry_count"] + 1` は **実際に redispatch した tick でのみ** storage の retry_count を bump する。持ち越し中は retry_count 不変・`current_tick > deadline_tick` 維持で action は `redispatch` のまま(`sink` へ誤落ちしない)。live wait 占有者は締切 K=2 tick 内に必ず clear / redispatch / sink へ遷移し wait 占有者でなくなり、以後その redispatch は代表選出で 1 件ずつ必ず進む → step 母集団は有限・min id 側から単調消費で遅延は**有界**、hang し続ければ retry_count が消費され既存 #26/#71 sink へ到達する(round2 が恐れた「永久に止めて sink を殺す」には至らない)。

**旧「組合せが変わりうる」前提の限定(issue #55 Problem)**: 従来 `groups` は「次 tick には候補の組合せが変わりうるため同じ衝突が起き続けるとは限らない」として全件持ち越していたが、**恒久的に同一ファイルを編集する 2 つの ready issue ではこの前提が成り立たず**(毎 tick 同じ 2 候補が同一 group に入り `safe` が空になり続ける)、両方が永久に dispatch されない = デッドロックになる。上記代表選出は占有者ゼロ group から 1 件ずつ直列に割ることでこれを解消する。**多 tick の帰結(両者が最終的に dispatch されデッドロックしない = DoD (i))は per-tick 純関数アサートの合成 + 実運用観測で担保し、tick-simulator は足さない**(下記 machine-enforce の限界)。

**machine-enforce の範囲と残る seam(DoD (iv)・issue #87 で更新)**: 上記の代表選出・占有者除外・step id 昇順 tie-break・fail-closed 単独候補の持ち越しという**代表選出規則そのもの**は、issue #87 で `scripts/select-dispatch-representatives.py` へ抽出し、smoke(`[12]`)が全分岐(「占有者が居る group から dispatch 0」「占有者ゼロ group から min id 代表 1 件」「fail-closed 単独は常に持ち越し」「tie-break は入力順非依存の min id」)を**負の自己検証込み**で検証する(`detect-dispatch-collision.py` の grouping 層 + `select-dispatch-representatives.py` の代表選出層の 2 段)。**残る非検証 seam は各候補の kind(`new_eligible`/`redispatch`/`wait_occupant`)の解決**であり、占有者判定は台帳 state(`dispatchMarker`/`pr.number`/締切)を要するため prose 側に留まる(🟡4 — 抽出は規則の回帰検知を効かせるが、kind 解決 seam は un-verified のまま)。**機械的な before/after 等価検証は原理的に不可能**(抽出元 prose に baseline test が無い・#37 前例)であり、prose↔script の規則一致は人間が目視確認する。**詳細と根拠は「既知の制限・拡張ポイント」節の該当項目に一本化する**(重複記載を避けるため、ここでは要旨のみ)。

**5 カテゴリ(対応役 / pr reviewer / 実装役 / issue review worker / issue reviewer)を合算して 上限 5 件**に切り詰める(issue #88: issue フェーズ 2 ロールも PR 3 カテゴリと**同じ 1 tick 5 件枠を共有**する — 独立枠を持たせない)。**優先順は「対応役 > pr reviewer > 実装役 > issue review worker > issue reviewer」**(round1 🟡5 決定)— PR フェーズを issue フェーズより優先する(in-flight のダウンストリーム作業を先に閉じる)。PR フェーズ内は手戻り修正を優先し新規 dispatch は余裕がある時だけ、issue フェーズ内も同型に issue review worker(指摘対応)> issue reviewer(新規レビュー)とする。実装役カテゴリ内では `redispatch` 候補(締切超過が古いもの優先)を新規 eligible 対象より先に数える。この優先順位付け自体は機械的な tie-break であり、レビュー判断ではない。実装役枠から溢れた `redispatch` 候補は「tick 冒頭 reconciliation」節のとおり marker を書き換えずに次 tick へ持ち越す。**各対象を処理する前の無条件スキップは、PR は `gh pr view <n> --json labels` の `need for human review` ラベル確認、issue は台帳の `issue.status == "need for human review"` 確認(status 自身が選別から外すため実質は選別 jq が兼ねる)で行う**。**ファイル衝突検知は実装役固有**で issue フェーズには適用しない(issue ロールはリポジトリ内ファイルを触らないため・round1 🟡5(iv))。

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

   **(A1・issue #71)dispatch prompt に「時間を自分で計測せよ / タイムボックスを自分で守れ」といった時間の自己管理を求める指示は書かない** — 締切(`reviewLock` の `deadline_tick`)の所有と hang 判定は orchestrator の職責(「tick 冒頭 reconciliation」節「reviewLock の reconciliation」)であり、委譲先に時計を持たせない(#53 症状1 の A2「orchestrator が能動的に時刻確認」却下と対の原則。上記 dispatch prompt に該当記述が無いことを維持する = 将来の追記を防ぐ予防的明記)。

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

対象 PR 番号 `#<N>` と `$REVIEW_MODE`(code-review の場合は加えて `$FINDINGS_PATH`)を渡し、次を Agent ツールで dispatch する(ツール制限は実装役と同じ。**`gh pr comment` 投稿は許可するが台帳・ラベルには触れさせない**)。**dispatch prompt 本文は `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer-dispatch.md` へ外出し済み**(issue #52 Phase B・実装役 / 対応役節と同型。★最重要★ の共通コア + pr reviewer 固有項目 + `roles/pr-reviewer.md`(判定 spec)をラップして「手順 4〜5.6 を実行し手順 6 は行わず `contracts/reviewer-return.schema.json` の形で返す」指示を含む)。この参照ファイルは **dispatch する subagent 自身が読む** — orchestrator 自身は読まない(実装役節と同型):

> 「`${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer-dispatch.md` を Read し、そこに書かれた指示をそのまま実行せよ(対象 PR は #<N>、review-mode=`$REVIEW_MODE`、code-review の場合は候補収集済みファイル `$FINDINGS_PATH`)。手順本体は転写しない — 必ずファイルを Read してから実行すること。」

**(A1・issue #71)pr reviewer の dispatch prompt にも「時間を自分で計測せよ / タイムボックスを自分で守れ」といった時間の自己管理を求める指示は書かない** — 締切(`reviewLock` の `deadline_tick`)の所有と hang 判定は orchestrator の職責(「tick 冒頭 reconciliation」節「reviewLock の reconciliation」)であり、委譲先に時計を持たせない(上記 dispatch prompt に該当記述が無いことを維持する = 将来の追記を防ぐ予防的明記)。

**outcome 解決(判定器の reviewer 行に渡すトークンを決める。dispatch 応答から解決する 5 outcome を必ず解決する — reviewLock hang の `timeout` は dispatch 応答ではなく「tick 冒頭 reconciliation」節の reviewLock reconciliation が解決する別経路のため、ここには含めない)**: 実装役の復旧検索・対応役の evidence gate と対称に、**reviewer にも「dispatch 結果失敗」分岐を持たせて単一 sink をすり抜けさせない**(「実装役は復旧検索、対応役は evidence gate で dispatch 失敗を捌けるが、reviewer だけ dispatch 結果失敗の分岐が無く単一 sink をすり抜ける」を、この `invalid` 分岐で塞ぐ)。判定順序は次のとおり(上から順に該当する最初の分岐を採用する):

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

### issue reviewer(issue #88)

pr reviewer を issue フェーズへ写したもの。**判定エンジンは 2 モード(既定=kit 同梱 spec `roles/issue-reviewer.md` / opt-in=個人 skill `reviewing-github-issues`・issue #93 で可搬化)**(PR 側の既定 `code-review` / opt-in `multi-angle` と対称。honest な明記は `roles/issue-reviewer-dispatch.md` frontmatter と `.harness/CLAUDE.harness.md`「役割の分離」節)。**PR 側の候補収集(`collectors/strategy.md`・code-review mode)に相当する orchestrator 前処理は無い**(単一エージェント判定のため — spec `roles/issue-reviewer.md` 1 ファイルが PR 側 `collectors/angles/*`(検出)と `roles/pr-reviewer.md`(判定)の両役割を担う)。**モード変数 `$ISSUE_REVIEW_MODE`(既定 `spec`)を「選別(jq)」節で既定展開し dispatch へ渡す**(PR 側 `$REVIEW_MODE` と対称)。

1. **`issueReviewLock` 書込**: dispatch 直前に「issue reviewer / issue review worker の in-flight ロック」節の書込手続きで `issueReviewLock` を書く(重複配車防止 + hang 検知を単独で担う・選別 jq は既に `.issueReviewLock == null` で除外済み)。**`issue.status` は書き換えない**(round1 🔴1/🔴2 — in-flight status マーカーは冗長かつ reconciliation の役割解決を壊すため。PR フェーズの reviewLock が `pr.status` を書かないのと対称)。

2. **dispatch**(ツール制限は pr reviewer と同じ。`gh issue comment` 投稿は許可するが台帳・ラベルには触れさせない)。**dispatch prompt 本文は `${CLAUDE_PLUGIN_ROOT}/roles/issue-reviewer-dispatch.md` へ外出し済み**(★最重要★ の共通コア + issue reviewer 固有項目 + 判定エンジン(既定=kit spec `roles/issue-reviewer.md` を Read 実行 / opt-in=個人 skill 起動)→ blocker_count/round/prev_markers 補完 → `evaluate-stop-condition.py` で escalate 補完 → marker 埋込 + 投稿 → `contracts/issue-reviewer-return.schema.json` の形で返す指示を含む)。この参照ファイルは **dispatch する subagent 自身が読む** — orchestrator 自身は読まない:

   > 「`${CLAUDE_PLUGIN_ROOT}/roles/issue-reviewer-dispatch.md` を Read し、そこに書かれた指示をそのまま実行せよ(対象 issue は #<N>、review-mode=`$ISSUE_REVIEW_MODE`(既定 `spec`))。手順本体は転写しない — 必ずファイルを Read してから実行すること。」

3. **outcome 解決(判定器の issue-reviewer 行に渡すトークンを決める。reviewer と対称の 5 outcome。`timeout` は dispatch 応答ではなく「issueReviewLock の reconciliation」が解決する別経路)**: 判定順序は pr reviewer の手順と同一 — (1) 返答が JSON でない / `escalate` を読めない → `invalid`、(2) `escalate_to_human` 有効 → `subjective_escalate`(「3 role 共通の `subjective_escalate` の解決方法」参照)、(3) `escalate == true` → `escalate`、(4) `escalate == false` かつ `has_blocker == false` → `clean_pass`、(5) `escalate == false` かつ `has_blocker == true` → `blockers`。

4. **判定器を呼び route / label_action を実行**(role=issue-reviewer。**全 outcome で `<clear_marker>`="true" `<marker_field>`="issueReviewLock" を渡し、手順 1 で書いた `issueReviewLock` を同一の原子書込で解除する**。`observation`(issue #50 A1)は pr reviewer と同型に sink 系(`invalid`/`escalate`/`subjective_escalate`)へ渡す):
   - `invalid` → `ledger_write` は null(`issue.status` は dispatch 元のまま)。`issueReviewLock` は解除する・route=sink・label_action=null。
   - `subjective_escalate` / `escalate` → 判定器の `ledger_write`(`issue.status`="need for human review")を **`ledger_write` の適用**手続きで書く(書いてから sink)・route=sink。sink の出口は「issue フェーズの sink の差分」に従いラベルを **issue に** 付与。
   - `clean_pass` → 判定器の `ledger_write`(`issue.status`="ready for implementation")を書く・route=normal・label_action=`add_ready_for_implementation`(issue の `ready for implementation` ラベル。実コマンドは「ルーティング判定」節 `label_action の実行` を参照し `gh issue edit` へ読み替える)。
   - `blockers` → 判定器の `ledger_write`(`issue.status`="completed review")を書く・route=normal・label_action=`remove_ready_for_implementation`。

   `subjective_escalate` / `escalate` / `clean_pass` / `blockers` の 4 分岐は判定確定のため、`ledger_write` 適用の直後に「作業レポートの代筆」節の共通手続きで `reports[]` へ 1 件追記する(`author`="issue reviewer"・`role`="reviewer"。`invalid` は判定物が無いため追記しない)。

### issue review worker(issue #88)

developer(対応役)を issue フェーズへ写したもの。**ただし issue フェーズには実行して落とせる証拠(test)が構造的に無いため evidence gate を持てない** — 前進 outcome は単一の `done` のみで、対応役の `evidence_pass`/`evidence_fail` 二分岐は無い(round1 🟡2 の正直な非対称)。「偽の前進」(無作業 dispatch でも `done` へ進む)の検知は次 round の issue reviewer 別セッション読取に一本化される(PR responder の evidence gate より構造的に弱い)。

1. **`issueReviewLock` 書込**: dispatch 直前に「issue reviewer / issue review worker の in-flight ロック」節の書込手続きで `issueReviewLock` を書く(選別 jq は `.issueReviewLock == null` で除外済み)。**`issue.status` は書き換えない**(round1 🔴1/🔴2 — 対応役の reviewLock が `pr.status` を書かないのと対称)。

2. **dispatch**(ツール制限は対応役と同じ。`gh issue comment` 投稿は許可するが台帳・ラベルには触れさせない)。**dispatch prompt 本文は `${CLAUDE_PLUGIN_ROOT}/roles/issue-review-worker.md` へ外出し済み**(★最重要★ の共通コア + issue review worker 固有項目 + 4 分類採否判定を inline。PR 側 `developer-responder.md` が dispatch file を分けないのと対称の単一ファイル):

   > 「`${CLAUDE_PLUGIN_ROOT}/roles/issue-review-worker.md` を Read し、そこに書かれた指示をそのまま実行せよ(対象 issue は #<N>)。手順本体は転写しない — 必ずファイルを Read してから実行すること。」

3. **主観的エスカレーションの確認**(返答検証より先に・検出条件は「3 role 共通の `subjective_escalate` の解決方法」参照)。該当すれば outcome=**`subjective_escalate`**。

4. **返答検証(越権の無効化)**: `proposed_status` が `"waiting for review"` 以外(特に `"ready for implementation"`)でも**無視して先へ進む**(worker の越権を orchestrator 側で機械的に無効化する — `.harness/CLAUDE.harness.md` の「issue review worker が `ready for implementation` を立てるのは越権」を技術的に担保。`ready for implementation` は issue-reviewer の `clean_pass` 経由でのみ到達する)。worker の返答は outcome 解決に使わない。

5. **outcome 解決 → 判定器を呼び route を実行**(role=issue-review-worker。**全 outcome で `<clear_marker>`="true" `<marker_field>`="issueReviewLock" を渡し `issueReviewLock` を解除する**。`observation` は sink 系(`subjective_escalate`)へ渡す):
   - 主観エスカレーション以外(通常の対応完了)→ outcome=**`done`** → 判定器の `ledger_write`(`issue.status`="waiting for review")を **`ledger_write` の適用**手続きで書く・route=normal(次 tick で issue reviewer が再レビュー)。
   - `subjective_escalate` → 判定器の `ledger_write`(`issue.status`="need for human review")を書く(書いてから sink)・route=sink。sink の出口はラベルを **issue に** 付与(「issue フェーズの sink の差分」)。

   `done` は worker が実際に作業した事実(採用/却下の判断・本文反映)を伴うため、`ledger_write` 適用の直後に「作業レポートの代筆」節の共通手続きで `reports[]` へ 1 件追記する(`author`="issue review worker"・`role`="developer"。worker は PR 対応役(`role`="developer")の issue 版であり、schema の `role` は区分(developer/reviewer 等)を表すため区分側に揃える・round1 🟡10。`subjective_escalate` は対応未完了のため追記しない)。

**issue フェーズには evidence gate 相当が無い(正直な限界・round1 🟡2)**: PR フェーズの対応役は evidence gate(test 独立再実行)で越権を無効化し独立検証するが、issue フェーズには実行して落とせる証拠が無い。有界化は「issueReviewLock の reconciliation」(hang 検知)+ issue reviewer の停止条件機構(round 上限 / blocker trend → escalate → sink)が担い、機械的独立検証は issue reviewer の別セッション読取に一本化される。「A＝PR と対称」は (i) この evidence gate 非対称と (ii) 判定エンジンの可搬性(issue reviewer が opt-in の個人 skill 依存)の 2 点を除いて成立する。

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

- **カウンタ(`statusesPostFailCount`・transient・schema 非宣言)**: 台帳 top-level に整数フィールドを持つ(`orchestratorTick` と同型・キー無しは 0 扱い)。`report-ledger-status.sh` を呼ぶたび、現在値と終了コードを `scripts/decide-statuses-post-action.py`(`evaluate-stop-condition.py` と同型の pure decision script・issue #54)へ渡し、**counter の更新値 `new_count` と halt 判定 `halt` を決定論的に受け取る**(閾値ロジックは script が唯一の正・prose に複製しない。他の判定器と同じ設計境界)。判定内容は **post 失敗(非 0)なら 1 加算**、**post 成功(0。STATE の値によらない)なら 0 にリセット**。呼び方:
```
FAIL_ACTION=$(printf '{"current_count":%d,"post_exit_code":%d}' "$STATUSES_POST_FAIL_COUNT" "$POST_EXIT" \
  | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/decide-statuses-post-action.py")
```
  返った `new_count` を `statusesPostFailCount` へ書き戻し、`halt` が true なら下記 global halt を実行する。
- **tick 報告への surface(常時)**: 呼ぶたびに成否を tick 報告(下記「報告」節の dispatch サマリ表)へ 1 列として記載する。これは post が失敗しても成功しても毎回行う(全 step を横断するため症状に合う)。
- **global halt(判定器が `halt: true` を返したら)**: 上の判定器が `halt: true` を返した(= `new_count` が閾値 **3 回** に達した。閾値 3 は校正根拠の無い best-effort 値で、他所の `K`/`N=2` より 1 大きいのは単発の network flake で即 halt しないための余裕。この閾値の単一ソースは `decide-statuses-post-action.py` の `HALT_THRESHOLD`)場合、**その時点で処理中の tick の残り候補への dispatch を打ち切る**(既に完了した step のローカル書込は取り消さない — 台帳への書込は post 試行より前に完了しているため、halt は post の失敗そのものへの対応であり、ローカル状態を巻き戻す話ではない)。`PushNotification` で人間に auth/network の復旧を促し、tick 報告に `🛑 global halt` を明記する。**counter はリセットしない**(次 tick も引き継ぐ)。**tick 全体を将来にわたって停止する仕組みは持たない** — 次 tick は通常どおり選別・dispatch を試み、最初の step の post 結果が自然な回復確認(probe)になる。成功すればそこで counter が 0 にリセットされ通常運転に戻る。失敗すれば(counter は既に閾値以上のため)その step の処理後ただちに再度 halt する。
- **per-step sink にしない理由**: Statuses post 失敗の主因(`gh auth switch` 事故・token 失効・network・rate limit)は **session 全体で起きる global 障害**であり、特定 step の品質問題ではない。特定 step だけを `need for human review` へ sink しても、他 step の post は同じ障害で失敗し続け実害(required check が付かない PR が無言で残る)が他 step で再発する。かつ、作業自体は正しい step を infra 障害で誤って blocker 化してしまう。global halt はこの mis-target を避ける。
- **閾値ロジックの script 化(issue #54 で実施・旧「見送り」の解消)**: 「連続 N 回失敗で halt」という閾値つき判定は、`evaluate-stop-condition.py` と同型の decision script に載せる方が「規則は script が正」の設計境界と一貫する(衝突検知(欠落 3)を script 化した判断と対称)。v1 は counter の読み書きが 1 行の比較で足りるとして prose のまま見送っていたが、**閾値(`>= 3`)・reset/increment の分岐が untested な prose のまま残るリスク(off-by-one 等が緑のまま素通しになる)を塞ぐため、issue #54 で `scripts/decide-statuses-post-action.py` へ切り出し `tests/smoke/run-smoke.sh` で全分岐(increment 0→1→2・閾値到達 2→3 halt・閾値超過後も失敗なら加算継続(reset しない)・成功で 0 へ reset・不正入力 exit 2)をアサートした**(#87 の decision script 抽出棚卸しから本項目を参照)。

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
| `issue reviewer` / `reviewer` | `clean_pass` / `blockers` / `escalate` / `subjective_escalate`(いずれも判定が確定し `issue.status` が遷移するため対象。`invalid` は dispatch 結果失敗で判定物が無いため対象外。issue #88) | 「issue reviewer」outcome 実行部 |
| `issue review worker` / `developer` | `done`(対応作業が実際に行われた事実を伴うため対象。`subjective_escalate` は対応未完了のため対象外。issue #88。`role` は区分側に揃え PR 対応役と対称・round1 🟡10) | 「issue review worker」手順 5 |
| `pr review worker` | 対象外(本コマンドが dispatch しないロール。`developer(対応役)` と機能は近いが、本コマンド経由ではなく個人 skill `working-triaged-pr-for-loop` 経由で手動 / loop 起動される独立ロールであり、本ファイルの配線対象ではない) | — |
| `orchestrator` | 対象外(上記 3 ロール分の代筆行為そのものが単一 writer = 本コマンドの実行として行われるため、別途 `author="orchestrator"` の重複 report は持たない) | — |

**`<body>` の組み立て方(ロールごと)**:
- 実装役: dispatch 応答(`${CLAUDE_PLUGIN_ROOT}/roles/developer-implementer.md` の返り値)に含まれる `summary`(実装内容の 1〜2 文要約)をそのまま使う。空・欠損なら `"issue #<N> の実装(PR #<pr_number>)"` にフォールバックする(observed-fact のみを書く原則により、無い情報を捏造しない)。
- 対応役: dispatch 応答(`${CLAUDE_PLUGIN_ROOT}/roles/developer-responder.md` の返り値)に含まれる `summary`(対応内訳の 1〜2 文要約)をそのまま使う。空・欠損なら `"PR #<n> のレビュー指摘対応"` にフォールバックする。
- pr reviewer: 手順内で既に取得済みの判定結果(`ledger_write` が書く遷移先 `pr.status`)と、dispatch 応答の `has_blocker` / `blocker_count` から組み立てる(例: `"判定 <遷移先 status> / has_blocker=<has_blocker> / blocker_count=<blocker_count>"`)。追加の `gh` 呼出は不要 — `blocker_count` は集計済みの blocker 件数であり finding 総数ではない点に注意(正直な明記。finding 総数を取りたければ `review_markdown` の解析が要るが、v1 では行わない)。
- issue reviewer(issue #88): pr reviewer と同型に、判定結果(`ledger_write` が書く遷移先 `issue.status`)と dispatch 応答の `has_blocker` / `blocker_count` から組み立てる(例: `"判定 <遷移先 issue.status> / has_blocker=<has_blocker> / blocker_count=<blocker_count>"`)。
- issue review worker(issue #88): dispatch 応答(`${CLAUDE_PLUGIN_ROOT}/roles/issue-review-worker.md` の返り値)に含まれる `summary`(対応内訳の 1〜2 文要約)をそのまま使う。空・欠損なら `"issue #<N> のレビュー指摘対応"` にフォールバックする。

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

## 2 モード運用(`/goal` 有期 / `/loop` 常設)

本節は本コマンドの **2 モード運用の正式宣言**である。本コマンドの二分岐(`$1` あり = `/goal` 文字列の組み立て / なし = 通常 tick 実行。#60 / #89)には、次の 2 つの運用モードが対応する — **常設運用は `/loop`・有期キャンペーンは `/goal`**。両者は代替関係ではなく用途の分担であり(#107 の 2 ループ運用モデルのうち、本コマンドは orchestrate ループ側の運用形を担う)、同一台帳に対しては択一(下記「二重オーケストレーターの排他」)。

| モード | 駆動 | 用途 | 停止 |
|---|---|---|---|
| **モード1: 有期キャンペーン**(`$1` = 自由文 / `pr <N>` / `issue <N>` → `/goal` 文字列を組み立てて提示。#60 / #89) | `/goal`(Stop hook・goal 評価器)を人間が実行 | **「この issue / phase を終端まで」の目標到達型**の集中運転 | 目標達成 or 停止条件(sink 13 文)到達で評価器が停止する。goal 評価器が価値を持つ用途 |
| **モード2: 常設巡航**(`$1` なし = 通常 tick を 1 回実行) | `/loop N /harness-orchestrate`(定期発火・1 発火 = 1 tick) | **discover(#78)駆動で仕事を回し続ける常設運用**。仕事が無ければ 0 件 tick の 1 行報告で終わり、`discover` ラベルが付けば次 tick で自然に流れ込む | 明示停止(`/loop` 解除)。空転時の退避・完了通知は #84(Phase 4)が将来部品 |

- **モード選択の基準**: 「終わりが定義できて、そこに到達したら止めたい」なら `/goal`(有期)。「discover 駆動で仕事が来る限り回し続けたい」なら `/loop`(常設)。**常設巡航を `/goal` で行おうとすると (1) 組み立てモードへの誤入(再帰)(2) 枯渇 / 永久停止のジレンマ (3) goal 評価器の常時コスト、の 3 問題が生じる**ため常設は `/loop` を使う(モード2 では各 tick が完結し、tick 跨ぎの状態は in-flight マーカー + reconciliation(#26)が本来の設計どおり担うため、goal 文が不要になり 3 問題が構造的に消える)。
- **#107 manage ループとの接点は `discover` ラベルただ 1 つ**: manage ループ(`/harness-product-manage` を `/loop` で日単位・#107)が兆候から issue を**起票**し、**v1(Alternatives A)では `discover` ラベルは人間が付与する**(PM は本文へ「discover 推奨」を明示するだけで自分では貼らない = WIP ゲート)。本 orchestrate ループ(モード2)が次 tick でその `discover` ラベル付き issue を拾って流し込む。GitHub がキューとして機能する疎結合であり、両ループは台帳・ラベル以外で直接結合しない(PM が自動でラベルを貼る全自動 = Alternatives B は目標状態だが規約改定が先行依存で v1 では採らない・`roles/product-manager.md`「提案止まりの境界」節)。

### 常設巡航(モード2 = `/loop`)の回し方

- 試行: `/loop 15m /harness-orchestrate`(review-mode=code-review 既定、15 分間隔)。
- review-mode を明示したい場合: `/loop 15m /harness-orchestrate "" multi-angle`。
- `/loop` は起動時の引数をそのまま毎 tick 再実行するため、review-mode は起動時の引数が毎 tick 引き継がれる。追加の状態保持は不要。
- **ゴール文言(`$1`)を渡すモードは `/loop` と併用しない**: `/loop` は起動時の引数をそのまま毎 tick 再実行するため、`$1` 付きで `/loop` に渡すと「`/goal` 文字列を組み立てて提示するだけ」の処理(通常 tick を実行しない)が毎 tick 繰り返され、実質的に何も進まない。`$1` 付き起動は 1 回限りの単発呼出として使い、提示された `/goal <文言>` をユーザーが実行することで初めて継続実行が始まる(上記「`/goal` 起動文字列の組み立て」節参照)。

### 二重オーケストレーターの排他(軸1 = A・規約明記。issue #110)

- **同一台帳に対して `/loop` 常設巡航(モード2)と `/goal` 有期キャンペーン(モード1)は択一とし、並行起動しない。** 両モードを同一台帳へ同時に走らせると単一 writer が 2 人になり、F案(#11)のローカル台帳は競合検知を持たないため、同時書込は後勝ちが無音で前の書込を消す(#81 Problem・実観測済み)。`dispatchMarker` / `reviewLock` は step 単位の in-flight ロックで、tick(orchestrator セッション)単位の排他はカバーしない。
- **この規約は機械強制ゼロの受容コストを持つ(正直な明記)**: 「運用規約で守れる」は楽観であり、人間が巡航中に別セッションで `/goal` を開けば後勝ち無音上書きは実際に起きる。**機械強制(B = tick 排他ロック #81)を Phase 4 へ defer する経緯・#77 が forcing function である点等、受容コストの詳細は `.harness/CLAUDE.harness.md`「台帳の書込経路」節を単一の正とし、ここでは繰り返さない**(issue #112 round1 🟡2: 2 ファイル間に drift guard が無いため、受容コスト記述の正本を governance 側へ一元化し将来 drift を減らす)。

## 既知の制限・拡張ポイント

- **真の無人化はまだできない**: `/loop` はセッションが開いている間だけ定期実行できる方式であり無人ではない。GitHub Actions `on: schedule` / `/schedule` クラウド routine による真の無人化は、判定 skill(`reviewing-multi-angle` 等・review-mode=multi-angle のみ)の kit 同梱が前提になるため別途対応が必要(review-mode=code-review(既定)は issue #49 以降 `${CLAUDE_PLUGIN_ROOT}/collectors/strategy.md`(kit 同梱・個人 skill 不要)による角度別 finder 収集のみに依存する。導入先が `.harness/collectors/angles/` に `skill:` 付き角度を追加した場合はその skill にも依存する)。
- **手動代行モードは第一級の運用モード(issue #71・B2)**: 本 orchestrator は `/loop` による定期実行だけでなく、**ルートエージェントが各 tick を都度手動起動する「手動代行モード」でも回る**(実測: `orchestratorTick` が 2026-07-16 の `1` から手動代行のみで前進した)。両モードで tick モデル(無状態 tick・`orchestratorTick` 加算)・配車ロジックは同一で差は無く、`/loop` は「手動代行の tick 起動を定期化した特殊形」に過ぎない。**有界停止の保証レベルは両モードとも tick 数ベース**であり実時間ベースではない(「有界停止の保証」節 B2 参照)— 手動代行モードでは次 tick の起動タイミングが人間に委ねられるため、sink 到達までの実時間は不定である(これは B2 として受容された帰結)。締切機構(`dispatchMarker` の `K=2` / `reviewLock` の `K_review=0`)が保証するのは「何 tick で sink へ到達するか」であって wall-clock の有界性ではない。
- **issue #11 の F案は実装済み**: 上記「既知のリスク」節参照。orchestrator の単一書込は ローカルファイル編集 + Statuses API 自己申告へ追従済み(main への直接 commit/push はしない)。
- **issue サイド(issue reviewer / issue review worker)の配車を配線済み(issue #88)**: issue フェーズも PR フェーズと対称に配線した(配車テーブル・decision script の 2 role・`issueReviewLock`(重複配車防止 + hang 検知を単独で担う・dispatch 前に `issue.status` は書き換えない・round1 🔴1/🔴2)・単一 sink(`issue.status="need for human review"`)・ダッシュボード可視化・reports[] 代筆)。ただし「A＝PR と対称」は **1 点(evidence gate)を除いて成立する**正直な非対称が残る: (i) issue フェーズには実行して落とせる証拠(test)が構造的に無く **evidence gate 相当が無い**(有界化は停止条件機構 + `issueReviewLock` hang 検知が担い、偽の前進検知は次 round の issue reviewer 別セッション読取に一本化 = PR responder より弱い)。**(ii) issue reviewer の判定エンジンの可搬性は issue #93 で解消済み** — 既定 `ISSUE_REVIEW_MODE=spec` は kit 同梱 spec `roles/issue-reviewer.md`(8 観点 rubric を parity 深さで inline)を実行し、他 repo は skill 無しで動く(個人 skill `reviewing-github-issues` は opt-in `ISSUE_REVIEW_MODE=skill` へ後退・skill 不在時は kit 既定へ fail-soft・PR 既定 `code-review` / opt-in `multi-angle` と対称)。残る受容コストは **kit 版 spec ⇔ 個人 skill の rubric drift が機械検知不可・best-effort 手動同期**(個人 skill は repo 外にあり smoke から読めない)である点のみ。**PR を伴わない issue 単体の close 代行はスコープ外**(`.harness/CLAUDE.harness.md`『終端の記録と merge 代行』踏襲)。
- **git-status ガードの限界と設計境界(部分的バックストップ・正直な明記)**: 台帳保護には次の点がある。
  - **(a) subagent の worktree 編集は捕捉できない**: 実装役 subagent は自前の worktree で作業するため、その `.harness/` 編集は orchestrator 自身の checkout で走る `git status` からは**見えない**。したがってこのガードは **orchestrator 自身の checkout 内の編集しか捕捉できない部分的バックストップ**に過ぎない。**「subagent に `Write` を渡さない」ツール制限は台帳保護の隔離にならない(issue #37・欠落 9。理由は「単一書込」節参照 — `Bash` を持つ子は `Bash` 経由で台帳を編集でき、実装役は `Bash` が必須)**。したがって台帳保護の実質はこの git-status ガード(部分的バックストップ)と各ロール委譲プロンプト冒頭の禁止文言(L1)のみに依存する。`Bash` 経由の編集は完全には防げず、hook 等による L3 相当の強制ではない。追加の構造防御は `Agent` ツールに環境隔離が入るまで別 issue とし、主防御の不在を正直に受容する。
  - **(b) 自身の書込の誤検知を避ける(ローカル編集方式)**: ローカル編集方式(F案)では orchestrator 自身の書込は commit されず作業ツリーに残り続ける(`.harness/plan-progress.json` は常に dirty)。この自分の書込を subagent の変更と**誤検知しない**よう、ガードは `git status` の dirty 判定ではなく、`plan-progress.json` については **orchestrator が最後に書いた内容のスナップショットと照合**し、`.harness/` のそれ以外のファイルのみ `git status` で HEAD 一致を確認する。orchestrator は自身の各書込の直後にスナップショットを更新する(「dirty = subagent の意図しない変更」と短絡しない — 誤検知で無関係 step を spurious に sink 隔離するのを防ぐ)。
  - **(c) git-status ガードだけが decision script を通らない唯一の失敗経路(設計境界・意図的)**: 他の全失敗面は「ルーティング判定」節の decision script が `route=sink` として決めるが、git-status ガードの drift 検知 → sink だけは script を経由しない。これは意図的である — **git-guard trip は「(role, outcome) に紐づくルーティング判断」ではなく、全ロール横断(cross-cutting)の pre-write 前提チェックであり、その帰結は自明に sink(分岐する判断ロジックが無い)ため decision script の対象外とする**(decision script はルーティング「判断」を集約するものであって、判断の無い自明な guard→sink はその対象ではない、という設計境界)。無理に決定表へ押し込まない。
- **dispatch 上限 5 件のトレードオフ**: 1 tick で処理しきれない場合は次 tick へ持ち越される(dedup は各ロールの status 遷移が担う)。**「tick 冒頭 reconciliation」の `redispatch` 候補もこの上限の対象**(「選別(jq)」節参照)であり、枠から溢れた候補は marker を書き換えずに持ち越されるため retry_count は消費されない。
- **ファイル衝突検知(`scripts/detect-dispatch-collision.py`)の抽出規則は machine-enforce されていない(既知のギャップ・issue #37・欠落 3)**: script が受け取る `files` は issue 本文の Implementation Scope から prose が抽出したものであり、抽出規則(バッククォート内のパスのみを対象ファイルとし、通りすがり言及を除外する)自体は script の対象外(pure-function 境界を守るため。「衝突判定(グラフの連結成分)」だけが script 側の正)。抽出漏れ・誤抽出は smoke では検出できず、fail-closed(`files: []`)側に倒すことで実害を「衝突不明な step を保守的に別 tick へ回す」に留めている。
- **恒久衝突ペアの代表選出・占有者除外(issue #55)の規則は issue #87 で decision script へ抽出済み(残る seam は kind 解決)**: 「ファイル衝突検知」節の代表選出述語(「1 group から dispatch は高々 1 件・live wait 占有者が居れば 0 件」・step id 昇順 tie-break・wait 占有者の inject / 除外・**fail-closed 単独候補(`files=[]`)は代表選出の母集団に含めず常に持ち越す**)という**規則そのもの**は、issue #87 で `scripts/select-dispatch-representatives.py`(`detect-dispatch-collision.py` の下流の pure decision script)へ抽出し、smoke `[12]` が全分岐を負の自己検証込みで検証する。`detect-dispatch-collision.py` は依然 Union-Find grouping のみで代表選出も占有者概念も持たない(**issue #55 で script は不変**・2 段構成: grouping 層 = collision / 代表選出層 = select-representatives)。**残る非検証 seam は各候補の kind(`new_eligible`/`redispatch`/`wait_occupant`)の解決**であり、占有者判定に台帳 state(`dispatchMarker`/`pr.number`/締切)を要するため prose 側に留まる(script へ入れると pure・stdin 完結境界を壊す・🟡4 — 抽出は代表選出規則の回帰検知を効かせるが kind 解決 seam は un-verified のまま)。headline の「両者が最終的に dispatch されデッドロックしない」(多 tick の temporal property・DoD (i))は依然 per-tick 純関数アサートの合成 + 実運用観測に委ねる(tick-simulator は足さない・over-engineering 回避 — 本抽出は per-tick の代表選出判断を machine-enforce するが、多 tick の liveness そのものは対象外)。**挙動不変は operational**(smoke ケースが prose「代表選出述語」を符号化・人間が目視確認・機械的等価検証は不可能・#37 前例)。
- **ルーティングは tested decision script**: (role, outcome) → (ledger_write, route, label_action) を `scripts/decide-orchestrator-route.py` が決定論的に解決し、`tests/smoke/run-smoke.sh` [8] が全 (role × outcome) 25 行を網羅検証する(reviewer の `invalid` 分岐 / implementer の `timeout` 分岐(issue #26)/ reviewer・responder の `timeout` 分岐(issue #71・reviewLock hang)/ 3 role 共通の `subjective_escalate`(issue #31)/ issue-reviewer・issue-review-worker の 9 行(issue #88)を含む)。散文分岐の取りこぼしを構造的に防ぐのが目的で、規則は script が正・prose は「outcome への解決」と「route の実行」だけを持つ。
- **A1(sink 系 outcome の観測必須フィールド)は独立検証ではなく自己規律の強化に留まる(issue #50 owner 決定 (b)・正直な明記)**: `route=sink` への解決に `observation`(コマンド + 終了コード + 出力要約)を必須化する A1(「ルーティング判定」節「呼び方」・`decide-orchestrator-route.py` モジュール docstring 参照)は、orchestrator 自身の 2 日間の自動運転で「観測できないもの」を「失敗」と 7 回誤断した実害(issue #50)への対策として導入した。**ただしこの検証は `observation` の存在・型のみを確認し、内容の真偽は検証しない** — orchestrator prose(判定を下す当人)が虚偽の観測を書けばそのまま通る(spoof 可能)。issue #50 の owner は「症状1(orchestrator/doer 自身の sink 判断)の常用経路は独立検証ゼロを正直に受容する」と決定した(選択肢 (b)。#17 round2 の Statuses API 自己申告「security boundary ではなく便宜シグナル」と同じ流儀)。**症状2(doer による DoD の独断書き換え)とは非対称**: そちらは PR reviewer という独立読み手(別セッション)が `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` の DoD 照合手順(issue #50 B2)で機械的に塞ぐが、症状1(orchestrator が sink へ倒す判断そのもの)には対称の独立読み手が存在しない。この非対称は本 issue の対応(Worker 権限)では解消できないと判断され保留された構造的な限界であり、(a) sink 倒し込み側にも独立検証の主体を配線する、という選択肢は #21(完全無人化)を本気で進める段階の前提として別途 issue 化する想定(issue #50 本文「レビュー反映 — 決定事項(round1/round2)」+ owner 決定コメント参照)。
- **`dispatchMarker` のライフサイクル(削除 / 永続 / 永続+`notified`)は machine-enforce されていない(既知のギャップ)**: 上記の decision script が検証するのは `(ledger_write, route, label_action)` の 3 つだけで、実装役の各 outcome が marker をどう扱うか(手順 6 の 3 分類)は `DECISION_TABLE` にも `tests/smoke/run-smoke.sh` にも反映されておらず、手順 6 の固定列挙(prose)だけが正である。これは意図的な現状維持であり、次の理由による: (i) `dispatchMarker` は transient なフィールドで、issue #68 で `plan-progress.schema.json` に **optional 宣言**した(型/形の正は `definitions.dispatchMarker`)が **検査対象外は維持**され(`step.required` 非追加・`step` の `additionalProperties` 不変)、`validate-plan-progress.py` は marker の値を検査しない(marker の**存在確認・妥当性**は `reconcile-dispatch-marker.py` が既に smoke [9] で網羅検証しているが、これは「marker が有効か」の判定であって「outcome ごとにどう処理すべきか」の判定ではない — 後者を machine-enforce するには decision script の出力契約(`ledger_write`/`route`/`label_action`)を拡張する必要があり、これは 1 フィールド追加では済まず、`decide-orchestrator-route.py` の 16 行・smoke [8] の `assert_route` 全件・「ルーティング判定」節の適用手続き・reconciliation の timeout 分岐(現状 decision script を経由しない別経路)を横断する変更になる。(ii) issue #31 は「主観的エスカレーション経路の追加」がスコープであり、marker ライフサイクルの machine-enforce 化はそれ自体別の改善提案として independently 評価すべき設計変更である。手順 6 を固定列挙(性質ベースの一文ではなく `no_pr`/`ambiguous`/`pr_evidence_pass`/`pr_evidence_fail`/`subjective_escalate` の個別列挙 + 新 outcome 追加時の追記指示)に変更したことが、今回のスコープで取れる現実的な緩和策である。**同種の欠落(散文の一般化が実際の分類を誤る)が今後も観測される場合は、decision script の出力契約への `marker_disposition` 相当フィールド追加を検討する。**
- **issue #26 との共有面(既知の drift リスク)**: `scripts/decide-orchestrator-route.py` の `DECISION_TABLE` と `tests/smoke/run-smoke.sh` [8] は issue #26(dispatch した子の生存監視と失敗の有界化)とも共有ファイルであり、両 issue が独立に `implementer` 行へ新エントリを追加する。詳細と rebase 時の注意点は「主観的エスカレーション(issue #31)」節の「issue #26 との共有面」を参照。
- **失敗経路は単一 sink に集約(重要)**: 実装役・対応役・reviewer のどの経路でも「前進不能 = need for human review sink 到達」で対称に扱う。reviewer も `escalate`(停止条件)に加え `invalid`(dispatch 結果失敗)を持ち、単一 sink をすり抜けない。個別ロールに独自の失敗処理(片方だけ有界停止・片方は無界ループ)を持たせない。書き込む事実 status だけがトリガーごとに異なる(「失敗経路(単一の need for human review sink)」節の一覧表を参照)。**実装役の `no_pr` はこの対称性の唯一の例外だったが、issue #26(P1 決定)で解消済み**(下記「実装役の `no_pr` の有界化(issue #26)」参照)。
- **対応役の無作業検知は escalate backstop に委ねる(意図的な既知の限界)**: 対応役だけは dispatch 結果失敗の即時検知分岐を持たない(最後の非対称)。subagent が **無作業/クラッシュでも test が元々緑なら `evidence_pass` → `waiting for review`** へ進む(偽の前進)。実装役(復旧検索)・reviewer(`invalid` 検知)が dispatch 失敗を即座に sink するのに対し、対応役の無作業だけ検知が **~3 round 遅延する**という latency の非対称が残る。ただし finding 未対応なら reviewer が同じ blocker を再検出 → `completed review` へ戻す往復が続き、**escalate backstop(round≥5 / blocker trend)が最終的に人間へ surface する**。これは bounded(`has_blocker=true` 維持で `clean_pass`=不正 merge には至らない)であり、walking skeleton では検知機構を足さず backstop に委ねる(作者の意図的判断)。実害(無作業 dispatch が頻発)が観測されたら follow-up で対応役の作業有無(`# PR Review Worker` コメント / commit の有無)検証を足す(対応役 flow の該当箇所にも同旨を明記済み)。
- **実装役の `no_pr` の有界化(issue #26・P1 決定で解消済み)**: 実装役 dispatch 後に PR が未作成(返答不正 + `Closes #N` 復旧検索 0 件)なら outcome=`no_pr` → route=skip で書込・副作用なく次 tick 再 dispatch される点は変わらないが、**issue #26 の「tick 冒頭 reconciliation」節の in-flight マーカー機構(締切 K=2 tick・リトライ上限 N=2)がこれを有界化する**。P1 決定(所有者判断・2026-07-14)により「無状態 tick では『完了して no_pr』と『まだ処理中』を区別できない」ため、`no_pr` は独立カウンタ(`no_pr_count`)を持たず、**締切超過(timeout・真の hang)と同じ `retry_count` に畳み込んで数える**。持続的な原因(issue が実装不能 / developer subagent が決定論的にクラッシュ)でも、最大 N=2 回のリトライ(計 3 dispatch)後は outcome=`timeout` として sink へ到達する。**本コマンドが掲げる「無界ループを残さない / 失敗経路を対称に扱う」不変条件の唯一の(文書化された)例外はこれで解消された**(旧版はこの段落で `no_pr` を無界の既知の限界と明記していたが、issue #26 の実装後は該当しない)。
  - **残る限界(issue #26 v1 のスコープ・意図的)**: (i) dispatch call 自体がセッションを止める**真の hang**は、`Agent` ツールにタイムアウト parameter が無い制約が変わらないため、リアルタイムには検知できない(marker が dispatch 直前に書かれているため、**人間がセッションを再起動した次の tick**で `TICK > deadline_tick` として事後検知される — tick を跨いだ persistent state による回復であり、hang 中のリアルタイム検知ではない)。(ii) `dispatchMarker`(`dispatched_tick`/`deadline_tick`/`retry_count`、および sink 通過後に追加される任意キー `notified`)は transient フィールドで、issue #68 で型/形の正を `plan-progress.schema.json` の `definitions.dispatchMarker` に **optional 宣言**した(検査対象外は維持 — `step.required` 非追加・`step` の `additionalProperties` 不変)が、この宣言を足しても `validate-plan-progress.py` の `--schema`/`--drift`・`tests/smoke/run-smoke.sh` の複製一致検査のいずれも marker の値(存在・妥当性)を検査対象にしない挙動は不変(壊れた/不整合なマーカーへの fail-closed 判定は `reconcile-dispatch-marker.py` 自身の責務であり、この判定ロジック自体は smoke `[9]` で網羅検証している。`notified` は script が読まない prose 専用の帳簿フィールドであり script の妥当性検査の対象外)。(iii) implementer/`timeout` の sink は PR が存在しないため `need for human review` ラベルを付与できず(`ambiguous` と同じ制約)、「無条件スキップ」は永続する `dispatchMarker` 自体が実装する — 人間の解除手段はラベル解除ではなく `dispatchMarker` の手動削除(「tick 冒頭 reconciliation」節参照)。(iv) `ambiguous` outcome 自体の再 dispatch 有界化は本 issue のスコープ外(手順 7 の原子書込で `dispatchMarker` を削除し、marker による有界化の対象外にする — 挙動は issue #26 以前と変わらない)。(v) K=2 tick / N=2 の値は校正根拠の無い best-effort(loop 間隔が実装役の想定所要より十分長い前提)であり、観測に応じた見直しは follow-up。
- **sink の出口を人間の意図と結線(issue #12 で実装済み)**: 「失敗経路(単一の need for human review sink)」節の**「sink の出口を人間の意図と結線」**を参照。reviewer/`escalate` は `pr.status="need for human review"` を書いてから sink するため、ラベル解除だけでは再 dispatch されない(status も人為的に戻す必要がある)。この結線の恩恵は `escalate` 経路のみで、`invalid`(dispatch 結果失敗)は引き続き無書込のまま(書ける確定事実が無いため)。
- **ラベル同期ロジックの複製(drift リスク)**: 本コマンドのラベル同期ロジック(「ルーティング判定」節の `label_action の実行`)は `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` 手順 6 の内容を単一書込の都合上複製している。将来どちらかの label 定義(色・説明・名称)を変更する場合は両ファイルを同時に更新すること(自動で同期されない、既知の drift リスク)。
- **developer(実装役・対応役)の dispatch prompt 外出し(issue #38・毎 tick の実効トークン削減)**: 両ロールの dispatch prompt 本文(旧版で本ファイルへ直接埋め込まれていた `> 「...」` の巨大な引用ブロック)を `${CLAUDE_PLUGIN_ROOT}/roles/developer-implementer.md` / `${CLAUDE_PLUGIN_ROOT}/roles/developer-responder.md` へ抽出した(pr reviewer 節が `${CLAUDE_PLUGIN_ROOT}/roles/pr-reviewer.md` を参照する既存パターンと同型)。抽出後は複製ではなく単一ソース化(旧「ラベル同期ロジックの複製」のような drift リスクは生じない)。**この参照ファイルは dispatch された subagent 自身が(自分の Read ツールで)読む設計であり、orchestrator 自身は読まない** — したがって当該ロールの dispatch が 0 件の tick では orchestrator はもとより誰もこれらのファイルを読まず、毎 tick の実効トークンが無条件に(dispatch の有無を判定する分岐無しで)削減される。実装役・対応役それぞれの evidence gate worktree 手続き(`git worktree add` の残骸掃除・実行・後始末)も、両ロールでほぼ同一だったロジックを `scripts/run-orchestrator-evidence-gate.sh` へ dedup 抽出した(こちらは全 tick で無条件に本体の行数を下げる。「developer(実装役)」節 手順 5・「developer(対応役)」節 手順 5 参照)。
- **委譲先の返り値は独立検証できない(正直な明記・意図的に塞がない。issue #37・欠落 7)**: pr reviewer の `has_blocker` / `escalate`、および 3 role 共通の `escalate_to_human` は、いずれも委譲先 subagent の自己申告であり、orchestrator 側で機械的に裏取りする手段が無い。evidence gate(`evidence.done` の独立再実行)は実装役・対応役の**作業結果**を独立検証しているが、reviewer の**判定そのもの**(diff を実際に見て finding を出したか)は検証できない — 捏造する reviewer が `clean_pass` を返せば `ready for merge` まで進んでしまう。緩和策は各ロール委譲プロンプト**冒頭**の「観測していないことを書くな。『エラー』と『処理中』を区別せよ。分からないことは未観測と書け」という L1 文言のみで(「dispatch 先ごとの委譲方式」節 各ロールの冒頭注記を参照)、実測では捏造後に自己訂正が起きたことはあるが、これは検証の代替ではない。`.harness/CLAUDE.harness.md` が明記する「doer ≠ judge の実質はほぼ別セッションの PR reviewer が実際の diff/状態を初見で読むこと単独に依存する」という設計は、その reviewer 自身のレイヤでは担保されないまま残る既知の限界であり、現時点で構造的な解決策は無い(塞げないものを塞いだことにしない)。
- **作業レポート代筆(`reports[]`)は machine-enforce されていない(既知のギャップ・issue #52 症状2)**: 「作業レポートの代筆」節の配線は、実装役 / 対応役 / pr reviewer の 3 ロールについて `ledger_write` 適用直後に `reports[]` へ追記する経路を追加するが、これは `tests/smoke/run-smoke.sh` の検証対象ではない(schema/drift 検証の対象外という `.harness/CLAUDE.harness.md` の既存の best-effort 方針をそのまま引き継ぐ)。したがって配線コード自体に typo や欠落があっても smoke は緑のまま通りうる — 発見は目視レビューか、ダッシュボードの `WorkFeed` で report が欠落していることの事後観測に依存する。issue reviewer / issue review worker は issue #88 で本コマンドが dispatch するようになったため `reports[]` 代筆対象に含めた(「作業レポートの代筆」節の表)。`pr review worker`(独立 skill)/ orchestrator 自身の 2 ロールは引き続き配線対象外であることを同表で明示した(DoD (iv') が要求する「7 ロール各々の代筆点の名指し」は、この「対象外である」という明記も含めて満たす)。
