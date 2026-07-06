#!/usr/bin/env python3
"""has_blocker の再集計 (harness-kit 定義)。python3 標準ライブラリのみの 1 ファイル。

/harness-review-pr 手順 5.5 の判定器。LLM の解釈で判定させず、ここで決定論的に判定する。

使い方:
    stdin に findings JSON 配列を渡す:
        [{"severity": "🔴"|"🟡"|"🟢", "sources": ["..."], ...}, ...]
    stdout に判定結果 JSON を返す:
        {"has_blocker": bool, "blocker_count": n,
         "unknown_source_blockers": [...], "unknown_severity_blockers": [...]}

規則 (severity は完全一致ではなく包含判定 — "🔴 critical" のような付記も拾う。
source は正規化 (小文字化・前後空白除去) 後の既知集合との完全一致判定 —
部分文字列判定だと "not-a-code-review-skill" が code-review 系に、"deep-search" が
arch 系に誤マッチして素通し / 誤 blocker 化するため):
- 既知集合: code-review 系 = {"code-review", "/code-review"} /
  arch 系 = {"arch", "reviewing-pr-architecture"} /
  google 系 = {"google", "reviewing-pr-google-method"}
- severity に 🔴 を含む → blocker
- severity に 🟡 を含む:
  - sources のいずれかがどの既知集合にも完全一致しない (または sources 欠損・空) →
    blocker (fail-closed)。一致しなかった source 表記を unknown_source_blockers に記録する
    (表記ゆれ・skill 出力の変化で 🟡 が素通し / 誤 arch 化するのを防ぐ)
  - sources に arch 系または google 系 → blocker
  - sources が code-review 系のみ → 非 blocker
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

# source の既知集合 (正規化後の完全一致で照合する)。
# WHY 完全一致: 部分文字列判定だと "not-a-code-review-skill" が code-review 系 (非 blocker) に、
# "deep-search" が arch 系に誤マッチする — 未知 source は fail-closed で blocker + 記録に落とす
KNOWN_ARCH = {"arch", "reviewing-pr-architecture"}
KNOWN_GOOGLE = {"google", "reviewing-pr-google-method"}
KNOWN_CODE_REVIEW = {"code-review", "/code-review"}


def input_error(cause):
    print(f"::error:: reaggregate-has-blocker: {cause}", file=sys.stderr)
    sys.exit(2)


def normalize(source):
    """照合前の正規化: 小文字化 + 前後空白除去。"""
    return source.strip().lower()


def is_arch(source):
    return normalize(source) in KNOWN_ARCH


def is_google(source):
    return normalize(source) in KNOWN_GOOGLE


def is_code_review(source):
    return normalize(source) in KNOWN_CODE_REVIEW


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
            unknowns = [s for s in sources if not is_known(s)]
            if unknowns or not sources:
                # fail-closed: 既知集合に完全一致しない source (または sources 欠損・空) は
                # blocker 扱いにし、未知表記を必ず記録する (arch/google 混在時も記録する)
                blocker_count += 1
                for s in unknowns or ["(sources なし)"]:
                    if s not in unknown_source_blockers:
                        unknown_source_blockers.append(s)
            elif any(is_arch(s) or is_google(s) for s in sources):
                blocker_count += 1
            else:
                pass  # code-review 系単独由来の 🟡 は非 blocker
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
