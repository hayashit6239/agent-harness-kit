# issue 起票書式 — タイトル prefix・本文構成・起票前チェックリスト

導入先 repo に依らない **issue の起票書式 (規約)**。タイトル prefix の選定フロー・Problem / Context / Alternatives (+ Implementation Scope) の本文構成・起票前チェックリスト・HEREDOC 実行例をここで定義する。role 横断規約のため `rules/` に置き (`${CLAUDE_PLUGIN_ROOT}/rules/` 経由で配布)、PM ロール (#107)・機械的兆候からの自動起票 (#102)・人間の起票が共通参照する。

tree の構造規約 (層・prefix 語彙の唯一の正・ラベル意味論・帰属と逸脱) は別ファイル `rules/issue-tree.md` にある。**prefix 語彙 13 種の唯一の正は `issue-tree.md` §2** であり、本ファイルはそれを参照する (重複定義を避ける)。本ファイルは「どの prefix を選ぶか」の判断フローと「本文をどう書くか」に集中する。

この規約の改定は**人間の判断**による。

---

## このスキルの目的

- タイトルの prefix だけで issue の種別が一目で分かる状態をつくる。
- 本文の構造を揃え、レビュワーが「問題 → 背景 → 選択肢」の順で把握できるようにする。
- git log の可読性: この kit の既定 merge 方式は **merge commit** (レビュー往復の記録を潰さないため squash は非既定・`.harness/CLAUDE.harness.md`「終端の記録と merge 代行」節)。したがって「squash で commit title に prefix が残る」ことは目的にしない。prefix は **issue 一覧・検索・種別判別**のために付ける。

### ラベルとの役割分担 (種別は prefix・Label は別信号)

種別 (feat / fix / …) は **prefix で表す**。GitHub Label は種別ではなく、`issue-tree.md` §5 が定義する **3 直交信号 (帰属 = phase ラベル / 着手指示 = `discover` / 状態 = `ready for merge` 等)** を表す。「Label で種別を表す」ことはしない (種別 = prefix / 帰属 = phase ラベル / 着手指示 = discover / 状態 = 状態ラベル、と信号を分ける)。

---

## タイトル規約

### 形式

```
<prefix>(<scope>): <subject>
```

- `prefix`: **必須**。`issue-tree.md` §2 の 13 種から内容にマッチするものを 1 つ選ぶ (語彙の正はそちら)。
- `scope`: 任意。変更領域を括弧内で示す (例: `feat(rules):`, `fix(orchestrate):`)。無理に付けると可読性が落ちるので迷ったら省略。
- `subject`: 「何を・どうするか」が分かる簡潔な短文。

### 内容から prefix を選ぶ判断フロー

発話や会話文脈から**上から順に**当てはめて最初にマッチしたものを採用する (prefix の意味は `issue-tree.md` §2):

1. **障害・不具合・期待通り動かない話題か？** → `fix`
2. **新しい機能・仕組みを作る話題か？** → `feat`
3. **結論が出ておらず意見を集めたいか？** → 方針を決めたい / 選択肢を並べたい → `discuss`
4. **既存の何かの変更か？**
   - 意味に影響しないコード整理 → `refactor` / 速度改善 → `perf` / ドキュメントのみ → `docs`
   - テストのみ → `test` / CI 設定のみ → `ci` / ビルド設定・依存 → `build`
5. **上記どれにも当てはまらない雑務** → `chore`
6. **複数 issue を束ねる親** → `epic` (中間構造層) / **ロードマップ正本** → `rfc` (最上位・単一インスタンス)
7. **過去変更の取り消し** → `revert`

複数該当するケースは**最も主要な変化**を prefix にする (例: 「CI を直してついでにドキュメント更新」は `ci`)。

### scope の選び方

リポジトリ既存の issue / commit で使われている scope 語彙を踏襲する (`gh issue list --limit 20` や `git log --oneline -20` で最近の scope を参照してから決める)。この kit 自身なら `rules` / `orchestrate` / `dashboard` / `smoke` 等が実例。導入先ではそのコード領域・機能・インフラの語彙に読み替える。

---

## 本文テンプレート

issue の種類によらず、**"Problem / Context / Alternatives" の 3 節構成**を基本とする。レビュワーが「何が問題か → なぜそれが問題か → どう解くか」の順で読めるようにするため。

### 基本テンプレート

```markdown
## Problem (課題)

<何が問題か。事象と影響を具体的に。1〜3 段落>

## Context (前提条件 / 制約 / 経緯)

<なぜその課題が発生しているか。背景情報・制約・関連する先行議論・再現条件・該当コード箇所など>

### <必要なら小見出しで分割>

## Alternatives (選択肢)

<取りうる複数の解決方針をそれぞれメリット / デメリット付きで列挙>

### A. <案のタイトル>

| 項目 | 内容 |
|---|---|
| メリット | ... |
| デメリット | ... |
| 変更範囲 | ... |

### B. <案のタイトル>

...

## Implementation Scope (実装範囲)

<この issue から PR を的確に切るための実装範囲。file/関数レベルの粒度で、PR 作者が「どこを触り何をテストするか」を迷わない程度に書く。実装系 issue (`feat` など) でのみ使い、References の直前に置く>

### <レイヤ 1: 例 Core (TDD)>

- **`<型/関数>`**: <責務を 1 行>。<テスト観点 (境界・空・異常)>

### テスト境界 / スコープ外 / DoD / 依存

- テスト境界: 実行テストで閉じる範囲と手動検証に回す範囲を 1 行ずつ
- スコープ外: 別 issue に送るもの (意図的除外を明記)
- DoD: 受け入れ条件 (検証コマンド・期待挙動)
- 依存: 前提となる issue / PR (`#NNN`)

## References (参考)

- <リンク・関連 issue・該当コード行>
```

### tree への帰属を明示する (epic 配下の issue)

epic スコープ内の issue を起票するときは、`issue-tree.md` §3 の帰属 3 シグナルを整合させる:

- **phase ラベル**を付ける (`roadmap.json` に登録済みの phase 名)。
- 本文に **`Part of #<epic>`** を書く (`issue-tree.md` §4.2 のリテラル唯一形 — 先頭大文字 `Part of ` + `#` + 連続数字。表記ゆれ不可)。References 節や冒頭サマリに置くのが読みやすい。
- 起票後 **GitHub sub-issue** として epic に配線する。

orphan (epic 非スコープの単発作業) は 3 シグナルいずれも付けなくてよい (`issue-tree.md` §3.4 — orphan は逸脱ではない)。

### Implementation Scope を入れるかの判断

`feat` など **PR 実装を伴う issue** では、Alternatives で方針を決めた後に Implementation Scope で「その方針を具体的に何を触ってどう確かめるか」まで降ろす。Alternatives が*方針の選択*なのに対し、Implementation Scope は*選んだ方針の実装契約*。

- **入れる**: `feat` / `perf` / `refactor` など、PR で実装する issue。粒度は file/関数レベル。
- **任意 / 省略**: `discuss`（方針未確定で実装範囲が書けない）、`docs` / `chore` / `test` など軽量で自明なもの。
- 位置は **References の直前** (Problem → Context → Alternatives → Implementation Scope → References の順)。

### テンプレが過剰なケース

再現手順が明確で修正方法も一意な単純バグなら、`## Problem` / `## Steps to Reproduce` / `## Expected / Actual` の軽量版でよい。重要なのはテンプレ遵守そのものではなく**レビュワーが 1 分で把握できる構造**なので、過剰適用は避ける。迷ったら基本テンプレ優先。

---

## 起票前チェックリスト

1. 既存 issue で同じ話題がないか `gh issue list --search "<キーワード>"` で確認。
2. prefix が内容と噛み合っているか再読 (`issue-tree.md` §2)。
3. Problem が**事象だけでなく影響・動機**を含んでいるか。
4. Alternatives を書いたなら**少なくとも 2 案**提示しているか (1 案しかないなら Alternatives 節は不要で Context に統合するか、prefix を `discuss` に寄せる)。
5. コードや run URL を参照している場合、**file_path:line_number 形式 or 完全 URL** で書いているか。
6. epic スコープ内なら帰属 3 シグナル (phase ラベル / `Part of #<epic>` / sub-issue 配線) を整合させたか。

---

## 実行 (HEREDOC)

`gh issue create --title "..." --body "..."` で起票する。本文は HEREDOC で渡すとエスケープ問題を避けられる:

```bash
gh issue create \
  --title "<prefix>(<scope>): <subject>" \
  --body "$(cat <<'EOF'
## Problem

...

## Context

...

## Alternatives

### A. ...

### B. ...

## References

- ...
EOF
)"
```

HEREDOC 内のバッククォートや `$` はシングルクォート `'EOF'` のおかげでエスケープ不要。逆にダブルクォート `"EOF"` を使うと展開されるので注意。

---

## やってはいけないこと

- prefix なしタイトルで起票する — 種別が分からず検索性が落ちる。
- 本文を 1 行だけで起票する — レビュワーが文脈を再構築できない。
- Alternatives に自分の推しだけ 1 案書く — それは Alternatives ではなく Proposal。prefix を `discuss` にするか Alternatives 節を省く。
- **GitHub Label で種別を表そうとする** — 種別は prefix。Label は `issue-tree.md` §5 の 3 直交信号 (帰属 / 着手指示 / 状態) を表す別軸の信号。
- `Part of #<epic>` を表記ゆれで書く (`part of`・全角 `＃`・`Part of#106` 等) — `issue-tree.md` §4.2 のリテラル唯一形以外は帰属信号として拾われない。
- ユーザーの指示が簡潔 (「issue 作って」等) でも規約を無視して雑に起票する — 簡潔指示こそこの規約で補完する対象。

---

## 任意の慣行: 起票後のセッションリネーム

起票したセッションを `issue-<番号>-<slug>` 形式にリネームしておくと、後でセッションを掘り起こすとき issue 番号で識別でき、worktree ブランチ名 (`feat/issue-<番号>-<slug>`) と表記が揃って issue → worktree → PR → commit log を一直線で追える。**これは Claude Code の UI コマンド `/rename` に依存する慣行**であり (assistant からは実行できずユーザーがタイプする必要がある)、kit の強制ではなく**任意の慣行**として言及する。導入先が Claude Code 以外なら該当しない。
