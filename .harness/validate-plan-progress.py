#!/usr/bin/env python3
"""plan-progress.json の検証器 (agent-harness-kit Phase 0)。python3 標準ライブラリのみの 1 ファイル。

使い方:
    python3 validate-plan-progress.py --schema <plan-progress.json>
        enum 逸脱 / 型 / 必須キー / 整合規則 / evidence-gate を検査する (ネットワーク不要)。
    python3 validate-plan-progress.py --drift <plan-progress.json>
        gh コマンドで GitHub の実態と台帳の githubState / isDraft を突き合わせる
        (gh の認証が必要。CI では GH_TOKEN を渡す)。

status の語彙 (enum) は同じディレクトリの plan-progress.schema.json から読む (単一源 —
このファイル内に enum を重複定義しない)。

判定は一方向: 台帳の主張が GitHub と矛盾したら fail。GitHub に在って台帳に無いものは不問。
失敗は「::error:: <場所>: <原因> <修正方法>」を出力して exit 1。成功は exit 0。
"""

import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

SCHEMA_PATH = Path(__file__).resolve().parent / "plan-progress.schema.json"

READY_ISSUE_STATUS = "ready for implementation"
READY_PR_STATUS = "ready for merge"

errors = []


def err(where, cause, fix):
    errors.append(f"::error:: {where}: {cause} {fix}")


def fatal(where, cause, fix):
    print(f"::error:: {where}: {cause} {fix}")
    sys.exit(1)


def is_int(v):
    """bool は int の派生型なので除外する。"""
    return isinstance(v, int) and not isinstance(v, bool)


def load_json(path, label):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        fatal(label, f"{path} が見つからない。", "パスを確認するか /harness-init で生成する")
    except json.JSONDecodeError as e:
        fatal(label, f"JSON として読めない ({e})。", "構文を修正する")


def load_enums():
    """plan-progress.schema.json から status / githubState の enum を読む (単一源)。"""
    schema = load_json(SCHEMA_PATH, "schema")
    try:
        defs = schema["definitions"]
        issue_status = defs["issueStatus"]["enum"]
        pr_status = defs["prStatus"]["enum"]
        issue_gh = defs["step"]["properties"]["issue"]["properties"]["githubState"]["enum"]
        pr_gh = defs["step"]["properties"]["pr"]["properties"]["githubState"]["enum"]
    except (KeyError, TypeError) as e:
        fatal("schema", f"plan-progress.schema.json に期待する定義が無い ({e})。",
              "templates の原本から複製し直す")
    return issue_status, pr_status, issue_gh, pr_gh


# ---------------------------------------------------------------------------
# --schema: enum / 型 / 必須キー / 整合規則 / evidence-gate
# ---------------------------------------------------------------------------

def check_phase(step, where, phase, status_enum, gh_enum):
    """step の issue / pr フェーズを検査し、フェーズの dict (無効なら None) を返す。"""
    if phase not in step:
        err(f"{where}.{phase}", "必須キーが無い。",
            '{"number": null, "status": null, "githubState": null} を追加する')
        return None
    p = step[phase]
    if not isinstance(p, dict):
        err(f"{where}.{phase}", "オブジェクトでない。",
            '{"number", "status", "githubState"} を持つオブジェクトにする')
        return None
    for k in ("number", "status", "githubState"):
        if k not in p:
            err(f"{where}.{phase}.{k}", "必須キーが無い。", "null でよいので明示する")
    n = p.get("number")
    if "number" in p and n is not None and not is_int(n):
        err(f"{where}.{phase}.number", f"整数か null でない ({n!r})。",
            "GitHub の番号 (整数) か null にする")
    if "status" in p and p.get("status") not in status_enum:
        err(f"{where}.{phase}.status", f"enum 外の値 ({p.get('status')!r})。",
            f"次のいずれかにする: {status_enum}")
    if "githubState" in p and p.get("githubState") not in gh_enum:
        err(f"{where}.{phase}.githubState", f"enum 外の値 ({p.get('githubState')!r})。",
            f"次のいずれかにする: {gh_enum}")
    if "lastReviewedStatus" in p and p.get("lastReviewedStatus") not in status_enum:
        err(f"{where}.{phase}.lastReviewedStatus",
            f"enum 外の値 ({p.get('lastReviewedStatus')!r})。",
            f"次のいずれかにする: {status_enum}")
    if phase == "pr" and "isDraft" in p and not isinstance(p.get("isDraft"), bool):
        err(f"{where}.pr.isDraft", f"真偽値でない ({p.get('isDraft')!r})。",
            "true / false にするか削除する")
    return p


def check_schema(data):
    issue_status_enum, pr_status_enum, issue_gh_enum, pr_gh_enum = load_enums()

    if not isinstance(data, dict):
        err("(top-level)", "オブジェクトでない。", "plan-progress.json 全体を {...} にする")
        return

    for key in ("updatedAt", "statusEnums", "evidence", "steps"):
        if key not in data:
            err(key, "必須キーが無い。", "plan-progress.init.json を参考にキーを追加する")

    if "updatedAt" in data:
        updated = data["updatedAt"]
        if not isinstance(updated, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", updated):
            err("updatedAt", f"YYYY-MM-DD 形式の文字列でない ({updated!r})。",
                "例: 2026-07-06 の形式に修正する")
        else:
            try:
                datetime.date.fromisoformat(updated)
            except ValueError:
                err("updatedAt", f"実在しない日付 ({updated!r})。", "正しい日付に修正する")

    if "statusEnums" in data:
        se = data["statusEnums"]
        if (not isinstance(se, dict)
                or not isinstance(se.get("issue"), list)
                or not isinstance(se.get("pr"), list)):
            err("statusEnums", "issue / pr の配列を持つオブジェクトでない。",
                "plan-progress.init.json の statusEnums を複製する")

    evidence = data.get("evidence")
    if "evidence" in data:
        if not isinstance(evidence, dict):
            err("evidence", "オブジェクトでない。",
                '{"build", "test", "lint", "done"} を持つオブジェクトにする')
        else:
            for k in ("build", "test", "lint", "done"):
                if k not in evidence:
                    err(f"evidence.{k}", "必須キーが無い。", "コマンド文字列か null を設定する")
                elif evidence[k] is not None and not isinstance(evidence[k], str):
                    err(f"evidence.{k}", f"文字列か null でない ({evidence[k]!r})。",
                        "コマンド文字列か null にする")

    ready_exists = False
    if "steps" in data:
        steps = data["steps"]
        if not isinstance(steps, list):
            err("steps", "配列でない。", "steps を [] にする")
        else:
            for i, step in enumerate(steps):
                if not isinstance(step, dict):
                    err(f"steps[{i}]", "オブジェクトでない。", "step を {...} にする")
                    continue
                sid = step.get("id")
                where = f"steps[{sid if isinstance(sid, str) and sid else i}]"
                if not isinstance(sid, str) or not sid:
                    err(f"{where}.id", "空でない文字列でない。", "step に一意な id を付ける")
                for k in ("kind", "title"):
                    if k in step and not isinstance(step[k], str):
                        err(f"{where}.{k}", f"文字列でない ({step[k]!r})。",
                            "文字列にするか削除する")

                issue = check_phase(step, where, "issue", issue_status_enum, issue_gh_enum)
                pr = check_phase(step, where, "pr", pr_status_enum, pr_gh_enum)

                # 整合規則: number が null なら status は「まだ何も起きていない」側に限る
                if issue and issue.get("number") is None and issue.get("status") is not None:
                    err(f"{where}.issue",
                        f"number が null なのに status が {issue.get('status')!r}。",
                        "issue を起票して number を入れるか、status を null に戻す")
                if pr and pr.get("number") is None and pr.get("status") not in (None, "implementation-ready"):
                    err(f"{where}.pr",
                        f"number が null なのに status が {pr.get('status')!r}。",
                        'PR を作成して number を入れるか、status を null / "implementation-ready" に戻す')

                if issue and issue.get("status") == READY_ISSUE_STATUS:
                    ready_exists = True
                if pr and pr.get("status") == READY_PR_STATUS:
                    ready_exists = True

    # evidence-gate: ready 系 status の step があるなら evidence.test は non-null
    # (init 忘れ・削除を防ぐ「床」。test が実際に走った保証ではない)
    if ready_exists and (not isinstance(evidence, dict) or evidence.get("test") is None):
        err("evidence.test",
            f'"{READY_ISSUE_STATUS}" / "{READY_PR_STATUS}" の step があるのに evidence.test が null。',
            "test を実行するコマンドを evidence.test に設定する")


# ---------------------------------------------------------------------------
# --drift: gh で GitHub の実態と照合
# ---------------------------------------------------------------------------

def gh_json(args, where):
    try:
        res = subprocess.run(["gh"] + args, capture_output=True, text=True)
    except FileNotFoundError:
        fatal(where, "gh コマンドが見つからない。", "gh をインストールして認証する")
    if res.returncode != 0:
        fatal(where, f"gh 呼出に失敗した ({res.stderr.strip()})。",
              "番号の実在と gh の認証 (GH_TOKEN) を確認する")
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError:
        fatal(where, f"gh の出力を JSON として読めない ({res.stdout.strip()!r})。",
              "gh のバージョンを確認する")


def check_drift(data):
    steps = data.get("steps") if isinstance(data, dict) else None
    if not isinstance(steps, list):
        fatal("steps", "配列でない。", "先に --schema 検査を通す")
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        sid = step.get("id") if isinstance(step.get("id"), str) else str(i)

        issue = step.get("issue")
        if isinstance(issue, dict) and is_int(issue.get("number")):
            n = issue["number"]
            actual = gh_json(["issue", "view", str(n), "--json", "state"],
                             f"steps[{sid}].issue")
            actual_state = str(actual.get("state", "")).lower()
            claimed = issue.get("githubState")
            if claimed is not None and claimed != actual_state:
                err(f"steps[{sid}].issue.githubState",
                    f"台帳は {claimed!r} だが GitHub (issue #{n}) は {actual_state!r}。",
                    f'githubState を "{actual_state}" に更新する')

        pr = step.get("pr")
        if isinstance(pr, dict) and is_int(pr.get("number")):
            n = pr["number"]
            actual = gh_json(["pr", "view", str(n), "--json", "state,isDraft"],
                             f"steps[{sid}].pr")
            actual_state = str(actual.get("state", "")).lower()
            claimed = pr.get("githubState")
            if claimed is not None and claimed != actual_state:
                err(f"steps[{sid}].pr.githubState",
                    f"台帳は {claimed!r} だが GitHub (PR #{n}) は {actual_state!r}。",
                    f'githubState を "{actual_state}" に更新する')
            # isDraft はキーがある場合のみ照合 (一方向判定)
            if "isDraft" in pr and pr.get("isDraft") != actual.get("isDraft"):
                err(f"steps[{sid}].pr.isDraft",
                    f"台帳は {pr.get('isDraft')!r} だが GitHub (PR #{n}) は {actual.get('isDraft')!r}。",
                    "isDraft を GitHub に合わせる")


# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("--schema", "--drift"):
        print("usage: validate-plan-progress.py (--schema|--drift) <plan-progress.json>",
              file=sys.stderr)
        sys.exit(2)
    mode, target = sys.argv[1], sys.argv[2]
    data = load_json(target, "plan-progress")

    if mode == "--schema":
        check_schema(data)
    else:
        check_drift(data)

    if errors:
        for e in errors:
            print(e)
        sys.exit(1)
    print(f"OK: {mode} 検査を通過 ({target})")
    sys.exit(0)


if __name__ == "__main__":
    main()
