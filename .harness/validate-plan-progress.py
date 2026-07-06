#!/usr/bin/env python3
"""plan-progress.json の検証器 (agent-harness-kit)。python3 標準ライブラリのみの 1 ファイル。

使い方:
    python3 validate-plan-progress.py --schema <plan-progress.json>
        enum 逸脱 / 型 / 必須キー / 整合規則 / evidence-gate を検査する (ネットワーク不要)。
    python3 validate-plan-progress.py --drift <plan-progress.json>
        gh コマンドで GitHub の実態と台帳の githubState / isDraft を突き合わせる
        (gh の認証が必要。CI では GH_TOKEN を渡す)。

status の語彙 (enum) は plan-progress.schema.json から読む (単一源)。schema は台帳ファイルと
同じディレクトリのものを優先し、無ければこのスクリプトと同じディレクトリのものを使う。
コードが参照する status / githubState のリテラル (ready 系・終端系) は起動時ガードで
schema の enum と突き合わせ、schema 改名にコードが未追随なら exit 1 で止める。

判定は一方向: 台帳の主張が GitHub と矛盾したら fail。GitHub に在って台帳に無いものは不問
(ただし number を主張する step は githubState も主張しなければならない — 穴を閉じるため)。
主張規則 (number の型 / number⇒githubState / 終端 status⇒githubState 整合) は --schema と
--drift の両モードで検査する (--drift 単独の手元実行でも素通しさせない)。
失敗は「::error:: <場所>: <原因> <修正方法>」を出力して exit 1。成功は exit 0。
gh 呼出そのものの失敗 (未インストール / 認証切れ等) は drift ではなく実行エラーとして
「gh 呼出に失敗した」系の文言で fail する。

exit code: 0 = 合格 / 1 = 検査失敗 (実行エラー含む) / 2 = usage エラー (引数不正)。
"""

import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

# コードが参照する status / githubState のリテラル。
# 起動時ガード (check_literals) で schema の enum に含まれることを検査する。
READY_ISSUE_STATUS = "ready for implementation"
READY_PR_STATUS = "ready for merge"
IMPL_READY_PR_STATUS = "implementation-ready"
MERGED_PR_STATUS = "merged pr"
CLOSED_ISSUE_STATUS = "closed issue"
GH_STATE_MERGED = "merged"
GH_STATE_CLOSED = "closed"

errors = []


def err(where, cause, fix):
    errors.append(f"::error:: {where}: {cause} {fix}")


def fatal(where, cause, fix):
    print(f"::error:: {where}: {cause} {fix}")
    sys.exit(1)


def is_int(v):
    """bool は int の派生型なので除外する。"""
    return isinstance(v, int) and not isinstance(v, bool)


def is_blank(v):
    """None または空白のみ文字列。evidence-gate では null と同等 (実行できるコマンドでない) に扱う。"""
    return v is None or (isinstance(v, str) and not v.strip())


def load_json(path, label):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        fatal(label, f"{path} が見つからない。", "パスを確認するか /harness-init で生成する")
    except json.JSONDecodeError as e:
        fatal(label, f"JSON として読めない ({e})。", "構文を修正する")


def resolve_schema_path(target):
    """schema の解決: 台帳ファイルと同じディレクトリを優先、無ければスクリプト位置 (fallback)。

    WHY: 新旧混在環境 (kit 側の新 schema と導入先の旧 schema が並存する等) で、
    台帳を別の場所の schema で検査して取り違えるのを防ぐ — 台帳が置かれた側の schema が正。
    """
    ledger_side = Path(target).resolve().parent / "plan-progress.schema.json"
    if ledger_side.is_file():
        return ledger_side
    return Path(__file__).resolve().parent / "plan-progress.schema.json"


def load_enums(schema_path):
    """plan-progress.schema.json から status / githubState の enum を読む (単一源)。"""
    schema = load_json(schema_path, "schema")
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


def check_literals(issue_status, pr_status, issue_gh, pr_gh):
    """起動時ガード: コードが参照するリテラルが schema の enum に含まれることを検査する。

    schema 側で status / githubState を改名したのにこのファイルが未追随のまま動く
    (検査が空振りして素通しになる) 事故を防ぐ。
    """
    checks = [
        ("READY_ISSUE_STATUS", READY_ISSUE_STATUS, issue_status, "definitions.issueStatus"),
        ("CLOSED_ISSUE_STATUS", CLOSED_ISSUE_STATUS, issue_status, "definitions.issueStatus"),
        ("READY_PR_STATUS", READY_PR_STATUS, pr_status, "definitions.prStatus"),
        ("IMPL_READY_PR_STATUS", IMPL_READY_PR_STATUS, pr_status, "definitions.prStatus"),
        ("MERGED_PR_STATUS", MERGED_PR_STATUS, pr_status, "definitions.prStatus"),
        ("GH_STATE_CLOSED", GH_STATE_CLOSED, issue_gh, "issue.githubState"),
        ("GH_STATE_MERGED", GH_STATE_MERGED, pr_gh, "pr.githubState"),
    ]
    for name, literal, enum, enum_name in checks:
        if literal not in enum:
            fatal("literal-guard",
                  f"コードのリテラル {name}={literal!r} が schema の {enum_name} の enum に無い"
                  " (schema 改名にコードが未追随)。",
                  "validate-plan-progress.py のリテラルを schema に合わせて更新する")


# ---------------------------------------------------------------------------
# 主張規則 (--schema / --drift 両モード共通)
# ---------------------------------------------------------------------------

def check_claims(p, where, phase):
    """フェーズ (issue / pr) の主張規則を検査する。

    WHY 両モード共通: --drift 単独の手元実行 (schema 検査を併走しない) でも、
    number の型崩れ / githubState:null / 終端 status の不整合が素通しにならないよう、
    GitHub との照合前にここで検査する。
    """
    if not isinstance(p, dict):
        return
    n = p.get("number")

    # number が非 null なら整数型 (型崩れは drift 照合もすり抜けるため主張規則で止める)
    if n is not None and not is_int(n):
        err(f"{where}.{phase}.number", f"整数か null でない ({n!r})。",
            "GitHub の番号 (整数) か null にする")

    # number を主張するなら githubState も主張する
    # (githubState:null のままだと drift の一方向判定をすり抜けるため)
    if n is not None and p.get("githubState") is None:
        states = "open / closed" if phase == "issue" else "open / merged / closed"
        err(f"{where}.{phase}.githubState",
            f"number ({n!r}) があるのに githubState が null。",
            f"GitHub の実態 ({states}) を写す")

    # 終端 status なら githubState も終端でなければならない
    if phase == "pr" and p.get("status") == MERGED_PR_STATUS and p.get("githubState") != GH_STATE_MERGED:
        err(f"{where}.pr",
            f'status が "{MERGED_PR_STATUS}" なのに githubState が'
            f" {p.get('githubState')!r}。",
            f'実際に merge されたなら githubState を "{GH_STATE_MERGED}" にする'
            "。されていないなら status を戻す")
    if phase == "issue" and p.get("status") == CLOSED_ISSUE_STATUS and p.get("githubState") != GH_STATE_CLOSED:
        err(f"{where}.issue",
            f'status が "{CLOSED_ISSUE_STATUS}" なのに githubState が'
            f" {p.get('githubState')!r}。",
            f'実際に close されたなら githubState を "{GH_STATE_CLOSED}" にする'
            "。されていないなら status を戻す")


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
    # number の型は主張規則 (check_claims — 両モード共通) 側で検査する
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


def check_schema(data, enums):
    issue_status_enum, pr_status_enum, issue_gh_enum, pr_gh_enum = enums

    if not isinstance(data, dict):
        err("(top-level)", "オブジェクトでない。", "plan-progress.json 全体を {...} にする")
        return

    for key in ("updatedAt", "evidence", "steps"):
        if key not in data:
            err(key, "必須キーが無い。", "plan-progress.init.json を参考にキーを追加する")

    # 再導入防止 (恒久規則): 台帳に statusEnums を置かない — 複製が schema と黙って乖離するため
    if "statusEnums" in data:
        err("statusEnums", "台帳に statusEnums を置かない (語彙の単一源は schema)。",
            "statusEnums キーを削除する (enum は plan-progress.schema.json だけが持つ)")

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
                if pr and pr.get("number") is None and pr.get("status") not in (None, IMPL_READY_PR_STATUS):
                    err(f"{where}.pr",
                        f"number が null なのに status が {pr.get('status')!r}。",
                        f'PR を作成して number を入れるか、status を null / "{IMPL_READY_PR_STATUS}" に戻す')

                # 主張規則 (number 型 / number⇒githubState / 終端整合) — 両モード共通実装
                check_claims(issue, where, "issue")
                check_claims(pr, where, "pr")

                if issue and issue.get("status") == READY_ISSUE_STATUS:
                    ready_exists = True
                if pr and pr.get("status") == READY_PR_STATUS:
                    ready_exists = True

    # evidence-gate: ready 系 status の step があるなら evidence.test は non-null
    # (init 忘れ・削除を防ぐ「床」。test が実際に走った保証ではない)
    # 空白のみの文字列は「実行できるコマンド」ではないので null と同等に扱う (素通し防止)
    if ready_exists and (not isinstance(evidence, dict) or is_blank(evidence.get("test"))):
        err("evidence.test",
            f'"{READY_ISSUE_STATUS}" / "{READY_PR_STATUS}" の step があるのに evidence.test が null'
            " または空白のみ。",
            "test を実行するコマンドを evidence.test に設定する")


# ---------------------------------------------------------------------------
# --drift: gh で GitHub の実態と照合
# ---------------------------------------------------------------------------

def resolve_repo_root(target):
    """台帳ファイルのある git repo ルートを解決する (gh を照合先 repo に固定するため)。"""
    ledger_dir = Path(target).resolve().parent
    try:
        res = subprocess.run(
            ["git", "-C", str(ledger_dir), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True)
    except FileNotFoundError:
        fatal("drift", "git コマンドが見つからない。", "git をインストールする")
    if res.returncode != 0 or not res.stdout.strip():
        fatal("drift",
              f"台帳 ({target}) のある git repo ルートを解決できない ({res.stderr.strip()})。",
              "台帳を git repo 内に置く (照合先 repo の固定に必要)")
    return res.stdout.strip()


def flush_errors_then_fatal(where, cause, fix):
    # WHY: drift 検査ループの途中で fatal すると蓄積済みの検出済み drift が消える (診断情報の損失) ため、先に全件出力する
    for e in errors:
        print(e)
    fatal(where, cause, fix)


def gh_json(args, where, cwd):
    """gh を台帳のある repo ルート (cwd) で実行する。失敗は drift ではなく実行エラー。

    返り値は「state (非空文字列) を持つ JSON オブジェクト (dict)」であることまで検証する
    (json.loads は null / 配列 / 文字列も受理するため、形状崩れは照合前にここで止める。
    両呼出元 (issue view / pr view) とも --json state を要求する前提)。
    """
    try:
        res = subprocess.run(["gh"] + args, capture_output=True, text=True, cwd=cwd)
    except FileNotFoundError:
        flush_errors_then_fatal(where, "gh コマンドが見つからない (drift 検査は実行できていない)。",
                                "gh をインストールして認証する")
    if res.returncode != 0:
        flush_errors_then_fatal(
            where, f"gh 呼出に失敗した ({res.stderr.strip()})。drift ではなく実行エラー。",
            "番号の実在と gh の認証 (GH_TOKEN) を確認する")
    try:
        parsed = json.loads(res.stdout)
    except json.JSONDecodeError:
        flush_errors_then_fatal(
            where, f"gh の出力を JSON として読めない ({res.stdout.strip()!r})。",
            "gh のバージョンを確認する")
    if not isinstance(parsed, dict):
        flush_errors_then_fatal(
            where, f"gh の出力が JSON オブジェクトでない ({res.stdout.strip()!r})。",
            "gh のバージョンを確認する")
    state = parsed.get("state")
    if not isinstance(state, str) or not state.strip():
        flush_errors_then_fatal(
            where, f"gh の出力に state (非空文字列) が無い ({res.stdout.strip()!r})。",
            "gh のバージョンと --json state の対応を確認する")
    return parsed


def check_drift(data, repo_root):
    steps = data.get("steps") if isinstance(data, dict) else None
    if not isinstance(steps, list):
        fatal("steps", "配列でない。", "先に --schema 検査を通す")
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        sid = step.get("id") if isinstance(step.get("id"), str) else str(i)

        # 主張規則 (number 型 / number⇒githubState / 終端整合) — 照合前に検査する。
        # --schema を併走しない手元単独実行でも false-pass させない (両モード共通実装)
        check_claims(step.get("issue"), f"steps[{sid}]", "issue")
        check_claims(step.get("pr"), f"steps[{sid}]", "pr")

        issue = step.get("issue")
        if isinstance(issue, dict) and is_int(issue.get("number")):
            n = issue["number"]
            actual = gh_json(["issue", "view", str(n), "--json", "state"],
                             f"steps[{sid}].issue", repo_root)
            actual_state = actual["state"].lower()
            claimed = issue.get("githubState")
            if claimed is not None and claimed != actual_state:
                err(f"steps[{sid}].issue.githubState",
                    f"台帳は {claimed!r} だが GitHub (issue #{n}) は {actual_state!r}。",
                    f'githubState を "{actual_state}" に更新する')

        pr = step.get("pr")
        if isinstance(pr, dict) and is_int(pr.get("number")):
            n = pr["number"]
            actual = gh_json(["pr", "view", str(n), "--json", "state,isDraft"],
                             f"steps[{sid}].pr", repo_root)
            actual_state = actual["state"].lower()
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

    # 起動時ガード: コードが参照するリテラルを schema の enum と突き合わせる (両モード共通)
    enums = load_enums(resolve_schema_path(target))
    check_literals(*enums)

    data = load_json(target, "plan-progress")

    if mode == "--schema":
        check_schema(data, enums)
    else:
        check_drift(data, resolve_repo_root(target))

    if errors:
        for e in errors:
            print(e)
        sys.exit(1)
    print(f"OK: {mode} 検査を通過 ({target})")
    sys.exit(0)


if __name__ == "__main__":
    main()
