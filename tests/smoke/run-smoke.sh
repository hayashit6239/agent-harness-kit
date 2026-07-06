#!/usr/bin/env bash
# agent-harness-kit Phase 0 smoke テスト — LLM 不要・決定論的。
#
# 1. fixture (捨て repo) に templates を複製し、evidence.test を実コマンドで埋めた
#    plan-progress.json を組み立てる
# 2. validate --schema が exit 0
# 3. evidence.test の実行が exit 0
# 4. 失敗 4 パターン (enum 逸脱 / 整合規則 / evidence-gate / drift) がすべて non-zero
# 5. すべて通れば "SMOKE OK" を出して exit 0
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

# --- 1. fixture を複製し .harness/ を組み立てる -----------------------------
cp -R "$FIXTURE" "$TMP/target-repo"
REPO="$TMP/target-repo"
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
echo "[1/5] fixture + .harness/ を組み立てた: $REPO"

# --- 2. schema 検証: exit 0 を期待 ------------------------------------------
python3 "$VALIDATOR" --schema "$PLAN" \
  || fail "正常な plan-progress.json で --schema が失敗した"
echo "[2/5] --schema exit 0"

# --- 3. evidence.test 実行: exit 0 を期待 ------------------------------------
TEST_CMD="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["evidence"]["test"])' "$PLAN")"
( cd "$REPO" && eval "$TEST_CMD" ) \
  || fail "evidence.test ($TEST_CMD) が exit 0 で終わらなかった"
echo "[3/5] evidence.test ($TEST_CMD) exit 0"

# --- 4. 失敗 4 パターン (すべて non-zero を期待) ------------------------------

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
    # (iv) 台帳は open と主張 (stub gh は MERGED を返す)
    step["pr"] = {"number": 1, "status": "created pr", "githubState": "open"}
else:
    raise SystemExit(f"unknown mode: {mode}")
d["steps"] = [step]
with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
}

# (i) enum 逸脱
make_broken "$TMP/broken-enum.json" enum
if python3 "$VALIDATOR" --schema "$TMP/broken-enum.json" > /dev/null; then
  fail "(i) enum 外の status で --schema が成功してしまった"
fi
echo "[4/5] (i) enum 逸脱 -> non-zero"

# (ii) 整合規則 (number:null なのに status:"created pr")
make_broken "$TMP/broken-consistency.json" consistency
if python3 "$VALIDATOR" --schema "$TMP/broken-consistency.json" > /dev/null; then
  fail "(ii) number:null + status:'created pr' で --schema が成功してしまった"
fi
echo "[4/5] (ii) 整合規則違反 -> non-zero"

# (iii) evidence-gate (ready 系 status ありで evidence.test:null)
make_broken "$TMP/broken-evidence.json" evidence
if python3 "$VALIDATOR" --schema "$TMP/broken-evidence.json" > /dev/null; then
  fail "(iii) ready 系 + evidence.test:null で --schema が成功してしまった"
fi
echo "[4/5] (iii) evidence-gate -> non-zero"

# (iv) drift: PATH 先頭に固定 JSON を返す gh の代役 (stub) を置き、
#      台帳の githubState (open) と食い違わせる
STUB="$TMP/stub-bin"
mkdir -p "$STUB"
cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
# smoke 用 gh 代役: 台帳と食い違う固定 JSON を返す
case "$1 $2" in
  "pr view")    echo '{"state":"MERGED","isDraft":false}' ;;
  "issue view") echo '{"state":"CLOSED"}' ;;
  *)            echo '{}' ;;
esac
SH
chmod +x "$STUB/gh"

make_broken "$TMP/broken-drift.json" drift
if PATH="$STUB:$PATH" python3 "$VALIDATOR" --drift "$TMP/broken-drift.json" > /dev/null; then
  fail "(iv) githubState の食い違いで --drift が成功してしまった"
fi
echo "[4/5] (iv) drift 食い違い -> non-zero"

# --- 5. 完了 ------------------------------------------------------------------
echo "[5/5] 全アサーション通過"
echo "SMOKE OK"
