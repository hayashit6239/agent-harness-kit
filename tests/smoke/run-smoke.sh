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
#    (決定表の全 role×outcome 14 行を網羅 = reviewer の invalid 分岐 + implementer の
#    timeout 分岐 (issue #26) + 3 role 共通の主観的エスカレーション
#    (issue #31・subjective_escalate) の存在を機械保証 /
#    網羅ケース数と DECISION_TABLE のエントリ総数を突き合わせる行数ガード /
#    不正入力 exit 2 の境界を含む)
# 9. reconcile-dispatch-marker (dispatch in-flight マーカーの tick 冒頭 reconciliation 判定・
#    issue #26) の単体判定が期待通り (marker 不在→eligible / 進捗確認→clear / 締切未到達→wait /
#    締切超過でリトライ余地あり→redispatch(retry_count 加算) / リトライ上限到達→sink /
#    壊れた・不整合な marker→sink(fail-closed。progressed=true でも優先) の境界、
#    妥当性検証の各項目 (型崩れ・負値・deadline<dispatched・dispatched>current の未来矛盾)、
#    不正入力 exit 2 の境界を含む)。加えて選別(jq) 実装役 / 対応役 / pr reviewer 各ブロックの
#    dispatchMarker / reviewLock(issue #37)ガードを、commands/harness-orchestrate.md と同一の
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
#    不正入力 exit 2 の境界を含む)
# 13. すべて通れば "SMOKE OK" を出して exit 0
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
echo "[1/13] fixture + .harness/ を組み立てた: $REPO"

# --- 2. schema 検証: exit 0 を期待 ------------------------------------------
python3 "$VALIDATOR" --schema "$PLAN" \
  || fail "正常な plan-progress.json で --schema が失敗した"
echo "[2/13] --schema exit 0"

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
echo "[2/13] 検査規則の直接呼出 (import) OK"

# --- 3. evidence.test 実行: exit 0 を期待 ------------------------------------
TEST_CMD="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["evidence"]["test"])' "$PLAN")"
( cd "$REPO" && eval "$TEST_CMD" ) \
  || fail "evidence.test ($TEST_CMD) が exit 0 で終わらなかった"
echo "[3/13] evidence.test ($TEST_CMD) exit 0"

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
  echo "[4/13] $label -> non-zero + 期待文言"
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
echo "[4/13] (xviii) dependsOn A⇄B 循環 (issue #57 round 2) -> non-zero + 期待文言"

# --- 以下は形が特殊で表に入れない個別ケース (無理に畳むと可読性が落ちる)。
#     番号は据え置きのため、出力順は表 → 個別の順になり通し番号どおりではない ---

# (v) statusEnums 残存 (再導入防止ガード): 変異が step への標準変異でなく
#     台帳トップレベルへのキー追加のため、表に入れず個別に残す
make_broken "$TMP/broken-statusenums.json" statusenums
expect_fail_with "(v) statusEnums 残存" \
  "台帳に statusEnums を置かない" \
  python3 "$VALIDATOR" --schema "$TMP/broken-statusenums.json"
echo "[4/13] (v) statusEnums 残存 -> non-zero + 期待文言"

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
echo "[4/13] (viii) literal-guard -> non-zero + 期待文言"

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
echo "[4/13] (ix) isDraft drift -> non-zero + 期待文言"

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
echo "[5/13] drift 正系 -> exit 0"

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
echo "[5/13] gh 実行失敗 -> non-zero + 実行エラー文言 (drift と区別)"

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
echo "[5/13] gh 途中失敗 -> 検出済み drift + gh 失敗エラーの両方を出力して exit 1"

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
echo "[5/13] (xv) gh null 出力 -> dict 形状エラー + 蓄積済み drift を出力して exit 1"

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
echo "[6/13] reaggregate-has-blocker 判定ケース OK (fail-closed 境界・混在 sources・複数 findings 集計を含む)"

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
echo "[7/13] evaluate-stop-condition 判定ケース OK (round 上限・trend・trend の and/or 判別・fail-open 境界・has_blocker 抑止・round<3 短絡・同時成立・round=3 境界・不正入力 exit 2)"

# --- 8. decide-orchestrator-route (orchestrator ルーティング判定) の単体判定 ----
# evaluate-stop-condition / reaggregate-has-blocker と同型の pure decision script。
# 決定表の全 (role × outcome) 14 行を網羅検証する — この網羅により、reviewer の "invalid"
# 分岐 (dispatch 結果失敗 -> sink)、implementer の "timeout" 分岐 (issue #26・in-flight
# マーカーのリトライ上限到達/不整合 -> sink)、および 3 role 共通の主観的エスカレーション
# (issue #31・"subjective_escalate") が存在し正しく sink に落ちることが機械的に保証される
# (orchestrator の散文分岐が毎 round どこかずれる問題を構造的に止める)。さらに網羅ケース数と
# DECISION_TABLE のエントリ総数を突き合わせる行数ガードで「行追加時の assert 書き忘れ」を塞ぐ。
# 不正入力 exit 2 も含む。
DECIDE="$ROOT/scripts/decide-orchestrator-route.py"

# $1=ラベル $2=role $3=outcome $4=期待する出力 JSON (キー順・空白を正規化して比較。
#   full 一致にすることで ledger_write / route / label_action の過不足も 1 度に検出する)
# 各呼出で ROUTE_CASES を 1 加算し、後段の行数ガードで DECISION_TABLE のエントリ総数と突き合わせる
ROUTE_CASES=0
assert_route() {
  local label="$1" role="$2" outcome="$3" want="$4" out got wantc
  out="$(printf '{"role":"%s","outcome":"%s"}' "$role" "$outcome" | python3 "$DECIDE")" \
    || fail "$label: decide-orchestrator-route の実行に失敗した"
  got="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,ensure_ascii=False))')"
  wantc="$(printf '%s' "$want" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,ensure_ascii=False))')"
  if [ "$got" != "$wantc" ]; then
    fail "$label: 出力が期待と一致しない (got: $got / want: $wantc)"
  fi
  ROUTE_CASES=$((ROUTE_CASES + 1))
}

# implementer (6 outcome)
assert_route "(a) implementer/no_pr" implementer no_pr \
  '{"ledger_write":null,"route":"skip","label_action":null}'
assert_route "(b) implementer/ambiguous" implementer ambiguous \
  '{"ledger_write":null,"route":"sink","label_action":null}'
assert_route "(c) implementer/pr_evidence_pass" implementer pr_evidence_pass \
  '{"ledger_write":{"pr.number":true,"pr.githubState":"open","pr.status":"created pr"},"route":"normal","label_action":null}'
assert_route "(d) implementer/pr_evidence_fail (書いてから sink)" implementer pr_evidence_fail \
  '{"ledger_write":{"pr.number":true,"pr.githubState":"open","pr.status":"created pr"},"route":"sink","label_action":null}'
# (d2) implementer/timeout (issue #26: in-flight マーカーがリトライ上限到達 or 不整合 -> sink。
#   PR は実在しない (ambiguous と同型で書込なし))
assert_route "(d2) implementer/timeout (issue #26 マーカー有界化 -> sink)" implementer timeout \
  '{"ledger_write":null,"route":"sink","label_action":null}'
assert_route "(k) implementer/subjective_escalate (issue #31・PR 未作成 -> 書込なしで sink)" implementer subjective_escalate \
  '{"ledger_write":null,"route":"sink","label_action":null}'
# responder (3 outcome)
assert_route "(e) responder/evidence_pass" responder evidence_pass \
  '{"ledger_write":{"pr.status":"waiting for review"},"route":"normal","label_action":null}'
assert_route "(f) responder/evidence_fail" responder evidence_fail \
  '{"ledger_write":null,"route":"sink","label_action":null}'
assert_route "(l) responder/subjective_escalate (issue #31・書いてから sink)" responder subjective_escalate \
  '{"ledger_write":{"pr.status":"need for human review"},"route":"sink","label_action":null}'
# reviewer (全 5 outcome — invalid/escalate/clean_pass/blockers/subjective_escalate を必ず網羅する。
#   invalid は dispatch 結果失敗を単一 sink に落とす分岐で、この行が抜けると reviewer だけ
#   sink をすり抜ける — 全網羅で「表に invalid 行が在る」ことを機械保証する)
assert_route "(g) reviewer/invalid (dispatch 失敗 -> sink)" reviewer invalid \
  '{"ledger_write":null,"route":"sink","label_action":null}'
assert_route "(h) reviewer/escalate (停止条件 -> need for human review へ書いてから sink)" reviewer escalate \
  '{"ledger_write":{"pr.status":"need for human review"},"route":"sink","label_action":null}'
assert_route "(i) reviewer/clean_pass" reviewer clean_pass \
  '{"ledger_write":{"pr.status":"ready for merge"},"route":"normal","label_action":"add_ready_for_merge"}'
assert_route "(j) reviewer/blockers" reviewer blockers \
  '{"ledger_write":{"pr.status":"completed review"},"route":"normal","label_action":"remove_ready_for_merge"}'
assert_route "(m) reviewer/subjective_escalate (issue #31・客観 escalate とは別トリガーだが同じ sink)" reviewer subjective_escalate \
  '{"ledger_write":{"pr.status":"need for human review"},"route":"sink","label_action":null}'

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
echo "[8/13] decision-table 行数ガード OK (assert_route ケース数 $ROUTE_CASES == DECISION_TABLE エントリ数 $TABLE_ENTRIES)"

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
echo "[8/13] decide-orchestrator-route 判定ケース OK (全 role×outcome 14 行を網羅 + 不正入力 exit 2 境界)"

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
echo "[9/13] reconcile-dispatch-marker 判定ケース OK (eligible/clear/wait/redispatch/sink 全 action・境界・fail-closed を含む)"

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
echo "[9/13] reconcile-dispatch-marker 不正入力 exit 2 境界 OK"

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
echo "[9/13] 選別(jq) 実装役の dispatchMarker ガード OK (marker 残存 step (wait/redispatch 中) を候補から除外・後方互換: dependsOn 無しの step は従来どおり配車)"

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
echo "[9/13] 選別(jq) 実装役の dependsOn ガード OK (issue #51・全依存終端/一部未終端/空配列/キー欠損/存在しないid(fail-closed)/依存先discuss型の6境界 + DoD(ii-a) 同一tick 2件以上eligible)"

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
echo "[9/13] 選別(jq) 対応役 / pr reviewer の reviewLock ガード OK (issue #37・in-flight な step を候補から除外)"

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
argv = argv + ["false", "dispatchMarker"][len(argv) - 4:]
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
echo "[9/13] ledger_write 適用 (i) lw=null + clear_marker=true -> marker 単独削除 OK"

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
echo "[9/13] ledger_write 適用 (ii) lw 非 null + clear_marker=true -> ledger_write と marker 削除の原子適用 OK"

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
echo "[9/13] ledger_write 適用 (iii) clear_marker 省略 -> marker 不変 OK"

# (iv) lw=null かつ clear_marker=false(省略) -> ファイルへ一切書き込まない (no_pr 経路相当の no-op)
mk_lw_fixture
BEFORE_HASH="$(shasum -a 256 "$LW_PLAN" | cut -d' ' -f1)"
APPLY_LW "$LW_PLAN" "S1" '{"ledger_write":null}' ""
AFTER_HASH="$(shasum -a 256 "$LW_PLAN" | cut -d' ' -f1)"
[ "$BEFORE_HASH" = "$AFTER_HASH" ] || fail "(iv) lw=null+clear_marker=false: no-op のはずがファイルが変化した"
echo "[9/13] ledger_write 適用 (iv) lw=null + clear_marker 省略 -> no-op OK"

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
echo "[9/13] ledger_write 適用 (v) marker_field 省略 -> 既定 dispatchMarker のみ削除 OK (issue #37 後方互換)"

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
echo "[9/13] ledger_write 適用 (vi) marker_field=reviewLock -> reviewLock のみ削除 OK (issue #37)"

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
  echo "[10/13] 複製一致検査 (kit checkout) OK (templates/ 全ファイルのカバーを含む)"
else
  echo "[10/13] 複製一致検査は skip (.harness/ が無い = kit checkout ではない)"
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
  echo "[11/13] 抽出 script 群 (${#EXTRACTED_SCRIPTS[@]} 件) bash -n + shellcheck OK"
else
  echo "[11/13] 抽出 script 群 (${#EXTRACTED_SCRIPTS[@]} 件) bash -n OK (shellcheck 未導入のため skip)"
fi

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
echo "[12/13] detect-dispatch-collision 判定ケース OK (衝突なし/全件衝突/部分衝突(推移閉包)/独立 2 組/fail-closed/候補 0 件/単一候補)"

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
echo "[12/13] detect-dispatch-collision 不正入力 exit 2 境界 OK"

# --- 13. 完了 -----------------------------------------------------------------
echo "[13/13] 全アサーション通過"
echo "SMOKE OK"
