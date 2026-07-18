#!/usr/bin/env bash
# orchestrator が developer(実装役)/ developer(対応役)の dispatch 後に、独立した一時 worktree で
# evidence.done(無ければ evidence.test にフォールバック)を実行する共通手続き。
#
# commands/harness-orchestrate.md「developer(実装役)」手順 5・「developer(対応役)」手順 5 が
# ほぼ同一のロジック(variable naming が異なるだけ)を重複して持っていたのを dedup して
# 1 箇所へ抽出したもの(issue #38)。worktree 作成・残骸掃除ロジックを散文に複製しない —
# scripts/report-ledger-status.sh と同じ「規則は script が正・prose は I/O」境界。
#
# subagent が dispatch 中に作った worktree は削除済みの可能性があり参照できないため、orchestrator
# 自身が独立して PR の head ブランチを取得し専用の一時 worktree を作って実行する
# (roles/pr-reviewer.md 手順 4 の per-PR worktree パターンと同じ)。
#
# 使い方:
#   run-orchestrator-evidence-gate.sh <owner/repo> <pr_number>
#     $1 <owner/repo> : 対象リポジトリ
#     $2 <pr_number>  : 対象 PR 番号(実装役は復旧検索/返答で確定した番号、対応役は既存の pr.number)
#
# exit code:
#   0   : evidence 実行が exit 0(呼出側は pr_evidence_pass / evidence_pass へ解決する)
#   非0 : evidence 実行が非 0、または worktree 残骸の掃除自体が失敗した(呼出側は
#         pr_evidence_fail / evidence_fail へ解決し、古い残骸で誤って pass/fail を出すより
#         停止を優先する)
#
# 全パスを絶対化する(CWD 非依存): ROOT / PLAN / WORKTREE を git のトップレベル基準で解決するため、
# repo ルート以外の CWD で実行しても失敗しない(scripts/report-ledger-status.sh と同じ方針)。
#
# 注: ネットワーク呼出(gh pr view / git fetch)・実際の worktree 作成は smoke テストの対象外
#     (手動確認)。smoke は bash -n の構文チェックのみ行う。
set -uo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: run-orchestrator-evidence-gate.sh <owner/repo> <pr_number>" >&2
  exit 2
fi

REPO="$1"
PR_NUMBER="$2"

ROOT="$(git rev-parse --show-toplevel)"
PLAN="$ROOT/.harness/plan-progress.json"

EVIDENCE_DONE=$(python3 - "$PLAN" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    plan = json.load(f)
evidence = plan.get("evidence") or {}
done = evidence.get("done") or evidence.get("test")
if not done:
    sys.exit(1)
print(done)
PY
)
if [ -z "$EVIDENCE_DONE" ]; then
  echo "::error:: 台帳の evidence.done / evidence.test が空(未設定)" >&2
  exit 1
fi

HEAD_REF=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefName --jq .headRefName)
git -C "$ROOT" fetch origin "$HEAD_REF" --quiet
WORKTREE="$ROOT/.claude/worktrees/orchestrate-pr-$PR_NUMBER"

# 残骸掃除つき add。直前 tick が remove 前に中断すると同一パスに古い worktree が残り add が失敗する。
# 失敗系の期待挙動(閉じた集合):
#   (a) 既存が同一 head でも「再利用せず」常に最新 origin/<head> で作り直す(未 fetch の古いコミット・
#       dirty な working tree で誤検証しないため、決定論的に「今の head を検証」を保証する)。
#   (b) locked/dirty で remove --force 自体が失敗したら掃除不能 → evidence を実行せず fail 扱い(sink)。
#   (c) admin record だけ残る(作業ディレクトリが消えている)場合は prune で解消してから再 add。
CLEANUP_FAILED=0
if ! git -C "$ROOT" worktree add --detach "$WORKTREE" "origin/$HEAD_REF"; then
  git -C "$ROOT" worktree remove --force "$WORKTREE"; REMOVE_EXIT=$?   # 残骸削除
  git -C "$ROOT" worktree prune                                        # (c) admin record 除去
  if [ "$REMOVE_EXIT" -ne 0 ]; then
    CLEANUP_FAILED=1                                        # (b) locked/dirty で remove 失敗 → 掃除不能
  elif ! git -C "$ROOT" worktree add --detach "$WORKTREE" "origin/$HEAD_REF"; then
    # 補助フォールバック: add --force で登録済みパスを上書き再利用(最新 head への確実な差し替えは
    # 保証されないため主手段にせず最後の手段のみ)。それも失敗なら掃除不能。
    git -C "$ROOT" worktree add --force --detach "$WORKTREE" "origin/$HEAD_REF" || CLEANUP_FAILED=1
  fi
fi

if [ "$CLEANUP_FAILED" -eq 1 ]; then
  EVIDENCE_EXIT=1                                           # (b) 掃除失敗 → 検証せず fail
else
  ( cd "$WORKTREE" && eval "$EVIDENCE_DONE" ); EVIDENCE_EXIT=$?
  git -C "$ROOT" worktree remove --force "$WORKTREE"        # 成否に関わらず後片付け
fi

exit "$EVIDENCE_EXIT"
