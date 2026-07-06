#!/usr/bin/env python3
"""has_blocker の再集計 (harness-kit 定義)。python3 標準ライブラリのみの 1 ファイル。

/harness-review-pr 手順 5.5 の判定器。LLM の解釈で判定させず、ここで決定論的に判定する。

使い方:
    stdin に findings JSON 配列を渡す:
        [{"severity": "🔴"|"🟡"|"🟢", "sources": ["..."], ...}, ...]
    stdout に判定結果 JSON を返す:
        {"has_blocker": bool, "blocker_count": n,
         "unknown_source_blockers": [...], "unknown_severity_blockers": [...]}

規則 (severity は完全一致ではなく包含判定 — "🔴 critical" のような付記も拾う):
- severity に 🔴 を含む → blocker
- severity に 🟡 を含む:
  - sources に arch 系 (`arch` を含む) または google 系 (`google` を含む) → blocker
  - sources が code-review 系 (`code-review` を含む) のみ → 非 blocker
  - sources がどの既知系にも一致しない → blocker (fail-closed)。
    一致しなかった source 表記を unknown_source_blockers に記録する
    (表記ゆれ・skill 出力の変化で 🟡 が素通しになるのを防ぐ)
- severity に 🟢 を含む → 非 blocker
- severity がどの絵文字も含まない / 欠損 / 非文字列 → blocker (fail-closed)。
  該当 finding の識別情報を unknown_severity_blockers に記録する
  ("red" のような表記ゆれや欠損で blocker が素通しになるのを防ぐ)

入力の findings 配列が JSON として読めない / 配列でない / 要素がオブジェクトでない場合は
exit 2 (判定エラーと入力エラーを区別する)。判定自体は has_blocker の真偽によらず exit 0。
"""

import json
import sys

SEV_RED = "🔴"
SEV_YELLOW = "🟡"
SEV_GREEN = "🟢"


def input_error(cause):
    print(f"::error:: reaggregate-has-blocker: {cause}", file=sys.stderr)
    sys.exit(2)


def is_arch(source):
    # "reviewing-pr-architecture" も "arch" を含むのでこの 1 判定で足りる
    return "arch" in source


def is_google(source):
    return "google" in source


def is_code_review(source):
    return "code-review" in source


def is_known(source):
    return is_arch(source) or is_google(source) or is_code_review(source)


def reaggregate(findings):
    blocker_count = 0
    unknown_source_blockers = []
    unknown_severity_blockers = []
    for i, f in enumerate(findings):
        if not isinstance(f, dict):
            input_error(f"findings[{i}] がオブジェクトでない ({f!r})。")
        severity = f.get("severity")
        sev = severity if isinstance(severity, str) else ""
        if SEV_RED in sev:
            blocker_count += 1
            continue
        if SEV_YELLOW in sev:
            sources = [s for s in (f.get("sources") or []) if isinstance(s, str)]
            if any(is_arch(s) or is_google(s) for s in sources):
                blocker_count += 1
            elif sources and all(is_code_review(s) for s in sources):
                pass  # code-review 系単独由来の 🟡 は非 blocker
            else:
                # fail-closed: 既知系に一致しない source (または sources 無し) は blocker 扱い
                blocker_count += 1
                for s in sources or ["(sources なし)"]:
                    if not is_known(s) and s not in unknown_source_blockers:
                        unknown_source_blockers.append(s)
            continue
        if SEV_GREEN in sev:
            continue  # 🟢 (nit・好み) は blocker にしない
        # fail-closed: どの絵文字も含まない・欠損・非文字列の severity は blocker 扱い
        # ("red" のような表記ゆれ・欠損の素通しを防ぐ)
        blocker_count += 1
        unknown_severity_blockers.append(
            {"index": i, "severity": severity, "summary": f.get("summary")})
    return {
        "has_blocker": blocker_count > 0,
        "blocker_count": blocker_count,
        "unknown_source_blockers": unknown_source_blockers,
        "unknown_severity_blockers": unknown_severity_blockers,
    }


def main():
    try:
        findings = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        input_error(f"stdin を JSON として読めない ({e})。")
    if not isinstance(findings, list):
        input_error("入力が findings の JSON 配列でない。")
    print(json.dumps(reaggregate(findings), ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
