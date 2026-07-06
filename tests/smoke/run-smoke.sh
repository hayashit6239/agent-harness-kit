#!/usr/bin/env bash
# agent-harness-kit smoke テスト — LLM 不要・決定論的。
#
# 1. fixture (捨て repo) に templates を複製し、evidence.test を実コマンドで埋めた
#    plan-progress.json を組み立てる (drift 検査が repo ルートを解決できるよう git init する)
# 2. validate --schema が exit 0
# 3. evidence.test の実行が exit 0
# 4. 失敗 9 パターン (enum 逸脱 / 整合規則 / evidence-gate / drift / statusEnums 残存 /
#    githubState null / 終端不整合 / literal-guard / isDraft drift) がすべて non-zero で、
#    かつ期待する ::error:: 文言 (どの検査で落ちたか) を出す
# 5. drift の正系 (stub gh が台帳と一致) が exit 0 / gh 実行失敗が drift と区別されて fail する /
#    gh が途中で失敗しても蓄積済みの検出済み drift が全件出力される
# 6. reaggregate-has-blocker (has_blocker 再集計) の単体判定が期待通り (fail-closed 境界を含む)
# 7. kit 自身の checkout (.harness/ がある場合) なら templates と複製の diff が空
#    (templates/ の全ファイルがペア列挙 + 既知除外でカバーされていることも検査)
# 8. すべて通れば "SMOKE OK" を出して exit 0
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
echo "[1/8] fixture + .harness/ を組み立てた: $REPO"

# --- 2. schema 検証: exit 0 を期待 ------------------------------------------
python3 "$VALIDATOR" --schema "$PLAN" \
  || fail "正常な plan-progress.json で --schema が失敗した"
echo "[2/8] --schema exit 0"

# --- 3. evidence.test 実行: exit 0 を期待 ------------------------------------
TEST_CMD="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["evidence"]["test"])' "$PLAN")"
( cd "$REPO" && eval "$TEST_CMD" ) \
  || fail "evidence.test ($TEST_CMD) が exit 0 で終わらなかった"
echo "[3/8] evidence.test ($TEST_CMD) exit 0"

# --- 4. 失敗 9 パターン (すべて non-zero + 期待文言を期待) --------------------

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
else:
    raise SystemExit(f"unknown mode: {mode}")
d["steps"] = [step]
with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
}

# (i) enum 逸脱
make_broken "$TMP/broken-enum.json" enum
expect_fail_with "(i) enum 逸脱" \
  "steps[S1].pr.status: enum 外の値" \
  python3 "$VALIDATOR" --schema "$TMP/broken-enum.json"
echo "[4/8] (i) enum 逸脱 -> non-zero + 期待文言"

# (ii) 整合規則 (number:null なのに status:"created pr")
make_broken "$TMP/broken-consistency.json" consistency
expect_fail_with "(ii) 整合規則違反" \
  "number が null なのに status が 'created pr'" \
  python3 "$VALIDATOR" --schema "$TMP/broken-consistency.json"
echo "[4/8] (ii) 整合規則違反 -> non-zero + 期待文言"

# (iii) evidence-gate (ready 系 status ありで evidence.test:null)
make_broken "$TMP/broken-evidence.json" evidence
expect_fail_with "(iii) evidence-gate" \
  "evidence.test が null" \
  python3 "$VALIDATOR" --schema "$TMP/broken-evidence.json"
echo "[4/8] (iii) evidence-gate -> non-zero + 期待文言"

# (iv) drift: PATH 先頭に固定 JSON を返す gh の代役 (stub) を置き、
#      台帳の githubState (open) と食い違わせる。台帳は git repo 内に置く
#      (validator が台帳の repo ルートで gh を実行するため)
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

DRIFT_PLAN="$HARNESS/drift-ledger.json"
make_broken "$DRIFT_PLAN" drift
expect_fail_with "(iv) drift 食い違い" \
  "台帳は 'open' だが GitHub (PR #1) は 'merged'" \
  env PATH="$STUB_MISMATCH:$PATH" python3 "$VALIDATOR" --drift "$DRIFT_PLAN"
echo "[4/8] (iv) drift 食い違い -> non-zero + 期待文言"

# (v) 旧形式の statusEnums 複製が台帳に残っている (再導入防止ガード)
make_broken "$TMP/broken-statusenums.json" statusenums
expect_fail_with "(v) statusEnums 残存" \
  "台帳に statusEnums を置かない" \
  python3 "$VALIDATOR" --schema "$TMP/broken-statusenums.json"
echo "[4/8] (v) statusEnums 残存 -> non-zero + 期待文言"

# (vi) number があるのに githubState:null
make_broken "$TMP/broken-ghstate-null.json" ghstate-null
expect_fail_with "(vi) githubState null" \
  "number (1) があるのに githubState が null" \
  python3 "$VALIDATOR" --schema "$TMP/broken-ghstate-null.json"
echo "[4/8] (vi) githubState null -> non-zero + 期待文言"

# (vii) 終端 status "merged pr" なのに githubState が open
make_broken "$TMP/broken-terminal.json" terminal-mismatch
expect_fail_with "(vii) 終端不整合" \
  'status が "merged pr" なのに githubState が '"'open'" \
  python3 "$VALIDATOR" --schema "$TMP/broken-terminal.json"
echo "[4/8] (vii) 終端不整合 -> non-zero + 期待文言"

# (viii) literal-guard: schema 複製から "ready for merge" を取り除いた壊れ schema を
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
echo "[4/8] (viii) literal-guard -> non-zero + 期待文言"

# (ix) isDraft drift: 台帳は isDraft:false、stub gh は state 一致 (OPEN) だが isDraft:true
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
echo "[4/8] (ix) isDraft drift -> non-zero + 期待文言"

# --- 5. drift の正系 / gh 実行失敗の区別 --------------------------------------

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
echo "[5/8] drift 正系 -> exit 0"

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
echo "[5/8] gh 実行失敗 -> non-zero + 実行エラー文言 (drift と区別)"

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
echo "[5/8] gh 途中失敗 -> 検出済み drift + gh 失敗エラーの両方を出力して exit 1"

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
echo "[6/8] reaggregate-has-blocker 判定 10 ケース OK (fail-closed 境界を含む)"

# --- 7. kit 自身の checkout なら複製の一致を検査 ------------------------------
# (fixture への複製検証とは別。templates が原本、.harness/ と .github/ は複製)
if [ -d "$ROOT/.harness" ]; then
  COPY_PAIRS=(
    "templates/validate-plan-progress.py:.harness/validate-plan-progress.py"
    "templates/plan-progress.schema.json:.harness/plan-progress.schema.json"
    "templates/CLAUDE.harness.md:.harness/CLAUDE.harness.md"
    "templates/harness-gate.yml:.github/workflows/harness-gate.yml"
  )
  # 複製対象外の既知除外 (init.json は導入先で書き換わる雛形なので複製一致を求めない)
  COPY_EXCLUDED=(
    "templates/plan-progress.init.json"
  )

  # 列挙の fail-open 防止: templates/ に新ファイルが増えたのにペア列挙への追記が
  # 漏れると、複製一致検査が黙って素通しになる。全ファイルのカバーを検査する
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

  for pair in "${COPY_PAIRS[@]}"; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    diff -u "$ROOT/$src" "$ROOT/$dst" \
      || fail "複製が古い: $dst が $src と一致しない。cp で同期せよ (cp $src $dst)"
  done
  echo "[7/8] 複製一致検査 (kit checkout) OK (templates/ 全ファイルのカバーを含む)"
else
  echo "[7/8] 複製一致検査は skip (.harness/ が無い = kit checkout ではない)"
fi

# --- 8. 完了 ------------------------------------------------------------------
echo "[8/8] 全アサーション通過"
echo "SMOKE OK"
