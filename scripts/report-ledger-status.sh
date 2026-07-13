#!/usr/bin/env bash
# 台帳検証の自己申告 (Statuses API) — ローカル台帳 (F案・issue #11/#17) の機械検証の代替。
#
# 状態遷移をローカルに書いたら、ローカルの validate-plan-progress.py (schema + drift) を実行し、
# その結果を対象 PR の head SHA へ Statuses API (POST /repos/{owner}/{repo}/statuses/{sha}) で
# 報告する。commit されないローカル台帳は GitHub ホスト CI が検証できないため、書込権限を持つ
# セッションが自己申告する。
#
# この自己申告は独立検証ゲートではなく「便宜シグナル (convenience signal)」である
# (spoof 可能・独立ランナー不在の受容コスト)。真の検証は別セッションの PR reviewer が
# 実際の diff/状態を初見で読むことが担う。設計上の位置づけと限界は
# .harness/CLAUDE.harness.md「台帳の書込経路」節を参照。
#
# commands/harness-orchestrate.md と commands/harness-review-pr.md の両方から呼ぶ単一の実体。
# 報告ロジックを散文に複製せず script を唯一の正とする (scripts/*.py と同じ境界)。
#
# 使い方:
#   report-ledger-status.sh <owner/repo> <head_sha> [context]
#     $1 <owner/repo> : 対象リポジトリ (例: hayashit6239/agent-harness-kit)
#     $2 <head_sha>   : 対象 PR の head SHA
#                       (gh pr view <n> --repo <repo> --json headRefOid --jq .headRefOid)
#     $3 [context]    : Statuses の context (省略時 harness-gate。
#                       branch protection の required check 名と一致させる)
#
# 全パスを絶対化する (CWD 非依存): ROOT / PLAN / validator を git のトップレベル基準で
# 解決するため、repo ルート以外の CWD で実行しても失敗しない (旧・散文複製版で混在していた
# 絶対 $PLAN + 相対 validator 呼出による CWD 依存失敗の根治)。
#
# 注: ネットワーク post (gh api) は smoke テストの対象外 (手動確認)。smoke は bash -n の
#     構文チェックのみ行う。
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: report-ledger-status.sh <owner/repo> <head_sha> [context]" >&2
  exit 2
fi

REPO="$1"
HEAD_SHA="$2"
CONTEXT="${3:-harness-gate}"

ROOT="$(git rev-parse --show-toplevel)"
PLAN="$ROOT/.harness/plan-progress.json"
VALIDATOR="$ROOT/.harness/validate-plan-progress.py"

if python3 "$VALIDATOR" --schema "$PLAN" \
   && python3 "$VALIDATOR" --drift "$PLAN"; then
  STATE=success
  DESC="ローカル台帳 schema/drift OK"
else
  STATE=failure
  DESC="ローカル台帳 schema/drift NG"
fi

gh api "repos/$REPO/statuses/$HEAD_SHA" \
  -f state="$STATE" -f context="$CONTEXT" -f description="$DESC" >/dev/null
