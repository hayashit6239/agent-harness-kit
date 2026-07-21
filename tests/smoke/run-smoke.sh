#!/usr/bin/env bash
# agent-harness-kit smoke テスト — LLM 不要・決定論的。
#
# 1. fixture (捨て repo) に templates を複製し、evidence.test を実コマンドで埋めた
#    plan-progress.json を組み立てる (drift 検査が repo ルートを解決できるよう git init する)
# 2. validate --schema が exit 0 + 検査規則 (check_claims) の import 直接呼出が違反を検出
# 3. evidence.test の実行が exit 0
# 4. 失敗パターン群がすべて non-zero + 期待する ::error:: 文言で落ちる
#    (内訳は FAIL_CASES 表と個別ケース節を参照 — ここに列挙しない。列挙は乖離の温床)
# 5. drift の正系 (stub gh が台帳と一致) が exit 0 / gh 実行失敗が drift と区別されて fail する /
#    gh が途中で失敗しても蓄積済みの検出済み drift が全件出力される /
#    gh が非オブジェクト JSON (null) を返したら実行エラーとして fail し蓄積 drift も失わない
# 6. reaggregate-has-blocker (has_blocker 再集計) の単体判定が期待通り (fail-closed 境界を含む)
# 7. evaluate-stop-condition (停止条件 round_flag/trend_flag/escalate) の単体判定が期待通り
#    (round 上限 / blocker trend / trend の and/or 判別 (片側成立) / 履歴不足時の fail-open /
#    has_blocker=false 抑止 / round<3 短絡 / round_flag+trend_flag 同時成立 / round=3 境界 /
#    不正入力 exit 2 の境界を含む)
# 8. decide-orchestrator-route (orchestrator ルーティング判定) の単体判定が期待通り
#    (決定表の全 role×outcome 16 行を網羅 = reviewer の invalid 分岐 + implementer の
#    timeout 分岐 (issue #26) + reviewer/responder の timeout 分岐 (issue #71・reviewLock hang) +
#    3 role 共通の主観的エスカレーション (issue #31・subjective_escalate) の存在を機械保証 /
#    網羅ケース数と DECISION_TABLE のエントリ総数を突き合わせる行数ガード /
#    不正入力 exit 2 の境界 /
#    A1 (issue #50): route=sink への解決には observation (観測した事実) が必須で、
#    無ければ fail-closed で exit 2 になる境界・非 sink outcome は observation 無しでも
#    従来通り成立する境界を含む)
# 9. reconcile-dispatch-marker (dispatch in-flight マーカーの tick 冒頭 reconciliation 判定・
#    issue #26) の単体判定が期待通り (marker 不在→eligible / 進捗確認→clear / 締切未到達→wait /
#    締切超過でリトライ余地あり→redispatch(retry_count 加算) / リトライ上限到達→sink /
#    壊れた・不整合な marker→sink(fail-closed。progressed=true でも優先) の境界、
#    妥当性検証の各項目 (型崩れ・負値・deadline<dispatched・dispatched>current の未来矛盾)、
#    不正入力 exit 2 の境界を含む)。加えて選別(jq) 実装役 / 対応役 / pr reviewer 各ブロックの
#    dispatchMarker / reviewLock(issue #37)ガードと、issue reviewer / issue review worker ブロックの
#    issueReviewLock + githubState ガード(issue #88・round1 🔴3: close 済み / number 未確定 issue の
#    誤 dispatch を防ぐ PR 側対称ガード)を、commands/harness-orchestrate.md と同一の
#    jq を直接実行して固定する。同じ実装役ブロックの jq で dependsOn ガード(issue #51・
#    スループット)の 6 種の境界(全依存終端 / 一部未終端 / 空配列 / キー欠損 /
#    存在しない id(fail-closed) / 依存先が discuss 型)と、DoD (ii-a)(依存の無い step が
#    同一 tick で 2 件以上 eligible として返る)も固定する。
#    さらに「ルーティング判定」節の ledger_write 適用手続き(marker 削除 + ledger_write の原子適用。
#    issue #37 で削除対象フィールド名を汎化する 6 番目の引数 `<marker_field>` を追加)を同一ロジックで
#    直接実行し、lw=null でも clear_marker=true なら marker 単独削除される・lw 非 null 時の原子適用・
#    clear_marker 省略時は marker 不変・lw=null かつ clear_marker 省略時は no-op・marker_field 省略時は
#    既定 "dispatchMarker" を消す(実装役の後方互換)・marker_field="reviewLock" を渡すとそちらを消す
#    (pr reviewer / 対応役)、の 6 ケースを固定する
# 10. kit 自身の checkout (.harness/ がある場合) なら templates と複製の diff が空
#    (templates/ の全ファイルが隠しファイル込み (dotglob) でペア列挙 + 既知除外で
#    カバーされていることも検査)
# 11. commands/*.md から抽出した共通 script 群 (report-ledger-status.sh: 台帳検証の自己申告・
#    #2/#7 で抽出 / run-orchestrator-evidence-gate.sh: evidence gate の worktree 手続き・
#    issue #38 で dedup 抽出) の bash -n 構文チェック (shellcheck があれば追加)。ネットワーク呼出
#    (gh api / gh pr view / git fetch) を伴う実処理は smoke 対象外 (手動確認)
# 12. detect-dispatch-collision (実装役 dispatch 候補のファイル衝突検知・issue #37) の単体判定が
#    期待通り (衝突なし / 全件衝突 / 部分衝突(推移閉包) / 独立した複数組の衝突 /
#    Implementation Scope 欠落(files 空配列)時の fail-closed / 候補 0 件 / 単一候補 の境界、
#    不正入力 exit 2 の境界を含む)。加えて issue #55(恒久衝突ペアの直列化)の grouping 層アサート:
#    wait 占有者 inject で新規候補が同一 group 入り(safe 非出現)/ 占有者 inject の有無で safe が入力差により
#    反転する負の自己検証 / redispatch×新規 eligible が同一ファイルで 1 group(経路A)/ 占有者とも他候補とも
#    非共有の redispatch は safe / fail-closed(files=[])単独候補は占有者が居ても groups に落ち代表選出の
#    母集団に入らない(+ files 非空なら safe に反転する負の自己検証)を固定する。加えて **その下流の
#    select-dispatch-representatives(恒久衝突ペアの代表選出述語・issue #55 を issue #87 で prose から抽出)**
#    の単体判定: safe の dispatch/占有者 inject 除外(負の自己検証)/ 占有者ゼロ group から step id 昇順
#    min id 代表 1 件(tie-break 入力順非依存)/ 占有者を含む group から dispatch 0(負の自己検証で占有者
#    presence が load-bearing)/ fail-closed 単独は常に持ち越し(負の自己検証で配置が load-bearing)/ kind
#    非依存代表 / 複合入力の partition 不変条件 / kind 網羅ガード / 不正入力 exit 2 を固定する。**代表選出
#    規則そのものは script 化済み(検証する)。残る非検証 seam は各候補の kind の解決(占有者判定は台帳 state
#    を要する・🟡4)であり、機械的な before/after 等価検証は不可能(#37 前例)**。
# 13. 共通コア(禁止事項)の単一ソース + 各 dispatch ファイル冒頭 ★最重要★ ブロックへの presence 検査
#    (issue #52 Phase B・症状1・A3)。CANONICAL_CORE(この script が唯一の単一ソース)の 5 行
#    (fork / SendMessage / gh auth switch / 台帳保護 / 観測禁止)を、6 dispatch ファイル
#    (実装役 / 対応役 / pr reviewer / collectors / issue reviewer / issue review worker・issue #88)の
#    冒頭 ★最重要★ ブロックが逐語部分一致で含むことを
#    アサート(round2 🟡1(a): 行の脱落だけでなく文言 drift も捕捉するため keyword 一致にしない)。
#    canonical 行を 1 本抜いたコピーが fail 判定になる負のケース(アサートが vacuous でないことの
#    自己検証)を含む。**塞ぐのは「単一ソースからの脱落 / 文言 drift」のみ**で、subagent の runtime
#    obedience(DoD (v))と「共通コア + ロール固有項目 *のみ* を持つ」排他(round2 🟡3)は構造的に
#    検証不能 = best-effort(人間レビュー担保)。
# 14. issue #89: commands/harness-orchestrate.md の /goal 構造化モード(pr / issue)雛形の機械検証。
#    (a) DoD-2 整合ドリフトガード: 凍結停止条件マニフェスト(FROZEN-STOP-CONDITIONS)の outcome
#        トークン集合が decide-orchestrator-route.py の route=="sink" outcome(11)+ git-status-guard
#        (decision script 外・1)= 12 と過不足なく一致する([8] 型の件数算出を route==sink に絞る)。
#        トークンを 1 本抜いたコピーが不一致になる負の自己検証([13] 型)を含む。
#    (b) DoD-3 パース単体: MODE-DETECTION-MANIFEST の regex(単一ソース)を bash =~ で適用し、strict
#        受理 / 現行自由文例 `issue #42 を…` の非誤分類(判定順の核)/ near-miss(裸キーワード・二重
#        空白・末尾空白)検出を固定する。
#    (c) DoD-1 決定性(構造的担保 + fixture lock): verbatim 雛形(両モード雛形 / 9 文 <STOP> /
#        merge 代行"明示指示"条項 / round3 で確定した issue 相の正直な注記)の presence 検査で drift を塞ぐ。
# 15. decide-enqueue-steps (discover→enqueue の純 enqueue/dedup 判定・issue #78) の単体判定が
#    期待通り (候補 issue.number + 現台帳 steps → 追加 step / no-op)。単一追加(DoD 1 件追加)/
#    冪等 no-op(既存 issue.number 一致 = 二重登録なし)/ batch 採番(max+1, max+2 逐次加算)/
#    batch 内重複 / 空入力 = no-op / 終端 step 突合(全 step・終端後再ラベル no-op)/ 起点 id /
#    非数値 id 除外 の境界と、不正入力 exit 2 の境界を含む。network discover(gh issue list
#    --label)は smoke 対象外=手動確認 (round2 🟡1)。
# 16. すべて通れば "SMOKE OK" を出して exit 0
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATES="$ROOT/templates"
FIXTURE="$ROOT/tests/smoke/fixtures/target-repo"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "SMOKE FAIL: $*" >&2
  exit 1
}

# exit 非 0 と、出力に期待する ::error:: 文言が含まれることを両方 assert する
# $1=ラベル $2=期待する部分文字列 $3...=実行するコマンド
expect_fail_with() {
  local label="$1" want="$2"
  shift 2
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$label: 成功してしまった (non-zero を期待)"
  fi
  if ! grep -qF "$want" <<< "$out"; then
    fail "$label: 期待文言が出力に無い (want: ${want} / got: ${out})"
  fi
}

# --- 1. fixture を複製し .harness/ を組み立てる -----------------------------
cp -R "$FIXTURE" "$TMP/target-repo"
REPO="$TMP/target-repo"
git init -q "$REPO" # validator は gh を台帳のある git repo ルートで実行するため、fixture も git repo にする
HARNESS="$REPO/.harness"
mkdir -p "$HARNESS"
cp "$TEMPLATES/plan-progress.schema.json" "$HARNESS/"
cp "$TEMPLATES/validate-plan-progress.py" "$HARNESS/"

VALIDATOR="$HARNESS/validate-plan-progress.py"
PLAN="$HARNESS/plan-progress.json"

# init.json を元に、evidence.test を fixture の実コマンドで埋めた台帳を組み立てる
python3 - "$TEMPLATES/plan-progress.init.json" "$PLAN" <<'PY'
import datetime
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    d = json.load(f)
d["project"] = "smoke-fixture"
d["updatedAt"] = datetime.date.today().isoformat()
d["evidence"]["test"] = "make test"
d["evidence"]["done"] = "make test"
with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
echo "[1/17] fixture + .harness/ を組み立てた: $REPO"

# --- 2. schema 検証: exit 0 を期待 ------------------------------------------
python3 "$VALIDATOR" --schema "$PLAN" \
  || fail "正常な plan-progress.json で --schema が失敗した"
echo "[2/17] --schema exit 0"

# validator を import して検査規則を直接呼ぶ (直接テスト可能性の固定化 — 構造の退行検知)
python3 - "$VALIDATOR" <<'PY_DIRECT'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("vpp", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
errors = []
m.check_claims(errors, {"number": 1, "status": "created pr", "githubState": None}, "steps[direct].pr", "pr")
assert errors, "check_claims の直接呼出が主張規則違反 (number⇒githubState) を検出しない"
# format_error の '::error:: ' prefix 契約を固定する (FAIL_CASES は本文の部分一致のみで、
# prefix が壊れても緑のまま GitHub Actions の PR アノテーション表示だけが静かに消えるため)
assert errors[0].startswith("::error:: "), (
    f"format_error の '::error:: ' prefix 契約が破れている (got: {errors[0]!r})")
assert "があるのに githubState が null" in errors[0], (
    f"期待する規則の文言が無い (got: {errors[0]!r})")  # 規則単位の固定化 (FAIL_CASES と同じ流儀)
PY_DIRECT
echo "[2/17] 検査規則の直接呼出 (import) OK"

# --- 3. evidence.test 実行: exit 0 を期待 ------------------------------------
TEST_CMD="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["evidence"]["test"])' "$PLAN")"
( cd "$REPO" && eval "$TEST_CMD" ) \
  || fail "evidence.test ($TEST_CMD) が exit 0 で終わらなかった"
echo "[3/17] evidence.test ($TEST_CMD) exit 0"

# --- 4. 失敗パターン群 (すべて non-zero + 期待文言を期待。件数はここに書かない — 乖離の温床) --------------------

# 正常台帳に step を 1 つ足しつつ、モードに応じて壊した variant を作る
make_broken() { # $1=出力パス $2=変異モード
  python3 - "$PLAN" "$1" "$2" <<'PY'
import json
import sys

src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8") as f:
    d = json.load(f)
step = {
    "id": "S1",
    "title": "smoke step",
    "issue": {"number": None, "status": None, "githubState": None},
    "pr": {"number": None, "status": None, "githubState": None},
}
if mode == "enum":
    # (i) status に enum 外の値
    step["pr"] = {"number": 1, "status": "banana", "githubState": "open"}
elif mode == "consistency":
    # (ii) number:null なのに status:"created pr"
    step["pr"] = {"number": None, "status": "created pr", "githubState": None}
elif mode == "evidence":
    # (iii) ready 系 status ありで evidence.test:null
    step["pr"] = {"number": 1, "status": "ready for merge", "githubState": "open"}
    d["evidence"]["test"] = None
elif mode == "drift":
    # (iv) 台帳は open と主張 (mismatch 用 stub gh は MERGED を返す)
    step["pr"] = {"number": 1, "status": "created pr", "githubState": "open"}
elif mode == "statusenums":
    # (v) 旧形式の statusEnums 複製が台帳に残っている (再導入防止ガードに掛かる)
    d["statusEnums"] = {"issue": [None, "created issue"], "pr": [None, "created pr"]}
elif mode == "ghstate-null":
    # (vi) number があるのに githubState が null (drift の一方向判定をすり抜ける穴)
    step["pr"] = {"number": 1, "status": "created pr", "githubState": None}
elif mode == "terminal-mismatch":
    # (vii) 終端 status "merged pr" なのに githubState が open
    step["pr"] = {"number": 1, "status": "merged pr", "githubState": "open"}
elif mode == "isdraft":
    # (ix) 台帳は isDraft:false と主張 (mismatch 用 stub gh は isDraft:true を返す)
    step["pr"] = {"number": 1, "status": "created pr", "githubState": "open", "isDraft": False}
elif mode == "issue-consistency":
    # (x) issue.number:null なのに issue.status:"created issue"
    step["issue"] = {"number": None, "status": "created issue", "githubState": None}
elif mode == "issue-terminal":
    # (xi) 終端 status "closed issue" なのに issue.githubState が open
    step["issue"] = {"number": 1, "status": "closed issue", "githubState": "open"}
elif mode == "issue-drift":
    # (xii) 台帳は issue open と主張 (mismatch 用 stub gh は CLOSED を返す)
    step["issue"] = {"number": 1, "status": "created issue", "githubState": "open"}
elif mode == "evidence-blank":
    # (xiii) ready 系 status ありで evidence.test が空文字列 (null 素通しの双子経路)
    step["pr"] = {"number": 1, "status": "ready for merge", "githubState": "open"}
    d["evidence"]["test"] = ""
elif mode == "dependson-missing":
    # (xvi) dependsOn (issue #51) が存在しない step id を指している (authoring-time fail-closed 検知。
    # S1 が唯一の step のため "NOPE" はどの step の id とも一致しない)
    step["dependsOn"] = ["NOPE"]
elif mode == "dependson-selfloop":
    # (xvii) dependsOn (issue #57 round 2 🔴1) が自分自身を指している (self-loop の循環参照)。
    # S1 が唯一の step のため "S1" は自分自身の id と一致する
    step["dependsOn"] = ["S1"]
else:
    raise SystemExit(f"unknown mode: {mode}")
d["steps"] = [step]
with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
}

# drift 系ケース共通の gh 代役 (stub): PATH 先頭に置くと、台帳と食い違う固定 JSON を返す。
# drift 系の台帳は git repo 内 ($HARNESS) に置く (validator が台帳の repo ルートで gh を実行するため)
STUB_MISMATCH="$TMP/stub-mismatch-bin"
mkdir -p "$STUB_MISMATCH"
cat > "$STUB_MISMATCH/gh" <<'SH'
#!/usr/bin/env bash
# smoke 用 gh 代役: 台帳と食い違う固定 JSON を返す
case "$1 $2" in
  "pr view")    echo '{"state":"MERGED","isDraft":false}' ;;
  "issue view") echo '{"state":"CLOSED"}' ;;
  *)            echo '{}' ;;
esac
SH
chmod +x "$STUB_MISMATCH/gh"

# 表駆動の失敗パターン: 1 行 = 「ラベル|変異モード|検査モード|期待文言」。
#   検査モード: schema = --schema で検査 / drift = STUB_MISMATCH を PATH 先頭に置いた --drift で検査
# 標準的な変異ケースの追加手順 (2 箇所だけ): ① make_broken に変異の elif を 1 つ足す
# ② この表に 1 行足す — 直後のループが make_broken → expect_fail_with → echo を一括で行う
FAIL_CASES=(
  "(i) enum 逸脱|enum|schema|steps[S1].pr.status: enum 外の値"
  "(ii) 整合規則違反|consistency|schema|number が null なのに status が 'created pr'"
  "(iii) evidence-gate|evidence|schema|evidence.test が null"
  "(iv) drift 食い違い|drift|drift|台帳は 'open' だが GitHub (PR #1) は 'merged'"
  "(vi) githubState null|ghstate-null|schema|number (1) があるのに githubState が null"
  "(vii) 終端不整合|terminal-mismatch|schema|status が \"merged pr\" なのに githubState が 'open'"
  "(x) issue 整合規則違反|issue-consistency|schema|number が null なのに status が 'created issue'"
  "(xi) issue 終端不整合|issue-terminal|schema|status が \"closed issue\" なのに githubState が 'open'"
  "(xii) issue drift 食い違い|issue-drift|drift|台帳は 'open' だが GitHub (issue #1) は 'closed'"
  "(xiii) evidence-gate 空文字列|evidence-blank|schema|evidence.test が null または空白のみ"
  "(xiv) --drift 単独の主張規則違反|ghstate-null|drift|number (1) があるのに githubState が null"
  "(xvi) dependsOn 存在しない id (issue #51)|dependson-missing|schema|存在しない step id を指している"
  "(xvii) dependsOn self-loop 循環 (issue #57 round 2)|dependson-selfloop|schema|dependsOn に循環参照がある"
)

for row in "${FAIL_CASES[@]}"; do
  IFS='|' read -r label mode checkmode want <<< "$row"
  case "$checkmode" in
    schema)
      broken="$TMP/broken-$mode.json"
      make_broken "$broken" "$mode"
      expect_fail_with "$label" "$want" \
        python3 "$VALIDATOR" --schema "$broken"
      ;;
    drift)
      broken="$HARNESS/broken-$mode-ledger.json"
      make_broken "$broken" "$mode"
      expect_fail_with "$label" "$want" \
        env PATH="$STUB_MISMATCH:$PATH" python3 "$VALIDATOR" --drift "$broken"
      ;;
    *)
      fail "FAIL_CASES の検査モードが不正 ($checkmode): $row"
      ;;
  esac
  echo "[4/17] $label -> non-zero + 期待文言"
done

# (xviii) dependsOn A⇄B 循環 (issue #57 round 2 🔴1): 2 step にまたがる循環は make_broken の
#         「S1 単独 step」の型に収まらないため、表に入れず個別に台帳を組み立てる。
#         A.dependsOn=["B"] / B.dependsOn=["A"] は「存在しない step id」チェックだけでは
#         検知できず (B も A も実在する)、有向グラフの循環検知でのみ拾える境界
CYCLE_AB_PLAN="$TMP/broken-dependson-cycle-ab.json"
python3 - "$PLAN" "$CYCLE_AB_PLAN" <<'PY'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    d = json.load(f)
d["steps"] = [
    {"id": "A", "title": "cycle A",
     "issue": {"number": None, "status": None, "githubState": None},
     "pr": {"number": None, "status": None, "githubState": None},
     "dependsOn": ["B"]},
    {"id": "B", "title": "cycle B",
     "issue": {"number": None, "status": None, "githubState": None},
     "pr": {"number": None, "status": None, "githubState": None},
     "dependsOn": ["A"]},
]
with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
expect_fail_with "(xviii) dependsOn A⇄B 循環 (issue #57 round 2)" \
  "dependsOn に循環参照がある" \
  python3 "$VALIDATOR" --schema "$CYCLE_AB_PLAN"
echo "[4/17] (xviii) dependsOn A⇄B 循環 (issue #57 round 2) -> non-zero + 期待文言"

# --- 以下は形が特殊で表に入れない個別ケース (無理に畳むと可読性が落ちる)。
#     番号は据え置きのため、出力順は表 → 個別の順になり通し番号どおりではない ---

# (v) statusEnums 残存 (再導入防止ガード): 変異が step への標準変異でなく
#     台帳トップレベルへのキー追加のため、表に入れず個別に残す
make_broken "$TMP/broken-statusenums.json" statusenums
expect_fail_with "(v) statusEnums 残存" \
  "台帳に statusEnums を置かない" \
  python3 "$VALIDATOR" --schema "$TMP/broken-statusenums.json"
echo "[4/17] (v) statusEnums 残存 -> non-zero + 期待文言"

# (viii) literal-guard: 壊れ schema の配置 (台帳と同じディレクトリ) が必要なため、表に入れず個別に残す。
#        schema 複製から "ready for merge" を取り除いた壊れ schema を
#        台帳と同じディレクトリに置いて起動 (validator は台帳側の schema を優先解決する)
LITDIR="$TMP/literal-guard"
mkdir -p "$LITDIR"
cp "$PLAN" "$LITDIR/plan-progress.json"
python3 - "$HARNESS/plan-progress.schema.json" "$LITDIR/plan-progress.schema.json" <<'PY'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    schema = json.load(f)
schema["definitions"]["prStatus"]["enum"].remove("ready for merge")
with open(dst, "w", encoding="utf-8") as f:
    json.dump(schema, f, ensure_ascii=False, indent=2)
PY
expect_fail_with "(viii) literal-guard" \
  "literal-guard" \
  python3 "$VALIDATOR" --schema "$LITDIR/plan-progress.json"
echo "[4/17] (viii) literal-guard -> non-zero + 期待文言"

# (ix) isDraft drift: 共通の STUB_MISMATCH では表現できない専用 stub (state は台帳と一致し
#      isDraft だけ食い違う) が必要なため、表に入れず個別に残す。
#      台帳は isDraft:false、stub gh は state 一致 (OPEN) だが isDraft:true
STUB_DRAFT="$TMP/stub-draft-bin"
mkdir -p "$STUB_DRAFT"
cat > "$STUB_DRAFT/gh" <<'SH'
#!/usr/bin/env bash
# smoke 用 gh 代役: state は台帳と一致、isDraft だけ食い違う固定 JSON を返す
case "$1 $2" in
  "pr view")    echo '{"state":"OPEN","isDraft":true}' ;;
  "issue view") echo '{"state":"OPEN"}' ;;
  *)            echo '{}' ;;
esac
SH
chmod +x "$STUB_DRAFT/gh"

ISDRAFT_PLAN="$HARNESS/isdraft-ledger.json"
make_broken "$ISDRAFT_PLAN" isdraft
expect_fail_with "(ix) isDraft drift" \
  "台帳は False だが GitHub (PR #1) は True" \
  env PATH="$STUB_DRAFT:$PATH" python3 "$VALIDATOR" --drift "$ISDRAFT_PLAN"
echo "[4/17] (ix) isDraft drift -> non-zero + 期待文言"

# --- 5. drift の正系 / gh 実行失敗の区別 --------------------------------------

# このセクションで使い回す drift 台帳 (PR #1 を "open" と主張する step を持つ) を用意する
DRIFT_PLAN="$HARNESS/drift-ledger.json"
make_broken "$DRIFT_PLAN" drift

# 正系: stub gh が台帳と一致する状態 (OPEN) を返す -> exit 0
# (fatal や検査ロジックの壊れで「たまたま non-zero」になっていないことの保証)
STUB_MATCH="$TMP/stub-match-bin"
mkdir -p "$STUB_MATCH"
cat > "$STUB_MATCH/gh" <<'SH'
#!/usr/bin/env bash
# smoke 用 gh 代役: 台帳と一致する固定 JSON を返す
case "$1 $2" in
  "pr view")    echo '{"state":"OPEN","isDraft":false}' ;;
  "issue view") echo '{"state":"OPEN"}' ;;
  *)            echo '{}' ;;
esac
SH
chmod +x "$STUB_MATCH/gh"
env PATH="$STUB_MATCH:$PATH" python3 "$VALIDATOR" --drift "$DRIFT_PLAN" \
  || fail "drift 正系 (stub gh が台帳と一致) で --drift が失敗した"
echo "[5/17] drift 正系 -> exit 0"

# gh 実行失敗: 壊れた gh (常に exit 1) では「drift 検出」ではなく
# 「実行エラー」と分かる文言で fail すること (紛れの防止)
STUB_BROKEN="$TMP/stub-broken-bin"
mkdir -p "$STUB_BROKEN"
cat > "$STUB_BROKEN/gh" <<'SH'
#!/usr/bin/env bash
echo "smoke: broken gh" >&2
exit 1
SH
chmod +x "$STUB_BROKEN/gh"
expect_fail_with "gh 実行失敗の区別" \
  "gh 呼出に失敗した" \
  env PATH="$STUB_BROKEN:$PATH" python3 "$VALIDATOR" --drift "$DRIFT_PLAN"
echo "[5/17] gh 実行失敗 -> non-zero + 実行エラー文言 (drift と区別)"

# gh 途中失敗: 2 step の台帳で step A (PR #1) は drift を検出し、step B (PR #2) で
# gh が失敗する。fatal しても蓄積済みの検出済み drift が全件出力されること (診断情報を失わない)
PARTIAL_PLAN="$HARNESS/partial-fail-ledger.json"
python3 - "$PLAN" "$PARTIAL_PLAN" <<'PY'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    d = json.load(f)
d["steps"] = [
    {"id": "SA", "title": "drift する step",
     "issue": {"number": None, "status": None, "githubState": None},
     "pr": {"number": 1, "status": "created pr", "githubState": "open"}},
    {"id": "SB", "title": "gh が失敗する step",
     "issue": {"number": None, "status": None, "githubState": None},
     "pr": {"number": 2, "status": "created pr", "githubState": "open"}},
]
with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
STUB_PARTIAL="$TMP/stub-partial-bin"
mkdir -p "$STUB_PARTIAL"
cat > "$STUB_PARTIAL/gh" <<'SH'
#!/usr/bin/env bash
# smoke 用 gh 代役: PR #1 は台帳と食い違う状態を返し、PR #2 では実行失敗する
case "$1 $2 $3" in
  "pr view 1") echo '{"state":"MERGED","isDraft":false}' ;;
  "pr view 2") echo "smoke: broken gh for pr 2" >&2; exit 1 ;;
  *)           echo '{}' ;;
esac
SH
chmod +x "$STUB_PARTIAL/gh"
partial_rc=0
partial_out="$(env PATH="$STUB_PARTIAL:$PATH" python3 "$VALIDATOR" --drift "$PARTIAL_PLAN" 2>&1)" || partial_rc=$?
if [ "$partial_rc" -ne 1 ]; then
  fail "gh 途中失敗: exit 1 を期待したが exit $partial_rc (出力: $partial_out)"
fi
grep -qF "台帳は 'open' だが GitHub (PR #1) は 'merged'" <<< "$partial_out" \
  || fail "gh 途中失敗: 蓄積済みの drift エラー (PR #1) が出力に無い (got: $partial_out)"
grep -qF "gh 呼出に失敗した" <<< "$partial_out" \
  || fail "gh 途中失敗: gh 失敗エラーが出力に無い (got: $partial_out)"
echo "[5/17] gh 途中失敗 -> 検出済み drift + gh 失敗エラーの両方を出力して exit 1"

# (xv) gh が非オブジェクト JSON (null) を返す: json.loads は null / 配列 / 文字列も受理する
#      ため、dict 形状検証で実行エラーとして fail し、蓄積済みの検出済み drift (PR #1) も
#      失わないこと (PARTIAL_PLAN を再利用: SA=PR#1 は drift、SB=PR#2 で null が返る)
STUB_NULL="$TMP/stub-null-bin"
mkdir -p "$STUB_NULL"
cat > "$STUB_NULL/gh" <<'SH'
#!/usr/bin/env bash
# smoke 用 gh 代役: PR #1 は台帳と食い違う状態を返し、PR #2 では null (非オブジェクト JSON) を返す
case "$1 $2 $3" in
  "pr view 1") echo '{"state":"MERGED","isDraft":false}' ;;
  "pr view 2") echo 'null' ;;
  *)           echo '{}' ;;
esac
SH
chmod +x "$STUB_NULL/gh"
null_rc=0
null_out="$(env PATH="$STUB_NULL:$PATH" python3 "$VALIDATOR" --drift "$PARTIAL_PLAN" 2>&1)" || null_rc=$?
if [ "$null_rc" -ne 1 ]; then
  fail "(xv) gh null 出力: exit 1 を期待したが exit $null_rc (出力: $null_out)"
fi
grep -qF "JSON オブジェクトでない" <<< "$null_out" \
  || fail "(xv) gh null 出力: dict 形状エラー文言が出力に無い (got: $null_out)"
grep -qF "台帳は 'open' だが GitHub (PR #1) は 'merged'" <<< "$null_out" \
  || fail "(xv) gh null 出力: 蓄積済みの drift エラー (PR #1) が出力に無い (got: $null_out)"
echo "[5/17] (xv) gh null 出力 -> dict 形状エラー + 蓄積済み drift を出力して exit 1"

# --- 6. reaggregate-has-blocker (has_blocker 再集計) の単体判定 ----------------
REAGG="$ROOT/scripts/reaggregate-has-blocker.py"

# $1=ラベル $2=期待する has_blocker (true/false) $3=findings JSON
assert_reagg() {
  local label="$1" want="$2" json="$3" out got
  out="$(printf '%s' "$json" | python3 "$REAGG")" \
    || fail "$label: reaggregate-has-blocker の実行に失敗した"
  got="$(python3 -c 'import json, sys; print(str(json.loads(sys.argv[1])["has_blocker"]).lower())' "$out")"
  if [ "$got" != "$want" ]; then
    fail "$label: has_blocker=$got (期待: $want / 出力: $out)"
  fi
}

assert_reagg "(a) 🔴" true \
  '[{"severity":"🔴","sources":["code-review"]}]'
assert_reagg "(b) arch 🟡" true \
  '[{"severity":"🟡","sources":["reviewing-pr-architecture"]}]'
assert_reagg "(c) code-review 単独 🟡" false \
  '[{"severity":"🟡","sources":["code-review"]}]'
assert_reagg "(d) 🟢 のみ" false \
  '[{"severity":"🟢","sources":["reviewing-pr-google-method"]}]'
assert_reagg "(e) 未知 source 🟡 (fail-closed)" true \
  '[{"severity":"🟡","sources":["mystery-skill"]}]'
# (e) は未知 source が unknown_source_blockers に記録されることも確認する
printf '%s' '[{"severity":"🟡","sources":["mystery-skill"]}]' \
  | python3 "$REAGG" | grep -qF "mystery-skill" \
  || fail "(e) 未知 source が unknown_source_blockers に記録されていない"

# severity の境界 (包含判定 + fail-closed)
assert_reagg "(f) 付記つき 🔴 (包含判定)" true \
  '[{"severity":"🔴 critical","sources":["code-review"]}]'
assert_reagg "(g) severity 欠損 (fail-closed)" true \
  '[{"sources":["code-review"]}]'
assert_reagg "(h) 未知 severity \"red\" (fail-closed)" true \
  '[{"severity":"red","sources":["code-review"],"summary":"boundary case"}]'
# (h) は該当 finding が unknown_severity_blockers に記録されることも確認する
printf '%s' '[{"severity":"red","sources":["code-review"],"summary":"boundary case"}]' \
  | python3 "$REAGG" | grep -qF "unknown_severity_blockers" \
  || fail "(h) unknown_severity_blockers が出力に無い"
printf '%s' '[{"severity":"red","sources":["code-review"],"summary":"boundary case"}]' \
  | python3 "$REAGG" | grep -qF "boundary case" \
  || fail "(h) 該当 finding の識別情報が unknown_severity_blockers に記録されていない"
assert_reagg "(i) findings 空配列" false '[]'

# (j) 不正入力 (配列でない) -> exit 2 (入力エラーは判定エラーと区別される)
reagg_rc=0
printf '%s' '{"not":"array"}' | python3 "$REAGG" >/dev/null 2>&1 || reagg_rc=$?
if [ "$reagg_rc" -ne 2 ]; then
  fail "(j) 配列でない入力で exit 2 を期待したが exit $reagg_rc"
fi

# source 照合の境界 (正規化後の完全一致 — 部分文字列照合の穴を塞いだことの検査)
# (k) "not-a-code-review-skill" は code-review を部分文字列に含むが、非 blocker に誤マッチしない
assert_reagg "(k) 未知 source not-a-code-review-skill 🟡 (fail-closed)" true \
  '[{"severity":"🟡","sources":["not-a-code-review-skill"]}]'
printf '%s' '[{"severity":"🟡","sources":["not-a-code-review-skill"]}]' \
  | python3 "$REAGG" | grep -qF "not-a-code-review-skill" \
  || fail "(k) 未知 source (not-a-code-review-skill) が unknown_source_blockers に記録されていない"
# (l) "deep-search" は arch を部分文字列に含むが、誤 arch 化せず unknown として記録される
assert_reagg "(l) 未知 source deep-search 🟡 (誤 arch 化しない)" true \
  '[{"severity":"🟡","sources":["deep-search"]}]'
printf '%s' '[{"severity":"🟡","sources":["deep-search"]}]' \
  | python3 "$REAGG" | grep -qF "deep-search" \
  || fail "(l) 未知 source (deep-search) が unknown_source_blockers に記録されていない (誤 arch 化の疑い)"
# (m) 🟡 で sources キー欠損 -> blocker + unknown_source_blockers に記録 (fail-closed)
assert_reagg "(m) 🟡 sources キー欠損 (fail-closed)" true \
  '[{"severity":"🟡","summary":"no sources key"}]'
printf '%s' '[{"severity":"🟡","summary":"no sources key"}]' \
  | python3 "$REAGG" | grep -qF "sources なし" \
  || fail "(m) sources キー欠損が unknown_source_blockers に記録されていない"

# 実運用形 (dedup 統合で sources が複数混在) と複数 findings の集計
# — 判定式の any→all 化・条件順序の退行を検知する (単発 sources だけでは全緑のまま通る)
assert_reagg "(n) 🟡 混在 sources [code-review, arch] (統合形)" true \
  '[{"severity":"🟡","sources":["code-review","reviewing-pr-architecture"]}]'
assert_reagg "(o) 🟡 混在 sources [code-review, google] (統合形)" true \
  '[{"severity":"🟡","sources":["code-review","google"]}]'
assert_reagg "(p) 複数 findings (blocker と非 blocker の混在)" true \
  '[{"severity":"🔴","sources":["code-review"]},{"severity":"🟡","sources":["code-review"]},{"severity":"🟢","sources":["google"]}]'
# (q) 複数 blocker の集計 (blocker_count が件数を数えていること)
reagg_count="$(printf '%s' '[{"severity":"🔴","sources":["code-review"]},{"severity":"🟡","sources":["arch"]}]' \
  | python3 "$REAGG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["blocker_count"])')"
[ "$reagg_count" = "2" ] || fail "(q) blocker_count=2 を期待したが $reagg_count"
echo "[6/17] reaggregate-has-blocker 判定ケース OK (fail-closed 境界・混在 sources・複数 findings 集計を含む)"

# --- 7. evaluate-stop-condition (停止条件 round_flag/trend_flag/escalate) の単体判定 ----
# reaggregate-has-blocker と対の decision script。round 上限 (round_flag) / blocker trend /
# 履歴不足・マーカー不正時の fail-open / has_blocker=false での抑止 / round<3 の短絡 /
# 不正入力 exit 2 を境界として固定する (prose の停止条件ロジックが退行しても smoke で拾う)
ESCALATE="$ROOT/scripts/evaluate-stop-condition.py"

# $1=ラベル $2=期待する escalate (true/false) $3=入力 JSON
assert_escalate() {
  local label="$1" want="$2" json="$3" out got
  out="$(printf '%s' "$json" | python3 "$ESCALATE")" \
    || fail "$label: evaluate-stop-condition の実行に失敗した"
  got="$(python3 -c 'import json, sys; print(str(json.loads(sys.argv[1])["escalate"]).lower())' "$out")"
  if [ "$got" != "$want" ]; then
    fail "$label: escalate=$got (期待: $want / 出力: $out)"
  fi
}

# (a) round < 3 は flags に関わらず escalate false (trend が立つ履歴 + has_blocker でも短絡する)
assert_escalate "(a) round<3 短絡" false \
  '{"round":2,"has_blocker":true,"blocker_count":4,"prev_markers":["blocker_count=4","blocker_count=4"]}'
# (b) round_flag: round=5 かつ has_blocker=true -> escalate true
assert_escalate "(b) round_flag (round=5)" true \
  '{"round":5,"has_blocker":true,"blocker_count":3,"prev_markers":[]}'
# (b) reason に round 上限到達が含まれることも確認する
printf '%s' '{"round":5,"has_blocker":true,"blocker_count":3,"prev_markers":[]}' \
  | python3 "$ESCALATE" | grep -qF "round 上限到達(round 5)" \
  || fail "(b) reason に round 上限到達の文言が無い"
# (c) trend_flag: blocker_count が 4,4,4 (2 回連続で非改善) -> escalate true
assert_escalate "(c) trend_flag (4,4,4 非改善)" true \
  '{"round":4,"has_blocker":true,"blocker_count":4,"prev_markers":["x blocker_count=4 y","x blocker_count=4 y"]}'
# (c) reason に trend 文言が含まれることも確認する
printf '%s' '{"round":4,"has_blocker":true,"blocker_count":4,"prev_markers":["x blocker_count=4 y","x blocker_count=4 y"]}' \
  | python3 "$ESCALATE" | grep -qF "改善していない" \
  || fail "(c) reason に trend の文言が無い"
# (d) trend 改善 (c2 -> c1 -> c0 = 5 -> 3 -> 2) -> escalate false
assert_escalate "(d) trend 改善 (5,3,2)" false \
  '{"round":4,"has_blocker":true,"blocker_count":2,"prev_markers":["blocker_count=3","blocker_count=5"]}'
# (d2) trend 片側のみ成立 -> trend_flag 不成立で escalate false (`and` セマンティクスの pin)。
#   時系列 c2 -> c1 -> c0 = 5 -> 1 -> 3 (prev_markers は most-recent-first なので c1=1, c2=5)。
#   round=4 (<5) で round_flag を無効化し trend_flag を isolate。
#   (c0>=c1)=(3>=1)=true かつ (c1>=c2)=(1>=5)=false -> `(c0>=c1) and (c1>=c2)` = false。
#   既存の (c) 4,4,4 (両真) と (d) 5,3,2 (両偽) は and/or どちらでも同結果で判別できない。
#   この片側成立ケースだけが and/or を判別する: もし将来 trend 判定を `and`->`or` に誤改変すると
#   (3>=1) or (1>=5) = true -> trend_flag=true -> escalate=true に変わり、この行が赤くなる
#   (途中で一度改善した PR を「2 連続で非改善」と誤判定して人間へ誤エスカレーションする退行を検知)。
assert_escalate "(d2) trend 片側成立 (and 判別・c2->c1->c0 = 5->1->3)" false \
  '{"round":4,"has_blocker":true,"blocker_count":3,"prev_markers":["<!-- x blocker_count=1 -->","<!-- x blocker_count=5 -->"]}'
# (d2) trend_flag=false も直接 pin する (escalate=false だけでは他要因の false と区別できないため。
#   `and`->`or` 誤改変時に trend_flag が true へ反転することを直接捕捉する)
printf '%s' '{"round":4,"has_blocker":true,"blocker_count":3,"prev_markers":["<!-- x blocker_count=1 -->","<!-- x blocker_count=5 -->"]}' \
  | python3 "$ESCALATE" | grep -qF '"trend_flag": false' \
  || fail "(d2) trend_flag=false を期待 (and セマンティクスの pin — or 誤改変なら true に反転する)"
# (e) 履歴不足 (prev_markers < 2 件) -> trend_flag 不成立で escalate false (fail-open)
assert_escalate "(e) 履歴不足 (1 件・fail-open)" false \
  '{"round":4,"has_blocker":true,"blocker_count":9,"prev_markers":["blocker_count=1"]}'
# (f) マーカー不正/パース不能 -> その履歴は欠損扱いで trend_flag 不成立 (fail-open)
assert_escalate "(f) マーカー不正 (欠損扱い・fail-open)" false \
  '{"round":4,"has_blocker":true,"blocker_count":9,"prev_markers":["no marker here","also nothing"]}'
# (g) has_blocker=false は flags が立っても escalate false
assert_escalate "(g) has_blocker=false 抑止" false \
  '{"round":5,"has_blocker":false,"blocker_count":4,"prev_markers":["blocker_count=4","blocker_count=4"]}'
# (h) 不正入力 (配列) -> exit 2 (入力エラーは判定エラーと区別される) + 期待文言
esc_rc=0
esc_out="$(printf '%s' '[]' | python3 "$ESCALATE" 2>&1)" || esc_rc=$?
if [ "$esc_rc" -ne 2 ]; then
  fail "(h) 配列でない入力で exit 2 を期待したが exit $esc_rc (出力: $esc_out)"
fi
grep -qF "入力が判定 JSON オブジェクトでない" <<< "$esc_out" \
  || fail "(h) 不正入力の期待文言が出力に無い (got: $esc_out)"
# (i) round_flag と trend_flag の同時成立 (round=5・blocker_count 非改善 4,4,4) -> escalate true。
#     reason が 2 要素を読点で連結することも確認する
assert_escalate "(i) round_flag+trend_flag 同時成立" true \
  '{"round":5,"has_blocker":true,"blocker_count":4,"prev_markers":["blocker_count=4","blocker_count=4"]}'
same_reason="$(printf '%s' '{"round":5,"has_blocker":true,"blocker_count":4,"prev_markers":["blocker_count=4","blocker_count=4"]}' | python3 "$ESCALATE")"
grep -qF "round 上限到達(round 5)" <<< "$same_reason" \
  || fail "(i) reason に round 要素が無い (got: $same_reason)"
grep -qF "改善していない" <<< "$same_reason" \
  || fail "(i) reason に trend 要素が無い (got: $same_reason)"
grep -qF "、" <<< "$same_reason" \
  || fail "(i) reason の 2 要素が読点で連結されていない (got: $same_reason)"
# (j) round=3 境界: 判定が始まる最小 round。round<3 短絡から外れ trend_flag が評価される
#     (4,4,4 で trend 成立 -> escalate true。round=2 の (a) が false なのと対をなす境界)
assert_escalate "(j) round=3 境界 (判定開始の最小 round・trend 成立)" true \
  '{"round":3,"has_blocker":true,"blocker_count":4,"prev_markers":["blocker_count=4","blocker_count=4"]}'
echo "[7/17] evaluate-stop-condition 判定ケース OK (round 上限・trend・trend の and/or 判別・fail-open 境界・has_blocker 抑止・round<3 短絡・同時成立・round=3 境界・不正入力 exit 2)"

# --- 8. decide-orchestrator-route (orchestrator ルーティング判定) の単体判定 ----
# evaluate-stop-condition / reaggregate-has-blocker と同型の pure decision script。
# 決定表の全 (role × outcome) 25 行 (implementer 6 + responder 4 + reviewer 6 + issue-reviewer 6 +
# issue-review-worker 3。issue-reviewer / issue-review-worker は issue #88) を網羅検証する —
# この網羅により、reviewer の "invalid"
# 分岐 (dispatch 結果失敗 -> sink)、implementer の "timeout" 分岐 (issue #26・in-flight
# マーカーのリトライ上限到達/不整合 -> sink)、reviewer/responder の "timeout" 分岐 (issue #71・
# reviewLock hang -> sink)、および 3 role 共通の主観的エスカレーション
# (issue #31・"subjective_escalate") が存在し正しく sink に落ちることが機械的に保証される
# (orchestrator の散文分岐が毎 round どこかずれる問題を構造的に止める)。さらに網羅ケース数と
# DECISION_TABLE のエントリ総数を突き合わせる行数ガードで「行追加時の assert 書き忘れ」を塞ぐ。
# 不正入力 exit 2 も含む。
DECIDE="$ROOT/scripts/decide-orchestrator-route.py"

# $1=ラベル $2=role $3=outcome $4=期待する出力 JSON (キー順・空白を正規化して比較。
#   full 一致にすることで ledger_write / route / label_action の過不足も 1 度に検出する)
# $5=省略可・observation JSON (A1・issue #50)。sink 系 outcome のケースはこれを渡す
#   (渡さないと route=sink の判定入力が観測必須フィールドを欠き fail-closed で exit 2 になる —
#   下の (r)/(s) が exit 2 になる境界そのものを別途検証する)。非 sink outcome では従来通り省略する。
# 各呼出で ROUTE_CASES を 1 加算し、後段の行数ガードで DECISION_TABLE のエントリ総数と突き合わせる
ROUTE_CASES=0
assert_route() {
  local label="$1" role="$2" outcome="$3" want="$4" obs="${5:-}" out got wantc payload
  if [ -n "$obs" ]; then
    payload="$(python3 -c '
import json, sys
role, outcome, obs_json = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({"role": role, "outcome": outcome, "observation": json.loads(obs_json)}))
' "$role" "$outcome" "$obs")"
  else
    payload="$(printf '{"role":"%s","outcome":"%s"}' "$role" "$outcome")"
  fi
  out="$(printf '%s' "$payload" | python3 "$DECIDE")" \
    || fail "$label: decide-orchestrator-route の実行に失敗した"
  got="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,ensure_ascii=False))')"
  wantc="$(printf '%s' "$want" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,ensure_ascii=False))')"
  if [ "$got" != "$wantc" ]; then
    fail "$label: 出力が期待と一致しない (got: $got / want: $wantc)"
  fi
  ROUTE_CASES=$((ROUTE_CASES + 1))
}

# A1 (issue #50) の観測フィールド。sink 系 outcome の assert_route はこれを $5 に渡す
# (中身は固定 fixture でよい — 本 script が検証するのは存在・型のみで内容の真偽は見ない。
# モジュール docstring 「観測必須フィールド (A1)」に spoof 可能性を明記済み)
OBS='{"command":"smoke fixture observation","exit_code":1,"summary":"smoke fixture summary"}'

# implementer (6 outcome)
assert_route "(a) implementer/no_pr" implementer no_pr \
  '{"ledger_write":null,"route":"skip","label_action":null}'
assert_route "(b) implementer/ambiguous" implementer ambiguous \
  '{"ledger_write":null,"route":"sink","label_action":null}' "$OBS"
assert_route "(c) implementer/pr_evidence_pass" implementer pr_evidence_pass \
  '{"ledger_write":{"pr.number":true,"pr.githubState":"open","pr.status":"created pr"},"route":"normal","label_action":null}'
assert_route "(d) implementer/pr_evidence_fail (書いてから sink)" implementer pr_evidence_fail \
  '{"ledger_write":{"pr.number":true,"pr.githubState":"open","pr.status":"created pr"},"route":"sink","label_action":null}' "$OBS"
# (d2) implementer/timeout (issue #26: in-flight マーカーがリトライ上限到達 or 不整合 -> sink。
#   PR は実在しない (ambiguous と同型で書込なし))
assert_route "(d2) implementer/timeout (issue #26 マーカー有界化 -> sink)" implementer timeout \
  '{"ledger_write":null,"route":"sink","label_action":null}' "$OBS"
assert_route "(k) implementer/subjective_escalate (issue #31・PR 未作成 -> 書込なしで sink)" implementer subjective_escalate \
  '{"ledger_write":null,"route":"sink","label_action":null}' "$OBS"
# responder (3 outcome)
assert_route "(e) responder/evidence_pass" responder evidence_pass \
  '{"ledger_write":{"pr.status":"waiting for review"},"route":"normal","label_action":null}'
assert_route "(f) responder/evidence_fail" responder evidence_fail \
  '{"ledger_write":null,"route":"sink","label_action":null}' "$OBS"
assert_route "(l) responder/subjective_escalate (issue #31・書いてから sink)" responder subjective_escalate \
  '{"ledger_write":{"pr.status":"need for human review"},"route":"sink","label_action":null}' "$OBS"
# reviewer (全 5 outcome — invalid/escalate/clean_pass/blockers/subjective_escalate を必ず網羅する。
#   invalid は dispatch 結果失敗を単一 sink に落とす分岐で、この行が抜けると reviewer だけ
#   sink をすり抜ける — 全網羅で「表に invalid 行が在る」ことを機械保証する)
assert_route "(g) reviewer/invalid (dispatch 失敗 -> sink)" reviewer invalid \
  '{"ledger_write":null,"route":"sink","label_action":null}' "$OBS"
assert_route "(h) reviewer/escalate (停止条件 -> need for human review へ書いてから sink)" reviewer escalate \
  '{"ledger_write":{"pr.status":"need for human review"},"route":"sink","label_action":null}' "$OBS"
assert_route "(i) reviewer/clean_pass" reviewer clean_pass \
  '{"ledger_write":{"pr.status":"ready for merge"},"route":"normal","label_action":"add_ready_for_merge"}'
assert_route "(j) reviewer/blockers" reviewer blockers \
  '{"ledger_write":{"pr.status":"completed review"},"route":"normal","label_action":"remove_ready_for_merge"}'
assert_route "(m) reviewer/subjective_escalate (issue #31・客観 escalate とは別トリガーだが同じ sink)" reviewer subjective_escalate \
  '{"ledger_write":{"pr.status":"need for human review"},"route":"sink","label_action":null}' "$OBS"
# reviewer/responder timeout (issue #71: reviewLock 締切超過 = hang -> sink)。実装役 timeout と対称に
# ledger_write=null (hang は検証不能なので status 遷移を捏造しない)。reviewer の invalid とは別 outcome
assert_route "(m2) reviewer/timeout (issue #71・reviewLock hang -> 書込なし sink)" reviewer timeout \
  '{"ledger_write":null,"route":"sink","label_action":null}' "$OBS"
assert_route "(m3) responder/timeout (issue #71・reviewLock hang -> 書込なし sink)" responder timeout \
  '{"ledger_write":null,"route":"sink","label_action":null}' "$OBS"
# issue-reviewer (issue #88: reviewer を issue フェーズへ写した 6 outcome。ledger_write は issue.status を書く。
#   clean_pass の遷移先は "ready for implementation"(PR の "ready for merge" と対称)・ラベルは
#   add/remove_ready_for_implementation。escalate/subjective_escalate は "need for human review" を書いてから sink)
assert_route "(ir-a) issue-reviewer/invalid (dispatch 失敗 -> sink)" issue-reviewer invalid \
  '{"ledger_write":null,"route":"sink","label_action":null}' "$OBS"
assert_route "(ir-b) issue-reviewer/escalate (停止条件 -> need for human review へ書いてから sink)" issue-reviewer escalate \
  '{"ledger_write":{"issue.status":"need for human review"},"route":"sink","label_action":null}' "$OBS"
assert_route "(ir-c) issue-reviewer/clean_pass (ready for implementation・PR の ready for merge と対称)" issue-reviewer clean_pass \
  '{"ledger_write":{"issue.status":"ready for implementation"},"route":"normal","label_action":"add_ready_for_implementation"}'
assert_route "(ir-d) issue-reviewer/blockers" issue-reviewer blockers \
  '{"ledger_write":{"issue.status":"completed review"},"route":"normal","label_action":"remove_ready_for_implementation"}'
assert_route "(ir-e) issue-reviewer/subjective_escalate (issue #31・客観 escalate とは別トリガーだが同じ sink)" issue-reviewer subjective_escalate \
  '{"ledger_write":{"issue.status":"need for human review"},"route":"sink","label_action":null}' "$OBS"
assert_route "(ir-f) issue-reviewer/timeout (issue #88・issueReviewLock hang -> 書込なし sink)" issue-reviewer timeout \
  '{"ledger_write":null,"route":"sink","label_action":null}' "$OBS"
# issue-review-worker (issue #88: responder を issue フェーズへ写すが evidence gate を持てない 3 outcome。
#   前進 outcome は単一の "done"(→ waiting for review)のみ。"ready for implementation" は書けない = doer≠judge)
assert_route "(iw-a) issue-review-worker/done (対応済み -> 再レビュー待ち)" issue-review-worker done \
  '{"ledger_write":{"issue.status":"waiting for review"},"route":"normal","label_action":null}'
assert_route "(iw-b) issue-review-worker/subjective_escalate (issue #31・書いてから sink)" issue-review-worker subjective_escalate \
  '{"ledger_write":{"issue.status":"need for human review"},"route":"sink","label_action":null}' "$OBS"
assert_route "(iw-c) issue-review-worker/timeout (issue #88・issueReviewLock hang -> 書込なし sink)" issue-review-worker timeout \
  '{"ledger_write":null,"route":"sink","label_action":null}' "$OBS"

# 行数ガード: DECISION_TABLE の全エントリ数 (role×outcome の全組み合わせ) と assert_route で
# 網羅したケース数 (ROUTE_CASES) が一致することを機械的に確認する。手動列挙は「行削除」は
# 個別 assert の欠落で捕捉できるが「行追加時の assert 書き忘れ」は緑のまま通る — この突き合わせで
# 塞ぐ (DECISION_TABLE に (role, outcome) を足したら assert_route も足さないと fail する)。
TABLE_ENTRIES="$(python3 - "$DECIDE" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("dor", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(sum(len(by_outcome) for by_outcome in m.DECISION_TABLE.values()))
PY
)"
[ "$ROUTE_CASES" -eq "$TABLE_ENTRIES" ] \
  || fail "decision-table 行数ガード: assert_route で網羅したケース数 ($ROUTE_CASES) が DECISION_TABLE のエントリ総数 ($TABLE_ENTRIES) と一致しない (行追加時の assert 書き忘れ / 行削除の取りこぼし)"
echo "[8/17] decision-table 行数ガード OK (assert_route ケース数 $ROUTE_CASES == DECISION_TABLE エントリ数 $TABLE_ENTRIES)"

# 不正入力 (判定エラーと入力エラーの区別 — evaluate-stop-condition と同じ流儀)
# (n) role が enum 外 -> exit 2
route_rc=0
printf '%s' '{"role":"reviewer2","outcome":"invalid"}' | python3 "$DECIDE" >/dev/null 2>&1 || route_rc=$?
[ "$route_rc" -eq 2 ] || fail "(n) role enum 外で exit 2 を期待したが exit $route_rc"
# (o) outcome が role に対応しない (implementer に reviewer の outcome) -> exit 2
route_rc=0
printf '%s' '{"role":"implementer","outcome":"escalate"}' | python3 "$DECIDE" >/dev/null 2>&1 || route_rc=$?
[ "$route_rc" -eq 2 ] || fail "(o) outcome 不整合で exit 2 を期待したが exit $route_rc"
# (p) 必須キー欠損 (outcome なし) -> exit 2
route_rc=0
printf '%s' '{"role":"reviewer"}' | python3 "$DECIDE" >/dev/null 2>&1 || route_rc=$?
[ "$route_rc" -eq 2 ] || fail "(p) 必須キー欠損で exit 2 を期待したが exit $route_rc"
# (q) 非オブジェクト入力 (配列) -> exit 2
route_rc=0
printf '%s' '["not","an","object"]' | python3 "$DECIDE" >/dev/null 2>&1 || route_rc=$?
[ "$route_rc" -eq 2 ] || fail "(q) 非オブジェクト入力で exit 2 を期待したが exit $route_rc"

# A1 (issue #50 round1 決定 🔴1): route=sink への解決は observation (観測した事実) が
# 必須で、無ければ fail-closed で exit 2 になる。normal/skip 系の outcome は従来通り
# observation 無しで成立する (上の (a)/(c)/(e)/(i)/(j) が既にこれを検証済み)。
# (r) sink outcome (implementer/ambiguous) で observation 欠落 -> exit 2 (fail-closed)
route_rc=0
printf '%s' '{"role":"implementer","outcome":"ambiguous"}' | python3 "$DECIDE" >/dev/null 2>&1 || route_rc=$?
[ "$route_rc" -eq 2 ] || fail "(r) sink outcome で observation 欠落なのに exit 2 にならなかった (exit $route_rc)"
# (s) sink outcome (reviewer/invalid) で observation はあるが必須キー欠損 (exit_code 無し) -> exit 2
route_rc=0
printf '%s' '{"role":"reviewer","outcome":"invalid","observation":{"command":"x","summary":"y"}}' \
  | python3 "$DECIDE" >/dev/null 2>&1 || route_rc=$?
[ "$route_rc" -eq 2 ] || fail "(s) observation の必須キー欠損で exit 2 を期待したが exit $route_rc"
# (t) sink outcome (responder/evidence_fail) で observation.exit_code が非整数 (文字列) -> exit 2
route_rc=0
printf '%s' '{"role":"responder","outcome":"evidence_fail","observation":{"command":"x","exit_code":"1","summary":"y"}}' \
  | python3 "$DECIDE" >/dev/null 2>&1 || route_rc=$?
[ "$route_rc" -eq 2 ] || fail "(t) observation.exit_code が非整数で exit 2 を期待したが exit $route_rc"
# (u) sink outcome (implementer/timeout) で observation.summary が空文字 -> exit 2
route_rc=0
printf '%s' '{"role":"implementer","outcome":"timeout","observation":{"command":"x","exit_code":1,"summary":""}}' \
  | python3 "$DECIDE" >/dev/null 2>&1 || route_rc=$?
[ "$route_rc" -eq 2 ] || fail "(u) observation.summary が空文字で exit 2 を期待したが exit $route_rc"
echo "[8/17] decide-orchestrator-route 判定ケース OK (全 role×outcome 25 行を網羅 + 不正入力 exit 2 境界 + A1 観測必須 fail-closed 境界)"

# label_action 執行レシピ presence 検査(round2 🔴1・issue #88): decide-orchestrator-route.py が
# emit しうる label_action トークン(null 以外)すべてが、commands/harness-orchestrate.md の
# 「label_action の実行」節に執行レシピ(バッククォート囲みのトークン見出し)を持つことを固定する。
# 塞ぐ故障クラス: script が emit するのに執行部にレシピが無く、`gh <pr|issue> edit --add-label` が
# 存在しないラベルへ実行されて失敗 → 台帳は進むが GitHub ラベルは欠落という無音 label/ledger drift。
# issue #88 では add/remove_ready_for_implementation を enum/decision script に足しながら執行部に
# レシピを足し忘れ、fresh repo の happy path で issue ラベル付与が無音失敗しうる状態だった。
ORCH="$ROOT/commands/harness-orchestrate.md"
[ -f "$ORCH" ] || fail "[8/17] harness-orchestrate.md が存在しない: $ORCH"
# decision script が返しうる label_action の非 null トークンを列挙(実値 "label_action": "<token>" のみ。
# docstring の "<null|...>" は先頭が英字でないため [a-z_]+ に一致せず拾わない)。
LABEL_TOKENS="$(grep -oE '"label_action": *"[a-z_]+"' "$DECIDE" | sed -E 's/.*"([a-z_]+)"$/\1/' | sort -u)"
[ -n "$LABEL_TOKENS" ] || fail "[8/17] decide-orchestrator-route.py から label_action トークンを抽出できない"
# 「label_action の実行」節本文を抽出(label_action と の実行 を同時に含む見出し行から次の '## ' 節見出しまで)。
LABEL_SECTION="$(awk '/label_action/ && /の実行/ {cap=1} cap{print} cap && /^## /{exit}' "$ORCH")"
[ -n "$LABEL_SECTION" ] || fail "[8/17] 「label_action の実行」節を抽出できない"
LABEL_TOKEN_COUNT=0
for tok in $LABEL_TOKENS; do
  grep -Fq "\`$tok\`" <<<"$LABEL_SECTION" \
    || fail "[8/17] label_action トークン '$tok' の執行レシピが「label_action の実行」節に無い(decision script が emit するのに執行部にレシピが欠落 = add-label 無音 drift のリスク・round2 🔴1)"
  LABEL_TOKEN_COUNT=$((LABEL_TOKEN_COUNT + 1))
done
# 自己検証(非 vacuous): 抽出したトークンが 4 種(add/remove × ready for merge/ready for implementation)
# 揃っていることを固定する。decision script に新トークンを足したのにここが 4 のままなら気づける。
[ "$LABEL_TOKEN_COUNT" -eq 4 ] \
  || fail "[8/17] label_action 非 null トークン数が期待(4)と不一致: $LABEL_TOKEN_COUNT ($LABEL_TOKENS)"
echo "[8/17] label_action 執行レシピ presence 検査 OK (decision script が emit する 4 トークンすべてに「label_action の実行」節の執行レシピが存在・round2 🔴1)"

# --- 9. reconcile-dispatch-marker (dispatch in-flight マーカーの reconciliation 判定・issue #26) --
# decide-orchestrator-route / evaluate-stop-condition / reaggregate-has-blocker と同型の
# pure decision script。marker 不在 (eligible) / 進捗確認 (clear) / 締切未到達 (wait) /
# 締切超過でリトライ余地あり (redispatch・retry_count 加算) / リトライ上限到達 (sink) /
# 壊れた・不整合な marker (sink・fail-closed) の全 action を境界込みで検証する。
RECONCILE="$ROOT/scripts/reconcile-dispatch-marker.py"

# $1=ラベル $2=入力 JSON $3=期待する出力 JSON (フル一致。キー順・空白を正規化して比較)
assert_reconcile() {
  local label="$1" json="$2" want="$3" out got wantc
  out="$(printf '%s' "$json" | python3 "$RECONCILE")" \
    || fail "$label: reconcile-dispatch-marker の実行に失敗した"
  got="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,ensure_ascii=False))')"
  wantc="$(printf '%s' "$want" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,ensure_ascii=False))')"
  if [ "$got" != "$wantc" ]; then
    fail "$label: 出力が期待と一致しない (got: $got / want: $wantc)"
  fi
}

# (a) marker 不在 -> eligible (in-flight ではないので配車選別の対象にしてよい)
assert_reconcile "(a) marker 不在 -> eligible" \
  '{"marker":null,"current_tick":5,"progressed":false}' \
  '{"action":"eligible"}'
# (b) 有効な marker + 進捗確認 -> clear (締切に関わらず優先)
assert_reconcile "(b) 進捗確認 -> clear" \
  '{"marker":{"dispatched_tick":1,"deadline_tick":3,"retry_count":0},"current_tick":2,"progressed":true}' \
  '{"action":"clear"}'
# (c) 有効な marker + 進捗なし + 締切未到達 (current_tick == deadline_tick の境界) -> wait
assert_reconcile "(c) 締切未到達 (境界 current==deadline) -> wait" \
  '{"marker":{"dispatched_tick":1,"deadline_tick":3,"retry_count":0},"current_tick":3,"progressed":false}' \
  '{"action":"wait"}'
# (d) 締切超過 (境界 current==deadline+1) + リトライ余地あり (0+1=1<=N=2) -> redispatch
assert_reconcile "(d) 締切超過 (境界 deadline+1)・リトライ余地あり -> redispatch" \
  '{"marker":{"dispatched_tick":1,"deadline_tick":3,"retry_count":0},"current_tick":4,"progressed":false}' \
  '{"action":"redispatch","retry_count":1}'
# (e) 締切超過 + リトライ余地あり境界 (retry_count=1 -> 2<=N=2) -> redispatch (最後の 1 回)
assert_reconcile "(e) リトライ上限境界 (1+1=2<=N) -> redispatch" \
  '{"marker":{"dispatched_tick":1,"deadline_tick":3,"retry_count":1},"current_tick":4,"progressed":false}' \
  '{"action":"redispatch","retry_count":2}'
# (f) 締切超過 + リトライ上限到達 (retry_count=2 -> 3>N=2) -> sink (計 3 dispatch = 初回+2リトライ)
assert_reconcile "(f) リトライ上限到達 (2+1=3>N) -> sink" \
  '{"marker":{"dispatched_tick":1,"deadline_tick":3,"retry_count":2},"current_tick":4,"progressed":false}' \
  '{"action":"sink","reason":"retries_exhausted","retry_count":3}'
# (g) 壊れた marker (必須キー欠損) -> sink・fail-closed (progressed=true でも優先されない)
assert_reconcile "(g) 必須キー欠損 marker (progressed=true でも sink 優先)" \
  '{"marker":{"dispatched_tick":1,"retry_count":0},"current_tick":4,"progressed":true}' \
  '{"action":"sink","reason":"invalid_marker"}'
# (h) 壊れた marker (型崩れ: retry_count が文字列) -> sink・fail-closed
assert_reconcile "(h) 型崩れ marker (retry_count が文字列) -> sink" \
  '{"marker":{"dispatched_tick":1,"deadline_tick":3,"retry_count":"0"},"current_tick":4,"progressed":false}' \
  '{"action":"sink","reason":"invalid_marker"}'
# (i) 壊れた marker (負値: retry_count<0) -> sink・fail-closed
assert_reconcile "(i) 負値 marker (retry_count<0) -> sink" \
  '{"marker":{"dispatched_tick":1,"deadline_tick":3,"retry_count":-1},"current_tick":4,"progressed":false}' \
  '{"action":"sink","reason":"invalid_marker"}'
# (j) 壊れた marker (不整合: deadline_tick < dispatched_tick) -> sink・fail-closed
assert_reconcile "(j) 不整合 marker (deadline<dispatched) -> sink" \
  '{"marker":{"dispatched_tick":5,"deadline_tick":3,"retry_count":0},"current_tick":6,"progressed":false}' \
  '{"action":"sink","reason":"invalid_marker"}'
# (k) 壊れた marker (未来矛盾: dispatched_tick > current_tick) -> sink・fail-closed
assert_reconcile "(k) 未来矛盾 marker (dispatched>current) -> sink" \
  '{"marker":{"dispatched_tick":10,"deadline_tick":12,"retry_count":0},"current_tick":4,"progressed":false}' \
  '{"action":"sink","reason":"invalid_marker"}'
# (l) bool は int 派生だが整数として扱わない (retry_count=true は型崩れ) -> sink・fail-closed
assert_reconcile "(l) bool 混入 marker (retry_count=true) -> sink" \
  '{"marker":{"dispatched_tick":1,"deadline_tick":3,"retry_count":true},"current_tick":4,"progressed":false}' \
  '{"action":"sink","reason":"invalid_marker"}'
# (r) max_retries:0 (reviewLock 用途・issue #71) -> 締切超過で redispatch を経ず即 sink。
#     (d) と同一の marker + current_tick (deadline 超過・retry_count=0) で max_retries だけ 0 に
#     すると、(d) の redispatch(retry_count=1)ではなく即 sink(retries_exhausted・retry_count=1)に
#     なる。max_retries 引数の分岐を (d) と対比して切り分けて固定する(既定 N=2 の (d)/(e)/(f) は
#     max_retries 未指定のまま回帰不変であることも同時に担保 = dispatchMarker の後方互換)。
assert_reconcile "(r) max_retries:0 (reviewLock) 締切超過 -> redispatch を経ず即 sink" \
  '{"marker":{"dispatched_tick":1,"deadline_tick":3,"retry_count":0},"current_tick":4,"progressed":false,"max_retries":0}' \
  '{"action":"sink","reason":"retries_exhausted","retry_count":1}'
echo "[9/17] reconcile-dispatch-marker 判定ケース OK (eligible/clear/wait/redispatch/sink 全 action・境界・fail-closed・max_retries:0 即 sink (issue #71) を含む)"

# 不正入力 (判定エラーと入力エラーの区別 — 他の decision script と同じ流儀)
# (m) marker キー欠損 -> exit 2
recon_rc=0
printf '%s' '{"current_tick":1,"progressed":false}' | python3 "$RECONCILE" >/dev/null 2>&1 || recon_rc=$?
[ "$recon_rc" -eq 2 ] || fail "(m) marker キー欠損で exit 2 を期待したが exit $recon_rc"
# (n) marker が null でもオブジェクトでもない (文字列) -> exit 2
recon_rc=0
printf '%s' '{"marker":"broken","current_tick":1,"progressed":false}' | python3 "$RECONCILE" >/dev/null 2>&1 || recon_rc=$?
[ "$recon_rc" -eq 2 ] || fail "(n) marker が非オブジェクトで exit 2 を期待したが exit $recon_rc"
# (o) current_tick が整数でない -> exit 2
recon_rc=0
printf '%s' '{"marker":null,"current_tick":"1","progressed":false}' | python3 "$RECONCILE" >/dev/null 2>&1 || recon_rc=$?
[ "$recon_rc" -eq 2 ] || fail "(o) current_tick 型不正で exit 2 を期待したが exit $recon_rc"
# (p) progressed が真偽値でない -> exit 2
recon_rc=0
printf '%s' '{"marker":null,"current_tick":1,"progressed":"no"}' | python3 "$RECONCILE" >/dev/null 2>&1 || recon_rc=$?
[ "$recon_rc" -eq 2 ] || fail "(p) progressed 型不正で exit 2 を期待したが exit $recon_rc"
# (q) 非オブジェクト入力 (配列) -> exit 2
recon_rc=0
printf '%s' '["not","an","object"]' | python3 "$RECONCILE" >/dev/null 2>&1 || recon_rc=$?
[ "$recon_rc" -eq 2 ] || fail "(q) 非オブジェクト入力で exit 2 を期待したが exit $recon_rc"
# (s) max_retries が非負整数でない (負値) -> exit 2 (issue #71・任意フィールドの入力検証。
#     不正値のまま reconcile へ渡して TypeError で落とさず fail-closed で早期に弾く)
recon_rc=0
printf '%s' '{"marker":null,"current_tick":1,"progressed":false,"max_retries":-1}' | python3 "$RECONCILE" >/dev/null 2>&1 || recon_rc=$?
[ "$recon_rc" -eq 2 ] || fail "(s) max_retries 負値で exit 2 を期待したが exit $recon_rc"
echo "[9/17] reconcile-dispatch-marker 不正入力 exit 2 境界 OK (max_retries 非負検証を含む)"

# 選別(jq) 実装役の dispatchMarker / dependsOn ガード。
# commands/harness-orchestrate.md 選別(jq) 実装役ブロックと同一の jq をここで直接実行し、
# `dispatchMarker` が残っている step (wait 決着で締切未到達、または redispatch が同 tick 内で
# 再試行して再び marker が残った場合) が候補から除外されることを固定する。このガードが無いと
# issue.status/pr.number が不変のまま選別に再度乗り、同一 issue へ二重 dispatch されうる。
# dependsOn ガード(issue #51・スループット)も同じ jq に含まれる — `dependsOn` の全要素が
# 終端(`issue.status == "closed issue"`)の step だけを候補にする。
SELECT_IMPLEMENTER_JQ='
  ( [ .steps[] | select(.issue.status == "closed issue") | .id ] ) as $terminal
  | [ .steps[]
      | select(.issue.status == "ready for implementation" and .pr.number == null and .dispatchMarker == null)
      | select((.dependsOn // []) | all(. as $d | $terminal | index($d) != null))
      | {id, issueNumber: .issue.number} ]
'
SELECT_IMPLEMENTER_INPUT='{"steps":[
  {"id":"X1","issue":{"status":"ready for implementation","number":1},"pr":{"number":null}},
  {"id":"X2","issue":{"status":"ready for implementation","number":2},"pr":{"number":null},
   "dispatchMarker":{"dispatched_tick":5,"deadline_tick":7,"retry_count":0}},
  {"id":"X3","issue":{"status":"ready for implementation","number":3},"pr":{"number":5}},
  {"id":"X4","issue":{"status":"created issue","number":4},"pr":{"number":null}}
]}'
SELECT_IMPLEMENTER_GOT="$(printf '%s' "$SELECT_IMPLEMENTER_INPUT" | jq -c "$SELECT_IMPLEMENTER_JQ")"
SELECT_IMPLEMENTER_WANT='[{"id":"X1","issueNumber":1}]'
[ "$SELECT_IMPLEMENTER_GOT" = "$SELECT_IMPLEMENTER_WANT" ] \
  || fail "選別(jq) 実装役: dispatchMarker が残る step (X2) が候補から除外されず二重 dispatch ガードが機能していない (got: $SELECT_IMPLEMENTER_GOT / want: $SELECT_IMPLEMENTER_WANT)"
echo "[9/17] 選別(jq) 実装役の dispatchMarker ガード OK (marker 残存 step (wait/redispatch 中) を候補から除外・後方互換: dependsOn 無しの step は従来どおり配車)"

# 選別(jq) 実装役の dependsOn ガード(issue #51・スループット)。
# 6 種の境界(全依存終端 / 一部未終端 / 空配列 / キー欠損 / 存在しない id(fail-closed) /
# 依存先が discuss 型)を SELECT_IMPLEMENTER_JQ (上記と同一・commands/harness-orchestrate.md と
# 同一の jq) で直接固定する。T-TERM1 は discuss 型の終端(PR を持たず issue.status のみで
# 終端に到達した想定・実台帳 P11 が実例)、T-TERM2 は PR を持つ型(merge 経由で終端に到達した想定)。
SELECT_DEPENDSON_INPUT='{"steps":[
  {"id":"T-TERM1","issue":{"status":"closed issue","number":90},"pr":{"number":null}},
  {"id":"T-TERM2","issue":{"status":"closed issue","number":91},"pr":{"number":99}},
  {"id":"T-NOTTERM","issue":{"status":"starting review","number":92},"pr":{"number":null}},
  {"id":"W1","issue":{"status":"ready for implementation","number":101},"pr":{"number":null},
   "dependsOn":["T-TERM1","T-TERM2"]},
  {"id":"W2","issue":{"status":"ready for implementation","number":102},"pr":{"number":null},
   "dependsOn":["T-TERM1","T-NOTTERM"]},
  {"id":"W3","issue":{"status":"ready for implementation","number":103},"pr":{"number":null},
   "dependsOn":[]},
  {"id":"W4","issue":{"status":"ready for implementation","number":104},"pr":{"number":null}},
  {"id":"W5","issue":{"status":"ready for implementation","number":105},"pr":{"number":null},
   "dependsOn":["T-GHOST"]},
  {"id":"W6","issue":{"status":"ready for implementation","number":106},"pr":{"number":null},
   "dependsOn":["T-TERM1"]}
]}'
SELECT_DEPENDSON_GOT="$(printf '%s' "$SELECT_DEPENDSON_INPUT" | jq -c "$SELECT_IMPLEMENTER_JQ")"
# 期待 eligible: W1(全依存終端)/ W3(空配列)/ W4(キー欠損)/ W6(依存先discuss型)。
# 除外: W2(一部未終端の T-NOTTERM を含む)/ W5(存在しない id T-GHOST を指し fail-closed)。
SELECT_DEPENDSON_WANT='[{"id":"W1","issueNumber":101},{"id":"W3","issueNumber":103},{"id":"W4","issueNumber":104},{"id":"W6","issueNumber":106}]'
[ "$SELECT_DEPENDSON_GOT" = "$SELECT_DEPENDSON_WANT" ] \
  || fail "選別(jq) 実装役: dependsOn ガードの判定が期待と不一致 (got: $SELECT_DEPENDSON_GOT / want: $SELECT_DEPENDSON_WANT)"
# DoD (ii-a): 依存の無い(または依存が全て終端した)step が選別 jq から同一 tick で 2 件以上
# eligible として返ることを機械検証する(同時配車の前提条件。実行時の並列 Agent 呼出そのもの
# (DoD (ii-b)) は bash smoke では検証できないため対象外 — 「developer(実装役)」節「実行ループ」参照)。
DEPENDSON_COUNT="$(printf '%s' "$SELECT_DEPENDSON_GOT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
[ "$DEPENDSON_COUNT" -ge 2 ] \
  || fail "選別(jq) 実装役: DoD (ii-a) — 同一 tick で 2 件以上 eligible を期待したが $DEPENDSON_COUNT 件しか返らなかった (got: $SELECT_DEPENDSON_GOT)"
echo "[9/17] 選別(jq) 実装役の dependsOn ガード OK (issue #51・全依存終端/一部未終端/空配列/キー欠損/存在しないid(fail-closed)/依存先discuss型の6境界 + DoD(ii-a) 同一tick 2件以上eligible)"

# 選別(jq) 対応役 / pr reviewer の reviewLock ガード(issue #37)。
# commands/harness-orchestrate.md 選別(jq) 対応役 / pr reviewer ブロックと同一の jq をここで
# 直接実行し、`reviewLock` が残っている step (in-flight) が候補から除外されることを固定する。
SELECT_RESPONDER_JQ='[ .steps[]
  | select(.pr.number != null and .pr.githubState == "open")
  | select(.pr.status == "completed review" and .reviewLock == null)
  | {id, number: .pr.number} ]'
SELECT_RESPONDER_INPUT='{"steps":[
  {"id":"Y1","pr":{"number":11,"githubState":"open","status":"completed review"}},
  {"id":"Y2","pr":{"number":12,"githubState":"open","status":"completed review"},
   "reviewLock":{"dispatched_tick":3}},
  {"id":"Y3","pr":{"number":13,"githubState":"open","status":"waiting for review"}}
]}'
SELECT_RESPONDER_GOT="$(printf '%s' "$SELECT_RESPONDER_INPUT" | jq -c "$SELECT_RESPONDER_JQ")"
SELECT_RESPONDER_WANT='[{"id":"Y1","number":11}]'
[ "$SELECT_RESPONDER_GOT" = "$SELECT_RESPONDER_WANT" ] \
  || fail "選別(jq) 対応役: reviewLock が残る step (Y2) が候補から除外されていない (got: $SELECT_RESPONDER_GOT / want: $SELECT_RESPONDER_WANT)"

SELECT_REVIEWER_JQ='[ .steps[]
  | select(.pr.number != null and .pr.githubState == "open")
  | select((.pr.status == "created pr" or .pr.status == "waiting for review") and .reviewLock == null)
  | {id, number: .pr.number} ] | unique_by(.number)'
SELECT_REVIEWER_INPUT='{"steps":[
  {"id":"Z1","pr":{"number":21,"githubState":"open","status":"created pr"}},
  {"id":"Z2","pr":{"number":22,"githubState":"open","status":"waiting for review"},
   "reviewLock":{"dispatched_tick":4}},
  {"id":"Z3","pr":{"number":23,"githubState":"open","status":"completed review"}}
]}'
SELECT_REVIEWER_GOT="$(printf '%s' "$SELECT_REVIEWER_INPUT" | jq -c "$SELECT_REVIEWER_JQ")"
SELECT_REVIEWER_WANT='[{"id":"Z1","number":21}]'
[ "$SELECT_REVIEWER_GOT" = "$SELECT_REVIEWER_WANT" ] \
  || fail "選別(jq) pr reviewer: reviewLock が残る step (Z2) が候補から除外されていない (got: $SELECT_REVIEWER_GOT / want: $SELECT_REVIEWER_WANT)"
echo "[9/17] 選別(jq) 対応役 / pr reviewer の reviewLock ガード OK (issue #37・in-flight な step を候補から除外)"

# 選別(jq) issue reviewer / issue review worker の issueReviewLock + githubState + cross-phase ガード
# (issue #88・round1 🔴3/🟡11・round2 🟡3)。commands/harness-orchestrate.md の issue 選別 jq と同一の jq を
# ここで直接実行し、次を固定する: (a) `.issueReviewLock == null` で in-flight step を除外(対応役 /
# pr reviewer の reviewLock ガードと同型)、(b) `.issue.number != null and .issue.githubState == "open"`
# ガード(PR 側 `.pr.number != null and .pr.githubState == "open"` と対称・round1 🔴3)で、GitHub 上で
# close 済み / number 未確定の issue を除外する(台帳が非終端 status のまま遅延しても誤 dispatch しない)、
# (c) `.pr.number == null` の cross-phase 相互排他ガード(round2 🟡3・実装役選別 `.pr.number == null` と
# 対称)で、PR が実在する step へ issue reviewer/worker が二重 dispatch するのを防ぐ(台帳 drift 時の
# defense-in-depth)。
SELECT_ISSUE_REVIEWER_JQ='
  ( [ .steps[] | select(.issue.status == "closed issue") | .id ] ) as $terminal
  | [ .steps[]
      | select(.issue.number != null and .issue.githubState == "open")
      | select((.issue.status == "created issue" or .issue.status == "waiting for review") and .issueReviewLock == null and .pr.number == null)
      | select((.dependsOn // []) | all(. as $d | $terminal | index($d) != null))
      | {id, number: .issue.number} ]
'
SELECT_ISSUE_WORKER_JQ='
  ( [ .steps[] | select(.issue.status == "closed issue") | .id ] ) as $terminal
  | [ .steps[]
      | select(.issue.number != null and .issue.githubState == "open")
      | select(.issue.status == "completed review" and .issueReviewLock == null and .pr.number == null)
      | select((.dependsOn // []) | all(. as $d | $terminal | index($d) != null))
      | {id, number: .issue.number} ]
'
# I1: 通常の created issue (open) → issue reviewer で eligible。
# I2: waiting for review だが issueReviewLock 保持 → in-flight で除外。
# I3: created issue だが githubState=closed → 🔴3 ガードで除外 (台帳が非終端のまま遅延)。
# I4: created issue だが number=null → 🔴3 ガードで除外 (issue 番号未確定)。
# I5: completed review (open) → issue review worker で eligible (reviewer 側では除外)。
# I6: closed issue (終端) → 両方で除外。
# I7: waiting for review だが githubState=closed → 🔴3 の中心ケース (非終端 status + close 済み) で除外。
# I8: reviewer-eligible な status/open/number だが pr.number 実在 → 🟡3 cross-phase ガードで除外
#     (このガードを外すと I8 が reviewer 出力へ漏れて WANT と不一致 = 非 vacuous の証明)。
# I9: worker-eligible な status/open/number だが pr.number 実在 → 🟡3 cross-phase ガードで worker から除外。
SELECT_ISSUE_INPUT='{"steps":[
  {"id":"I1","issue":{"status":"created issue","number":201,"githubState":"open"},"pr":{"number":null}},
  {"id":"I2","issue":{"status":"waiting for review","number":202,"githubState":"open"},"pr":{"number":null},
   "issueReviewLock":{"dispatched_tick":3,"deadline_tick":3,"retry_count":0}},
  {"id":"I3","issue":{"status":"created issue","number":203,"githubState":"closed"},"pr":{"number":null}},
  {"id":"I4","issue":{"status":"created issue","number":null,"githubState":null},"pr":{"number":null}},
  {"id":"I5","issue":{"status":"completed review","number":205,"githubState":"open"},"pr":{"number":null}},
  {"id":"I6","issue":{"status":"closed issue","number":206,"githubState":"closed"},"pr":{"number":null}},
  {"id":"I7","issue":{"status":"waiting for review","number":207,"githubState":"closed"},"pr":{"number":null}},
  {"id":"I8","issue":{"status":"waiting for review","number":208,"githubState":"open"},"pr":{"number":51,"githubState":"open"}},
  {"id":"I9","issue":{"status":"completed review","number":209,"githubState":"open"},"pr":{"number":52,"githubState":"open"}}
]}'
SELECT_ISSUE_REVIEWER_GOT="$(printf '%s' "$SELECT_ISSUE_INPUT" | jq -c "$SELECT_ISSUE_REVIEWER_JQ")"
SELECT_ISSUE_REVIEWER_WANT='[{"id":"I1","number":201}]'
[ "$SELECT_ISSUE_REVIEWER_GOT" = "$SELECT_ISSUE_REVIEWER_WANT" ] \
  || fail "選別(jq) issue reviewer: issueReviewLock/githubState/cross-phase ガードの判定が期待と不一致 (got: $SELECT_ISSUE_REVIEWER_GOT / want: $SELECT_ISSUE_REVIEWER_WANT)"
SELECT_ISSUE_WORKER_GOT="$(printf '%s' "$SELECT_ISSUE_INPUT" | jq -c "$SELECT_ISSUE_WORKER_JQ")"
SELECT_ISSUE_WORKER_WANT='[{"id":"I5","number":205}]'
[ "$SELECT_ISSUE_WORKER_GOT" = "$SELECT_ISSUE_WORKER_WANT" ] \
  || fail "選別(jq) issue review worker: issueReviewLock/githubState/cross-phase ガードの判定が期待と不一致 (got: $SELECT_ISSUE_WORKER_GOT / want: $SELECT_ISSUE_WORKER_WANT)"
echo "[9/17] 選別(jq) issue reviewer / issue review worker の issueReviewLock + githubState + cross-phase ガード OK (issue #88・round1 🔴3: close済み/number未確定 issue を除外・in-flight step を除外・round2 🟡3: PR 実在 step を二重 dispatch から除外)"

# ledger_write 適用手続き(「ルーティング判定」節)の直接検証。
# commands/harness-orchestrate.md の同手続きと同一のロジックをここで直接実行し、次を固定する:
#   (i)  lw=null + clear_marker=true でも dispatchMarker が削除される (旧コードは
#        `if lw is not None:` の外側に marker 削除が無く、ledger_write=null の ambiguous outcome
#        では永久に marker が残っていた)
#   (ii) lw が非 null のときは ledger_write の全キーと marker 削除が同一書込で適用される
#        (原子性の確認)
#   (iii) clear_marker が false/省略なら marker に触れない (対応役・reviewer 等 通常経路の回帰確認)
#   (iv) lw=null かつ clear_marker=false/省略ならファイルへ一切書き込まない (no-op の確認)
#   (v)  marker_field を省略すると既定 "dispatchMarker" が削除される (issue #37 で 6 番目の引数を
#        追加した後も実装役の既存呼出 (5 引数) が挙動不変であることの後方互換確認)
#   (vi) marker_field="reviewLock" を渡すと dispatchMarker ではなく reviewLock だけが削除される
#        (pr reviewer / 対応役 が in-flight ロックを解除する経路)
APPLY_LW() {
  # $1=plan_json_path $2=step_id $3=route_json $4=pr_number [$5=clear_marker] [$6=marker_field]
  # 呼出元が渡した個数のまま "$@" で python へ引き渡す(固定 5/6 個に埋めない) — こうすることで
  # 5 引数呼出(marker_field 省略)・4 引数呼出(clear_marker/marker_field 両方省略)のときに
  # 下記 python 側の argv 長パディング式が実地で経路を通り、prose の実呼出(引数を省略した場合は
  # 末尾の shell 引数自体を渡さない)と同じ挙動になる。
  python3 - "$@" <<'PY'
import datetime, json, os, sys
argv = sys.argv[1:]
if len(argv) > 6:
    print("::error:: too many args", file=sys.stderr)
    sys.exit(2)
argv = argv + ["false", "dispatchMarker"][len(argv) - 4:]  # commands/harness-orchestrate.md「ルーティング判定」節の同一 pad の意図的ミラー — 変える時は両方揃える (issue #54)
plan_path, step_id, route_json, pr_number, clear_marker, marker_field = argv[:6]
lw = json.loads(route_json)["ledger_write"]
if lw is not None or clear_marker == "true":
    with open(plan_path, encoding="utf-8") as f:
        plan = json.load(f)
    step = next(s for s in plan["steps"] if s["id"] == step_id)
    if lw is not None:
        for key, val in lw.items():
            section, field = key.split(".", 1)
            if key == "pr.number" and val is True:
                val = int(pr_number)
            step[section][field] = val
    if clear_marker == "true":
        step.pop(marker_field, None)
    plan["updatedAt"] = datetime.date.today().isoformat()
    with open(plan_path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(plan, f, ensure_ascii=False, indent=2)
    os.replace(plan_path + ".tmp", plan_path)
PY
}

LW_PLAN="$TMP/lw-apply-plan.json"

mk_lw_fixture() {
  # marker 付きの単一 step を持つ最小台帳を作る
  printf '%s' '{"steps":[{"id":"S1","issue":{"status":"ready for implementation","number":9},"pr":{"number":null,"githubState":null,"status":null},"dispatchMarker":{"dispatched_tick":1,"deadline_tick":3,"retry_count":0}}]}' \
    > "$LW_PLAN"
}

mk_lw_fixture_reviewlock() {
  # dispatchMarker と reviewLock の両方を持つ step を作る (issue #37: marker_field の区別確認用)
  printf '%s' '{"steps":[{"id":"S1","issue":{"status":null,"number":9},"pr":{"number":11,"githubState":"open","status":"completed review"},"dispatchMarker":{"dispatched_tick":1,"deadline_tick":3,"retry_count":0},"reviewLock":{"dispatched_tick":5}}]}' \
    > "$LW_PLAN"
}

# (i) lw=null + clear_marker=true -> marker だけ削除される
mk_lw_fixture
APPLY_LW "$LW_PLAN" "S1" '{"ledger_write":null}' "" "true"
python3 - "$LW_PLAN" <<'PY' || fail "(i) lw=null+clear_marker=true: marker 削除に失敗した"
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
step = plan["steps"][0]
assert "dispatchMarker" not in step, f"dispatchMarker が残っている: {step}"
assert step["pr"]["number"] is None, "pr.number が意図せず書き換わった"
PY
echo "[9/17] ledger_write 適用 (i) lw=null + clear_marker=true -> marker 単独削除 OK"

# (ii) lw 非 null + clear_marker=true -> ledger_write の全キーと marker 削除が同一書込で適用される
mk_lw_fixture
APPLY_LW "$LW_PLAN" "S1" '{"ledger_write":{"pr.number":true,"pr.githubState":"open","pr.status":"created pr"}}' "42" "true"
python3 - "$LW_PLAN" <<'PY' || fail "(ii) lw 非 null + clear_marker=true: 原子適用に失敗した"
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
step = plan["steps"][0]
assert "dispatchMarker" not in step, f"dispatchMarker が残っている: {step}"
assert step["pr"] == {"number": 42, "githubState": "open", "status": "created pr"}, f"pr フィールドが期待と不一致: {step['pr']}"
PY
echo "[9/17] ledger_write 適用 (ii) lw 非 null + clear_marker=true -> ledger_write と marker 削除の原子適用 OK"

# (iii) clear_marker=false(省略) -> marker には触れない (通常の対応役/reviewer 経路)
mk_lw_fixture
APPLY_LW "$LW_PLAN" "S1" '{"ledger_write":{"pr.status":"waiting for review"}}' ""
python3 - "$LW_PLAN" <<'PY' || fail "(iii) clear_marker 省略: marker が意図せず変化した"
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
step = plan["steps"][0]
assert step.get("dispatchMarker") == {"dispatched_tick": 1, "deadline_tick": 3, "retry_count": 0}, f"dispatchMarker が変化した: {step.get('dispatchMarker')}"
assert step["pr"]["status"] == "waiting for review", f"pr.status が書かれていない: {step['pr']}"
PY
echo "[9/17] ledger_write 適用 (iii) clear_marker 省略 -> marker 不変 OK"

# (iv) lw=null かつ clear_marker=false(省略) -> ファイルへ一切書き込まない (no_pr 経路相当の no-op)
mk_lw_fixture
BEFORE_HASH="$(shasum -a 256 "$LW_PLAN" | cut -d' ' -f1)"
APPLY_LW "$LW_PLAN" "S1" '{"ledger_write":null}' ""
AFTER_HASH="$(shasum -a 256 "$LW_PLAN" | cut -d' ' -f1)"
[ "$BEFORE_HASH" = "$AFTER_HASH" ] || fail "(iv) lw=null+clear_marker=false: no-op のはずがファイルが変化した"
echo "[9/17] ledger_write 適用 (iv) lw=null + clear_marker 省略 -> no-op OK"

# (v) marker_field 省略(5 引数呼出)-> 既定 "dispatchMarker" が削除される。dispatchMarker と
#     reviewLock の両方を持つ fixture で検証し、reviewLock は無関係のまま残ることも確認する
#     (issue #37: 実装役の既存呼出(5 引数)が挙動不変であることの後方互換確認)
mk_lw_fixture_reviewlock
APPLY_LW "$LW_PLAN" "S1" '{"ledger_write":null}' "" "true"
python3 - "$LW_PLAN" <<'PY' || fail "(v) marker_field 省略: 既定 dispatchMarker の削除に失敗した"
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
step = plan["steps"][0]
assert "dispatchMarker" not in step, f"dispatchMarker が残っている: {step}"
assert step.get("reviewLock") == {"dispatched_tick": 5}, f"無関係の reviewLock が変化した: {step.get('reviewLock')}"
PY
echo "[9/17] ledger_write 適用 (v) marker_field 省略 -> 既定 dispatchMarker のみ削除 OK (issue #37 後方互換)"

# (vi) marker_field="reviewLock"(6 引数呼出)-> reviewLock だけが削除され dispatchMarker は無関係のまま残る
#      (pr reviewer / 対応役 が in-flight ロックを解除する経路。issue #37)
mk_lw_fixture_reviewlock
APPLY_LW "$LW_PLAN" "S1" '{"ledger_write":null}' "" "true" "reviewLock"
python3 - "$LW_PLAN" <<'PY' || fail "(vi) marker_field=reviewLock: reviewLock の削除に失敗した"
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
step = plan["steps"][0]
assert "reviewLock" not in step, f"reviewLock が残っている: {step}"
assert step.get("dispatchMarker") == {"dispatched_tick": 1, "deadline_tick": 3, "retry_count": 0}, f"無関係の dispatchMarker が変化した: {step.get('dispatchMarker')}"
PY
echo "[9/17] ledger_write 適用 (vi) marker_field=reviewLock -> reviewLock のみ削除 OK (issue #37)"

# reviewLock 書込 → clear の 1 往復 (issue #54)。marker_field 分岐の *clear* は上の (vi) が既に
# 固定しているが、「reviewer / 対応役の in-flight ロック」節の *書込* 手続き (dispatch 直前に
# reviewLock を書く) は smoke に未反映だった。書込手続きを直接ミラーして「書込 → 同一台帳を clear」
# の 1 往復を固定する (網羅的な reviewLock ライフサイクル整合検査は #87 に委ねる — ここは最小 1 往復)。
WRITE_REVIEWLOCK() {
  # $1=plan_json_path $2=step_id $3=tick
  # commands/harness-orchestrate.md「reviewer / 対応役の in-flight ロック」節の書込手続きのミラー。
  # 手続きを変える場合はこの関数と当該 python を揃える (prose 手続きの直接検証用ミラー)。
  python3 - "$1" "$2" "$3" <<'PY'
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
}

# reviewLock 無しの step から書込 -> 期待形で present になる (dispatch 直前・pr.status は書き換えない)
printf '%s' '{"steps":[{"id":"S1","issue":{"status":null,"number":9},"pr":{"number":11,"githubState":"open","status":"completed review"}}]}' > "$LW_PLAN"
WRITE_REVIEWLOCK "$LW_PLAN" "S1" 7
python3 - "$LW_PLAN" <<'PY' || fail "reviewLock 書込: 期待形で書けていない"
import json, sys
step = json.load(open(sys.argv[1], encoding="utf-8"))["steps"][0]
assert step.get("reviewLock") == {"dispatched_tick": 7, "deadline_tick": 7, "retry_count": 0}, f"reviewLock が期待形でない: {step.get('reviewLock')}"
assert step["pr"]["status"] == "completed review", "書込が pr.status を意図せず変えた (dispatch 前に status を書き換えない原則に反する)"
PY
# 同一 tick 内で clear (全 outcome で marker_field=reviewLock を渡す解除経路) -> reviewLock が消える
APPLY_LW "$LW_PLAN" "S1" '{"ledger_write":null}' "" "true" "reviewLock"
python3 - "$LW_PLAN" <<'PY' || fail "reviewLock clear: 1 往復で解除できていない"
import json, sys
step = json.load(open(sys.argv[1], encoding="utf-8"))["steps"][0]
assert "reviewLock" not in step, f"reviewLock が残っている (1 往復で解除されていない): {step}"
PY
echo "[9/15] reviewLock 書込 → clear の 1 往復 OK (issue #54・書込手続きミラー + marker_field=reviewLock 解除)"

# statusesPostFailCount 更新 + global halt の判定 (scripts/decide-statuses-post-action.py・issue #54)。
# 「Statuses post 失敗の surface と global halt」節が prose で持っていた increment/reset/閾値判定を
# evaluate-stop-condition.py と同型の pure decision script へ切り出したもの。全分岐
# (increment 0→1→2・閾値到達 2→3 で halt・閾値超過後も失敗なら加算継続 (reset しない)・
# 成功で 0 へ reset・不正入力 exit 2) を固定し、閾値 3 の off-by-one が緑のまま素通しになるのを塞ぐ。
STATUSES_POST="$ROOT/scripts/decide-statuses-post-action.py"

# $1=ラベル $2=入力 JSON $3=期待する出力 JSON (キー順を正規化して full 一致)
assert_statuses_post() {
  local label="$1" json="$2" want="$3" got wantc
  got="$(printf '%s' "$json" | python3 "$STATUSES_POST")" \
    || fail "$label: decide-statuses-post-action の実行に失敗した"
  got="$(printf '%s' "$got" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,ensure_ascii=False))')"
  wantc="$(printf '%s' "$want" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,ensure_ascii=False))')"
  [ "$got" = "$wantc" ] || fail "$label: 出力が期待と一致しない (got: $got / want: $wantc)"
}

HALT_REASON='Statuses post 連続失敗が閾値(3)に到達(global halt)'
# post 失敗 (非 0) -> increment。閾値 3 未満は halt=false
assert_statuses_post "increment 0->1" '{"current_count":0,"post_exit_code":1}' '{"new_count":1,"halt":false,"reason":""}'
assert_statuses_post "increment 1->2" '{"current_count":1,"post_exit_code":1}' '{"new_count":2,"halt":false,"reason":""}'
# 閾値到達 (2->3) で halt=true + reason
assert_statuses_post "閾値到達 2->3 halt" '{"current_count":2,"post_exit_code":1}' "{\"new_count\":3,\"halt\":true,\"reason\":\"$HALT_REASON\"}"
# 閾値超過後も失敗なら加算継続 (reset しない・halt 継続。exit code は非 0 なら値によらない)
assert_statuses_post "閾値超過後も加算 3->4" '{"current_count":3,"post_exit_code":128}' "{\"new_count\":4,\"halt\":true,\"reason\":\"$HALT_REASON\"}"
# post 成功 (0) -> 0 へ reset (現在値によらない・halt=false)
assert_statuses_post "成功で reset (2->0)" '{"current_count":2,"post_exit_code":0}' '{"new_count":0,"halt":false,"reason":""}'
assert_statuses_post "成功で reset (閾値超え 5->0)" '{"current_count":5,"post_exit_code":0}' '{"new_count":0,"halt":false,"reason":""}'
echo "[9/15] decide-statuses-post-action 判定ケース OK (increment/reset/閾値到達 halt/閾値超過継続・issue #54)"

# 不正入力 exit 2 の境界 (evaluate-stop-condition 等と同じ検証スタイル)
for bad in \
  '{"current_count":1}' \
  '{"post_exit_code":1}' \
  '{"current_count":true,"post_exit_code":1}' \
  '{"current_count":1,"post_exit_code":1.5}' \
  '{"current_count":-1,"post_exit_code":1}' \
  '[1,2]' \
  'nope'
do
  sp_rc=0
  sp_out="$(printf '%s' "$bad" | python3 "$STATUSES_POST" 2>&1)" || sp_rc=$?
  [ "$sp_rc" -eq 2 ] || fail "[9/15] decide-statuses-post-action 不正入力: exit 2 を期待したが $sp_rc (input: $bad)"
  grep -qF "::error:: decide-statuses-post-action:" <<<"$sp_out" \
    || fail "[9/15] decide-statuses-post-action 不正入力: script 名 prefix 付き ::error:: が無い (input: $bad / got: $sp_out)"
done
echo "[9/15] decide-statuses-post-action 不正入力 exit 2 境界 OK (欠損/型不正/負値/非JSON/非オブジェクト)"

# --- 10. kit 自身の checkout なら複製の一致を検査 ------------------------------
# (fixture への複製検証とは別。templates が原本、.harness/ は複製)
if [ -d "$ROOT/.harness" ]; then
  COPY_PAIRS=(
    "templates/validate-plan-progress.py:.harness/validate-plan-progress.py"
    "templates/plan-progress.schema.json:.harness/plan-progress.schema.json"
    "templates/CLAUDE.harness.md:.harness/CLAUDE.harness.md"
  )
  # 複製対象外の既知除外 (init.json は導入先で書き換わる雛形なので複製一致を求めない)
  COPY_EXCLUDED=(
    "templates/plan-progress.init.json"
  )

  # 列挙の fail-open 防止: templates/ に新ファイルが増えたのにペア列挙への追記が
  # 漏れると、複製一致検査が黙って素通しになる。全ファイルのカバーを検査する
  # (dotglob: 隠しファイル (.* 名) も列挙対象にする — 無いと未登録の隠しファイルが素通しになる)
  shopt -s dotglob
  for f in "$ROOT/templates"/*; do
    base="$(basename "$f")"
    # __pycache__ は py_compile (evidence.lint) の副産物で、templates のファイルではない
    [ "$base" = "__pycache__" ] && continue
    rel="templates/$base"
    covered=no
    for pair in "${COPY_PAIRS[@]}"; do
      [ "${pair%%:*}" = "$rel" ] && covered=yes
    done
    for excl in "${COPY_EXCLUDED[@]}"; do
      [ "$excl" = "$rel" ] && covered=yes
    done
    [ "$covered" = yes ] \
      || fail "複製ペア列挙に未登録: $rel (run-smoke.sh の COPY_PAIRS に複製先を追記するか、複製対象外なら COPY_EXCLUDED に加える)"
  done
  shopt -u dotglob

  for pair in "${COPY_PAIRS[@]}"; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    diff -u "$ROOT/$src" "$ROOT/$dst" \
      || fail "複製が古い: $dst が $src と一致しない。cp で同期せよ (cp $src $dst)"
  done
  echo "[10/17] 複製一致検査 (kit checkout) OK (templates/ 全ファイルのカバーを含む)"
else
  echo "[10/17] 複製一致検査は skip (.harness/ が無い = kit checkout ではない)"
fi

# --- 11. commands/*.md から抽出した共通 script 群の構文チェック -----------
# report-ledger-status.sh: commands/*.md から複製削除し単一 script へ抽出した Statuses 自己申告
# ロジック (#2/#7 対応)。
# run-orchestrator-evidence-gate.sh: commands/harness-orchestrate.md「developer(実装役)」/
# 「developer(対応役)」の重複した evidence gate worktree 手続きを dedup した script (issue #38)。
# ネットワーク呼出 (gh api / gh pr view / git fetch) を伴う実処理は smoke 対象外 (手動確認) のため、
# ここでは bash -n の構文チェックのみ行う (shellcheck があれば追加で静的検査)。これらの script は
# templates/ 複製対象ではないので section 9 の COPY_PAIRS には含めない。
EXTRACTED_SCRIPTS=(
  "scripts/report-ledger-status.sh"
  "scripts/run-orchestrator-evidence-gate.sh"
)
for rel in "${EXTRACTED_SCRIPTS[@]}"; do
  sh_path="$ROOT/$rel"
  [ -f "$sh_path" ] || fail "$rel が見つからない: $sh_path"
  bash -n "$sh_path" || fail "$rel の bash -n 構文チェックに失敗した"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$sh_path" || fail "$rel の shellcheck に失敗した"
  fi
done
if command -v shellcheck >/dev/null 2>&1; then
  echo "[11/17] 抽出 script 群 (${#EXTRACTED_SCRIPTS[@]} 件) bash -n + shellcheck OK"
else
  echo "[11/17] 抽出 script 群 (${#EXTRACTED_SCRIPTS[@]} 件) bash -n OK (shellcheck 未導入のため skip)"
fi

# 挙動アサート (bash -n 構文チェックを超える): run-orchestrator-evidence-gate.sh が
# ネットワーク (gh pr view / git fetch / worktree add) に到達する *前* の 2 経路を fixture で固定する
# (issue #54: PR#41 本文の「14 outcome 網羅の決定論的アサーションで担保」誤記の実質的な穴埋め =
#  挙動同一性テスト。ネットワーク到達後の worktree 手続きは引き続き smoke 対象外・手動確認)。
EG_GATE="$ROOT/scripts/run-orchestrator-evidence-gate.sh"

# (a) 引数不足 (< 2) -> exit 2 + usage (CWD/ネットワーク非依存)
eg_rc=0
eg_out="$(bash "$EG_GATE" only-one-arg 2>&1)" || eg_rc=$?
[ "$eg_rc" -eq 2 ] || fail "[11/15] evidence-gate 引数不足: exit 2 を期待したが $eg_rc"
grep -qF "usage: run-orchestrator-evidence-gate.sh" <<<"$eg_out" \
  || fail "[11/15] evidence-gate 引数不足: usage 文言が無い (got: $eg_out)"

# (b) evidence.done/test が両方空 -> exit 1 + script 名 prefix 付き ::error:: (ネットワーク非到達)。
#     item 5 で他 5 本の .py と揃えた `::error:: run-orchestrator-evidence-gate:` prefix を挙動として固定。
EG_REPO="$TMP/eg-gate-repo"
git init -q "$EG_REPO"
mkdir -p "$EG_REPO/.harness"
printf '%s' '{"project":"eg","updatedAt":"2026-01-01","evidence":{"done":null,"test":null},"steps":[]}' \
  > "$EG_REPO/.harness/plan-progress.json"
eg_rc=0
eg_out="$( cd "$EG_REPO" && bash "$EG_GATE" owner/repo 42 2>&1 )" || eg_rc=$?
[ "$eg_rc" -eq 1 ] || fail "[11/15] evidence-gate 空 evidence: exit 1 を期待したが $eg_rc (got: $eg_out)"
grep -qF "::error:: run-orchestrator-evidence-gate: 台帳の evidence.done / evidence.test が空" <<<"$eg_out" \
  || fail "[11/15] evidence-gate 空 evidence: script 名 prefix 付き ::error:: が無い (got: $eg_out)"
echo "[11/15] evidence-gate 挙動アサート OK (引数不足 exit 2 / 空 evidence exit 1 + prefix・ネットワーク前の経路のみ・issue #54)"

# --- 12. detect-dispatch-collision (実装役 dispatch 候補のファイル衝突検知・issue #37) --------
# decide-orchestrator-route 等と同型の pure decision script。衝突なし / 全件衝突 / 部分衝突
# (推移閉包) / Implementation Scope 欠落時の fail-closed / 不正入力 exit 2 を境界込みで検証する。
COLLISION="$ROOT/scripts/detect-dispatch-collision.py"

# $1=ラベル $2=入力 JSON $3=期待する出力 JSON (フル一致。キー順・配列順・空白を正規化して比較)
assert_collision() {
  local label="$1" json="$2" want="$3" out got wantc
  out="$(printf '%s' "$json" | python3 "$COLLISION")" \
    || fail "$label: detect-dispatch-collision の実行に失敗した"
  got="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["groups"]=sorted(sorted(g) for g in d["groups"]); print(json.dumps(d,sort_keys=True,ensure_ascii=False))')"
  wantc="$(printf '%s' "$want" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["groups"]=sorted(sorted(g) for g in d["groups"]); print(json.dumps(d,sort_keys=True,ensure_ascii=False))')"
  if [ "$got" != "$wantc" ]; then
    fail "$label: 出力が期待と一致しない (got: $got / want: $wantc)"
  fi
}

# (a) 衝突なし (ファイルが互いに素) -> 両方 safe
assert_collision "(a) 衝突なし" \
  '[{"id":"A","files":["x.py"]},{"id":"B","files":["y.py"]}]' \
  '{"groups":[],"safe":["A","B"]}'
# (b) 全件衝突 (同一ファイルを共有) -> 1 group
assert_collision "(b) 全件衝突 (同一ファイル共有)" \
  '[{"id":"A","files":["x.py"]},{"id":"B","files":["x.py"]}]' \
  '{"groups":[["A","B"]],"safe":[]}'
# (c) 部分衝突 + 推移閉包 (A-B は x.py 共有、B-C は y.py 共有 -> A-B-C は同一 group。D は無関係で safe)
assert_collision "(c) 部分衝突・推移閉包 (A-B-C 同一 group、D は safe)" \
  '[{"id":"A","files":["x.py"]},{"id":"B","files":["x.py","y.py"]},{"id":"C","files":["y.py"]},{"id":"D","files":["z.py"]}]' \
  '{"groups":[["A","B","C"]],"safe":["D"]}'
# (d) 独立した 2 組の衝突 (A-B が 1 組、C-D が別の 1 組) -> 2 group
assert_collision "(d) 独立した 2 組の衝突" \
  '[{"id":"A","files":["x.py"]},{"id":"B","files":["x.py"]},{"id":"C","files":["y.py"]},{"id":"D","files":["y.py"]}]' \
  '{"groups":[["A","B"],["C","D"]],"safe":[]}'
# (e) files 空配列 (Implementation Scope 欠落) は他候補と無関係でも fail-closed で単独 group -> safe に含めない
assert_collision "(e) files 空配列 (fail-closed・単独でも safe にしない)" \
  '[{"id":"A","files":[]},{"id":"B","files":["y.py"]}]' \
  '{"groups":[["A"]],"safe":["B"]}'
# (f) 候補 0 件 -> groups/safe とも空
assert_collision "(f) 候補 0 件" '[]' '{"groups":[],"safe":[]}'
# (g) 単一候補・非空 files -> safe (衝突相手がいなくても safe)
assert_collision "(g) 単一候補・非空 files -> safe" \
  '[{"id":"A","files":["x.py"]}]' \
  '{"groups":[],"safe":["A"]}'
echo "[12/17] detect-dispatch-collision 判定ケース OK (衝突なし/全件衝突/部分衝突(推移閉包)/独立 2 組/fail-closed/候補 0 件/単一候補)"

# issue #55: 恒久衝突ペアの直列化(wait 占有者 inject + 代表選出)の grouping 層アサート
# (平文コメントの見出し。トップレベルの `# --- N.` 区切りは流用しない — これは [12] の一部)
# 【2 段構成・issue #87 で更新】detect-dispatch-collision.py は pure Union-Find grouping のみで、
# 代表選出(step id 昇順で 1 件)・占有者除外・「占有者が居る group から 0 件」・fail-closed 単独候補の
# 持ち越しという**規則そのもの**は下流の select-dispatch-representatives.py が担う(issue #87 で prose から
# 抽出・下記ブロックで検証)。したがってこの [12] grouping 層ブロックが機械検証するのは「wait 占有者 /
# redispatch / 新規 eligible を同一ファイルで同一 group にまとめた入力 -> size>=2 group / safe=[] になる」
# 「files=[] を単独 group に落とす」という grouping 層の事実までで、「代表 1 件」「占有者 group から 0 件」
# 「fail-closed は持ち越し」という代表選出の判断結果は**下記 select-dispatch-representatives ブロックが検証する**
# (issue #55 で detect 側 script は不変)。残る非検証 seam は各候補の kind の解決(占有者判定は台帳 state を
# 要する・🟡4)であり、この限界は harness-orchestrate.md「既知の制限・拡張ポイント」節にも明記済み。
#
# (n) 恒久衝突ペア(占有者ゼロ・2 新規 eligible N1/N2 が同一ファイルを恒久共有)-> 1 group / safe=[]
#     grouping は (b) と同型だが、これが issue #55 が割りたいデッドロック対象(毎 tick 同一 2 候補が
#     同一 group・safe 空で両方が永久に持ち越される)。prose の代表選出が step id 昇順で N1 を 1 件だけ
#     dispatch し N2 を持ち越すことで直列に割る(この「代表 1 件」判断自体は prose 側・非検証)。
assert_collision "(n) #55 恒久衝突ペア(占有者ゼロ)-> 1 group" \
  '[{"id":"N1","files":["harness-orchestrate.md"]},{"id":"N2","files":["harness-orchestrate.md"]}]' \
  '{"groups":[["N1","N2"]],"safe":[]}'
# (o) live wait 占有者 O を inject した衝突 group(O + 新規 eligible N が同一ファイル)-> group [N,O] / safe=[]
#     grouping 層の事実として N が占有者 O と同一 group に入る(safe に出ない)ことだけを固定する。この
#     grouping を根拠に prose 側が「占有者が居る group から dispatch 0」で N を持ち越し・占有者 O は inject
#     専用で非 dispatch とする(占有者 / dispatch の意味づけは prose の判断・script は関知しない)。
assert_collision "(o) #55 wait 占有者 inject -> N は占有者と同一 group(safe 非出現)" \
  '[{"id":"O","files":["harness-orchestrate.md"]},{"id":"N","files":["harness-orchestrate.md"]}]' \
  '{"groups":[["N","O"]],"safe":[]}'
# (p) 負の自己検証(grouping 層のみ・(o) の対): 占有者 O を inject しない入力では N は単独 safe になり、
#     inject した (o) では N が group 入りで safe から消える。**grouping 層で N の safe 有無が入力差
#     (占有者ファイルの有無)で反転する**ことだけを固定する = (o) が vacuous でないことの証明。
#     「占有者 inject が load-bearing」「占有者離脱後に N が直列進行する(DoD (i))」という占有者・多 tick
#     semantics の解釈は prose 側の判断であって script は検証しない(冒頭ブロック・DoD (iv) 参照)。
assert_collision "(p) #55 占有者 inject 無し -> N が safe((o) の対・入力差で safe が反転)" \
  '[{"id":"N","files":["harness-orchestrate.md"]}]' \
  '{"groups":[],"safe":["N"]}'
# (q) redispatch R × 新規 eligible N が同一ファイル(占有者ゼロ・経路 A)-> group [N,R] / safe=[]
#     grouping 層では 2 候補が 1 group に入るだけ。prose 側が step id 昇順で min id を代表 1 件だけ
#     dispatch(高々 1 件)し他方を持ち越す(規則X/Y の一本化で decidable — 「R も dispatch(2 件同時)」
#     にはしない。この判断自体は prose 側・非検証)。
assert_collision "(q) #55 redispatch × 新規 eligible 同一ファイル(経路 A)-> 1 group" \
  '[{"id":"N","files":["harness-orchestrate.md"]},{"id":"R","files":["harness-orchestrate.md"]}]' \
  '{"groups":[["N","R"]],"safe":[]}'
# (r) 占有者とも他候補ともファイルを共有しない redispatch R(R は完全に独立したファイル)-> safe=[R]
#     規則Y(限定): 占有者を共有しない redispatch は #26/#71 機構どおり dispatch 経路に残す。ただし safe に
#     落ちる条件は「占有者非共有」だけでは不十分で、**「占有者を共有せず かつ 他候補ともファイル非共有」**
#     である(同ブロック (q) がその反例 — redispatch が非占有者 N と同一ファイルを共有すると group [N,R] 入りで
#     safe に出ない。「占有者非共有 ⇔ safe」は成立しない)。ここでは R が run-smoke.sh を単独で持ち他と
#     共有しないため safe(締切 sink を殺さない)。占有者 O と同一ファイルの N のみが group 入り。
assert_collision "(r) #55 占有者とも他候補とも非共有の redispatch -> safe" \
  '[{"id":"R","files":["run-smoke.sh"]},{"id":"O","files":["harness-orchestrate.md"]},{"id":"N","files":["harness-orchestrate.md"]}]' \
  '{"groups":[["N","O"]],"safe":["R"]}'
# (s) fail-closed 単独候補(X: Implementation Scope 欠落で files=[])× live wait 占有者 O
#     -> groups=[["X"]] / safe=["O"](round2 🔴1 の回帰止め)
#     script は files=[] の X を(他候補とファイルを共有しなくても)単独 group として groups に落とす
#     (empty_ids 分岐)。この X は「占有者ゼロの単独 group」に見えるが、prose 側は fail-closed 持ち越し
#     として扱い代表選出の母集団に含めない(= 代表 1 件 dispatch しない・常に次 tick へ持ち越す)。旧 round の
#     ように占有者ゼロ group へ無差別に「代表 1 件」を適用すると、X が実際に O のファイルを触る場合に同一
#     ファイル 2 件同時 in-flight(DoD (ii) 違反)を招く。占有者 O は非空 files の単独 safe = inject 専用で除外。
#     ※検証できるのは「X が groups に落ちる」grouping 層まで。「X を代表選出しない」判断自体は prose 側・非検証。
assert_collision "(s) #55 fail-closed 単独候補 × 占有者 -> X は groups(代表選出の母集団外)" \
  '[{"id":"O","files":["harness-orchestrate.md"]},{"id":"X","files":[]}]' \
  '{"groups":[["X"]],"safe":["O"]}'
# (t) 負の自己検証(grouping 層のみ・(s) の対): (s) と占有者 O は同一で X の files だけを [] から
#     非空・非共有(run-smoke.sh)へ変えると、X は groups から safe へ反転する。**fail-closed 分類(files=[])
#     こそが X を groups(= 持ち越し母集団)へ落とす load-bearing な入力**であり、対象ファイルが判れば衝突
#     しない X は safe = dispatch 可能になることを固定する((s) が vacuous でないことの証明)。
assert_collision "(t) #55 fail-closed の対・X に非共有 files を与える -> X は safe に反転" \
  '[{"id":"O","files":["harness-orchestrate.md"]},{"id":"X","files":["run-smoke.sh"]}]' \
  '{"groups":[],"safe":["O","X"]}'
echo "[12/15] detect-dispatch-collision issue #55 grouping 層 OK (占有者 inject で N 非 safe / (o) の対で safe 反転 / redispatch×新規 経路A 1 group / 占有者とも他候補とも非共有 redispatch は safe / fail-closed 単独候補は占有者が居ても groups(+ 非共有 files で safe に反転))"

# 不正入力 (判定エラーと入力エラーの区別 — 他の decision script と同じ流儀)
# (h) 配列でない入力 -> exit 2
coll_rc=0
printf '%s' '{"not":"a list"}' | python3 "$COLLISION" >/dev/null 2>&1 || coll_rc=$?
[ "$coll_rc" -eq 2 ] || fail "(h) 非配列入力で exit 2 を期待したが exit $coll_rc"
# (i) 要素がオブジェクトでない -> exit 2
coll_rc=0
printf '%s' '["not-an-object"]' | python3 "$COLLISION" >/dev/null 2>&1 || coll_rc=$?
[ "$coll_rc" -eq 2 ] || fail "(i) 非オブジェクト要素で exit 2 を期待したが exit $coll_rc"
# (j) id 欠損 -> exit 2
coll_rc=0
printf '%s' '[{"files":[]}]' | python3 "$COLLISION" >/dev/null 2>&1 || coll_rc=$?
[ "$coll_rc" -eq 2 ] || fail "(j) id 欠損で exit 2 を期待したが exit $coll_rc"
# (k) files 欠損 -> exit 2
coll_rc=0
printf '%s' '[{"id":"A"}]' | python3 "$COLLISION" >/dev/null 2>&1 || coll_rc=$?
[ "$coll_rc" -eq 2 ] || fail "(k) files 欠損で exit 2 を期待したが exit $coll_rc"
# (l) files の要素が文字列でない -> exit 2
coll_rc=0
printf '%s' '[{"id":"A","files":[1]}]' | python3 "$COLLISION" >/dev/null 2>&1 || coll_rc=$?
[ "$coll_rc" -eq 2 ] || fail "(l) files 要素が非文字列で exit 2 を期待したが exit $coll_rc"
# (m) id の重複 -> exit 2
coll_rc=0
printf '%s' '[{"id":"A","files":[]},{"id":"A","files":["x"]}]' | python3 "$COLLISION" >/dev/null 2>&1 || coll_rc=$?
[ "$coll_rc" -eq 2 ] || fail "(m) id 重複で exit 2 を期待したが exit $coll_rc"
echo "[12/17] detect-dispatch-collision 不正入力 exit 2 境界 OK"

# issue #87: 恒久衝突ペアの代表選出述語(issue #55)を prose から抽出した decision script の単体判定
# (平文コメントの見出し。トップレベルの `# --- N.` 区切りは流用しない — これは [12] の一部で、上流の
# detect-dispatch-collision.py が返す {groups, safe} の**下流**の判定器)。
# 【何を machine-enforce するか】上記 [12] #55 ブロックが「prose 側・非検証」と明記していた代表選出の
# 判断結果そのもの(「1 group から dispatch は高々 1 件・占有者が居る group からは 0 件・step id 昇順
# tie-break・fail-closed 単独候補は常に持ち越し」)を、issue #87 で `select-dispatch-representatives.py`
# へ抽出し全分岐をアサートする。**残る非検証 seam**: 各候補の kind(new_eligible / redispatch /
# wait_occupant)の解決は prose 側(占有者判定は台帳 state を要する・🟡4)。**挙動不変は operational**
# (smoke ケースが prose「代表選出述語」の規則を符号化・人間が prose↔script を目視確認・機械的等価検証は
# 不可能。#37 前例)。
SELECTREP="$ROOT/scripts/select-dispatch-representatives.py"

# $1=ラベル $2=入力JSON(1 行) $3=期待出力JSON(フル一致・配列順/キー順を正規化して比較)。
# 併せて partition 不変条件(dispatch/carry_over/injected_only が互いに素・和集合=入力の全 id)を毎回検査する。
assert_selectrep() {
  local label="$1" json="$2" want="$3" out got wantc
  out="$(printf '%s' "$json" | python3 "$SELECTREP")" \
    || fail "$label: select-dispatch-representatives の実行に失敗した"
  got="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({k:sorted(d[k]) for k in ("dispatch","carry_over","injected_only")},sort_keys=True,ensure_ascii=False))')"
  wantc="$(printf '%s' "$want" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({k:sorted(d[k]) for k in ("dispatch","carry_over","injected_only")},sort_keys=True,ensure_ascii=False))')"
  [ "$got" = "$wantc" ] || fail "$label: 出力が期待と一致しない (got: $got / want: $wantc)"
  # partition 不変条件: 3 集合は互いに素・和集合は入力(groups∪safe)の全 id に一致(detect の
  # 「全 id はちょうど 1 箇所」不変条件を下流で維持することの機械検証)。
  printf '%s\n%s' "$json" "$out" | python3 -c '
import json,sys
inp=json.loads(sys.stdin.readline()); out=json.loads(sys.stdin.readline())
allids=set()
for g in inp["groups"]: allids|=set(g)
allids|=set(inp["safe"])
d,c,i=out["dispatch"],out["carry_over"],out["injected_only"]
assert len(d)+len(c)+len(i)==len(set(d)|set(c)|set(i)), "partition が互いに素でない"
assert set(d)|set(c)|set(i)==allids, "partition の和集合が入力 id 集合と一致しない"
' || fail "$label: partition 不変条件(disjoint / 和集合=全id)が破れた"
}

# (a) safe の dispatch 対象候補(new_eligible / redispatch)はそのまま dispatch
assert_selectrep "(a) safe dispatch 候補 -> 全 dispatch" \
  '{"groups":[],"safe":["A","B"],"candidates":{"A":{"kind":"new_eligible"},"B":{"kind":"redispatch"}}}' \
  '{"dispatch":["A","B"],"carry_over":[],"injected_only":[]}'
# (b) 負の自己検証((a) の対): safe に居る wait 占有者は inject 専用で dispatch から除外され injected_only へ。
#     入力の kind だけを (a) から変えると同 id が dispatch → injected_only へ反転する = kind が load-bearing。
assert_selectrep "(b) safe の wait 占有者 -> injected_only((a) の対・kind で反転)" \
  '{"groups":[],"safe":["A","O"],"candidates":{"A":{"kind":"new_eligible"},"O":{"kind":"wait_occupant"}}}' \
  '{"dispatch":["A"],"carry_over":[],"injected_only":["O"]}'
# (c) #55 デッドロック分割: 占有者ゼロの恒久衝突組(2 新規 eligible が同一ファイル)-> step id 昇順で
#     min id を 1 件だけ dispatch し他を持ち越す(「1 group から高々 1 件」で直列に割る)。
assert_selectrep "(c) #55 占有者ゼロ group -> min id 代表 1 件 dispatch・他 carry_over" \
  '{"groups":[["N1","N2"]],"safe":[],"candidates":{"N1":{"kind":"new_eligible"},"N2":{"kind":"new_eligible"}}}' \
  '{"dispatch":["N1"],"carry_over":["N2"],"injected_only":[]}'
# (d) 負の自己検証((c) の tie-break): group の並びを逆順で渡しても代表は「先頭」ではなく step id 昇順の
#     min id。入力順に依存しない完全順序であることを固定する((c) が「たまたま先頭」で通っていないことの証明)。
assert_selectrep "(d) #55 tie-break は入力順非依存の min id((c) の対・逆順でも min)" \
  '{"groups":[["N2","N1"]],"safe":[],"candidates":{"N1":{"kind":"new_eligible"},"N2":{"kind":"new_eligible"}}}' \
  '{"dispatch":["N1"],"carry_over":["N2"],"injected_only":[]}'
# (e) live wait 占有者を含む恒久衝突組 -> 今 tick は何も dispatch しない(dispatch 候補は carry_over・
#     占有者は injected_only)。「占有者が居る group からは 0 件」。
assert_selectrep "(e) #55 占有者を含む group -> dispatch 0(候補 carry・占有者 injected)" \
  '{"groups":[["N","O"]],"safe":[],"candidates":{"N":{"kind":"new_eligible"},"O":{"kind":"wait_occupant"}}}' \
  '{"dispatch":[],"carry_over":["N"],"injected_only":["O"]}'
# (e') 負の自己検証((e) の対): (e) の占有者 O を dispatch 対象候補(redispatch)へ変えると、占有者ゼロ
#     group になり min id が 1 件 dispatch される。**占有者 presence が「dispatch 0」の load-bearing な入力**
#     であること(=(e) が vacuous でない)を固定する。min("N","R")="N"。
assert_selectrep "(e') #55 占有者を候補化 -> min id が dispatch((e) の対・占有者 presence が load-bearing)" \
  '{"groups":[["N","R"]],"safe":[],"candidates":{"N":{"kind":"new_eligible"},"R":{"kind":"redispatch"}}}' \
  '{"dispatch":["N"],"carry_over":["R"],"injected_only":[]}'
# (f) fail-closed 単独候補(size==1 group = 対象ファイル抽出 0 件で files=[])-> 占有者の有無・代表選出に
#     よらず常に持ち越す(dispatch しない)。「代表選出の母集団に含めない」。
assert_selectrep "(f) fail-closed 単独候補(size==1 group)-> 常に carry_over(dispatch しない)" \
  '{"groups":[["X"]],"safe":[],"candidates":{"X":{"kind":"new_eligible"}}}' \
  '{"dispatch":[],"carry_over":["X"],"injected_only":[]}'
# (f') 負の自己検証((f) の対): 同じ new_eligible の X を(対象ファイルが判って衝突しない)safe に置くと
#     dispatch される。**groups(fail-closed 持ち越し)か safe かの配置が load-bearing**であり、(f) の
#     「常に carry_over」が「new_eligible は常に carry」の誤りでないことを固定する。
assert_selectrep "(f') fail-closed の対・X が safe なら dispatch((f) の対・配置で反転)" \
  '{"groups":[],"safe":["X"],"candidates":{"X":{"kind":"new_eligible"}}}' \
  '{"dispatch":["X"],"carry_over":[],"injected_only":[]}'
# (g) 占有者ゼロ group で new_eligible + redispatch 混在 -> kind によらず step id 昇順 min id が代表
#     (規則 X/Y 一本化。redispatch を優先/後回しにするのではなく id 順の 1 件)。min("N","R")="N"。
assert_selectrep "(g) #55 占有者ゼロ・new+redispatch 混在 -> kind 非依存で min id 代表" \
  '{"groups":[["R","N"]],"safe":[],"candidates":{"N":{"kind":"new_eligible"},"R":{"kind":"redispatch"}}}' \
  '{"dispatch":["N"],"carry_over":["R"],"injected_only":[]}'
# (h) 複合入力(safe + 占有者ゼロ group + 占有者 group + fail-closed 単独)で全分岐を 1 度に通し、
#     dispatch/carry_over/injected_only の partition と各 group「高々 1 件」を同時に固定する。
assert_selectrep "(h) 複合入力 -> 全分岐の合成 + partition 不変条件" \
  '{"groups":[["N1","N2"],["M","P"],["X"]],"safe":["A","Os"],"candidates":{"A":{"kind":"new_eligible"},"Os":{"kind":"wait_occupant"},"N1":{"kind":"new_eligible"},"N2":{"kind":"new_eligible"},"M":{"kind":"wait_occupant"},"P":{"kind":"redispatch"},"X":{"kind":"new_eligible"}}}' \
  '{"dispatch":["A","N1"],"carry_over":["N2","P","X"],"injected_only":["M","Os"]}'
echo "[12/17] select-dispatch-representatives 代表選出述語(issue #55 を #87 で抽出)OK (safe dispatch/占有者 inject 除外(負の自己検証)/占有者ゼロ min id 代表 1 件(tie-break 入力順非依存)/占有者 group から 0 件(負の自己検証)/fail-closed 単独は常に持ち越し(負の自己検証)/kind 非依存代表/複合 partition)"

# kind 網羅ガード(route 行数ガードと同型): script の VALID_KINDS が smoke の網羅対象と一致することを
# 突き合わせ、「kind を足したのにテスト書き忘れ / 削除の取りこぼし」を機械検知する。
KINDS_IN_SCRIPT="$(python3 - "$SELECTREP" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("selrep", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(",".join(sorted(m.VALID_KINDS)))
PY
)"
EXPECTED_KINDS="new_eligible,redispatch,wait_occupant"
[ "$KINDS_IN_SCRIPT" = "$EXPECTED_KINDS" ] \
  || fail "kind 網羅ガード: script の VALID_KINDS ($KINDS_IN_SCRIPT) が smoke の網羅対象 ($EXPECTED_KINDS) と一致しない (kind 追加時のテスト書き忘れ / 削除の取りこぼし)"
echo "[12/17] select-dispatch-representatives kind 網羅ガード OK (VALID_KINDS == $EXPECTED_KINDS)"

# 不正入力(判定エラーと入力エラーの区別 — 他の decision script と同じ流儀)
selrep_exit2() {  # $1=ラベル $2=入力
  local label="$1" json="$2" rc=0
  printf '%s' "$json" | python3 "$SELECTREP" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "$label: exit 2 を期待したが exit $rc"
}
selrep_exit2 "(i) 非オブジェクト入力 -> exit 2" '["not","a","dict"]'
selrep_exit2 "(j) candidates キー欠損 -> exit 2" '{"groups":[],"safe":["A"]}'
selrep_exit2 "(k) kind 未解決 id(fail-closed)-> exit 2" '{"groups":[],"safe":["A","B"],"candidates":{"A":{"kind":"new_eligible"}}}'
selrep_exit2 "(l) candidates に余分な id -> exit 2" '{"groups":[],"safe":["A"],"candidates":{"A":{"kind":"new_eligible"},"Z":{"kind":"new_eligible"}}}'
selrep_exit2 "(m) kind が enum 外 -> exit 2" '{"groups":[],"safe":["A"],"candidates":{"A":{"kind":"bogus"}}}'
selrep_exit2 "(n) id 重複(groups∪safe)-> exit 2" '{"groups":[["A"]],"safe":["A"],"candidates":{"A":{"kind":"new_eligible"}}}'
selrep_exit2 "(o) 空 group(size 0)-> exit 2" '{"groups":[[]],"safe":[],"candidates":{}}'
echo "[12/17] select-dispatch-representatives 不正入力 exit 2 境界 OK"

# --- 13. 共通コア(禁止事項)の単一ソース + dispatch ファイル冒頭ブロックへの presence 検査 -------
# issue #52 Phase B・症状1・A3。この配列(CANONICAL_CORE)が禁止事項の共通コアの唯一の正(単一ソース)。
# 各 dispatch ファイルの冒頭 ★最重要★ ブロックが、この 5 行を「逐語部分一致(verbatim substring)」で
# 含むことをアサートする(round2 🟡1(a))。逐語一致にすることで「行の脱落(drift)」だけでなく
# 「文言だけ 1 箇所書き換えて古いまま」も捕捉する(keyword 一致では後者をすり抜ける)。
#
# 【この閉ループが塞ぐもの / 塞がないもの(DoD (v)・round2 🟡3 の正直な限界)】
#  - 塞ぐ:  各ファイルの冒頭ブロックからの共通コア行の脱落・文言 drift(単一ソースからの乖離)。
#  - 塞がない(best-effort・人間レビュー担保):
#      (a) subagent が実際に指示を遵守するか(runtime obedience)は構造的に検証不能。
#      (b)「共通コア + ロール固有項目 *のみ*」の排他(のみ)= 正準行を残したまま矛盾する追記をしても
#          presence は緑のまま(allowlist 検査は入れず honest downgrade。round2 🟡3)。
CANONICAL_CORE=(
'**fork を使うな(fan-out は `general-purpose`)**: 作業中に subagent を fan-out する場面では `subagent_type: "general-purpose"` で起動せよ(`fork` は呼出元の会話文脈を丸ごと継承し、狭い directive を無視して呼出元の最上位タスクを再実行する)。文脈は各 subagent に自己完結する形で渡す。'
'**`SendMessage` を使うな**: 結果は最終メッセージで直接返せ(`SendMessage` は宛先解決に失敗して結果が消失する)。'
'**`gh auth switch` を実行するな**: active アカウントを変えると orchestrator 自身の `gh` 操作が壊れる。'
'**台帳(`.harness/plan-progress.json`)に触れるな**: Read も編集もするな。`git stash` / `git checkout` / `git reset` で戻そうともするな(作業ツリー上で dirty なのは F案の正常な状態)。'
'**観測していないことを書くな**: 『エラー』と『処理中』を区別せよ。分からないことは未観測と書け。'
)
DISPATCH_FILES=(
"$ROOT/roles/developer-implementer.md"
"$ROOT/roles/developer-responder.md"
"$ROOT/roles/pr-reviewer-dispatch.md"
"$ROOT/collectors/strategy.md"
"$ROOT/roles/issue-reviewer-dispatch.md"
"$ROOT/roles/issue-review-worker.md"
)

# ファイルの冒頭 ★最重要★ ブロック(★最重要★ 行から直後の '---' 区切りまで)を取り出し、
# CANONICAL_CORE の全行を逐語部分一致で含むか判定する(0=全て含む / 1=ブロック抽出失敗 or 欠落あり)。
# `fail` を直接呼ばず戻り値で返すことで、正のケースと負のケース(vacuous でない自己検証)の両方に使える。
core_block_has_all() {
  local file="$1" block line
  block="$(awk '/★最重要★/{cap=1} cap{print} cap&&/^---$/{exit}' "$file")"
  [ -n "$block" ] || return 1
  for line in "${CANONICAL_CORE[@]}"; do
    grep -Fq "$line" <<<"$block" || return 1
  done
  return 0
}

# 正: 6 dispatch ファイルすべての冒頭ブロックが 5 canonical 行を含む
for f in "${DISPATCH_FILES[@]}"; do
  [ -f "$f" ] || fail "[13/17] dispatch ファイルが存在しない: $f"
  block="$(awk '/★最重要★/{cap=1} cap{print} cap&&/^---$/{exit}' "$f")"
  [ -n "$block" ] || fail "[13/17] ★最重要★ ブロックを抽出できない(区切り '---' が無い?): $f"
  for line in "${CANONICAL_CORE[@]}"; do
    grep -Fq "$line" <<<"$block" \
      || fail "[13/17] 共通コア行が $f の冒頭ブロックに無い(脱落 / 文言 drift): $line"
  done
done
echo "[13/17] 共通コア presence 検査 OK (6 dispatch ファイル × 5 canonical 行・逐語部分一致・単一ソースは CANONICAL_CORE)"

# 負(自己検証): canonical 行を 1 本抜いたコピーは fail 判定になる(アサートが vacuous でない証明)
NEG_TMP="$TMP/neg-dispatch.md"
grep -vF "${CANONICAL_CORE[0]}" "${DISPATCH_FILES[0]}" > "$NEG_TMP"
if core_block_has_all "$NEG_TMP"; then
  fail "[13/17] 共通コア presence 検査が vacuous(canonical 行を 1 本抜いても pass した)"
fi
echo "[13/17] 共通コア presence 検査の負のケース OK (canonical 行を抜いたコピーは fail 判定)"

# --- 14. issue #93: issue reviewer 判定エンジンの kit 同梱化(spec presence + dispatch→spec 参照整合 + 8 観点/3 ファミリー見出し presence)---
# issue #93: 判定 rubric を kit 同梱 roles/issue-reviewer.md へ inline し、dispatch の既定を
# 個人 skill 非依存(spec 参照)へ切替えたことを機械検証する([13] の CANONICAL_CORE と同型の
# presence + 負の自己検証)。実測の結果 [13] の CANONICAL_CORE は 6 *dispatch* ファイルの禁止事項
# 共通コアを逐語検査するのみで、spec 本体の presence も dispatch→spec 参照整合も検査していない
# (PR 側にも相当検査は無い)ため、本 issue で「新設」と明示決定した(round1 🔴)。3 アサーション:
#   (a) roles/issue-reviewer.md(判定 spec 本体)が存在する。
#   (b) dispatch→spec 参照整合: roles/issue-reviewer-dispatch.md の既定経路が
#       roles/issue-reviewer.md を参照し、かつ個人 skill 起動(`Skill` … reviewing-github-issues)を
#       *既定にしていない*(opt-in sentinel 見出しより後にのみ現れる = 無条件でない)。
#       文字列の有無だけでは「無条件でない」を表せない(opt-in 経路として skill 文字列は残るため)。
#       sentinel 見出しの行位置で判定する(round2 🟡 L2/L5 の指摘に対応 — negative half をテスト可能に)。
#   (c) roles/issue-reviewer.md に 8 観点(L1-L8)見出し + 3 ファミリー見出しが presence する
#       (inline がパリティ深さで行われた最低限の構造フロア)。**パリティ*深さ*そのもの**
#       (問い・なぜ効く・兆候の中身の充実)は決定論では検査できず DoD ② の人間受け入れが負う —
#       (c) は 8 見出しが在るだけの hollow spec を許す最低限の歯止め(round2 🟡 L1: ① 構造フロア / ② 実質)。
# 各 (b)(c) に「既定に skill を混ぜた / sentinel を抜いた / 観点見出しを 1 本抜いたコピーが fail する」
# 負の自己検証を付ける([13] と同流儀・vacuous でない証明)。
# 本 spec は spec 本体であり ★最重要★ 共通コアは持たない(それは dispatch ラッパ roles/issue-reviewer-dispatch.md
# 側が既に保持)ため DISPATCH_FILES(=[13] の共通コア検査対象・6 ファイル)には**加えない**
# (PR 側 roles/pr-reviewer.md が DISPATCH_FILES に無いのと対称。(b)(c) は CANONICAL_CORE とは別軸の検査)。
IR_SPEC="$ROOT/roles/issue-reviewer.md"
IR_DISPATCH="$ROOT/roles/issue-reviewer-dispatch.md"
[ -f "$IR_DISPATCH" ] || fail "[14/17] dispatch ファイルが存在しない: $IR_DISPATCH"

# (a) 判定 spec 本体 presence
[ -f "$IR_SPEC" ] || fail "[14/17] (a) 判定 spec が存在しない: $IR_SPEC"
echo "[14/17] (a) issue reviewer 判定 spec presence OK (roles/issue-reviewer.md)"

# (b) dispatch→spec 参照整合。opt-in sentinel 見出しの行位置で「skill を既定にしていない」を判定する。
IR_OPTIN_SENTINEL='### opt-in モード(`ISSUE_REVIEW_MODE=skill`)'
IR_DEFAULT_SPECREF='`${CLAUDE_PLUGIN_ROOT}/roles/issue-reviewer.md` を Read'
IR_SKILL_INVOKE='`Skill` ツールで `reviewing-github-issues` を起動'

# 判定関数: dispatch が既定で spec を参照し、skill 起動が opt-in sentinel より後にのみ現れるか。
# 0=整合(既定=spec 参照・skill は opt-in sentinel 配下)/ 1=不整合(sentinel 欠落 / 既定の spec 参照が無い
# / skill 起動が sentinel より前 = 既定経路に混入)。fail を直接呼ばず戻り値で返し、正・負(vacuous でない
# 自己検証)両方に使う([13] の core_block_has_all と同型)。
dispatch_defaults_to_spec() {
  local file="$1" sline dline kline
  sline="$(grep -nF "$IR_OPTIN_SENTINEL" "$file" | head -1 | cut -d: -f1)"
  [ -n "$sline" ] || return 1                    # opt-in sentinel 欠落 -> fail-closed
  dline="$(grep -nF "$IR_DEFAULT_SPECREF" "$file" | head -1 | cut -d: -f1)"
  [ -n "$dline" ] || return 1                    # 既定の spec 参照が無い -> fail
  [ "$dline" -lt "$sline" ] || return 1          # 既定の spec 参照は sentinel より前(= 既定経路)
  kline="$(grep -nF "$IR_SKILL_INVOKE" "$file" | head -1 | cut -d: -f1)"
  [ -n "$kline" ] || return 1                    # opt-in path 自体(skill 起動)が無い -> fail
  [ "$kline" -gt "$sline" ] || return 1          # 最初の skill 起動が sentinel より後(= 既定に非混入)
  return 0
}

dispatch_defaults_to_spec "$IR_DISPATCH" \
  || fail "[14/17] (b) dispatch→spec 参照整合が崩れている(既定が spec を参照しない / skill 起動が opt-in sentinel より前に混入 / sentinel 欠落): $IR_DISPATCH"
echo "[14/17] (b) dispatch→spec 参照整合 OK (既定=spec 参照・個人 skill 起動は opt-in sentinel 配下のみ・既定に非混入)"

# (b) 負の自己検証1: skill 起動行を先頭(sentinel より前 = 既定経路)へ注入したコピーは fail
IR_NEG_DEFAULT_SKILL="$TMP/neg-ir-default-skill.md"
{ printf '%s\n' "$IR_SKILL_INVOKE"; cat "$IR_DISPATCH"; } > "$IR_NEG_DEFAULT_SKILL"
if dispatch_defaults_to_spec "$IR_NEG_DEFAULT_SKILL"; then
  fail "[14/17] (b) 参照整合が vacuous(既定経路に skill 起動を注入しても pass した)"
fi
# (b) 負の自己検証2: opt-in sentinel を除去したコピーは fail(sentinel が既定/opt-in の境界を担う)
IR_NEG_NO_SENTINEL="$TMP/neg-ir-no-sentinel.md"
grep -vF "$IR_OPTIN_SENTINEL" "$IR_DISPATCH" > "$IR_NEG_NO_SENTINEL"
if dispatch_defaults_to_spec "$IR_NEG_NO_SENTINEL"; then
  fail "[14/17] (b) 参照整合が vacuous(opt-in sentinel を抜いても pass した)"
fi
echo "[14/17] (b) 参照整合の負のケース OK (既定に skill 注入 / sentinel 除去のいずれも fail 判定)"

# (c) 8 観点(L1-L8)見出し + 3 ファミリー見出しの presence
IR_LENS_HEADINGS=('#### L1.' '#### L2.' '#### L3.' '#### L4.' '#### L5.' '#### L6.' '#### L7.' '#### L8.')
IR_FAMILY_HEADINGS=('### ファミリー1' '### ファミリー2' '### ファミリー3')
spec_has_all_lenses() {
  local file="$1" h
  for h in "${IR_LENS_HEADINGS[@]}" "${IR_FAMILY_HEADINGS[@]}"; do
    grep -Fq "$h" "$file" || return 1
  done
  return 0
}
spec_has_all_lenses "$IR_SPEC" \
  || fail "[14/17] (c) 8 観点(L1-L8)/ 3 ファミリー見出しのいずれかが判定 spec に無い: $IR_SPEC"
echo "[14/17] (c) 8 観点 / 3 ファミリー見出し presence OK (roles/issue-reviewer.md)"

# (c) 負の自己検証: 観点見出しを 1 本抜いたコピーは fail(presence 検査が vacuous でない証明)
IR_NEG_SPEC="$TMP/neg-ir-spec.md"
grep -vF "${IR_LENS_HEADINGS[4]}" "$IR_SPEC" > "$IR_NEG_SPEC"   # L5 見出しを抜く
if spec_has_all_lenses "$IR_NEG_SPEC"; then
  fail "[14/17] (c) 観点見出し presence 検査が vacuous(L5 見出しを抜いても pass した)"
fi
echo "[14/17] (c) 観点見出し presence の負のケース OK (L5 見出しを抜いたコピーは fail 判定)"

# --- 15. issue #89: /goal モード雛形の機械検証(DoD-1/2/3) -----------------------
# commands/harness-orchestrate.md の構造化モード(pr / issue)雛形について、issue #89 の
# DoD 3 点を機械検証する([8](decision script から件数算出)+ [13](単一ソース presence +
# 負の自己検証)の型を合成):
#   (a) DoD-2 整合ドリフトガード: 凍結停止条件マニフェスト(FROZEN-STOP-CONDITIONS)の
#       outcome トークン集合が、decide-orchestrator-route.py の route=="sink" outcome(PR 11 + issue 6 = 17)+
#       git-status-guard(decision script 外・1)= 18 と過不足なく一致する(散文表の行数では
#       なく decision script が単一の正)。トークンを 1 本抜いたコピーが不一致になる負の自己検証付き。
#   (b) DoD-3 パース単体: MODE-DETECTION-MANIFEST の regex(単一ソース)を bash =~ で適用し、
#       strict 受理 / 現行自由文例 `issue #42 を…` の非誤分類 / near-miss(裸キーワード・二重空白)を固定。
#   (c) DoD-1 決定性(構造的担保 + fixture lock): verbatim 雛形は <N> の literal 置換のみで
#       LLM パラフレーズを挟まないため出力は決定的。smoke は雛形本体(13 文の <STOP>・両モード雛形・
#       merge 代行"明示指示"条項・issue #88 で成文化した issue 相の停止条件注記)が verbatim で存在することを
#       presence 検査して drift を塞ぐ(assemble を実行する LLM は smoke から呼べないため、雛形の
#       固定 = golden fixture として扱う)。
ORCH_MD="$ROOT/commands/harness-orchestrate.md"
[ -f "$ORCH_MD" ] || fail "[15/17] コマンドファイルが存在しない: $ORCH_MD"

# 凍結ブロック(BEGIN/END マーカー間)から `token | 停止条件文` の token を抽出する
extract_frozen_tokens() {
  awk '/FROZEN-STOP-CONDITIONS:BEGIN/{c=1;next} /FROZEN-STOP-CONDITIONS:END/{c=0} c' "$1" \
    | grep ' | ' | sed 's/ |.*//' | sed 's/[[:space:]]*$//'
}
# MODE-DETECTION-MANIFEST から指定ラベルの regex(単一ソース)を取り出す
extract_mode_regex() {
  awk '/MODE-DETECTION-MANIFEST:BEGIN/{c=1;next} /MODE-DETECTION-MANIFEST:END/{c=0} c' "$ORCH_MD" \
    | sed -n "s/^$1 = //p" | head -1
}

# (a) DoD-2: 期待トークン集合を decision script から機械算出(sink outcome 17 + git-status-guard 1)
#   [8] の "sum(len(by_outcome) …)" 行数ガードと同型に、DECISION_TABLE を import して route=="sink"
#   のみを列挙する。git-status-guard は decision script を通らない唯一の sink(88 行「判定器の外」)
#   なので smoke 側の名前付き定数として 1 種足す。
EXPECTED_TOKENS="$(python3 - "$DECIDE" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("dor", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
toks = {f"{role}/{outcome}"
        for role, by_outcome in m.DECISION_TABLE.items()
        for outcome, r in by_outcome.items() if r["route"] == "sink"}
toks.add("git-status-guard")  # decision script 外の 1 種(harness-orchestrate.md 88 行)
print("\n".join(sorted(toks)))
PY
)"
EXPECTED_COUNT="$(printf '%s\n' "$EXPECTED_TOKENS" | grep -c .)"
[ "$EXPECTED_COUNT" -eq 18 ] \
  || fail "[15/17] 期待トークン数が 18 でない ($EXPECTED_COUNT) — decision script の route==sink outcome が変化した? 凍結マニフェストと一緒に更新が必要"

FROZEN_TOKENS="$(extract_frozen_tokens "$ORCH_MD" | sort)"
EXPECTED_SORTED="$(printf '%s\n' "$EXPECTED_TOKENS" | sort)"
if [ "$FROZEN_TOKENS" != "$EXPECTED_SORTED" ]; then
  fail "[15/17] 凍結停止条件マニフェストのトークン集合が decision script の sink outcome + git-status-guard と一致しない(過不足あり)。diff (< 期待 / > 凍結ブロック):
$(diff <(printf '%s\n' "$EXPECTED_SORTED") <(printf '%s\n' "$FROZEN_TOKENS") || true)"
fi
echo "[15/17] (a) DoD-2 凍結ブロック ↔ decision script 整合ガード OK (18 トークン集合一致: sink 17 + git-status-guard 1)"

# (a) 負の自己検証: 凍結ブロックからトークンを 1 本抜いたコピーは不一致になる(アサートが vacuous でない証明)
# 抜くトークンは他トークンの部分文字列でないものを選ぶ(例: `reviewer/escalate |` は
# `issue-reviewer/escalate |` にも部分一致し 2 本抜けてしまうため使わない)。`implementer/ambiguous |` は一意。
NEG_ORCH="$TMP/neg-orchestrate.md"
grep -vF 'implementer/ambiguous |' "$ORCH_MD" > "$NEG_ORCH"
NEG_TOKENS="$(extract_frozen_tokens "$NEG_ORCH" | sort)"
if [ "$NEG_TOKENS" = "$EXPECTED_SORTED" ]; then
  fail "[15/17] 整合ガードが vacuous(凍結ブロックのトークンを 1 本抜いても集合一致してしまう)"
fi
echo "[15/17] (a) DoD-2 整合ガードの負のケース OK (トークンを抜いたコピーは不一致)"

# (b) DoD-3: モード判定 regex を単一ソース(マニフェスト)から取り出し bash =~ で適用する
RE_PR="$(extract_mode_regex MODE-PR)"
RE_ISSUE="$(extract_mode_regex MODE-ISSUE)"
RE_BARE="$(extract_mode_regex NEAR-BARE)"
RE_LOOSE="$(extract_mode_regex NEAR-LOOSE)"
for v in RE_PR RE_ISSUE RE_BARE RE_LOOSE; do
  [ -n "${!v}" ] || fail "[15/17] MODE-DETECTION-MANIFEST から $v を抽出できない(マニフェスト形式が変わった?)"
done
# 判定順「構造化を先に照合 → near-miss → 自由文」をコマンド本文どおりに再現する
classify_mode() {
  local s="$1"
  if [[ $s =~ $RE_PR ]] || [[ $s =~ $RE_ISSUE ]]; then echo structured; return; fi
  if [[ $s =~ $RE_BARE ]] || [[ $s =~ $RE_LOOSE ]]; then echo near-miss; return; fi
  echo freeform
}
assert_classify() {
  local got; got="$(classify_mode "$1")"
  [ "$got" = "$2" ] || fail "[15/17] パース判定: [$1] -> got=$got / want=$2"
}
assert_classify "pr 36" structured
assert_classify "issue 55" structured
assert_classify "pr 0" structured        # 実在検証しない(#60 と同じ提示のみ姿勢)
assert_classify "issue #42 を ready for implementation になるまでレビュー・対応を繰り返して" freeform  # 現行自由文例の非誤分類(判定順の核)
assert_classify "pr" near-miss            # 裸キーワード(引用符欠落で番号が \$2 へ流れた兆候)
assert_classify "issue" near-miss
assert_classify "pr  36" near-miss        # 二重空白
assert_classify "issue 55 " near-miss     # 末尾空白
assert_classify "issue abc" freeform      # 非数値 -> strict/near いずれも不一致
assert_classify "prfoo" freeform
echo "[15/17] (b) DoD-3 パース単体 OK (strict 受理 / 現行自由文例の非誤分類 / near-miss 検出)"

# (c) DoD-1: verbatim 雛形の presence 検査(fixture lock)。determinism は literal 置換で構造的に担保。
assert_present() {
  grep -qF "$1" "$ORCH_MD" || fail "[15/17] 雛形の verbatim 断片が欠落 / drift: $1"
}
assert_present '/goal 「PR #<N> を ready for merge になるまでレビュー・対応を繰り返して。'
assert_present '/goal 「issue #<N> を issue レビュー → ready for implementation → PR 作成 → PR レビュー・対応 → ready for merge まで一気通貫で進めて。'
# 13 文の凍結 <STOP> 並び(両モード共通・PR 相 8 文 + issue 相 4 文 + git-status ガード 1 文)。
# PR→issue の畳み込み境界を跨いで末尾(issue 相 subjective_escalate・issueReviewLock timeout・git ガード)まで固定する。
assert_present '実装役・対応役・reviewer いずれかが主観的エスカレーションを返した / issue reviewer dispatch が escalate=true を返した(round/trend 停止条件)/ issue reviewer dispatch の返答が JSON でない(dispatch 結果失敗)/ issue reviewer・issue review worker いずれかが主観的エスカレーションを返した / issue reviewer・issue review worker の issueReviewLock が締切超過(dispatch の hang・timeout)/ git-status ガードが .harness/ への意図しない変更を検知した'
# (c) merge 代行の"明示指示"条項 + 自動到達点 ready for merge 止まり(round2 🟡(1) の (c) 採用)
assert_present 'この goal ループの停止条件ではない(自動ループの到達点は ready for merge 止まり)。'
assert_present '同節の言う"明示指示"に相当する'
# issue #88 で issue 相の停止条件を成文化済み。issue モード雛形が issue 相・PR 相の両フェーズの停止条件を組み立てることを固定する。
assert_present 'issue #88 で issue フェーズの sink outcome(issue reviewer の escalate(round 上限 / blocker trend)・dispatch 結果失敗・主観的エスカレーション・issueReviewLock の hang / issue review worker の主観的エスカレーション・issueReviewLock の hang)を decision script に成文化したため、issue 相にもレビューが収束しない失敗モードを自動 halt する停止条件が備わり、本雛形はそれらを含めて組み立てる。'
echo "[15/17] (c) DoD-1 雛形 verbatim presence 検査 OK (両モード雛形 / 13 文 <STOP> / merge 代行明示指示 / issue 相の停止条件注記)"

# --- 16. decide-enqueue-steps (discover→enqueue の純 enqueue/dedup 判定・issue #78) ----------
# decide-orchestrator-route / reconcile-dispatch-marker / evaluate-stop-condition と同型の
# pure decision script (network 非依存・LLM 非依存・stdin JSON → stdout・決定論)。discover→enqueue
# フェーズの中間層 (候補 issue.number + 現台帳 steps → 追加 step / no-op) を検証する。network
# discover (gh issue list --label) は smoke 対象外=手動確認 (round2 🟡1)。dedup key=issue.number・
# 突合範囲=全 step (終端含む)・終端後の再ラベル=no-op (round1 🔴2)、batch 採番=max+1,max+2,…
# 逐次加算 (round2 🟡2)、空入力=no-op (round1 🟡2)、step 雛形 (round1 🟡1) を境界込みで固定する。
# DoD「1 件追加・二重登録なし」と batch fixture「既存 1 + 新規 2 (1 件 issue.number 重複) →
# 追加 1 件・id=max+1・重複 no-op」を含む。
ENQUEUE="$ROOT/scripts/decide-enqueue-steps.py"

# $1=ラベル $2=入力 JSON $3=期待する出力 JSON (フル一致。キー順・空白を正規化して比較)
assert_enqueue() {
  local label="$1" json="$2" want="$3" out got wantc
  out="$(printf '%s' "$json" | python3 "$ENQUEUE")" \
    || fail "$label: decide-enqueue-steps の実行に失敗した"
  got="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,ensure_ascii=False))')"
  wantc="$(printf '%s' "$want" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,ensure_ascii=False))')"
  if [ "$got" != "$wantc" ]; then
    fail "$label: 出力が期待と一致しない (got: $got / want: $wantc)"
  fi
}

# 台帳 step の共通フラグメント (id=1 / issue.number=50 / created issue)。dedup・採番の突合元。
STEP1='{"id":"1","issue":{"number":50,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}'

# (a) DoD happy path: ラベル付き対象 1 件 → step 1 件追加・id=max+1 (既存 max=1 → "2")
assert_enqueue "(a) 単一候補 -> 1 件追加・id=max+1" \
  "{\"candidates\":[78],\"steps\":[$STEP1]}" \
  '{"enqueue":[{"id":"2","issue":{"number":78,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}]}'
# (b) DoD 冪等性: 同じ issue.number は 2 回目 no-op (既存 50 に一致 -> 二重登録しない)
assert_enqueue "(b) 既存 issue.number と一致 -> no-op (冪等性)" \
  "{\"candidates\":[50],\"steps\":[$STEP1]}" \
  '{"enqueue":[]}'
# (c) batch fixture (round2 🟡2): 既存 1 + 新規 2 (50 は既存と重複) -> 追加 1 件 (78)・id=max+1・重複 no-op
assert_enqueue "(c) batch: 既存1+新規2(1件重複) -> 追加1・id=max+1・重複no-op" \
  "{\"candidates\":[50,78],\"steps\":[$STEP1]}" \
  '{"enqueue":[{"id":"2","issue":{"number":78,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}]}'
# (d) batch 採番: 新規 2 件 (どちらも非重複) -> id=max+1, max+2 の逐次加算 (同一 tick 内の連番衝突なし)
assert_enqueue "(d) batch: 新規2件 -> id=max+1,max+2 逐次加算" \
  "{\"candidates\":[78,79],\"steps\":[$STEP1]}" \
  '{"enqueue":[{"id":"2","issue":{"number":78,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}},{"id":"3","issue":{"number":79,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}]}'
# (e) batch 内重複: 同一 tick の候補に同じ number が 2 度 -> 1 件だけ enqueue
assert_enqueue "(e) batch 内重複 [78,78] -> 1 件だけ enqueue" \
  '{"candidates":[78,78],"steps":[]}' \
  '{"enqueue":[{"id":"1","issue":{"number":78,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}]}'
# (f) 空入力 (候補 0 件・クエリ成功で 0 件のケース) -> no-op (round1 🟡2)
assert_enqueue "(f) 空候補 -> no-op" \
  '{"candidates":[],"steps":[]}' \
  '{"enqueue":[]}'
# (g) 終端 step との突合: 全 step 突合のため終端 (closed issue / merged pr) の number にも一致で no-op
#     (round1 🔴2「終端後の再ラベル = no-op」— status を見ず number だけで閉じる)
assert_enqueue "(g) 終端 step の number に一致 -> no-op (全 step 突合・終端含む)" \
  '{"candidates":[50],"steps":[{"id":"9","issue":{"number":50,"status":"closed issue","githubState":"closed"},"pr":{"number":12,"status":"merged pr","githubState":"merged"}}]}' \
  '{"enqueue":[]}'
# (h) 既存 step ゼロ + 候補 1 件 -> 起点 id=1 (max=0 -> max+1=1)
assert_enqueue "(h) 既存 step 無し -> 起点 id=1" \
  '{"candidates":[78],"steps":[]}' \
  '{"enqueue":[{"id":"1","issue":{"number":78,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}]}'
# (i) 非数値 id は max 計算から除外 (数値 id "3" が最大 -> 新規 id=4・非数値 id と衝突しない)
assert_enqueue "(i) 非数値 id は max 計算から除外 -> 数値 max+1" \
  '{"candidates":[78],"steps":[{"id":"seed","issue":{"number":40,"status":"closed issue","githubState":"closed"},"pr":{"number":null,"status":null,"githubState":null}},{"id":"3","issue":{"number":41,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}]}' \
  '{"enqueue":[{"id":"4","issue":{"number":78,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}]}'
# --- `P<n>` id 規約への追随 (issue #78 round1 🔴・PR #103) --------------------------------------
# この repo の実台帳は `P1`..`P21` のような `P<n>` 形式を採る。旧実装は `int(sid)` で `P<n>` を
# 全除外し起点を 1 に落としていた (P<n> 台帳へ enqueue すると id が "P22" ではなく "1" になり
# 名前空間が分断される)。新規 id は既存台帳の形式に追随して `P<max+1>` を返すことを lock する。
# `P<n>` step の共通フラグメント (id=P1,P2,P7 / 数値部の最大は 7 -> 起点 P8。数値部の "max" であって
# "件数" でないことも同時に検証する)。
STEP_P1='{"id":"P1","issue":{"number":60,"status":"closed issue","githubState":"closed"},"pr":{"number":11,"status":"merged pr","githubState":"merged"}}'
STEP_P2='{"id":"P2","issue":{"number":61,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}'
STEP_P7='{"id":"P7","issue":{"number":62,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}'
STEPS_P="$STEP_P1,$STEP_P2,$STEP_P7"
# (a2) `P<n>` 台帳: 単一候補 -> `P<max+1>` (P7 が最大 -> P8。int(sid) 版は "1" に落ちて失敗する)
assert_enqueue "(a2) P<n> 台帳: 単一候補 -> P<max+1>" \
  "{\"candidates\":[78],\"steps\":[$STEPS_P]}" \
  '{"enqueue":[{"id":"P8","issue":{"number":78,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}]}'
# (d2) `P<n>` 台帳 batch: 新規 2 件 -> `P<max+1>,P<max+2>` (P8,P9 の逐次加算・同形式)
assert_enqueue "(d2) P<n> 台帳 batch: 新規2件 -> P<max+1>,P<max+2>" \
  "{\"candidates\":[78,79],\"steps\":[$STEPS_P]}" \
  '{"enqueue":[{"id":"P8","issue":{"number":78,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}},{"id":"P9","issue":{"number":79,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}]}'
# (i2) `P<n>` + 非数値 id 混在: 非数値 (seed) を除外し `P<n>` 形式で採番 (P7 が最大 -> P8)
assert_enqueue "(i2) P<n>+非数値 id 混在 -> 非数値除外して P<max+1>" \
  "{\"candidates\":[78],\"steps\":[{\"id\":\"seed\",\"issue\":{\"number\":40,\"status\":\"closed issue\",\"githubState\":\"closed\"},\"pr\":{\"number\":null,\"status\":null,\"githubState\":null}},$STEP_P7]}" \
  '{"enqueue":[{"id":"P8","issue":{"number":78,"status":"created issue","githubState":"open"},"pr":{"number":null,"status":null,"githubState":null}}]}'
echo "[16/17] decide-enqueue-steps 判定ケース OK (単一追加/冪等 no-op/batch 採番/batch 内重複/空入力/終端突合/起点 id/非数値 id 除外/P<n> 形式追随)"

# 不正入力 (判定エラーと入力エラーの区別 — 他の decision script と同じ流儀)
# (j) candidates キー欠損 -> exit 2
enq_rc=0
printf '%s' '{"steps":[]}' | python3 "$ENQUEUE" >/dev/null 2>&1 || enq_rc=$?
[ "$enq_rc" -eq 2 ] || fail "(j) candidates 欠損で exit 2 を期待したが exit $enq_rc"
# (k) candidates が配列でない -> exit 2
enq_rc=0
printf '%s' '{"candidates":"x","steps":[]}' | python3 "$ENQUEUE" >/dev/null 2>&1 || enq_rc=$?
[ "$enq_rc" -eq 2 ] || fail "(k) candidates 非配列で exit 2 を期待したが exit $enq_rc"
# (l) candidates 要素が整数でない (文字列) -> exit 2
enq_rc=0
printf '%s' '{"candidates":["78"],"steps":[]}' | python3 "$ENQUEUE" >/dev/null 2>&1 || enq_rc=$?
[ "$enq_rc" -eq 2 ] || fail "(l) candidates 要素が文字列で exit 2 を期待したが exit $enq_rc"
# (m) candidates 要素が bool (int 派生だが issue.number として扱わない) -> exit 2
enq_rc=0
printf '%s' '{"candidates":[true],"steps":[]}' | python3 "$ENQUEUE" >/dev/null 2>&1 || enq_rc=$?
[ "$enq_rc" -eq 2 ] || fail "(m) candidates 要素が bool で exit 2 を期待したが exit $enq_rc"
# (n) steps キー欠損 -> exit 2
enq_rc=0
printf '%s' '{"candidates":[78]}' | python3 "$ENQUEUE" >/dev/null 2>&1 || enq_rc=$?
[ "$enq_rc" -eq 2 ] || fail "(n) steps 欠損で exit 2 を期待したが exit $enq_rc"
# (o) steps が配列でない -> exit 2
enq_rc=0
printf '%s' '{"candidates":[78],"steps":{}}' | python3 "$ENQUEUE" >/dev/null 2>&1 || enq_rc=$?
[ "$enq_rc" -eq 2 ] || fail "(o) steps 非配列で exit 2 を期待したが exit $enq_rc"
# (p) steps 要素がオブジェクトでない -> exit 2
enq_rc=0
printf '%s' '{"candidates":[78],"steps":["x"]}' | python3 "$ENQUEUE" >/dev/null 2>&1 || enq_rc=$?
[ "$enq_rc" -eq 2 ] || fail "(p) steps 要素が非オブジェクトで exit 2 を期待したが exit $enq_rc"
# (q) 非オブジェクト入力 (配列) -> exit 2
enq_rc=0
printf '%s' '["not","an","object"]' | python3 "$ENQUEUE" >/dev/null 2>&1 || enq_rc=$?
[ "$enq_rc" -eq 2 ] || fail "(q) 非オブジェクト入力で exit 2 を期待したが exit $enq_rc"
echo "[16/17] decide-enqueue-steps 不正入力 exit 2 境界 OK"

# --- 17. 完了 -----------------------------------------------------------------
echo "[17/17] 全アサーション通過"
echo "SMOKE OK"
